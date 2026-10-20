import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vault/production/connection_problem.dart';
import 'package:vault/production/messenger_service.dart';
import 'package:vault/production/vault_runtime.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/vault_net.dart';

/// Bounded chat workspace, kept mounted across destinations to retain drafts.
class MessengerPane extends StatefulWidget {
  const new({
    required this.runtime,
    required this.active,
    required this.selectedPeerId,
    required this.onSelectPeer,
    required this.onAddPerson,
    required this.onShareContact,
    required this.onConnectionSetup,
    required this.onContactDetails,
    required this.onPair,
    required this.onConnectOverInternet,
    required this.onShowPairingCode,
    required this.onScanPairingCode,
    this.utilityActions,
    super.key,
  });

  final VaultRuntime runtime;
  final bool active;
  final String? selectedPeerId;
  final ValueChanged<String?> onSelectPeer;
  final Future<void> Function() onAddPerson;
  final Future<void> Function() onShareContact;
  final VoidCallback onConnectionSetup;
  final ValueChanged<ContactCard> onContactDetails;

  /// Starts pairing, given the ignored noncontact sender when there is one.
  final ValueChanged<String?> onPair;

  /// Offers the public broker preset from the first-run empty state.
  final VoidCallback onConnectOverInternet;
  final VoidCallback onShowPairingCode;
  final VoidCallback onScanPairingCode;
  final Widget? utilityActions;

  @override
  State<MessengerPane> createState() => _MessengerPaneState();
}

class _MessengerPaneState extends State<MessengerPane> {
  final _drafts = <String, TextEditingController>{};
  final _errors = <String, String>{};
  final _busy = <String>{};
  final _timelines = <String, _ConversationScrollController>{};
  final _timelineAnchors = <String, String>{};
  final _newMessages = <String>{};
  final _composerFocus = <String, FocusNode>{};
  final GlobalKey<State<StatefulWidget>> _conversationKey = GlobalKey();
  final _search = TextEditingController();
  String _query = '';
  String? _actionError;
  bool _readScheduled = false;

  VaultRuntime get r => widget.runtime;

  @override
  void dispose() {
    for (final controller in _drafts.values) {
      controller.dispose();
    }
    for (final controller in _timelines.values) {
      controller.dispose();
    }
    for (final focus in _composerFocus.values) {
      focus.dispose();
    }
    _search.dispose();
    super.dispose();
  }

  Future<void> _action(String key, Future<void> Function() action) async {
    if (_busy.contains(key)) return;
    setState(() {
      _busy.add(key);
      _actionError = null;
    });
    try {
      await action();
    } on ConnectionProblemException {
      // The runtime records it; the conversation shows it with its remedy.
    } on Object catch (error) {
      if (mounted) setState(() => _actionError = '$error');
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  void _markRead(String peerId) {
    if (!widget.active ||
        r.messenger.unreadCount(peerId) == 0 ||
        _readScheduled) {
      return;
    }
    _readScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _readScheduled = false;
      final currentPeerId = widget.selectedPeerId;
      if (mounted &&
          widget.active &&
          currentPeerId != null &&
          r.messenger.unreadCount(currentPeerId) > 0) {
        r.messenger.markRead(currentPeerId);
      }
    });
  }

