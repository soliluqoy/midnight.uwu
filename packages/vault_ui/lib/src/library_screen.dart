import 'package:flutter/material.dart';

import 'package:vault_ui/src/components.dart';
import 'package:vault_ui/src/study_controller.dart';

/// Local media browsing and the explicitly simulated approved-library detail.
class LibraryScreen extends StatelessWidget {
  /// Creates library content for the app's padded, scrollable content area.
  const new({
    required this.controller,
    required this.onAddMedia,
    required this.onPublication,
    required this.onPeople,
    required this.onOpenMedia,
    required this.onBack,
    super.key,
  });

  /// Presentation state; remote metadata is available only while readable.
  final StudyController controller;

  /// Opens the native media picker without publishing the selected media.
  final VoidCallback onAddMedia;

  /// Opens the app's publication review.
  final VoidCallback onPublication;

  /// Opens People, where connection and access actions belong.
  final VoidCallback onPeople;

  /// Opens the app's native photo viewer or video player.
  final ValueChanged<LibraryItem> onOpenMedia;

  /// Leaves the remote-library detail.
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    if (controller.browsingRemote && !controller.remoteReadable) {
      return _unreadableRemote(context);
    }

    final remote = controller.browsingRemote;
    final items = controller.visibleItems;
    final ownEmpty = !remote && controller.localItems.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (remote) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back to People'),
            ),
          ),
          const SizedBox(height: 20),
        ],
        VaultPageHeader(
          eyebrow: remote
              ? 'Shared with you · simulation'
              : 'A place for what matters',
          title: remote
              ? '${controller.peerName}’s library.'
              : 'Your life. Your library.',
          subtitle: remote
              ? 'Alpine days · the approved sample collection only.'
              : 'Your selected media, close to home. '
                    'Adding files does not publish them.',
          action: remote
              ? null
              : FilledButton.icon(
                  onPressed: onAddMedia,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('Add media'),
                ),
        ),
        if (remote)
          const InfoStrip(
            title: 'Approved sample scope · Alpine days',
            message:
                'These bundled examples illustrate approved browsing. '
                'Search covers this loaded collection only. No peer connection '
                'or media transfer is running.',
            icon: Icons.verified_user_outlined,
          )
        else
          _publicationSummary(),
        const SizedBox(height: 24),
        if (!remote && !controller.sourceAvailable) ...[
          InfoStrip(
            title: 'Sample source access needs attention',
            message:
                'This walkthrough is showing permission loss. Restoring '
                'the sample state does not recover an Android storage '
                'permission '
                'or change access to your selected files.',
            icon: Icons.folder_off_outlined,
            action: OutlinedButton.icon(
              onPressed: () => controller.change(() {
                controller.sourceAvailable = true;
              }),
              icon: const Icon(Icons.restore),
              label: const Text('Restore sample access'),
            ),
          ),
          const SizedBox(height: 24),
        ],
        if (!remote && !controller.viewer) ...[
          _sampleCollections(context),
          const SizedBox(height: 28),
        ],
        if (ownEmpty)
          _emptyLibrary(context)
        else ...[
          _LibraryTools(controller: controller),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                remote ? 'Alpine days' : controller.collection ?? 'All media',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              StateChip(
                '${items.length} ${items.length == 1 ? 'item' : 'items'}',
              ),
              if (!remote && controller.collection != null)
                OutlinedButton.icon(
                  onPressed: () => controller.change(() {
                    controller.collection = null;
                  }),
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('All collections'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (items.isEmpty)
            InfoStrip(
              title: 'No matching media',
              message: 'Try another search, media type or collection.',
              icon: Icons.search_off,
              action: OutlinedButton.icon(
                onPressed: () => controller.change(() {
                  controller.query = '';
                  controller.filter = null;
                  controller.collection = null;
                }),
                icon: const Icon(Icons.filter_alt_off_outlined),
                label: const Text('Clear filters'),
              ),
            )
          else
            _MediaCollection(
              items: items,
              listView: controller.listView,
              onOpenMedia: onOpenMedia,
            ),
        ],
        const PrivacyFooter(),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'No network calls in this preview.',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    );
  }

  Widget _publicationSummary() => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 650;
      return SectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!compact) const Icon(Icons.shield_outlined),
                if (!compact) const Text('Publication preview'),
                StateChip(
                  controller.publishing
                      ? 'Publishing · simulated'
                      : 'Not publishing',
                  tone: controller.publishing
                      ? StatusTone.positive
                      : StatusTone.neutral,
                ),
                if (compact)
                  OutlinedButton(
                    onPressed: onPublication,
                    child: Text(
                      controller.publishing ? 'Stop sharing' : 'Review sharing',
                    ),
                  ),
              ],
            ),
            if (!compact) ...[
              const SizedBox(height: 12),
              const Text(
                'Media stays local in this preview. Review scope and consent '
                'separately; picking files never starts sharing.',
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onPublication,
                icon: const Icon(Icons.tune),
                label: const Text('Review publication'),
              ),
            ],
          ],
        ),
      );
    },
  );

  Widget _sampleCollections(BuildContext context) {
    if (!controller.sampleData) {
      return InfoStrip(
        title: 'Try a sample collection',
        message:
            'Optional bundled photos and a short video. '
            'Nothing is scanned or added from your device.',
        icon: Icons.landscape_outlined,
        action: OutlinedButton.icon(
          onPressed: () => controller.change(() {
            controller.sampleData = true;
            controller.collection = null;
          }),
          icon: const Icon(Icons.collections_outlined),
          label: const Text('Show sample collections'),
        ),
      );
    }
    const names = ['Alpine days', 'Slow weekends', 'Coastal notes'];
    final compact =
        MediaQuery.sizeOf(context).width < 650 &&
        MediaQuery.textScalerOf(context).scale(1) <= 1.3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              compact ? 'Collections · samples' : 'A few places to begin',
              style: compact
                  ? Theme.of(context).textTheme.titleMedium
                  : Theme.of(context).textTheme.headlineSmall,
            ),
            TextButton.icon(
              onPressed: () => controller.change(() {
                controller.sampleData = false;
                controller.collection = null;
              }),
              icon: const Icon(Icons.hide_image_outlined),
              label: const Text('Hide samples'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (!compact)
          Text(
            'Illustrative collections · bundled examples, not a device scan.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 760
                ? 3
                : constraints.maxWidth >= 440
                ? 2
                : 1;
            final width = compact
                ? 180.0
                : (constraints.maxWidth - (columns - 1) * 16) / columns;
            final tiles = <Widget>[
              for (final name in names)
                SizedBox(
                  width: width,
                  child: _CollectionTile(
                    name: name,
                    item: sampleLibrary.firstWhere(
                      (item) => item.collection == name,
                    ),
                    selected: controller.collection == name,
                    compact: compact,
                    onTap: () => controller.change(() {
                      controller.collection = controller.collection == name
                          ? null
                          : name;
                    }),
                  ),
                ),
            ];
            if (compact) {
              return SizedBox(
                height: 138,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: tiles.length,
                  itemBuilder: (context, index) => tiles[index],
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 12),
                ),
              );
            }
            return Wrap(spacing: 16, runSpacing: 16, children: tiles);
          },
        ),
      ],
    );
  }

  Widget _emptyLibrary(BuildContext context) => SectionCard(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.photo_library_outlined,
          size: 40,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 20),
        Text(
          'Make yourself at home.',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 10),
        const Text(
          'Choose photos or videos to view on this device, or connect to '
          'someone from People. You do not need a library of your own '
          'to begin.',
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton.icon(
              onPressed: onAddMedia,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add media'),
            ),
            OutlinedButton.icon(
              onPressed: onPeople,
              icon: const Icon(Icons.person_add_alt_outlined),
              label: const Text('Connect to someone'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          'Importing does not publish or upload your media.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  Widget _unreadableRemote(BuildContext context) {
    final (title, message) = _remoteExplanation();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back to People'),
          ),
        ),
        const SizedBox(height: 20),
        const VaultPageHeader(
          eyebrow: 'Shared library · simulation',
          title: 'Private stays private.',
          subtitle: 'Media details are hidden while access is not available.',
        ),
        InfoStrip(title: title, message: message, icon: Icons.lock_outline),
        const PrivacyFooter(),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'No network calls in this preview.',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    );
  }

  (String, String) _remoteExplanation() {
    switch (controller.access) {
      case StudyAccess.none:
        return (
          'No access requested',
          'Use People to review the contact and deliberately request sample '
              'access. No private media has been loaded.',
        );
      case StudyAccess.pending:
        return (
          'Waiting for approval',
          'The sample owner has not approved this request. A connection alone '
              'does not grant access. Review the request in People.',
        );
      case StudyAccess.denied:
        return (
          'Request denied',
          'The sample owner declined access. Private media details remain '
              'hidden. Contact and request actions are in People.',
        );
      case StudyAccess.revoked:
        return (
          'Access revoked',
          'The sample approval has ended. No further protected content is '
              'available here; already received or saved copies '
              'cannot be recalled.',
        );
      case StudyAccess.blocked:
        return (
          'Access blocked',
          'This sample identity cannot browse or request access while blocked. '
              'Private media details remain hidden.',
        );
      case StudyAccess.approved:
        break;
    }
    if (controller.connection == StudyConnection.noRoute) {
      return (
        'No direct route',
        'The simulated connection has no direct route. Approval does not '
            'establish a connection. Connection actions are in People; '
            'this preview has no network transport.',
      );
    }
    if (controller.connection == StudyConnection.disconnected) {
      return (
        'Deliberately disconnected',
        'The sample session was disconnected. It will not reconnect '
            'automatically. Return to People to review the connection.',
      );
    }
    if (controller.connection != StudyConnection.connected) {
      return (
        'Owner unavailable',
        'The sample connection is not available. Approval alone is not '
            'enough to browse. Review the connection in People.',
      );
    }
    if (!controller.sourceAvailable) {
      return (
        'Source unavailable',
        'The sample owner’s source permission is unavailable. '
            'The owner must restore access; a viewer cannot recover it here.',
      );
    }
    if (!controller.ownerPublishing) {
      return (
        'Owner is not publishing',
        'The sample owner has stopped publication. Previous approval '
            'does not make the library available.',
      );
    }
    return (
      'Library unavailable',
      'This sample library is not available in the current walkthrough state. '
          'Return to People to review the contact and access.',
    );
  }
}

