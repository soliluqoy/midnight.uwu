import 'package:flutter/material.dart';

import 'package:vault_ui/src/components.dart';
import 'package:vault_ui/src/study_controller.dart';

/// Durable access decisions, simulated sessions and actual local save records.
class ActivityScreen extends StatelessWidget {
  /// Creates the activity page without inventing transfers or measured rates.
  const new({
    required this.controller,
    required this.onReview,
    required this.onManageAccess,
    required this.onDisconnect,
    required this.onConnect,
    super.key,
  });

  /// Shared local preview state and completed native save records.
  final StudyController controller;

  /// Opens the owner's pending access request.
  final VoidCallback onReview;

  /// Opens approval, revocation or blocked-state details.
  final VoidCallback onManageAccess;

  /// Explicitly stops the simulated session.
  final VoidCallback onDisconnect;

  /// Opens the deliberate simulated connection flow.
  final VoidCallback onConnect;

  bool get _hasPeer => controller.viewer || controller.contactName.isNotEmpty;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const VaultPageHeader(
        eyebrow: 'The things happening between us',
        title: 'A little activity.',
        subtitle:
            'Requests, sessions and saved moments. Peer activity is '
            'simulated; saved-copy records below come from completed '
            'local exports in this app session.',
      ),
      if (controller.pendingRequest) ...[
        _request(context),
        const SizedBox(height: 20),
      ],
      LayoutBuilder(
        builder: (context, constraints) {
          final session = _session(context);
          final access = _access(context);
          if (constraints.maxWidth >= 1000 &&
              MediaQuery.textScalerOf(context).scale(1) <= 1.3) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: session),
                const SizedBox(width: 24),
                Expanded(child: access),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [session, const SizedBox(height: 20), access],
          );
        },
      ),
      const SizedBox(height: 20),
      _savedCopies(context),
      const PrivacyFooter(),
    ],
  );

  Widget _request(BuildContext context) => SectionCard(
    title: 'Needs your decision',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const StateChip(
          'Simulated · request pending',
          tone: StatusTone.attention,
          icon: Icons.person_outline,
        ),
        const SizedBox(height: 12),
        Text(
          '${controller.peerName} would like access',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          controller.verified
              ? 'You marked the illustrative identity as manually compared.'
              : 'The illustrative identity has not been manually compared.',
        ),
        const SizedBox(height: 8),
        const Text(
          'This request remains here until you decide, even if the '
          'simulated connection is interrupted. Review the identity, '
          'collection and permitted actions before approving. '
          'A connected state is not approval.',
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: onReview, child: const Text('Review')),
      ],
    ),
  );

  Widget _session(BuildContext context) {
    if (!_hasPeer) {
      return const InfoStrip(
        title: 'No peer session',
        message:
            'Add a person in People when you want to connect. '
            'No connections is a normal state. Local media needs no peer.',
        icon: Icons.link_off,
      );
    }
    final connected = controller.connection == StudyConnection.connected;
    return SectionCard(
      title: 'Session',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StateChip(
            'Simulated · ${_sessionLabel()}',
            tone: connected ? StatusTone.positive : StatusTone.neutral,
            icon: connected ? Icons.link : Icons.link_off,
          ),
          const SizedBox(height: 14),
          Text(
            controller.peerName,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            controller.viewer
                ? 'Illustrative direction: receiving from Alex → this viewer.'
                : 'Illustrative direction: this owner → '
                      '${controller.peerName}.',
          ),
          const SizedBox(height: 8),
          const Text(
            'No peer media is being transferred. No measured byte count, '
            'transfer rate or verified direct-path information is available '
            'in this native interface preview.',
          ),
          const SizedBox(height: 12),
          Text(_sessionExplanation()),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: connected ? onDisconnect : onConnect,
            child: Text(connected ? 'Disconnect' : 'Connect'),
          ),
        ],
      ),
    );
  }

  Widget _access(BuildContext context) {
    if (!_hasPeer) {
      return const InfoStrip(
        title: 'No access decisions yet',
        message:
            'Adding a person, comparing identity and connecting are '
            'separate from approving access. No private media is shown here.',
        icon: Icons.lock_outline,
      );
    }
    return SectionCard(
      title: controller.viewer ? 'Access from Alex' : 'Access you control',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StateChip(
            'Simulated · ${_accessLabel()}',
            tone: switch (controller.access) {
              StudyAccess.approved => StatusTone.positive,
              StudyAccess.pending => StatusTone.attention,
              StudyAccess.revoked || StudyAccess.blocked => StatusTone.negative,
              _ => StatusTone.neutral,
            },
            icon: Icons.lock_outline,
          ),
          const SizedBox(height: 14),
          Text(_accessDetails()),
          if (controller.access == StudyAccess.approved) ...[
            const SizedBox(height: 12),
            Text(
              'Alpine days · illustrative collection',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'Sample scope: browse and save. This is a presentation state, '
              'not a signed or owner-enforced capability.',
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'Disconnect stops a session; revocation stops future access. '
            'Neither can recall already received, captured or externally '
            'saved copies. This preview does not enforce production security.',
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: onManageAccess,
            child: Text(controller.viewer ? 'Access details' : 'Manage access'),
          ),
        ],
      ),
    );
  }

  Widget _savedCopies(BuildContext context) => SectionCard(
    title: 'Saved copies',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${controller.savedCopies.length} completed local '
          '${controller.savedCopies.length == 1 ? 'export' : 'exports'} '
          'recorded this app session',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        const Text(
          'These records are created only after an OS save completes. '
          'They are not a scan of your device, an active download queue '
          'or a promise that an external copy still exists at that location.',
        ),
        if (controller.savedCopies.isEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'No completed saves yet. Open a local item or an available '
            'approved sample item and choose Save a copy.',
          ),
        ],
        for (final copy in controller.savedCopies) ...[
          const SizedBox(height: 18),
          const Divider(),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.task_alt, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      copy.name,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    SelectableText(copy.destination),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );

  String _sessionLabel() => switch (controller.connection) {
    StudyConnection.idle => 'not connected',
    StudyConnection.connected => 'connected',
    StudyConnection.interrupted => 'interrupted',
    StudyConnection.disconnected => 'disconnected by you',
    StudyConnection.noRoute => 'no direct route',
  };

  String _sessionExplanation() => switch (controller.connection) {
    StudyConnection.idle =>
      'Connect deliberately to explore the simulated '
          'session. Your own local files remain available without it.',
    StudyConnection.connected =>
      'Disconnect is separate from changing '
          'approval. It leaves the simulated session stopped until you '
          'explicitly connect again.',
    StudyConnection.interrupted =>
      'The simulated session was interrupted. '
          'New remote bytes are unavailable. Connect can continue the '
          'walkthrough; no cloud fallback or automatic recovery is claimed.',
    StudyConnection.disconnected =>
      'You disconnected. No background '
          'reconnect should override that choice. Choose Connect explicitly '
          'when you want to continue.',
    StudyConnection.noRoute =>
      'A direct route was not established in the '
          'simulation. The cause is not known. Coordinate a retry or try '
          'a different permitted network; manual exchange cannot guarantee '
          'reachability.',
  };

  String _accessLabel() => switch (controller.access) {
    StudyAccess.none => 'not requested',
    StudyAccess.pending => 'pending',
    StudyAccess.approved => 'approved',
    StudyAccess.denied => 'denied',
    StudyAccess.revoked => 'revoked',
    StudyAccess.blocked => 'blocked',
  };

  String _accessDetails() => switch (controller.access) {
    StudyAccess.none =>
      'No sample access has been requested. A connection '
          'or identity comparison does not expose a private library.',
    StudyAccess.pending =>
      controller.viewer
          ? 'Your simulated request is waiting for Alex. No private media '
                'is visible before approval.'
          : 'The owner decision is still pending. Review it above; '
                'reconnecting does not approve it.',
    StudyAccess.approved =>
      controller.viewer
          ? 'Alex approved the sample scope. Availability still depends '
                'on publication, the session and source availability.'
          : 'You approved the sample scope for ${controller.peerName}. '
                'You can review or stop future access separately from '
                'disconnecting the session.',
    StudyAccess.denied =>
      'The simulated request was declined. No access '
          'was granted. Any new request must be deliberate.',
    StudyAccess.revoked =>
      'The simulated approval has ended. New protected '
          'content must not be fetched using that old approval. Existing '
          'copies are not remotely deleted.',
    StudyAccess.blocked =>
      'The simulated identity is blocked from further '
          'requests and access. Connecting is not a bypass; access details '
          'explain the restriction.',
  };
}
