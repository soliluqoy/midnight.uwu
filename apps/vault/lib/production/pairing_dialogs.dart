import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vault/production/connection_problem.dart';
import 'package:vault/production/pairing_code.dart';
import 'package:vault/production/pairing_join.dart';
import 'package:vault/production/vault_runtime.dart';
import 'package:vault_protocol/vault_protocol.dart' show PairingInvite;

int get _unixNow => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Shows this device's single-use pairing code until a phone introduces
/// itself, then asks once before adding it. Pops with the added contact.
class PairingHostDialog extends StatefulWidget {
  const new({required this.runtime, required this.invite, super.key});

  final VaultRuntime runtime;
  final PairingInvite invite;

  @override
  State<PairingHostDialog> createState() => _PairingHostDialogState();
}

class _PairingHostDialogState extends State<PairingHostDialog> {
  late PairingInvite _invite = widget.invite;
  late final Timer _tick;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.runtime,
    builder: (context, _) {
      final request = widget.runtime.pairingRequest;
      final remaining = _invite.expiresAt - _unixNow;
      return AlertDialog(
        title: Text(
          request == null ? 'Pair a phone' : '${request.name} wants to pair',
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (request != null) ...[
                  const Text('Their fingerprint:'),
                  const SizedBox(height: 4),
                  SelectableText(request.nodeId),
                  const SizedBox(height: 12),
                  const Text(
                    'Check that the phone shows the same fingerprint. Adding '
                    'this contact allows direct messages. It does not share '
                    'your library.',
                  ),
                ] else if (remaining > 0) ...[
                  Center(child: PairingCode(_invite.encode())),
                  const SizedBox(height: 12),
                  const Text(
                    'On your phone, open Midnight and choose Scan pairing '
                    'code.',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Works once. Expires in ${remaining ~/ 60}:'
                    '${(remaining % 60).toString().padLeft(2, '0')}. '
                    'This device: ${shortFingerprint(_invite.card.nodeId)}',
                  ),
                ] else
                  const Text('This code expired. Make a new one to continue.'),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: request != null
            ? [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          widget.runtime.endPairing();
                          Navigator.pop(context);
                        },
                  child: const Text('Decline'),
                ),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _act(() async {
                          await widget.runtime.approvePairing();
                          if (context.mounted) Navigator.pop(context, request);
                        }),
                  child: const Text('Add contact'),
                ),
              ]
            : [
                if (remaining > 0)
                  TextButton(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: _invite.encode()),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Copied. Anyone with this text can pair until '
                              'it expires, so send it only to your device.',
                            ),
                          ),
                        );
                      }
                    },
                    child: const Text('Copy code as text'),
                  )
                else
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _act(() async {
                            final next = await widget.runtime.startPairing();
                            if (mounted) setState(() => _invite = next);
                          }),
                    child: const Text('New code'),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
      );
    },
  );
}

/// Shows a scanner's [PairingJoin] progress. Pops true to open the chat.
class PairingJoinDialog extends StatelessWidget {
  const new({required this.join, required this.ownNodeId, super.key});

  final PairingJoin join;
  final String ownNodeId;

  static const List<(PairingStep, String)> _steps = [
    (PairingStep.configuring, 'Set up connection'),
    (PairingStep.introducing, 'Introduce this phone'),
    (PairingStep.waitingForApproval, 'Wait for approval'),
    (PairingStep.connecting, 'Connect directly'),
  ];

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: join,
    builder: (context, progress, _) {
      final host = join.invite.card.name;
      final reached = switch (progress) {
        PairingUnderway(:final step) => step.index,
        PairingConnected() => PairingStep.values.length,
        PairingFailed() => -1,
      };
      return AlertDialog(
        title: Text(switch (progress) {
          PairingUnderway() => 'Pairing with $host',
          PairingConnected() => 'Connected to $host',
          PairingFailed() => 'Pairing did not finish',
        }),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (progress case PairingFailed(:final problem, :final detail))
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      [
                        if (problem != null)
                          problemCopy(problem, who: host).text,
                        ?detail,
                      ].join('\n\n'),
                    ),
                  )
                else ...[
                  for (final (step, label) in _steps)
                    ListTile(
                      key: ValueKey('pairing-step-${step.name}'),
                      contentPadding: EdgeInsets.zero,
                      leading: reached > step.index
                          ? const Icon(Icons.check_circle)
                          : reached == step.index
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.radio_button_unchecked),
                      title: Text(label),
                    ),
                  if (progress case PairingUnderway(
                    step: PairingStep.waitingForApproval,
                  ))
                    Text(
                      'On $host, choose Add contact. This phone’s '
                      'fingerprint ends in '
                      '${ownNodeId.substring(ownNodeId.length - 6)}.',
                    ),
                  if (progress is PairingConnected)
                    const Text(
                      'You can message each other now. Library access still '
                      'needs a separate request and approval.',
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (progress is PairingConnected)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Open chat'),
            )
          else
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(progress is PairingFailed ? 'Close' : 'Hide'),
            ),
        ],
      );
    },
  );
}

/// Explains what pairing with [invite] will do, for the confirm dialog.
String pairingConfirmText(
  PairingInvite invite, {
  required bool switchesBroker,
  required bool isInternetPreset,
}) {
  final card = invite.card;
  const adds =
      'Midnight will add this device as a contact so you can message each '
      'other directly. Pairing does not share either library.';
  const thirdParty =
      ', a free public service run by a third party with no availability '
      'guarantee';
  final broker =
      'Connection setup will use ${invite.brokerHost}:${invite.brokerPort}'
      '${isInternetPreset ? thirdParty : ''}. It passes only encrypted setup '
      'messages. Chats and media never go through it.';
  return [
    '${card.name}\n${card.nodeId}',
    adds,
    if (switchesBroker) broker,
  ].join('\n\n');
}
