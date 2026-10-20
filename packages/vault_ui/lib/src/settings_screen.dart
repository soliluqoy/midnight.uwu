import 'package:flutter/material.dart';

import 'package:vault_ui/src/components.dart';
import 'package:vault_ui/src/study_controller.dart';

/// Local appearance and explicitly illustrative sharing and resource controls.
class SettingsScreen extends StatelessWidget {
  /// Creates settings without claiming active network or backup services.
  const new({
    required this.controller,
    required this.onIdentity,
    required this.onPublication,
    required this.onListing,
    required this.onManageAccess,
    required this.onDiagnostics,
    super.key,
  });

  /// Current perspective's non-secret presentation state.
  final StudyController controller;

  /// Opens information about the current local illustrative identity.
  final VoidCallback onIdentity;

  /// Reviews own publication or confirms stopping it.
  final VoidCallback onPublication;

  /// Confirms changing the current perspective's public listing choice.
  final VoidCallback onListing;

  /// Opens the current owner's access rules or the viewer's access details.
  final VoidCallback onManageAccess;

  /// Starts an explicit native export of actual local preview diagnostics.
  final VoidCallback onDiagnostics;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const VaultPageHeader(
        eyebrow: 'Make yourself at home',
        title: 'On your terms.',
        subtitle:
            'A few clear controls. No account behind the curtain. '
            'This is a native interface preview, not production identity, '
            'authorization or peer delivery.',
      ),
      LayoutBuilder(
        builder: (context, constraints) {
          final personal = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _identity(context),
              const SizedBox(height: 20),
              _access(context),
              const SizedBox(height: 20),
              _diagnostics(),
            ],
          );
          final resources = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _publication(),
              const SizedBox(height: 20),
              _storage(context),
              const SizedBox(height: 20),
              _uplink(context),
              const SizedBox(height: 20),
              _availability(),
            ],
          );
          if (constraints.maxWidth >= 1000 &&
              MediaQuery.textScalerOf(context).scale(1) <= 1.3) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: personal),
                const SizedBox(width: 24),
                Expanded(child: resources),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [personal, const SizedBox(height: 20), resources],
          );
        },
      ),
      const PrivacyFooter(),
    ],
  );

  Widget _identity(BuildContext context) => SectionCard(
    title: 'Identity & appearance',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          controller.localName.isEmpty ? 'Local viewer' : controller.localName,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        StateChip(
          controller.viewer
              ? 'Simulated · viewer perspective'
              : 'Simulated · owner perspective',
          icon: Icons.person_outline,
        ),
        const SizedBox(height: 12),
        const Text(
          'This is your current local identity view, not the peer’s '
          'identity. The display label is not unique, and a device name '
          'is not a person. This preview creates no cryptographic keys, '
          'cloud account, recovery secret or identity synchronization.',
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: onIdentity,
          child: const Text('View local identity'),
        ),
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 16),
        Text('Dark appearance', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        const Text('Changes the local interface theme.'),
        Semantics(
          label: 'Dark appearance',
          child: Switch.adaptive(
            value: controller.dark,
            onChanged: (value) =>
                controller.change(() => controller.dark = value),
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
        ),
      ],
    ),
  );

  Widget _access(BuildContext context) => SectionCard(
    title: controller.viewer ? 'Access from Alex' : 'Your access rules',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (controller.viewer) ...[
          const Text(
            'Alex controls approval for Alex’s collection. Your local '
            'settings cannot remember approval on Alex’s behalf or '
            'grant you access. View the current simulated decision '
            'without changing an owner rule.',
          ),
        ] else if (controller.contactName.isEmpty) ...[
          const Text(
            'No contact-specific rule is configured. Add a person '
            'before reviewing a bounded approval. A name, comparison '
            'or connection is never approval by itself.',
          ),
        ] else ...[
          Text(
            'Remember a bounded sample approval',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'For ${controller.peerName} only · Alpine days sample '
            'collection · browse and save. This separately chosen '
            'owner-side preference is not all-library or forever access.',
          ),
          const SizedBox(height: 8),
          const Text(
            'The switch changes a remembered simulation preference only. '
            'It does not approve a pending request, create a capability '
            'or enforce a security rule.',
          ),
          Semantics(
            label:
                'Remember bounded sample approval for '
                '${controller.peerName}',
            child: Switch.adaptive(
              value: controller.rememberApproval,
              onChanged: (value) =>
                  controller.change(() => controller.rememberApproval = value),
              materialTapTargetSize: MaterialTapTargetSize.padded,
            ),
          ),
          StateChip(
            controller.rememberApproval
                ? 'Simulated · remembered rule selected'
                : 'Simulated · remembered rule off',
          ),
        ],
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: onManageAccess,
          child: Text(
            controller.viewer ? 'View access details' : 'Manage access',
          ),
        ),
      ],
    ),
  );

  Widget _publication() => SectionCard(
    title: 'Your publication & visibility',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StateChip(
          controller.publishing
              ? 'Simulated · own publication on'
              : 'Simulated · own publication stopped',
          tone: controller.publishing
              ? StatusTone.positive
              : StatusTone.neutral,
          icon: Icons.folder_shared_outlined,
        ),
        const SizedBox(height: 12),
        const Text(
          'This controls the current perspective’s own library, not '
          'the other person’s publication. Selecting local media is '
          'separate from publishing. Review scope and received-copy '
          'limits before starting. No peer media is served by this preview.',
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: onPublication,
          child: Text(
            controller.publishing ? 'Stop publishing' : 'Review publication',
          ),
        ),
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 16),
        const Text('Optional public listing'),
        const SizedBox(height: 8),
        const Text(
          'Public listing is separate from publication and approval. '
          'Review the proposed public metadata before changing this '
          'simulated choice. No directory is contacted. Turning a real '
          'listing off could not erase previously observed announcements.',
        ),
        Semantics(
          label: 'Simulated public listing; opens confirmation',
          child: Switch.adaptive(
            value: controller.publicListing,
            onChanged: (_) => onListing(),
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
        ),
        StateChip(
          controller.publicListing
              ? 'Simulated · listing selected'
              : 'Simulated · not publicly listed',
        ),
      ],
    ),
  );

  Widget _storage(BuildContext context) => SectionCard(
    title: 'Cache & saved copies',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${controller.cacheMb} MB illustrative cache',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'This is a demonstration counter, not a measurement of device '
          'storage or a real playback cache. Clear changes the counter '
          'to zero only. Originals, selected media and saved copies '
          'are untouched; no files are deleted.',
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: controller.cacheMb == 0
              ? null
              : () => controller.change(() => controller.cacheMb = 0),
          icon: const Icon(Icons.cleaning_services_outlined),
          label: Text(
            controller.cacheMb == 0
                ? 'Illustrative cache is clear'
                : 'Clear illustrative cache',
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '${controller.savedCopies.length} completed local '
          '${controller.savedCopies.length == 1 ? 'export' : 'exports'} '
          'recorded this app session. Activity lists the actual selected '
          'destinations. External saved files are not managed by this '
          'counter or recalled by revocation.',
        ),
      ],
    ),
  );

  Widget _uplink(BuildContext context) => SectionCard(
    title: 'Illustrative uplink preference',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${controller.uplinkMbps.toStringAsFixed(0)} Mbps',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'A local preview value only, not measured speed, an active '
          'bandwidth cap or a scheduler. Moving this control does not '
          'change device traffic or video quality.',
        ),
        const SizedBox(height: 8),
        Slider(
          value: controller.uplinkMbps,
          min: 1,
          max: 50,
          divisions: 49,
          label:
              '${controller.uplinkMbps.toStringAsFixed(0)} Mbps '
              '(illustrative)',
          semanticFormatterCallback: (value) =>
              '${value.toStringAsFixed(0)} megabits per second, '
              'illustrative preference',
          onChanged: (value) =>
              controller.change(() => controller.uplinkMbps = value),
        ),
        const Text('1–50 Mbps · demonstration range'),
      ],
    ),
  );

  Widget _diagnostics() => InfoStrip(
    title: 'Local diagnostics',
    message:
        'Export a local report about this preview only when you '
        'choose. This is not a peer connection test or proof of security. '
        'The native save flow lets you choose the destination; no '
        'diagnostic upload runs in the background.',
    icon: Icons.description_outlined,
    action: OutlinedButton.icon(
      onPressed: onDiagnostics,
      icon: const Icon(Icons.file_download_outlined),
      label: const Text('Export local diagnostics'),
    ),
  );

  Widget _availability() => const InfoStrip(
    title: 'Availability needs an available owner',
    message:
        'A future Windows owner would need an explicitly implemented '
        'tray/background lifecycle; closing this preview does not promise '
        'continued sharing. Android may pause or end app execution, and '
        'continued serving would require a supported lifecycle and '
        'visible user control. Neither platform runs a peer service in '
        'this build. There is no cloud media fallback. Your own local '
        'files and completed saved copies are separate from peer '
        'availability.',
    icon: Icons.devices_outlined,
  );
}
