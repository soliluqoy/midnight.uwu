import 'package:flutter/material.dart';

import 'package:vault_ui/src/components.dart';
import 'package:vault_ui/src/study_controller.dart';

/// Known people and independent identity, connection and access preview states.
class PeopleScreen extends StatelessWidget {
  /// Creates a people page without starting a network or authorization service.
  const new({
    required this.controller,
    required this.onAddPerson,
    required this.onVerify,
    required this.onConnect,
    required this.onDisconnect,
    required this.onReview,
    required this.onManageAccess,
    required this.onBrowse,
    required this.onManual,
    super.key,
  });

  /// Shared presentation state, not a production identity or grant store.
  final StudyController controller;

  /// Opens the explicit add-person flow.
  final VoidCallback onAddPerson;

  /// Opens manual identity comparison information.
  final VoidCallback onVerify;

  /// Opens the simulated connection flow.
  final VoidCallback onConnect;

  /// Deliberately disconnects the simulated session.
  final VoidCallback onDisconnect;

  /// Opens the owner's pending-request review.
  final VoidCallback onReview;

  /// Opens access details, including blocked-state explanations.
  final VoidCallback onManageAccess;

  /// Opens the approved library or its current unavailability explanation.
  final VoidCallback onBrowse;

  /// Explains manual connection without pretending to exchange signaling data.
  final VoidCallback onManual;