  void _scrollToLatest([String? peerId]) {
    final id = peerId ?? widget.selectedPeerId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || id == null) return;
      final timeline = _timelines[id];
      if (timeline == null || !timeline.hasClients) return;
      final latest = timeline.position.minScrollExtent;
      if (MediaQuery.disableAnimationsOf(context)) {
        timeline.jumpTo(latest);
      } else {
        timeline.animateTo(
          latest,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
      if (_newMessages.remove(id)) setState(() {});
    });
  }

  Future<void> _send(ContactCard contact) async {
    final peerId = contact.nodeId;
    final controller = _drafts[peerId]!;
    final text = controller.text;
    final session = r.sessions[peerId];
    if (_busy.contains('send-$peerId')) return;
    if (text.trim().isEmpty) return;
    if (utf8.encode(text).length > MessengerService.maxTextBytes) {
      setState(
        () => _errors[peerId] =
            'Message exceeds 4096 UTF-8 bytes. Shorten it before sending.',
      );
      return;
    }
    if (session == null || session.state != PeerSessionState.connected) {
      setState(
        () => _errors[peerId] =
            'Connect to this person before sending. Your draft is kept.',
      );
      return;
    }
    setState(() {
      _busy.add('send-$peerId');
      _errors.remove(peerId);
    });
    try {
      await r.messenger.send(session, text);
      if (!mounted) return;
      // Do not erase text typed while this operation was in progress.
      if (controller.text == text) controller.clear();
      _scrollToLatest(peerId);
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _errors[peerId] =
              'Message not confirmed: $error. Your draft is kept; '
              'if it appears below, use Retry to resend the same message.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove('send-$peerId'));
    }
  }

  String _state(PeerSession? session) => switch (session?.state) {
    PeerSessionState.negotiating => 'Connecting…',
    PeerSessionState.authenticating => 'Authenticating direct session…',
    PeerSessionState.connected => 'Direct session connected',
    PeerSessionState.failed => 'Connection failed',
    PeerSessionState.closed || null => 'Not connected',
  };

  Widget _avatar(String name) => CircleAvatar(
    child: Text(
      name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    ContactCard? selected;
    for (final contact in r.contacts) {
      if (contact.nodeId == widget.selectedPeerId) selected = contact;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final split = constraints.maxWidth >= 760 * textScale.clamp(1, 1.6);
        final list = _contactList(showUtilities: selected == null);
        final conversation = selected == null
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Choose a person to start a conversation.\n'
                    'Both apps must be online and directly reachable.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : KeyedSubtree(
                key: _conversationKey,
                child: _conversation(selected, showBack: !split),
              );
        if (!split) return selected == null ? list : conversation;
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 300 * textScale.clamp(1, 1.3), child: list),
              const VerticalDivider(width: 1),
              Expanded(child: conversation),
            ],
          ),
        );
      },
    );
  }

  Widget _contactList({required bool showUtilities}) {
    final query = _query.trim().toLowerCase();
    final contacts =
        r.contacts
            .where(
              (contact) =>
                  contact.name.toLowerCase().contains(query) ||
                  contact.nodeId.toLowerCase().contains(query),
            )
            .toList()
          ..sort((a, b) {
            final aMessages = r.messenger.messages(a.nodeId);
            final bMessages = r.messenger.messages(b.nodeId);
            if (aMessages.isEmpty && bMessages.isEmpty) {
              return a.name.toLowerCase().compareTo(b.name.toLowerCase());
            }
            if (aMessages.isEmpty) return 1;
            if (bMessages.isEmpty) return -1;
            return bMessages.last.sentAt.compareTo(aMessages.last.sentAt);
          });
    final queued = r.manual?.pendingExports.length ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: CustomScrollView(
            key: const PageStorageKey('chat-contacts'),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          Text(
                            'Chats',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          if (showUtilities && widget.utilityActions != null)
                            widget.utilityActions!,
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            key: const ValueKey('pair-primary'),
                            onPressed: Platform.isAndroid
                                ? widget.onScanPairingCode
                                : widget.onShowPairingCode,
                            icon: Icon(
                              Platform.isAndroid
                                  ? Icons.qr_code_scanner
                                  : Icons.qr_code,
                            ),
                            label: Text(
                              Platform.isAndroid
                                  ? 'Scan pairing code'
                                  : 'Pair a phone',
                            ),
                          ),
                          OutlinedButton(
                            onPressed: Platform.isAndroid
                                ? widget.onShowPairingCode
                                : widget.onScanPairingCode,
                            child: Text(
                              Platform.isAndroid
                                  ? 'Show pairing code'
                                  : 'Enter pairing code',
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _busy.contains('add')
                                ? null
                                : () => _action('add', widget.onAddPerson),
                            icon: const Icon(Icons.person_add_alt_1_outlined),
                            label: const Text('Add person'),
                          ),
                          TextButton(
                            onPressed: _busy.contains('share')
                                ? null
                                : () => _action('share', widget.onShareContact),
                            child: const Text('Share my contact'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _search,
                        onChanged: (value) => setState(() => _query = value),
                        decoration: const InputDecoration(
                          labelText: 'Search contacts',
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // A selected conversation owns its contextual notice.
                      // Queue entries cannot reliably be attributed to a peer.
                      if (widget.selectedPeerId == null) ...[
                        if (r.signalingProblem case final problem?)
                          ConnectionProblemNotice(
                            problem: problem,
                            who: 'other devices',
                            busy: _busy.contains('start'),
                            onAction: (_) => _action('start', r.start),
                          ),
                        if (r.unknownSenders.keys.lastOrNull case final sender?)
                          ConnectionProblemNotice(
                            problem: ConnectionProblem.notAContact,
                            who: shortFingerprint(sender),
                            onAction: (_) => widget.onPair(sender),
                            onDismiss: () => r.dismissUnknownSender(sender),
                          ),
                        if (r.messengerError != null)
                          _notice(
                            'Message storage or delivery: ${r.messengerError}',
                            important: true,
                          )
                        else if (r.transportError != null &&
                            r.signalingProblem == null)
                          _notice(r.transportError!, important: true)
                        else if (queued > 0 && r.contacts.isNotEmpty)
                          _notice(
                            '$queued connection frame(s) waiting. Open setup '
                            'to exchange connection information.',
                          ),
                        if (_actionError != null)
                          _notice(_actionError!, important: true),
                        if (queued > 0 && r.contacts.isNotEmpty)
                          TextButton.icon(
                            onPressed: widget.onConnectionSetup,
                            icon: const Icon(Icons.settings_ethernet),
                            label: Text('Connection setup ($queued)'),
                          ),
                      ],
                      if (r.contacts.isEmpty) ...[
                        const SizedBox(height: 24),
                        const Icon(Icons.chat_bubble_outline, size: 48),
                        const SizedBox(height: 12),
                        const Text(
                          'Your people. Your media. Your choice.',
                          textAlign: TextAlign.center,
                        ),
                        if (!r.config.usesInternetPreset) ...[
                          const SizedBox(height: 16),
                          Center(
                            child: FilledButton.icon(
                              key: const ValueKey('first-run-internet'),
                              onPressed: widget.onConnectOverInternet,
                              icon: const Icon(Icons.public),
                              label: const Text('Connect over the internet'),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Uses a free third-party service only to pass '
                            'encrypted setup messages. Or use manual exchange '
                            'in Connection setup.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                        const SizedBox(height: 16),
                        const Text(
                          'To add someone, choose Pair a phone on one device '
                          'and Scan pairing code on the other. Or exchange '
                          'public contacts by hand, compare the complete '
                          'fingerprints, then Add person.\n\n'
                          'Your identity stays on this device. Both apps must '
                          'be running and directly reachable for new messages.',
                          textAlign: TextAlign.center,
                        ),
                      ] else if (contacts.isEmpty) ...[
                        const SizedBox(height: 24),
                        const Text(
                          'No contacts match this search. '
                          'Your saved conversations have not been removed.',
                        ),
                        TextButton(
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                          child: const Text('Clear search'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: contacts.length,
                itemBuilder: (context, index) => _contactRow(contacts[index]),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _contactRow(ContactCard contact) {
    final messages = r.messenger.messages(contact.nodeId);
    final last = messages.isEmpty ? null : messages.last;
    final unread = r.messenger.unreadCount(contact.nodeId);
    final draft = _drafts.putIfAbsent(
      contact.nodeId,
      TextEditingController.new,
    );
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: draft,
      builder: (context, value, _) => ListTile(
        selected: widget.selectedPeerId == contact.nodeId,
        leading: _avatar(contact.name),
        title: Text(contact.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value.text.isNotEmpty
                  ? 'Draft: ${value.text}'
                  : last == null
                  ? 'No messages yet'
                  : '${last.outgoing ? 'You: ' : ''}${last.text}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              _state(r.sessions[contact.nodeId]),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        trailing: last == null && unread == 0
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (last != null)
                    Text(
                      _shortTime(last.sentAt),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  if (unread > 0)
                    Semantics(
                      label: '$unread unread messages',
                      child: Badge(label: Text('$unread')),
                    ),
                ],
              ),
        onTap: () => widget.onSelectPeer(contact.nodeId),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    );
  }

  String _shortTime(DateTime sentAt) {
    final local = sentAt.toLocal();
    final now = DateTime.now();
    if (local.year != now.year ||
        local.month != now.month ||
        local.day != now.day) {
      return MaterialLocalizations.of(context).formatShortDate(local);
    }
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }

  Widget _notice(String text, {bool important = false}) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: important
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: important
            ? Theme.of(context).colorScheme.onErrorContainer
            : null,
      ),
    ),
  );

  Widget _conversation(ContactCard contact, {required bool showBack}) {
    final peerId = contact.nodeId;
    _markRead(peerId);
    final session = r.sessions[peerId];
    final connected = session?.state == PeerSessionState.connected;
    final active =
        session != null &&
        session.state != PeerSessionState.closed &&
        session.state != PeerSessionState.failed;
    final messages = r.messenger.messages(peerId);
    final draft = _drafts.putIfAbsent(peerId, TextEditingController.new);
    final focus = _composerFocus.putIfAbsent(peerId, FocusNode.new);
    final timeline = _timelines.putIfAbsent(
      peerId,
      _ConversationScrollController.new,
    );
    if (messages.isNotEmpty) {
      _timelineAnchors.putIfAbsent(peerId, () => messages.last.id);
    }
    final queued = r.manual?.pendingExports.length ?? 0;
    final problem = r.problemFor(peerId);
    final failure =
        _actionError ??
        r.messengerError ??
        (problem == null ? session?.failureReason ?? r.transportError : null);
    final notice =
        failure ??
        (queued > 0
            ? 'Exchange connection information to finish connecting. '
                  'The complete setup queue has $queued frame(s), which may '
                  'belong to different connections. '
                  'Send frames and import replies.'
            : !connected
            ? active
                  ? 'Connecting. Keep both apps running '
                        'and directly reachable. '
                        'Your draft stays here; it will not send automatically.'
                  : 'Connect to send. Both apps must be running and directly '
                        'reachable. Drafts stay here and '
                        'never send automatically.'
            : null);
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * .34),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.utilityActions case final actions?)
                      Align(alignment: Alignment.centerRight, child: actions),
                    Row(
                      children: [
                        if (showBack)
                          IconButton(
                            tooltip: 'Back to chats',
                            onPressed: () => widget.onSelectPeer(null),
                            icon: const Icon(Icons.arrow_back),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                contact.name,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              Text(
                                _state(session),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Contact details and fingerprint',
                          onPressed: () => widget.onContactDetails(contact),
                          icon: const Icon(Icons.info_outline),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        TextButton(
                          onPressed: _busy.contains('connect-$peerId')
                              ? null
                              : () => _action('connect-$peerId', () async {
                                  if (active) {
                                    await r.disconnect(session);
                                  } else {
                                    await r.connect(contact);
                                    if (mounted &&
                                        widget.active &&
                                        widget.selectedPeerId == peerId &&
                                        (r.manual?.pendingExports.isNotEmpty ??
                                            false)) {
                                      widget.onConnectionSetup();
                                    }
                                  }
                                }),
                          child: Text(active ? 'Disconnect' : 'Connect'),
                        ),
                        if (queued > 0 ||
                            (!connected && (active || failure != null)))
                          TextButton.icon(
                            onPressed: widget.onConnectionSetup,
                            icon: const Icon(Icons.settings_ethernet),
                            label: Text(
                              queued > 0
                                  ? 'Connection setup ($queued)'
                                  : 'Connection setup',
                            ),
                          ),
                      ],
                    ),
                    if (problem != null)
                      ConnectionProblemNotice(
                        problem: problem,
                        who: contact.name,
                        busy: _busy.contains('connect-$peerId'),
                        onAction: (_) => _action(
                          'connect-$peerId',
                          () => r.connect(contact),
                        ),
                        onDismiss: problem == ConnectionProblem.youDisconnected
                            ? () => r.dismissBlockedOffer(peerId)
                            : null,
                      ),
                    if (notice != null && (problem == null || failure != null))
                      _notice(notice, important: failure != null),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _MessageTimeline(
                  key: ValueKey(peerId),
                  peerId: peerId,
                  anchorId: _timelineAnchors[peerId],
                  messages: messages,
                  controller: timeline,
                  onNewMessages: () {
                    if (mounted && !_newMessages.contains(peerId)) {
                      setState(() => _newMessages.add(peerId));
                    }
                  },
                  onAtLatest: () {
                    if (mounted && _newMessages.contains(peerId)) {
                      setState(() => _newMessages.remove(peerId));
                    }
                  },
                  scrollToLatest: () => _scrollToLatest(peerId),
                  itemBuilder: (message) =>
                      _bubble(message, session, connected),
                ),
                if (_newMessages.contains(peerId))
                  Positioned(
                    bottom: 8,
                    left: 12,
                    right: 12,
                    child: Align(
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                        ),
                        onPressed: () => _scrollToLatest(peerId),
                        icon: const Icon(Icons.arrow_downward),
                        label: const Text('New messages · Jump to latest'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * .42),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: draft,
                  builder: (context, value, _) {
                    final bytes = utf8.encode(value.text).length;
                    final tooLong = bytes > MessengerService.maxTextBytes;
                    final sending = _busy.contains('send-$peerId');
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_errors[peerId] case final error?)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _notice(error, important: true),
                          ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: TextField(
                                key: ValueKey('composer-$peerId'),
                                controller: draft,
                                focusNode: focus,
                                minLines: 1,
                                maxLines: constraints.maxHeight < 400 ? 2 : 4,
                                keyboardType: TextInputType.multiline,
                                textInputAction: TextInputAction.newline,
                                decoration: InputDecoration(
                                  labelText: 'Message ${contact.name}',
                                  hintText: connected
                                      ? 'Write a message'
                                      : 'Draft kept on this device',
                                  helperText:
                                      bytes >= 3584 ||
                                          _errors.containsKey(peerId)
                                      ? '$bytes / 4096 UTF-8 bytes'
                                      : null,
                                  errorText: tooLong
                                      ? '$bytes / 4096 UTF-8 bytes. Shorten this message.'
                                      : null,
                                  suffixIcon: IconButton(
                                    tooltip: 'Message limit: 4096 UTF-8 bytes',
                                    onPressed: _messageHelp,
                                    icon: const Icon(
                                      Icons.help_outline,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: IconButton.filled(
                                tooltip: sending
                                    ? 'Sending message'
                                    : 'Send message',
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                onPressed:
                                    !connected ||
                                        tooLong ||
                                        value.text.trim().isEmpty ||
                                        sending
                                    ? null
                                    : () => _send(contact),
                                icon: Icon(
                                  sending ? Icons.more_horiz : Icons.send,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _messageHelp() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('About messages'),
      content: const SingleChildScrollView(
        child: Text(
          'Each message can contain up to 4096 UTF-8 bytes, not characters. '
          'Some characters use more than one byte.\n\n'
          'Both apps must be running and directly reachable. '
          'Drafts are kept in this app session, '
          'not queued for automatic sending.\n\n'
          'Delivered means saved by their app, not read by the person. '
          'An unconfirmed message may have arrived. Retry deliberately resends '
          'the original message using the same ID.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  Widget _bubble(ChatMessage message, PeerSession? session, bool connected) {
    final local = message.sentAt.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final timestamp =
        '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
    final status = switch (message.status) {
      MessageStatus.sending => 'Sending…',
      MessageStatus.delivered => 'Delivered',
      MessageStatus.unconfirmed => 'Unconfirmed · May have arrived',
      MessageStatus.received => 'Received',
    };
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: message.outgoing
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: message.outgoing
                ? colors.primaryContainer
                : colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                message.text,
                style: TextStyle(
                  color: message.outgoing
                      ? colors.onPrimaryContainer
                      : colors.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Semantics(
                label: 'Sender time $timestamp. $status. Message details',
                button: true,
                child: InkWell(
                  onTap: () => _messageDetails(message, timestamp, status),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      widthFactor: 1,
                      child: Text(
                        '${_shortTime(message.sentAt)} · $status',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ),
                ),
              ),
              if (message.outgoing &&
                  message.status == MessageStatus.unconfirmed) ...[
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: !connected || _busy.contains('retry-${message.id}')
                      ? null
                      : () => _action(
                          'retry-${message.id}',
                          () => r.messenger.retry(session!, message.id),
                        ),
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    _busy.contains('retry-${message.id}')
                        ? 'Retrying…'
                        : 'Retry',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _messageDetails(
    ChatMessage message,
    String timestamp,
    String status,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Message details'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sender time: $timestamp\n$status'),
            const SizedBox(height: 12),
            Text(switch (message.status) {
              MessageStatus.sending =>
                'Waiting for the recipient app to confirm storage.',
              MessageStatus.delivered =>
                'Saved by their app, not read by the person.',
              MessageStatus.unconfirmed =>
                'This message may have arrived. Retry uses the same message ID '
                    'to avoid duplicate copies. Reconnecting '
                    'does not retry it automatically.',
              MessageStatus.received => 'Received and saved on this device.',
            }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Retains a person's history offset when their scrollable leaves the tree.
/// PageStorage alone can restore a stale offset after switching conversations.
class _ConversationScrollController extends ScrollController {
  double _savedOffset = 0;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => ScrollPositionWithSingleContext(
    physics: physics,
    context: context,
    initialPixels: _savedOffset,
    keepScrollOffset: false,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );

  @override
  void detach(ScrollPosition position) {
    if (position.hasPixels) {
      _savedOffset = position.pixels;
    }
    super.detach(position);
  }
}

/// A stable center anchors existing history while newer messages grow below it.
/// Unlike prepending to a reversed list, arrival does not move older content.
class _MessageTimeline extends StatefulWidget {
  const new({
    required this.peerId,
    required this.anchorId,
    required this.messages,
    required this.controller,
    required this.onNewMessages,
    required this.onAtLatest,
    required this.scrollToLatest,
    required this.itemBuilder,
    super.key,
  });

  final String peerId;
  final String? anchorId;
  final List<ChatMessage> messages;
  final ScrollController controller;
  final VoidCallback onNewMessages;
  final VoidCallback onAtLatest;
  final VoidCallback scrollToLatest;
  final Widget Function(ChatMessage) itemBuilder;

  @override
  State<_MessageTimeline> createState() => _MessageTimelineState();
}

class _MessageTimelineState extends State<_MessageTimeline> {
  static const ValueKey<String> _center = ValueKey('history-anchor');
  String? _lastId;

  @override
  void initState() {
    super.initState();
    _lastId = widget.messages.isEmpty ? null : widget.messages.last.id;
  }

  @override
  void didUpdateWidget(covariant _MessageTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    final lastId = widget.messages.isEmpty ? null : widget.messages.last.id;
    if (lastId != _lastId && lastId != null) {
      final nearLatest =
          !widget.controller.hasClients ||
          widget.controller.offset -
                  widget.controller.position.minScrollExtent <
              80;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (nearLatest) {
          widget.scrollToLatest();
        } else {
          widget.onNewMessages();
        }
      });
    }
    _lastId = lastId;
  }

  Widget _item(int index) {
    final message = widget.messages[index];
    return KeyedSubtree(
      key: ValueKey(message.id),
      child: widget.itemBuilder(message),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return const Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No messages yet.\nMessages are saved on this device. '
              'Delivered means the other app saved your message, '
              'not that it was read.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final found = widget.messages.indexWhere((m) => m.id == widget.anchorId);
    // Bounded history may eventually evict the original anchor.
    final pivot = found < 0 ? 0 : found;
    return NotificationListener<ScrollEndNotification>(
      onNotification: (_) {
        if (widget.controller.hasClients &&
            widget.controller.offset -
                    widget.controller.position.minScrollExtent <
                24) {
          widget.onAtLatest();
        }
        return false;
      },
      child: CustomScrollView(
        key: PageStorageKey('timeline-${widget.peerId}'),
        controller: widget.controller,
        reverse: true,
        center: _center,
        slivers: [
          SliverList.builder(
            itemCount: widget.messages.length - pivot - 1,
            itemBuilder: (context, index) => _item(pivot + 1 + index),
          ),
          SliverList.builder(
            key: _center,
            itemCount: pivot + 1,
            itemBuilder: (context, index) => _item(pivot - index),
          ),
        ],
      ),
    );
  }
}