class _LibraryTools extends StatelessWidget {
  const new({required this.controller});

  final StudyController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final entry in const <(String, MediaKind?)>[
            ('All', null),
            ('Photos', MediaKind.photo),
            ('Videos', MediaKind.video),
          ])
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: ChoiceChip(
                label: Text(entry.$1),
                selected: controller.filter == entry.$2,
                onSelected: (_) => controller.change(() {
                  controller.filter = entry.$2;
                }),
                materialTapTargetSize: MaterialTapTargetSize.padded,
              ),
            ),
        ],
      ),
      const SizedBox(height: 16),
      _LibrarySearch(controller: controller),
      const SizedBox(height: 14),
      Wrap(
        spacing: 16,
        runSpacing: 14,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 160, maxWidth: 240),
            child: PopupMenuButton<MediaSort>(
              tooltip: 'Sort media',
              initialValue: controller.sort,
              onSelected: (sort) => controller.change(() {
                controller.sort = sort;
              }),
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: MediaSort.newest,
                  checked: controller.sort == MediaSort.newest,
                  child: const Text('Newest first'),
                ),
                CheckedPopupMenuItem(
                  value: MediaSort.name,
                  checked: controller.sort == MediaSort.name,
                  child: const Text('Name'),
                ),
              ],
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            controller.sort == MediaSort.newest
                                ? 'Sort: Newest first'
                                : 'Sort: Name',
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.expand_more),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              IconButton.filledTonal(
                onPressed: () => controller.change(() {
                  controller.listView = false;
                }),
                isSelected: !controller.listView,
                tooltip: 'Grid layout',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const Icon(Icons.grid_view_outlined),
                selectedIcon: const Icon(Icons.grid_view),
              ),
              IconButton.filledTonal(
                onPressed: () => controller.change(() {
                  controller.listView = true;
                }),
                isSelected: controller.listView,
                tooltip: 'List layout',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const Icon(Icons.view_list_outlined),
                selectedIcon: const Icon(Icons.view_list),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

// The screen stays stateless; this leaf owns the editing lifecycle so parent
// notifications never replace the search controller or its focus/selection.
class _LibrarySearch extends StatefulWidget {
  const new({required this.controller});

  final StudyController controller;

  @override
  State<_LibrarySearch> createState() => _LibrarySearchState();
}

class _LibrarySearchState extends State<_LibrarySearch> {
  late final TextEditingController _text;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.controller.query);
  }

  @override
  void didUpdateWidget(covariant _LibrarySearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    final query = widget.controller.query;
    if (_text.text != query) {
      _text.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _text,
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(
      labelText: 'Search media',
      hintText: widget.controller.browsingRemote
          ? 'Search the approved sample collection'
          : 'Search your loaded media',
      prefixIcon: const Icon(Icons.search),
      suffixIcon: widget.controller.query.isEmpty
          ? null
          : IconButton(
              tooltip: 'Clear search',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: () {
                _text.clear();
                widget.controller.change(() {
                  widget.controller.query = '';
                });
              },
              icon: const Icon(Icons.close),
            ),
    ),
    onChanged: (value) => widget.controller.change(() {
      widget.controller.query = value;
    }),
  );
}