  bool get _hasPeer => controller.viewer || controller.contactName.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final person = _hasPeer ? _person(context) : _empty();
    final discovery = _discovery();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VaultPageHeader(
          eyebrow: 'A smaller circle, a better connection',
          title: 'Good company.',
          subtitle:
              'A contact is a person. A connection is a path. '
              'Access is a separate decision. These peer states are simulated.',
          action: FilledButton.icon(
            onPressed: onAddPerson,
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: const Text('Add person'),
          ),
        ),
        if (_hasPeer &&
            (controller.connection == StudyConnection.noRoute ||
                controller.connection == StudyConnection.interrupted ||
                controller.connection == StudyConnection.disconnected)) ...[
          _connectionNotice(),
          const SizedBox(height: 20),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 1000 &&
                MediaQuery.textScalerOf(context).scale(1) <= 1.3) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: person),
                  const SizedBox(width: 24),
                  Expanded(flex: 2, child: discovery),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [person, const SizedBox(height: 20), discovery],
            );
          },
        ),
        const PrivacyFooter(),
      ],
    );
  }

  Widget _empty() => InfoStrip(
    title: 'Your circle starts here',
    message:
        'No person has been added. Your local library stays separate. '
        'Adding a contact does not connect to them, verify their identity '
        'or grant access to media.',
    icon: Icons.people_outline,
    action: OutlinedButton(
      onPressed: onAddPerson,
      child: const Text('Add your first person'),
    ),
  );

  Widget _person(BuildContext context) {
    final peer = controller.peerName;
    final initials = peer
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => String.fromCharCode(part.runes.first))
        .join()
        .toUpperCase();
    return SectionCard(
      title: 'Known locally · study contact',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: CircleAvatar(
                  radius: 25,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .secondaryContainer,
                  child: Text(initials),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(peer, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    const Text('Local label · simulated identity'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StateChip(
                controller.verified
                    ? 'Identity · compared'
                    : 'Identity · unverified',
                tone: controller.verified
                    ? StatusTone.positive
                    : StatusTone.neutral,
                icon: Icons.fingerprint,
              ),
              StateChip(
                'Connection · ${_connectionLabel()}',
                tone: controller.connection == StudyConnection.connected
                    ? StatusTone.positive
                    : StatusTone.neutral,
                icon: Icons.link,
              ),
              StateChip(
                'Access · ${_accessLabel()}',
                tone: switch (controller.access) {
                  StudyAccess.approved => StatusTone.positive,
                  StudyAccess.pending => StatusTone.attention,
                  StudyAccess.blocked ||
                  StudyAccess.revoked => StatusTone.negative,
                  _ => StatusTone.neutral,
                },
                icon: Icons.lock_outline,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _primaryAction(),
              OutlinedButton(
                onPressed: onVerify,
                child: Text(
                  controller.verified ? 'View comparison' : 'Compare identity',
                ),
              ),
              if (controller.connection == StudyConnection.connected)
                OutlinedButton(
                  onPressed: onDisconnect,
                  child: const Text('Disconnect'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Identity and access details'),
            children: [
              const Text(
                'A name or avatar is not proof of identity. Comparing '
                'identity grants no access. This preview creates no keys.',
              ),
              const SizedBox(height: 12),
              Text(_accessExplanation()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _primaryAction() {
    if (controller.access == StudyAccess.blocked) {
      return FilledButton(
        onPressed: onManageAccess,
        child: const Text('Manage'),
      );
    }
    if (controller.connection != StudyConnection.connected) {
      return FilledButton(onPressed: onConnect, child: const Text('Connect'));
    }
    if (!controller.viewer) {
      return FilledButton(
        onPressed: controller.access == StudyAccess.pending
            ? onReview
            : onManageAccess,
        child: Text(
          controller.access == StudyAccess.pending ? 'Review' : 'Manage',
        ),
      );
    }
    if (controller.access == StudyAccess.approved) {
      return FilledButton(onPressed: onBrowse, child: const Text('Browse'));
    }
    if (controller.access == StudyAccess.pending) {
      return OutlinedButton(
        onPressed: onManageAccess,
        child: const Text('Request details'),
      );
    }
    return FilledButton(
      onPressed: () {
        if (controller.connection != StudyConnection.connected ||
            controller.access == StudyAccess.blocked ||
            controller.access == StudyAccess.pending ||
            controller.access == StudyAccess.approved) {
          return;
        }
        controller.change(() => controller.access = StudyAccess.pending);
      },
      child: const Text('Request access'),
    );
  }

  Widget _connectionNotice() {
    final (title, message) = switch (controller.connection) {
      StudyConnection.noRoute => (
        'Simulated · no direct route',
        'A direct connection could not be established in this walkthrough. '
            'Coordinate with the other person and try again, or consider '
            'a different permitted network. Manual exchange cannot guarantee '
            'a route. No cloud media fallback is implemented.',
      ),
      StudyConnection.interrupted => (
        'Simulated · connection interrupted',
        'The simulated session stopped unexpectedly. New peer bytes are '
            'unavailable; local files and completed saved copies are separate. '
            'Connect deliberately to continue the walkthrough.',
      ),
      _ => (
        'Simulated · disconnected by you',
        'This session stays disconnected until you choose Connect. '
            'Disconnecting is not revoking access and does not remove '
            'already saved copies.',
      ),
    };
    return InfoStrip(title: title, message: message);
  }

  Widget _discovery() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const InfoStrip(
        title: 'A directory, not the whole world',
        message:
            'Public discovery is optional and bounded to a chosen '
            'directory. Results would be partial, never a global search '
            'or a list of everyone nearby. This native preview does not '
            'query a directory or show invented results. No private '
            'filenames, paths or thumbnails are exposed here. Viewing '
            'discovery would not list your own profile.',
        icon: Icons.explore_outlined,
      ),
      const SizedBox(height: 20),
      InfoStrip(
        title: 'Already in touch?',
        message:
            'Manual connection would exchange complete offer and '
            'answer data through a channel you choose. A short identity '
            'code is not that exchange. Here you can read how it differs '
            'from adding a person; no signaling is sent.',
        icon: Icons.swap_horiz,
        action: OutlinedButton(
          onPressed: onManual,
          child: const Text('About manual connection'),
        ),
      ),
    ],
  );

  String _connectionLabel() => switch (controller.connection) {
    StudyConnection.idle => 'not connected',
    StudyConnection.connected => 'connected',
    StudyConnection.interrupted => 'interrupted',
    StudyConnection.disconnected => 'disconnected by you',
    StudyConnection.noRoute => 'no direct route',
  };

  String _accessLabel() => switch (controller.access) {
    StudyAccess.none => 'not requested',
    StudyAccess.pending => 'request pending',
    StudyAccess.approved => 'approved',
    StudyAccess.denied => 'request denied',
    StudyAccess.revoked => 'access revoked',
    StudyAccess.blocked => 'blocked',
  };

  String _accessExplanation() => switch (controller.access) {
    StudyAccess.none =>
      controller.viewer
          ? 'Connect, then deliberately request access. No private media '
                'is shown before approval.'
          : 'No request is waiting. Connecting alone '
                'does not share your media.',
    StudyAccess.pending =>
      controller.viewer
          ? 'Your simulated request is waiting for Alex. It stays pending '
                'without sending repeated prompts. No private media is shown.'
          : 'This person is waiting for your decision. Review identity and '
                'the exact sample scope before approving.',
    StudyAccess.approved =>
      controller.viewer
          ? 'Approval is separate from availability. Browse can explain '
                'an unpublished library, disconnected session or unavailable '
                'source without exposing private media.'
          : 'The sample approval covers Alpine days, with browsing and '
                'saving. Manage access separately from this connection.',
    StudyAccess.denied =>
      controller.viewer
          ? 'The owner declined. A new simulated request is a deliberate '
                'action, available only while connected.'
          : 'The request was declined. No media access is approved.',
    StudyAccess.revoked =>
      'Future access has ended in the simulation. '
          'Previously received or saved copies cannot be recalled. '
          'A fresh request does not restore an old grant.',
    StudyAccess.blocked =>
      'Further requests are blocked in this simulation. '
          'Manage explains the restriction; connecting does not bypass it. '
          'Blocking is not deletion of someone else’s copies.',
  };
}