class _CollectionTile extends StatelessWidget {
  const new({
    required this.name,
    required this.item,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final String name;
  final LibraryItem item;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '$name, sample collection',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected
            ? colors.secondaryContainer
            : colors.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: compact
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaThumb(item: item),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ColoredBox(
                        color: const Color(0xCC15261A),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            name,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: Colors.white,
                                  fontFamily: 'VaultSerif',
                                ),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: 2.3,
                      child: MediaThumb(item: item),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            selected
                                ? 'Selected · tap to show all'
                                : 'Explore sample collection',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _MediaCollection extends StatelessWidget {
  const new({
    required this.items,
    required this.listView,
    required this.onOpenMedia,
  });

  final List<LibraryItem> items;
  final bool listView;
  final ValueChanged<LibraryItem> onOpenMedia;

  @override
  Widget build(BuildContext context) {
    if (listView) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < items.length; index++) ...[
            if (index > 0) const SizedBox(height: 12),
            _MediaTile(
              item: items[index],
              listView: true,
              onTap: () => onOpenMedia(items[index]),
            ),
          ],
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1100
            ? 4
            : constraints.maxWidth >= 740
            ? 3
            : 2;
        final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
        return Wrap(
          spacing: 16,
          runSpacing: 20,
          children: [
            for (final item in items)
              SizedBox(
                width: width,
                child: _MediaTile(
                  item: item,
                  listView: false,
                  onTap: () => onOpenMedia(item),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MediaTile extends StatelessWidget {
  const new({required this.item, required this.listView, required this.onTap});

  final LibraryItem item;
  final bool listView;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = item.kind == MediaKind.video ? 'Video' : 'Photo';
    final date = MaterialLocalizations.of(context).formatMediumDate(item.date);
    final details = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            item.collection,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text('$kind · $date', style: theme.textTheme.labelSmall),
          const SizedBox(height: 8),
          Text(
            item.isAsset ? 'Bundled sample' : 'Selected on this device',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
    final thumbnail = Stack(
      fit: StackFit.expand,
      children: [
        MediaThumb(item: item),
        if (item.kind == MediaKind.video)
          const Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0x99000000),
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: EdgeInsets.all(10),
                child: Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
          ),
      ],
    );
    return Semantics(
      button: true,
      label:
          'Open $kind, ${item.title}, ${item.collection}, $date, '
          '${item.isAsset ? 'bundled sample' : 'selected on this device'}',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: theme.colorScheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: listView
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 88, height: 100, child: thumbnail),
                    Expanded(child: details),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(aspectRatio: 4 / 3, child: thumbnail),
                    details,
                  ],
                ),
        ),
      ),
    );
  }
}
