import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vault/features/pairing/qr_scan_page.dart';
import 'package:vault/features/player/media_viewer.dart';
import 'package:vault/platform/library_sources.dart';
import 'package:vault/platform/media_exporter.dart';
import 'package:vault/platform/media_picker.dart';
import 'package:vault/production/connection_problem.dart';
import 'package:vault/production/messenger_pane.dart';
import 'package:vault/production/pairing_dialogs.dart';
import 'package:vault/production/pairing_join.dart';
import 'package:vault/production/public_config.dart';
import 'package:vault/production/vault_runtime.dart';
import 'package:vault_delivery/vault_delivery.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_media_index/vault_media_index.dart';
import 'package:vault_net/vault_net.dart';
import 'package:vault_player/range_server.dart';
import 'package:vault_protocol/vault_protocol.dart'
    show PairingCodeExpired, PairingInvite;
import 'package:vault_ui/vault_ui.dart' show SectionCard, vaultTheme;

String _formatExpiry(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal().toString();

enum _VaultUtility {
  activity,
  settings,
  connection,
  discovery,
  sources,
  identity,
  appearance,
  network,
  availability,
  privacy,
  about,
}

class VaultApp extends StatefulWidget {
  const new({required this.runtime, super.key});
  final VaultRuntime runtime;
  @override
  State<VaultApp> createState() => _VaultAppState();
}

class _VaultAppState extends State<VaultApp> with WidgetsBindingObserver {
  static final ThemeData _lightTheme = vaultTheme(dark: false);
  static final ThemeData _darkTheme = vaultTheme(dark: true);
  static final ThemeData _highContrastLight = vaultTheme(
    dark: false,
    highContrast: true,
  );
  static final ThemeData _highContrastDark = vaultTheme(
    dark: true,
    highContrast: true,
  );
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _downloads = <String, ({File file, String name, String mime})>{};
  final _transfers = <String, DeliveryCancellation>{};
  final _transferNames = <String, String>{};
  final _progress = <String, ValueNotifier<({int received, int total})>>{};
  final _failedTransfers =
      <String, ({String name, String message, bool cancelled})>{};
  String? _actionFailure;
  final _busy = <String>{};
  final _remotePosters = <String, Uint8List>{};
  final _posterTails = [Future<void>.value(), Future<void>.value()];
  int _posterLane = 0;
  final _posterFailures = <String>{};
  int _page = 0;
  int _navigationGeneration = 0;
  final _utilityTrail = <_VaultUtility>[];
  final GlobalKey<State<StatefulWidget>> _chatWorkspaceKey = GlobalKey();
  final _utilityFocus = FocusNode(debugLabel: 'Vault utility');
  final _contactFocus = FocusNode(debugLabel: 'Contact details');
  List<_VaultUtility>? _contactUtilityOrigin;
  String? _contactPeerId;
  FocusNode? _utilityOpener;
  FocusNode? _contactOpener;
  ({int page, String? chat, List<_VaultUtility> utilities})? _libraryOrigin;
  int _libraryPage = 0;
  final _remotePages = <String, int>{};
  String _discoveryQuery = '';
  String? _selectedLibrary;
  String? _selectedChat;
  String _peopleQuery = '';
  bool _readyOnly = false;
  String _localQuery = '';
  String _localType = 'all';
  final _remoteQueries = <String, String>{};
  final _remoteTypes = <String, String>{};
  final _libraryFailures = <String, String>{};
  VaultRuntime get r => widget.runtime;
  BuildContext get pageContext => _navigator.currentContext!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    r.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) unawaited(r.stop());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    r.removeListener(_changed);
    for (final transfer in _transfers.values) {
      transfer.cancel();
    }
    _utilityFocus.dispose();
    _contactFocus.dispose();
    unawaited(r.close());
    super.dispose();
  }

  void _notice(String message) =>
      _messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _run(String key, Future<void> Function() action) async {
    if (_busy.contains(key)) return;
    setState(() {
      _busy.add(key);
      _actionFailure = null;
    });
    try {
      await action();
    } on DeliveryCancelled {
      _notice(
        'Download cancelled. Verified partial data may be reused '
        'if access remains valid.',
      );
    } on ConnectionProblemException catch (problem) {
      if (mounted) setState(() => _actionFailure = '$problem');
    } on Object catch (error) {
      // No key material or contact exports are logged. Service errors are shown
      // locally and only in response to an actual attempted operation.
      if (mounted) setState(() => _actionFailure = 'Operation failed: $error');
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<bool> _confirm(
    String title,
    String message, {
    String action = 'Confirm',
  }) async =>
      await showDialog<bool>(
        context: pageContext,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: SelectableText(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<String?> _input(
    String title, {
    String initial = '',
    String? explanation,
    String label = 'Paste text',
    bool multiline = true,
    TextInputType? keyboardType,
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: pageContext,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (explanation != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(explanation),
                  ),
                TextField(
                  controller: controller,
                  autofocus: true,
                  minLines: multiline ? 3 : 1,
                  maxLines: multiline ? 10 : 1,
                  maxLength: multiline ? 262144 : null,
                  keyboardType: keyboardType,
                  textInputAction: multiline
                      ? TextInputAction.newline
                      : TextInputAction.done,
                  onSubmitted: multiline
                      ? null
                      : (_) => Navigator.pop(context, controller.text.trim()),
                  decoration: InputDecoration(
                    labelText: label,
                    counterText: '',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    // Dialog route may animate out while its TextField is still mounted.
    unawaited(
      Future<void>.delayed(const Duration(seconds: 1), controller.dispose),
    );
    return value;
  }

  Future<void> _export(String title, String text) async {
    await showDialog<void>(
      context: pageContext,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Copy this text and send it through your chosen '
                  'channel. Only share with the intended person.',
                ),
                const SizedBox(height: 12),
                ExpansionTile(
                  key: const PageStorageKey('export-details'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text('View export text'),
                  children: [
                    SizedBox(
                      height: 240,
                      child: SingleChildScrollView(
                        key: const PageStorageKey('export-scroll'),
                        child: SelectableText(
                          text,
                          key: const PageStorageKey('export-text'),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              _notice('Copied. Send it through your chosen channel.');
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy text'),
          ),
        ],
      ),
    );
  }

  Future<void> _importContact() async {
    final text = await _input(
      'Import public contact',
      explanation:
          'A name is not proof of identity. Compare the complete fingerprint '
          'with the person through a trusted channel.',
    );
    if (text == null) return;
    final card = await ContactCard.decode(text);
    if (!await _confirm(
      'Compare fingerprint',
      '${card.name}\n\n${card.nodeId}\n\n'
          'Have you compared every character with the intended person '
          'through a trusted channel? Adding this contact allows direct '
          'messages. Library access still needs separate approval.',
      action: 'Compared — add contact',
    )) {
      return;
    }
    await r.addContact(card);
  }

  Future<void> _importMedia() async {
    final selected = await NativeMediaPicker.pick();
    var added = 0;
    try {
      for (final source in selected) {
        await r.library.addFile(source.file, name: source.name);
        added++;
      }
    } finally {
      for (final source in selected) {
        if (source.temporary) {
          final stat = await FileStat.stat(source.file.path);
          if (stat.type == FileSystemEntityType.file) {
            await source.file.delete();
          }
        }
      }
    }
    _changed();
    if (added > 0) {
      _notice('Imported $added media file(s) into durable app storage.');
    }
  }

  Future<void> _showLocal(LibraryItem item) async {
    _navigationGeneration++;
    _messenger.currentState?.clearSnackBars();
    final visible = _localVisibleItems();
    final selected = visible.indexWhere((entry) => entry.id == item.id);
    final snapshot = selected < 0 ? [item] : visible;
    await Navigator.of(pageContext).push<void>(
      MaterialPageRoute(
        builder: (_) => MediaViewer(
          sourceLabel: 'My library',
          initialIndex: selected < 0 ? 0 : selected,
          items: [
            for (final entry in snapshot)
              ViewerItem(
                name: entry.name,
                mimeType: entry.mimeType,
                size: entry.size,
                width: entry.metadata.width,
                height: entry.metadata.height,
                durationMillis: entry.metadata.durationMillis,
                open: () => _openLocalViewerSource(entry),
              ),
          ],
        ),
      ),
    );
  }

  Future<ViewerSource> _openLocalViewerSource(LibraryItem item) async {
    if (item.mimeType.startsWith('image/')) {
      final root = Directory('${r.library.root.parent.path}/image-preview');
      await root.create(recursive: true);
      final directory = await root.createTemp('viewer-');
      final file = File('${directory.path}/preview');
      Future<void> release() async {
        if (directory.existsSync()) await directory.delete(recursive: true);
      }

      try {
        final output = await file.open(mode: FileMode.write);
        try {
          for (var index = 0; index < item.chunks.length; index++) {
            await output.writeFrom(await r.library.readChunk(item, index));
          }
        } finally {
          await output.close();
        }
        return ViewerSource(uri: file.uri, release: release);
      } on Object {
        await release();
        rethrow;
      }
    }
    final server = VaultRangeServer(
      contentId: item.id,
      length: item.size,
      mimeType: item.mimeType,
      fetchChunk: (index, cancellation) async {
        cancellation.check();
        final bytes = await r.library.readChunk(item, index);
        cancellation.check();
        return bytes;
      },
    );
    try {
      return ViewerSource(uri: await server.start(), release: server.close);
    } on Object {
      await server.close();
      rethrow;
    }
  }

  Future<void> _addSource() async {
    final root = await AndroidSourceAccess.chooseFolder();
    if (root == null) return;
    await r.library.addSource(root);
    _changed();
  }

  Future<void> _refreshSources() async {
    await r.library.refresh();
    _changed();
    _notice(
      'Selected source folders refreshed. '
      'Unchanged content retains its identity.',
    );
  }

  Future<void> _showRemote(PeerSession session, RemoteMedia item) async {
    _navigationGeneration++;
    _messenger.currentState?.clearSnackBars();
    final visible = _remoteVisibleItems(session.peerId);
    final selected = visible.indexWhere((entry) => entry.id == item.id);
    final snapshot = selected < 0 ? [item] : visible;
    var sourceLabel = 'Shared library';
    for (final contact in r.contacts) {
      if (contact.nodeId == session.peerId) {
        sourceLabel = '${contact.name}’s library';
        break;
      }
    }
    await Navigator.of(pageContext).push<void>(
      MaterialPageRoute(
        builder: (_) => MediaViewer(
          sourceLabel: sourceLabel,
          initialIndex: selected < 0 ? 0 : selected,
          session: session,
          items: [
            for (final entry in snapshot) _remoteViewerItem(session, entry),
          ],
        ),
      ),
    );
  }

  ViewerItem _remoteViewerItem(PeerSession session, RemoteMedia item) {
    DeliveryCancellation? cancellation;
    Future<ViewerSource>? opening;
    return ViewerItem(
      name: item.name,
      mimeType: item.mimeType,
      size: item.size,
      width: item.width,
      height: item.height,
      durationMillis: item.durationMillis,
      open: () {
        cancellation = DeliveryCancellation();
        return opening = _openRemoteViewerSource(session, item, cancellation!);
      },
      cancelOpen: item.mimeType.startsWith('image/')
          ? () async {
              cancellation?.cancel();
              try {
                await opening;
              } on Object {
                // The original loader owns the result/error; this is a barrier.
              }
            }
          : null,
    );
  }

  Future<ViewerSource> _openRemoteViewerSource(
    PeerSession session,
    RemoteMedia item,
    DeliveryCancellation cancellation,
  ) async {
    if (session.state != PeerSessionState.connected) {
      throw StateError('Peer disconnected or access ended.');
    }
    if (item.mimeType.startsWith('image/')) {
      await _download(
        session,
        item,
        announce: false,
        cancellation: cancellation,
      );
      if (session.state != PeerSessionState.connected) {
        throw StateError('Peer disconnected or access ended.');
      }
      // Verified app cache remains available for the separate Save copy action.
      return ViewerSource(
        uri: _downloads['${session.peerId}/${item.id}']!.file.uri,
      );
    }
    final uri = await r.delivery.play(session, item);
    return ViewerSource(
      uri: uri,
      release: () => r.delivery.stopPlayback(session, uri),
    );
  }

  Future<void> _download(
    PeerSession session,
    RemoteMedia item, {
    bool announce = true,
    DeliveryCancellation? cancellation,
  }) async {
    final key = '${session.peerId}/${item.id}';
    if (_transfers.containsKey(key)) {
      throw StateError('This item is already downloading.');
    }
    final transferCancellation = cancellation ?? DeliveryCancellation();
    _transfers[key] = transferCancellation;
    _transferNames[key] = item.name;
    _failedTransfers.remove(key);
    final progress = ValueNotifier((received: 0, total: item.size));
    _progress[key] = progress;
    _changed();
    try {
      final file = await r.delivery.download(
        session,
        item,
        cancellation: transferCancellation,
        onProgress: (received, total) {
          if (mounted) {
            progress.value = (received: received, total: total);
          }
        },
      );
      _downloads[key] = (file: file, name: item.name, mime: item.mimeType);
      if (announce) {
        _notice(
          'Verified download complete in app cache. '
          'Choose Save copy to keep it outside Midnight.',
        );
      }
    } on Object catch (error) {
      if (announce) {
        _failedTransfers[key] = (
          name: item.name,
          message: error is DeliveryCancelled
              ? 'Cancelled'
              : 'Download failed: $error',
          cancelled: error is DeliveryCancelled,
        );
      }
      rethrow;
    } finally {
      _transfers.remove(key);
      _transferNames.remove(key);
      _progress.remove(key)?.dispose();
      _changed();
    }
  }

  double? _transferFraction(({int received, int total}) progress) =>
      progress.total <= 0
      ? null
      : (progress.received / progress.total).clamp(0.0, 1.0);

  Future<void> _save(({File file, String name, String mime}) download) async {
    final destination = await MediaExporter().save(
      download.file,
      name: download.name,
      mimeType: download.mime,
    );
    if (destination != null) {
      _notice('Copy saved to the destination you selected.');
    }
  }

  Widget _button(
    String label,
    String key,
    Future<void> Function() action, {
    bool enabled = true,
  }) => OutlinedButton(
    onPressed: enabled && !_busy.contains(key) ? () => _run(key, action) : null,
    child: Text(_busy.contains(key) ? '$label…' : label),
  );

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: SectionCard(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );

  Widget _actions(List<Widget> children) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Wrap(spacing: 8, runSpacing: 8, children: children),
  );

  Widget _primary(
    String label,
    String key,
    Future<void> Function() action, {
    IconData icon = Icons.add,
    bool enabled = true,
  }) => FilledButton.icon(
    onPressed: enabled && !_busy.contains(key) ? () => _run(key, action) : null,
    icon: Icon(icon, size: 18),
    label: Text(_busy.contains(key) ? '$label…' : label),
  );

  Widget _expandable(
    String title,
    List<Widget> children, {
    String? subtitle,
    IconData icon = Icons.tune,
    bool initiallyExpanded = false,
  }) => Card(
    margin: const EdgeInsets.only(bottom: 18),
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      key: PageStorageKey(title),
      initiallyExpanded: initiallyExpanded,
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget _error(String message) => Builder(
    builder: (context) => Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              message,
              key: PageStorageKey('error-text-$message'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _avatar(String name) {
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part.characters.first)
        .join()
        .toUpperCase();
    return CircleAvatar(
      radius: 24,
      child: Text(initials.isEmpty ? '?' : initials),
    );
  }

  static const List<(IconData, IconData, String)> _destinations = [
    (Icons.chat_bubble_outline, Icons.chat_bubble, 'Chats'),
    (Icons.people_outline, Icons.people, 'Libraries'),
    (Icons.photo_library_outlined, Icons.photo_library, 'My library'),
  ];

  _VaultUtility? get _utility =>
      _utilityTrail.isEmpty ? null : _utilityTrail.last;

  String _utilityTitle(_VaultUtility utility) => switch (utility) {
    _VaultUtility.activity => 'Requests & transfers',
    _VaultUtility.settings => 'Identity & Settings',
    _VaultUtility.connection => 'Connection setup',
    _VaultUtility.discovery => 'Public discovery',
    _VaultUtility.sources => 'Folders & imports',
    _VaultUtility.identity => 'Your identity',
    _VaultUtility.appearance => 'Appearance',
    _VaultUtility.network => 'Connection settings',
    _VaultUtility.availability => 'Availability',
    _VaultUtility.privacy => 'Privacy & security',
    _VaultUtility.about => 'About this build',
  };

  void _selectDestination(int value) => setState(() {
    _navigationGeneration++;
    _page = value;
    _utilityTrail.clear();
    _contactPeerId = null;
    _libraryOrigin = null;
    _contactUtilityOrigin = null;
  });

  void _openUtility(_VaultUtility utility) {
    if (_utility == utility) return;
    _navigationGeneration++;
    if (_utilityTrail.isEmpty) {
      _utilityOpener = FocusManager.instance.primaryFocus;
    }
    setState(() => _utilityTrail.add(utility));
    _restoreFocus(_utilityFocus);
  }

  void _showContactDetails(ContactCard contact) {
    _navigationGeneration++;
    _contactOpener = FocusManager.instance.primaryFocus;
    setState(() {
      _contactUtilityOrigin = _utilityTrail.isEmpty
          ? null
          : List.of(_utilityTrail);
      _utilityTrail.clear();
      _contactPeerId = contact.nodeId;
    });
    _restoreFocus(_contactFocus);
  }

  void _restoreFocus(FocusNode? node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (node?.context?.mounted ?? false)) node!.requestFocus();
    });
  }

  void _goBack() {
    _navigationGeneration++;
    FocusNode? restore;
    setState(() {
      if (_utilityTrail.isNotEmpty) {
        _utilityTrail.removeLast();
        if (_utilityTrail.isEmpty) restore = _utilityOpener;
      } else if (_contactPeerId != null) {
        _contactPeerId = null;
        restore = _contactOpener;
        final origin = _contactUtilityOrigin;
        _contactUtilityOrigin = null;
        if (origin != null) _utilityTrail.addAll(origin);
      } else if (_page == 0) {
        _selectedChat = null;
      } else if (_page == 1 && _selectedLibrary != null) {
        _selectedLibrary = null;
        final origin = _libraryOrigin;
        _libraryOrigin = null;
        if (origin != null) {
          _page = origin.page;
          _selectedChat = origin.chat;
          _utilityTrail.addAll(origin.utilities);
        }
      }
    });
    _restoreFocus(restore);
  }

  ContactCard? _contactFor(String? peerId) {
    for (final contact in r.contacts) {
      if (contact.nodeId == peerId) return contact;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Midnight',
    navigatorKey: _navigator,
    scaffoldMessengerKey: _messenger,
    debugShowCheckedModeBanner: false,
    theme: _lightTheme,
    darkTheme: _darkTheme,
    highContrastTheme: _highContrastLight,
    highContrastDarkTheme: _highContrastDark,
    themeMode: r.config.dark ? ThemeMode.dark : ThemeMode.light,
    home: LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final wide = constraints.maxWidth >= 900 && textScale < 1.8;
        final rail = !wide && constraints.maxWidth >= 600 && textScale < 1.5;
        final navigationWidth = wide
            ? 220.0
            : rail
            ? 88.0
            : 0.0;
        final contact = _contactFor(_contactPeerId);
        final contactPane =
            contact != null &&
            _utility == null &&
            constraints.maxWidth - navigationWidth >= 1140 &&
            textScale < 1.5;
        final contactRoute = _contactPeerId != null && !contactPane;
        final workspaceIndex = _utility != null
            ? 1
            : contactRoute
            ? 2
            : _page == 0
            ? 0
            : 1;
        final detail =
            _utility != null ||
            _contactPeerId != null ||
            (_page == 0 && _selectedChat != null) ||
            (_page == 1 && _selectedLibrary != null);
        final title = _utility != null
            ? _utilityTitle(_utility!)
            : contactRoute
            ? 'Contact details'
            : _page == 1 && _selectedLibrary != null
            ? '${_contactFor(_selectedLibrary)?.name ?? 'Person'}’s library'
            : _destinations[_page].$3;
        final chatHeader = _page == 0 && _utility == null && !contactRoute;
        return CallbackShortcuts(
          bindings: {
            if (detail)
              const SingleActivator(LogicalKeyboardKey.escape): _goBack,
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              appBar: chatHeader
                  ? null
                  : AppBar(
                      automaticallyImplyLeading: false,
                      toolbarHeight:
                          24 + MediaQuery.textScalerOf(context).scale(28),
                      leading: detail
                          ? IconButton(
                              tooltip: 'Back',
                              onPressed: _goBack,
                              icon: const Icon(Icons.arrow_back),
                            )
                          : null,
                      title: Semantics(
                        header: true,
                        child: Tooltip(
                          message: title,
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ),
                      ),
                      actions: [
                        if (!wide) _utilityActions(),
                        const SizedBox(width: 8),
                      ],
                    ),
              body: PopScope(
                canPop: !detail,
                onPopInvokedWithResult: (didPop, result) {
                  if (!didPop) _goBack();
                },
                child: SafeArea(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (wide || rail) ...[
                        SizedBox(
                          width: navigationWidth,
                          child: _sidebar(wide: wide),
                        ),
                        const VerticalDivider(width: 1),
                      ],
                      Expanded(
                        child: Column(
                          children: [
                            if (r.delivery.publishing) _sharingStatus(),
                            if (_actionFailure != null)
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight: constraints.maxHeight * .25,
                                ),
                                child: SingleChildScrollView(
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Material(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .errorContainer,
                                      borderRadius: BorderRadius.circular(12),
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: Semantics(
                                                liveRegion: true,
                                                child: Text(
                                                  _actionFailure!,
                                                  style: TextStyle(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onErrorContainer,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            IconButton(
                                              tooltip:
                                                  'Dismiss operation error',
                                              onPressed: () => setState(
                                                () => _actionFailure = null,
                                              ),
                                              icon: const Icon(Icons.close),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Expanded(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: IndexedStack(
                                      index: workspaceIndex,
                                      sizing: StackFit.expand,
                                      children: [
                                        ExcludeFocus(
                                          excluding: workspaceIndex != 0,
                                          child: MessengerPane(
                                            key: _chatWorkspaceKey,
                                            runtime: r,
                                            active:
                                                _page == 0 &&
                                                _utility == null &&
                                                !contactRoute,
                                            selectedPeerId: _selectedChat,
                                            onSelectPeer: (peerId) =>
                                                setState(() {
                                                  _navigationGeneration++;
                                                  _selectedChat = peerId;
                                                }),
                                            onAddPerson: _importContact,
                                            onShareContact: _shareMyContact,
                                            onConnectionSetup:
                                                _showConnectionSetup,
                                            onContactDetails:
                                                _showContactDetails,
                                            onPair: (_) =>
                                                _run('pair', _pairPhone),
                                            onShowPairingCode: () =>
                                                _run('pair', _pairPhone),
                                            onScanPairingCode: () => _run(
                                              'scan-pair',
                                              _scanPairingCode,
                                            ),
                                            onConnectOverInternet: () => _run(
                                              'internet-preset',
                                              _connectOverInternet,
                                            ),
                                            utilityActions: wide
                                                ? null
                                                : _utilityActions(),
                                          ),
                                        ),
                                        ExcludeFocus(
                                          excluding: workspaceIndex != 1,
                                          child: Focus(
                                            focusNode: _utilityFocus,
                                            canRequestFocus: _utility != null,
                                            child: _contentPage(
                                              wide: wide,
                                              identity: _utility != null
                                                  ? 'utility-${_utility!.name}'
                                                  : _selectedLibrary != null &&
                                                        _page == 1
                                                  ? 'remote-$_selectedLibrary'
                                                  : 'destination-$_page',
                                              children: _utility != null
                                                  ? _utilityContents(_utility!)
                                                  : _page == 1
                                                  ? _selectedLibrary == null
                                                        ? _people()
                                                        : _selectedLibraryView(
                                                            _selectedLibrary!,
                                                          )
                                                  : _page == 2
                                                  ? _library()
                                                  : const [],
                                            ),
                                          ),
                                        ),
                                        ExcludeFocus(
                                          excluding: workspaceIndex != 2,
                                          child: Focus(
                                            focusNode: contactPane
                                                ? null
                                                : _contactFocus,
                                            canRequestFocus: contactRoute,
                                            child: _contentPage(
                                              wide: wide,
                                              identity:
                                                  'contact-$_contactPeerId',
                                              children: contactPane
                                                  ? const []
                                                  : contact == null
                                                  ? [
                                                      const Text(
                                                        'Contact removed.',
                                                      ),
                                                    ]
                                                  : _contactDetails(contact),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (contactPane) ...[
                                    const VerticalDivider(width: 1),
                                    SizedBox(
                                      width: 360,
                                      child: Focus(
                                        focusNode: _contactFocus,
                                        child: Column(
                                          children: [
                                            ListTile(
                                              title: const Text(
                                                'Contact details',
                                              ),
                                              trailing: IconButton(
                                                tooltip:
                                                    'Close contact details',
                                                onPressed: _goBack,
                                                icon: const Icon(Icons.close),
                                              ),
                                            ),
                                            Expanded(
                                              child: _contentPage(
                                                wide: false,
                                                identity:
                                                    'person-${contact.nodeId}',
                                                children: _contactDetails(
                                                  contact,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              bottomNavigationBar: wide || rail || detail
                  ? null
                  : Material(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerLowest,
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (
                                var index = 0;
                                index < _destinations.length;
                                index++
                              )
                                Expanded(
                                  child: _navigationEntry(index, compact: true),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        );
      },
    ),
  );

  Widget _contentPage({
    required bool wide,
    required String identity,
    required List<Widget> children,
  }) => FocusTraversalGroup(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final minimum = wide ? 28.0 : 16.0;
        final centered = (constraints.maxWidth - 1200) / 2;
        final gutter = centered > minimum ? centered : minimum;
        return CustomScrollView(
          key: PageStorageKey(identity),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 32),
              sliver: SliverMainAxisGroup(
                slivers: [
                  for (final child in children)
                    if (child is _VaultMediaGrid)
                      child
                    else
                      SliverToBoxAdapter(child: child),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );

  List<Widget> _utilityContents(_VaultUtility utility) => switch (utility) {
    _VaultUtility.activity => _activity(),
    _VaultUtility.settings => _settings(),
    _VaultUtility.connection => _connectionSetup(),
    _VaultUtility.discovery => _discovery(),
    _VaultUtility.sources => _sources(),
    _VaultUtility.identity => _identitySettings(),
    _VaultUtility.appearance => _appearanceSettings(),
    _VaultUtility.network => _networkSettings(),
    _VaultUtility.availability => _availabilitySettings(),
    _VaultUtility.privacy => _privacySettings(),
    _VaultUtility.about => _aboutSettings(),
  };

  Widget _utilityActions() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        key: const ValueKey('open-activity'),
        tooltip: 'Requests & transfers',
        onPressed: () => _openUtility(_VaultUtility.activity),
        icon: r.requests.isEmpty
            ? const Icon(Icons.inbox_outlined)
            : Badge(
                label: Text('${r.requests.length}'),
                child: const Icon(Icons.inbox_outlined),
              ),
      ),
      IconButton(
        key: const ValueKey('open-settings'),
        tooltip: 'Identity & Settings',
        onPressed: () => _openUtility(_VaultUtility.settings),
        icon: SizedBox(width: 32, height: 32, child: _avatar(r.config.name)),
      ),
    ],
  );

  Widget _sidebar({required bool wide}) => ListView(
    padding: EdgeInsets.symmetric(horizontal: wide ? 12 : 4, vertical: 16),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        child: wide
            ? Row(
                children: [
                  const Icon(Icons.nightlight_round, size: 27),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Midnight',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(pageContext).textTheme.headlineSmall,
                    ),
                  ),
                ],
              )
            : const Icon(Icons.nightlight_round, size: 27),
      ),
      for (var index = 0; index < _destinations.length; index++)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _navigationEntry(index, compact: !wide),
        ),
      const Divider(height: 40),
      if (wide) ...[
        ListTile(
          key: const ValueKey('sidebar-activity'),
          leading: _activityIcon(),
          title: const Text('Requests & transfers'),
          selected: _utility == _VaultUtility.activity,
          onTap: () => _openUtility(_VaultUtility.activity),
        ),
        ListTile(
          leading: _connectionIcon(),
          title: const Text('Connection setup'),
          selected: _utility == _VaultUtility.connection,
          onTap: _showConnectionSetup,
        ),
        const SizedBox(height: 20),
        ListTile(
          leading: _avatar(r.config.name),
          title: Text(
            r.config.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: const Text('Identity & Settings'),
          onTap: () => _openUtility(_VaultUtility.settings),
        ),
      ] else ...[
        IconButton(
          tooltip: 'Requests & transfers',
          onPressed: () => _openUtility(_VaultUtility.activity),
          icon: _activityIcon(),
        ),
        IconButton(
          tooltip: 'Connection setup',
          onPressed: _showConnectionSetup,
          icon: _connectionIcon(),
        ),
        IconButton(
          tooltip: 'Identity & Settings',
          onPressed: () => _openUtility(_VaultUtility.settings),
          icon: const Icon(Icons.manage_accounts_outlined),
        ),
      ],
    ],
  );

  Widget _activityIcon() => r.requests.isEmpty
      ? const Icon(Icons.inbox_outlined)
      : Badge(
          label: Text('${r.requests.length}'),
          child: const Icon(Icons.inbox_outlined),
        );

  Widget _connectionIcon() {
    final count = r.manual?.pendingExports.length ?? 0;
    return count == 0
        ? const Icon(Icons.link)
        : Badge(label: Text('$count'), child: const Icon(Icons.link));
  }

  Widget _navigationEntry(int index, {required bool compact}) {
    final destination = _destinations[index];
    final selected = _page == index && _utility == null;
    final colors = Theme.of(pageContext).colorScheme;
    final unread = index == 0
        ? r.contacts.fold<int>(
            0,
            (total, contact) => total + r.messenger.unreadCount(contact.nodeId),
          )
        : 0;
    final icon = index == 0
        ? Badge(
            isLabelVisible: unread > 0,
            label: Text('$unread'),
            child: Icon(selected ? destination.$2 : destination.$1),
          )
        : Icon(selected ? destination.$2 : destination.$1);
    return Semantics(
      selected: selected,
      child: TextButton(
        key: ValueKey('destination-$index'),
        onPressed: () => _selectDestination(index),
        style: TextButton.styleFrom(
          foregroundColor: selected
              ? colors.onPrimaryContainer
              : colors.onSurfaceVariant,
          backgroundColor: selected
              ? colors.primaryContainer
              : Colors.transparent,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 4 : 16,
            vertical: 12,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: compact
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  icon,
                  const SizedBox(height: 5),
                  Text(destination.$3, textAlign: TextAlign.center),
                ],
              )
            : Row(
                children: [
                  icon,
                  const SizedBox(width: 14),
                  Expanded(child: Text(destination.$3)),
                ],
              ),
      ),
    );
  }

  Widget _sharingStatus() => Builder(
    builder: (context) => Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.wifi_tethering, size: 20),
            const SizedBox(width: 10),
            const Expanded(child: Text('Sharing on')),
            TextButton(
              onPressed: _busy.contains('stop-sharing')
                  ? null
                  : () => _run(
                      'stop-sharing',
                      () => r.setPublishing(enabled: false),
                    ),
              child: const Text('Stop sharing'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _taskIntro(String message, {Widget? action}) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final copy = Text(
          message,
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        );
        if (action == null) return copy;
        if (constraints.maxWidth < 640 ||
            MediaQuery.textScalerOf(context).scale(16) > 24) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [copy, const SizedBox(height: 16), action],
          );
        }
        return Row(
          children: [
            Expanded(child: copy),
            const SizedBox(width: 24),
            action,
          ],
        );
      },
    ),
  );

  Widget _utilityLink(
    String title,
    String subtitle,
    IconData icon,
    _VaultUtility utility,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: Theme.of(pageContext).colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(16),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openUtility(utility),
      ),
    ),
  );

  Future<void> _addMedia() async {
    final choice = await showModalBottomSheet<String>(
      context: pageContext,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Add to My library',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('Add folder'),
              subtitle: const Text(
                'Reference originals where they are. Refresh after changes; '
                'removing a folder from Midnight does not delete its '
                'originals.',
              ),
              onTap: () => Navigator.pop(context, 'folder'),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.file_copy_outlined),
              title: const Text('Import media copies'),
              subtitle: const Text(
                'Copy selected files into Midnight’s app storage. '
                'This uses additional space on this device.',
              ),
              onTap: () => Navigator.pop(context, 'copies'),
            ),
            const SizedBox(height: 16),
            const Text(
              'Adding media does not start sharing or approve anyone.',
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    setState(() => _busy.add('media-work'));
    try {
      if (choice == 'folder') await _addSource();
      if (choice == 'copies') await _importMedia();
    } finally {
      if (mounted) setState(() => _busy.remove('media-work'));
    }
  }

  List<Widget> _library() {
    final allItems = r.library.items;
    final items = _localVisibleItems();
    final page = _validPage(_libraryPage, items.length);
    final offset = page * 100;
    final count = (items.length - offset).clamp(0, 100);
    return [
      _taskIntro(
        '${allItems.length} photos & videos · Only what you choose',
        action: _primary('Add media', 'add-media', _addMedia),
      ),
      _publication(),
      if (r.requests.isNotEmpty)
        _utilityLink(
          '${r.requests.length} library access '
              '${r.requests.length == 1 ? 'request' : 'requests'}',
          'Review the person, scope and duration before approving.',
          Icons.inbox_outlined,
          _VaultUtility.activity,
        ),
      if (r.mediaError != null) _error(r.mediaError!),
      if (_busy.contains('media-work') || _busy.contains('source-refresh')) ...[
        const LinearProgressIndicator(),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Updating your library…'),
        ),
      ],
      if (allItems.isNotEmpty)
        _mediaFilters(
          identity: 'local',
          query: _localQuery,
          type: _localType,
          label: 'Search your filenames',
          onQuery: (value) => setState(() {
            _localQuery = value;
            _libraryPage = 0;
          }),
          onType: (value) => setState(() {
            _localType = value;
            _libraryPage = 0;
          }),
        ),
      if (allItems.isEmpty)
        _section('A place for what matters', [
          const Icon(Icons.photo_library_outlined, size: 48),
          const SizedBox(height: 16),
          const Text(
            'Choose a folder or import individual copies. '
            'Nothing is shared until you start sharing and approve a person.',
          ),
          _actions([
            TextButton.icon(
              onPressed: () => _selectDestination(1),
              icon: const Icon(Icons.people_outline),
              label: const Text('Browse someone’s library'),
            ),
          ]),
        ])
      else if (items.isEmpty)
        _section('No matching media', [
          const Text('Try another filename or choose a different media type.'),
        ])
      else
        _VaultMediaGrid(
          itemCount: count,
          itemBuilder: (context, index) => _libraryItem(items[offset + index]),
        ),
      if (items.length > 100)
        _pagination(
          items.length,
          page,
          (value) => setState(() => _libraryPage = value),
        ),
      const SizedBox(height: 24),
      _utilityLink(
        'Folders & imports',
        '${r.library.sources.length} selected folders · '
            'Refresh or manage sources',
        Icons.folder_outlined,
        _VaultUtility.sources,
      ),
    ];
  }

  List<Widget> _sources() => [
    _taskIntro(
      'Folders are referenced, not copied. '
      'Only sources you choose are indexed.',
      action: _primary('Add media', 'add-media', _addMedia),
    ),
    _actions([_button('Refresh folders', 'source-refresh', _refreshSources)]),
    if (_busy.contains('source-refresh') || _busy.contains('media-work')) ...[
      const SizedBox(height: 16),
      const LinearProgressIndicator(),
      const Text('Updating your library…'),
    ],
    const SizedBox(height: 20),
    if (r.library.sources.isEmpty)
      _section('No referenced folders', [
        const Text(
          'Add folder keeps originals in place. Imported copies appear in '
          'My library and can be managed through each item’s details.',
        ),
      ]),
    for (final source in r.library.sources)
      _section('Referenced folder', [
        SelectableText(source, key: PageStorageKey('source-text-$source')),
        _actions([
          _button('Remove folder', 'source-remove-$source', () async {
            if (await _confirm(
              'Remove folder from Midnight?',
              'Remove its indexed entries and release Android tree access. '
                  'Original files and recipient copies are not deleted.',
              action: 'Remove folder',
            )) {
              await r.library.removeSource(source);
              await AndroidSourceAccess.release(source);
              _changed();
            }
          }),
        ]),
      ]),
    const SizedBox(height: 16),
    const Text(
      'Refresh folders after changes. Android keeps access to the chosen '
      'folder until it is removed or permission is revoked. Providers need '
      'stable metadata and seekable reads; missing, changed or inaccessible '
      'files fail visibly rather than serving stale media.',
    ),
  ];

  Future<void> _toggleSharing() async {
    if (r.delivery.publishing) {
      await r.setPublishing(enabled: false);
      return;
    }
    if (!await _confirm(
      'Start sharing your library?',
      '${r.library.items.length} indexed photos and videos across '
          '${r.library.sources.length} referenced folders '
          'and your imported copies.\n\n'
          'Only authenticated people you approve can '
          'browse, play and download. '
          'Approval lasts 24 hours and covers the whole selected library, '
          'including future folder refreshes and imports. Existing unexpired '
          'approvals may still be valid.\n\n'
          'Recipients can keep received copies. Keep Midnight available; '
          'sharing is best-effort, not always-on hosting.\n\n'
          'Public discovery stays separate. Stopping sharing stops new reads '
          'without revoking remembered grants or ending a usable chat.',
      action: 'Start sharing',
    )) {
      return;
    }
    if (!r.running) await r.start();
    await r.setPublishing(enabled: true);
  }

  Widget _publication() => Card(
    margin: const EdgeInsets.only(bottom: 20),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final status = Row(
            children: [
              Icon(
                r.delivery.publishing
                    ? Icons.wifi_tethering
                    : Icons.lock_outline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.delivery.publishing
                          ? 'Sharing with approved people'
                          : 'Sharing off',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      r.delivery.publishing
                          ? 'Whole library · New imports and '
                                'refreshes included.'
                          : 'Your library stays local until '
                                'you choose to share.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          );
          final action = r.delivery.publishing
              ? TextButton(
                  onPressed: () => _openUtility(_VaultUtility.availability),
                  child: const Text('Availability'),
                )
              : _button('Start sharing', 'publish', _toggleSharing);
          return constraints.maxWidth >= 560
              ? Row(
                  children: [
                    Expanded(child: status),
                    const SizedBox(width: 16),
                    action,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    status,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: action),
                  ],
                );
        },
      ),
    ),
  );

  String _fileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _previewFallback(String mime, {String label = 'No preview'}) =>
      Builder(
        builder: (context) => ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  mime.startsWith('image/')
                      ? Icons.image_outlined
                      : Icons.videocam_outlined,
                  size: 38,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 8),
                Text(label, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        ),
      );

  Widget _libraryItem(LibraryItem item) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: _busy.contains('open-${item.id}')
          ? null
          : () => _run('open-${item.id}', () => _showLocal(item)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (item.posterPath != null)
                  Image.file(
                    File(item.posterPath!),
                    fit: BoxFit.cover,
                    cacheWidth: 520,
                    errorBuilder: (context, error, stack) => _previewFallback(
                      item.mimeType,
                      label: 'Preview unavailable',
                    ),
                  )
                else
                  _previewFallback(item.mimeType),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Tooltip(
                    message: 'Open ${item.name}',
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.black54,
                      child: Icon(
                        item.mimeType.startsWith('image/')
                            ? Icons.open_in_full
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 19,
                      ),
                    ),
                  ),
                ),
                if (_busy.contains('open-${item.id}'))
                  const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Builder(
                        builder: (context) => Text(
                          item.mimeType.startsWith('image/')
                              ? 'Photo · ${_fileSize(item.size)}'
                              : 'Video · ${_fileSize(item.size)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Media details & options',
                  onPressed: () => _localDetails(item),
                  icon: const Icon(Icons.more_horiz),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _localDetails(LibraryItem item) => showDialog<void>(
    context: pageContext,
    builder: (context) => AlertDialog(
      title: Text(item.name),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${item.mimeType} · ${_fileSize(item.size)} '
                '(${item.size} bytes)',
              ),
              const SizedBox(height: 12),
              Text(
                _metadataText(
                  item.metadata.width,
                  item.metadata.height,
                  item.metadata.durationMillis,
                ),
              ),
              if (item.metadata.unavailableReason != null) ...[
                const SizedBox(height: 12),
                Text('Preview unavailable: ${item.metadata.unavailableReason}'),
              ],
              const SizedBox(height: 16),
              Text(
                item.sourceUri == null
                    ? 'Imported copy stored privately in Midnight.'
                    : 'Referenced original. Reads need current permission '
                          'and unchanged content.',
              ),
              if (item.sourceUri != null) SelectableText(item.sourceUri!),
              const SizedBox(height: 16),
              const Text('Content ID'),
              SelectableText(item.id),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            unawaited(
              _run('remove-${item.id}', () async {
                if (await _confirm(
                  'Remove from library?',
                  'This removes the Midnight entry and any imported private '
                      'copy, not source originals or anyone’s saved copy. '
                      'Referenced items can return on folder refresh.',
                  action: 'Remove',
                )) {
                  await r.library.remove(item.id);
                  _changed();
                }
              }),
            );
          },
          child: Text(
            item.sourceUri == null
                ? 'Remove private copy'
                : 'Remove index entry',
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            unawaited(_run('open-${item.id}', () => _showLocal(item)));
          },
          child: const Text('Open'),
        ),
      ],
    ),
  );

  String _metadataText(int? width, int? height, int? durationMillis) {
    final dimensions = width != null && height != null
        ? '$width × $height'
        : 'Dimensions unavailable';
    final duration = durationMillis == null
        ? ''
        : ' · ${Duration(milliseconds: durationMillis)}';
    return '$dimensions$duration';
  }

  int _validPage(int page, int count) {
    final last = count == 0 ? 0 : (count - 1) ~/ 100;
    return page < 0
        ? 0
        : page > last
        ? last
        : page;
  }

  Widget _pagination(int count, int page, ValueChanged<int> select) =>
      _actions([
        Text(
          '$count item(s) · page ${page + 1} of '
          '${count == 0 ? 1 : (count + 99) ~/ 100}',
        ),
        OutlinedButton(
          onPressed: page > 0 ? () => select(page - 1) : null,
          child: const Text('Previous'),
        ),
        OutlinedButton(
          onPressed: (page + 1) * 100 < count ? () => select(page + 1) : null,
          child: const Text('Next'),
        ),
      ]);

  void _showConnectionSetup() => _openUtility(_VaultUtility.connection);

  static const _internetPresetExplanation =
      'Midnight will use broker.emqx.io, a free public service run by a third '
      'party (EMQX), to pass connection-setup messages between your devices. '
      'Each message is encrypted for the other device. Your chats, photos and '
      'videos never go through it: they travel directly between the devices.'
      '\n\n'
      'The service has no availability guarantee and can be slow or down. It '
      'can see when setup messages are sent and which Midnight identity they '
      'are addressed to, but not what they say.\n\n'
      'You can return to manual exchange or use your own broker in '
      'Connection settings.';

  /// Switches to the public broker preset and starts connections, asking
  /// before it stops any running signaling.
  Future<void> _connectOverInternet() async {
    if (!r.config.usesInternetPreset) {
      if (!await _confirm(
        'Connect over the internet?',
        _internetPresetExplanation,
        action: 'Use internet setup',
      )) {
        return;
      }
      if (r.running) {
        if (!await _confirm(
          'Stop current connections?',
          'Changing the connection setup closes current connections. '
              'Local history and received copies stay on this device.',
          action: 'Stop and switch',
        )) {
          return;
        }
        await r.stop();
      }
      await r.saveConfig(r.config.withInternetPreset());
    }
    await r.start();
  }

  void _openChat(String peerId) => setState(() {
    _navigationGeneration++;
    _page = 0;
    _selectedChat = peerId;
    _utilityTrail.clear();
    _contactPeerId = null;
  });

  /// Shows this device's single-use pairing code for a phone to scan.
  Future<void> _pairPhone() async {
    if (r.config.transport != 'mqtt') {
      await _connectOverInternet();
      if (r.config.transport != 'mqtt') return;
    }
    final invite = await r.startPairing();
    try {
      if (!mounted) return;
      final added = await showDialog<ContactCard>(
        context: pageContext,
        barrierDismissible: false,
        builder: (context) => PairingHostDialog(runtime: r, invite: invite),
      );
      if (added != null) {
        _notice('Added ${added.name}. Connecting to it now.');
        _openChat(added.nodeId);
      }
    } finally {
      r.endPairing();
    }
  }

  /// Scans (Android) or pastes another device's pairing code and pairs.
  Future<void> _scanPairingCode() async {
    final text = Platform.isAndroid
        ? await Navigator.of(pageContext).push<String>(
            MaterialPageRoute(builder: (context) => const QrScanPage()),
          )
        : await _input(
            'Enter pairing code',
            explanation:
                'On the other device, choose Pair a phone, then Copy code as '
                'text, and paste it here.',
            label: 'Pairing code',
            multiline: false,
          );
    if (text == null || text.isEmpty) return;
    final PairingInvite invite;
    try {
      invite = await PairingInvite.parse(
        text,
        now: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
    } on PairingCodeExpired catch (expired) {
      setState(() => _actionFailure = '$expired');
      return;
    } on FormatException catch (error) {
      setState(() => _actionFailure = error.message);
      return;
    }
    if (invite.card.nodeId == r.nodeId) {
      setState(
        () => _actionFailure =
            'This is your own pairing code. Scan it with the other device.',
      );
      return;
    }
    final switching = r.needsBrokerSwitch(invite);
    if (!await _confirm(
      'Pair with ${invite.card.name}?',
      pairingConfirmText(
        invite,
        switchesBroker: switching,
        isInternetPreset:
            invite.brokerHost == PublicConfig.internetBrokerHost &&
            invite.brokerPort == PublicConfig.internetBrokerPort,
      ),
      action: 'Pair',
    )) {
      return;
    }
    if (switching && r.running) {
      if (!await _confirm(
        'Stop current connections?',
        'Pairing moves connection setup to ${invite.brokerHost}. This closes '
            'current connections. Local history and received copies stay on '
            'this device.',
        action: 'Stop and continue',
      )) {
        return;
      }
      await r.stop();
    }
    if (!mounted) return;
    final join = PairingJoin(r, invite);
    unawaited(join.run());
    try {
      final openChat = await showDialog<bool>(
        context: pageContext,
        barrierDismissible: false,
        builder: (context) =>
            PairingJoinDialog(join: join, ownNodeId: r.nodeId),
      );
      if (openChat ?? false) _openChat(invite.card.nodeId);
    } finally {
      join.dispose();
    }
  }

  Future<void> _shareMyContact() async {
    final card = await ContactCard.create(r.identity, name: r.config.name);
    await _export('My public contact — no private keys', await card.encode());
  }

  Future<void> _importFrame() async {
    final text = await _input(
      'Import connection frame',
      explanation:
          'Paste an encrypted frame from an imported contact. '
          'Exchange every offer, answer and acknowledgement.',
      label: 'Connection frame',
    );
    if (text != null) await r.manual!.importText(text);
  }

  bool _matchesMedia(String name, String mime, String query, String type) =>
      name.toLowerCase().contains(query.trim().toLowerCase()) &&
      (type == 'all' ||
          (type == 'photos' && mime.startsWith('image/')) ||
          (type == 'videos' && mime.startsWith('video/')));

  List<LibraryItem> _localVisibleItems() => r.library.items
      .where(
        (item) =>
            _matchesMedia(item.name, item.mimeType, _localQuery, _localType),
      )
      .toList();

  List<RemoteMedia> _remoteVisibleItems(String peerId) =>
      (r.remote[peerId] ?? const <RemoteMedia>[])
          .where(
            (item) => _matchesMedia(
              item.name,
              item.mimeType,
              _remoteQueries[peerId] ?? '',
              _remoteTypes[peerId] ?? 'all',
            ),
          )
          .toList();

  Widget _mediaFilters({
    required String identity,
    required String query,
    required String type,
    required String label,
    required ValueChanged<String> onQuery,
    required ValueChanged<String> onType,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: ValueKey('media-search-$identity'),
          initialValue: query,
          onChanged: onQuery,
          decoration: InputDecoration(
            labelText: label,
            prefixIcon: const Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in const [
              ('all', 'All media'),
              ('photos', 'Photos'),
              ('videos', 'Videos'),
            ])
              ChoiceChip(
                label: Text(option.$2),
                selected: type == option.$1,
                onSelected: (_) => onType(option.$1),
              ),
          ],
        ),
      ],
    ),
  );

  bool _libraryReady(ContactCard card) =>
      r.sessions[card.nodeId]?.state == PeerSessionState.connected &&
      r.remote.containsKey(card.nodeId) &&
      !_libraryFailures.containsKey(card.nodeId);

  List<ContactCard> _visibleContacts() => r.contacts
      .where(
        (card) =>
            card.name.toLowerCase().contains(
              _peopleQuery.trim().toLowerCase(),
            ) &&
            (!_readyOnly || _libraryReady(card)),
      )
      .toList();

  Widget _exploreIntro() => _taskIntro(
    'Photos & videos, shared by people you know.',
    action: _primary(
      'Add person',
      'contact-import',
      _importContact,
      icon: Icons.person_add_alt_1_outlined,
    ),
  );

  Widget _contactLibraries() {
    final cards = _visibleContacts();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const ValueKey('people-search'),
          initialValue: _peopleQuery,
          onChanged: (value) => setState(() => _peopleQuery = value),
          decoration: const InputDecoration(
            labelText: 'Search known people',
            prefixIcon: Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('All'),
              selected: !_readyOnly,
              onSelected: (_) => setState(() => _readyOnly = false),
            ),
            Tooltip(
              message:
                  'Connected libraries with an authorized index loaded. '
                  'Every media request still checks access.',
              child: ChoiceChip(
                label: const Text('Ready to browse'),
                selected: _readyOnly,
                onSelected: (_) => setState(() => _readyOnly = true),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (cards.isEmpty)
          _section('No libraries match', [
            const Text(
              'Try another name or choose All to connect and request access.',
            ),
          ])
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
              final columns = (constraints.maxWidth / (310 * scale))
                  .floor()
                  .clamp(1, 3);
              final width =
                  (constraints.maxWidth - (columns - 1) * 18) / columns;
              return Wrap(
                spacing: 18,
                runSpacing: 18,
                children: [
                  for (final card in cards)
                    SizedBox(width: width, child: _contact(card)),
                ],
              );
            },
          ),
        const SizedBox(height: 24),
      ],
    );
  }

  List<Widget> _people() => [
    _exploreIntro(),
    if (r.manual != null && r.manual!.pendingExports.isNotEmpty)
      _connectionTask(),
    if (r.contacts.isEmpty)
      _section('Their world, by invitation', [
        const Icon(Icons.people_outline, size: 48),
        const SizedBox(height: 16),
        const Text(
          'Add someone you know, compare their complete fingerprint, then '
          'connect and ask for access. '
          'Adding a contact grants no media access.',
        ),
        _actions([
          TextButton.icon(
            onPressed: () => _run('my-contact', _shareMyContact),
            icon: const Icon(Icons.ios_share),
            label: const Text('Share my contact'),
          ),
        ]),
      ])
    else
      _contactLibraries(),
    _utilityLink(
      'Public discovery',
      'Optional, partial listings · Separate from contacts and media',
      Icons.travel_explore,
      _VaultUtility.discovery,
    ),
  ];

  Widget _connectionTask() => _section('Connection exchange needs you', [
    Text(
      '${r.manual!.pendingExports.length} connection frames are waiting. '
      'Send every frame and import replies while both apps are running.',
    ),
    _actions([
      TextButton.icon(
        onPressed: _showConnectionSetup,
        icon: const Icon(Icons.swap_horiz),
        label: const Text('Review connection exchange'),
      ),
    ]),
  ]);

  List<Widget> _connectionSetup() => [
    _taskIntro(
      'Exchange connection information through your chosen channel. '
      'Messages and media travel directly between both running apps.',
    ),
    _section('Connection status', [
      Text(
        !r.running
            ? 'Stopped · Nothing connects automatically.'
            : r.config.transport == 'manual'
            ? 'Manual exchange · Send every frame and import replies.'
            : r.transportConnected
            ? 'MQTT signaling ready · Peer connections are separate.'
            : 'MQTT signaling unavailable · A working direct '
                  'session may still be usable.',
      ),
      if (r.signalingProblem case final problem?) ...[
        const SizedBox(height: 12),
        ConnectionProblemNotice(
          problem: problem,
          who: 'other devices',
          busy: _busy.contains('transport'),
          onAction: (_) => _run('transport', r.start),
        ),
      ] else if (r.transportError != null) ...[
        const SizedBox(height: 12),
        _error(r.transportError!),
      ],
      _actions([
        _button(
          r.running ? 'Stop & disconnect all' : 'Start connections',
          'transport',
          () async {
            if (!r.running) {
              await r.start();
            } else if (await _confirm(
              'Stop all connections?',
              'Disconnect current peers and stop library sharing. Incoming '
                  'offers remain blocked until you choose Connect again. '
                  'Local history and received copies are not erased.',
              action: 'Stop & disconnect all',
            )) {
              await r.stop(rememberDisconnect: true);
            }
          },
        ),
        TextButton(
          onPressed: () => _openUtility(_VaultUtility.network),
          child: const Text('Connection settings'),
        ),
      ]),
    ]),
    if (!r.config.usesInternetPreset)
      _section('Easiest: connect over the internet', [
        const Text(
          'A public connection-setup service passes encrypted setup '
          'messages for you, so there is nothing to copy by hand. Chats '
          'and media still travel directly between the devices.',
        ),
        _actions([
          _primary(
            'Connect over the internet',
            'internet-preset',
            _connectOverInternet,
            icon: Icons.public,
          ),
        ]),
      ]),
    _section('Pair with a QR code', [
      const Text(
        'Show a code on one device and scan it with the other. Both devices '
        'then use the same connection setup and add each other as contacts. '
        'Pairing never shares a library.',
      ),
      _actions([
        _primary(
          Platform.isAndroid ? 'Scan pairing code' : 'Pair a phone',
          Platform.isAndroid ? 'scan-pair' : 'pair',
          Platform.isAndroid ? _scanPairingCode : _pairPhone,
          icon: Platform.isAndroid ? Icons.qr_code_scanner : Icons.qr_code,
        ),
        _button(
          Platform.isAndroid ? 'Show pairing code' : 'Enter pairing code',
          Platform.isAndroid ? 'pair' : 'scan-pair',
          Platform.isAndroid ? _pairPhone : _scanPairingCode,
        ),
      ]),
    ]),
    if (r.unknownSenders.isNotEmpty || r.blockedOffers.isNotEmpty)
      _section('Ignored connection attempts', [
        for (final sender in r.unknownSenders.keys.toList().reversed)
          ConnectionProblemNotice(
            key: ValueKey('unknown-$sender'),
            problem: ConnectionProblem.notAContact,
            who: shortFingerprint(sender),
            onAction: (_) => _run('pair', _pairPhone),
            onDismiss: () => r.dismissUnknownSender(sender),
          ),
        for (final peerId in r.blockedOffers.toList())
          if (_contactFor(peerId) case final contact?)
            ConnectionProblemNotice(
              key: ValueKey('blocked-$peerId'),
              problem: ConnectionProblem.youDisconnected,
              who: contact.name,
              busy: _busy.contains('peer-$peerId'),
              onAction: (_) => _run('peer-$peerId', () => r.connect(contact)),
              onDismiss: () => r.dismissBlockedOffer(peerId),
            ),
      ]),
    if (r.config.transport == 'manual') ...[
      _section('Exchange with the other person', [
        const Text(
          'Send every queued offer, answer and acknowledgement, then import '
          'replies. More frames may appear during exchange. Frames have '
          'deadlines; keep both apps running.',
        ),
        _actions([
          _primary(
            'Import reply',
            'signal-import',
            _importFrame,
            icon: Icons.input,
            enabled: r.manual != null,
          ),
        ]),
        if (r.manual == null)
          const Text(
            'Start connections before importing connection information.',
          )
        else if (r.manual!.pendingExports.isEmpty)
          const Text(
            'No frames waiting to export. This is not proof that a peer is '
            'connected; check the person’s actual connection state.',
          ),
      ]),
      if (r.manual != null)
        for (final (index, text) in r.manual!.pendingExports.indexed)
          _section('Frame ${index + 1} of ${r.manual!.pendingExports.length}', [
            const Text(
              'Copying is not transmission. Removing a frame is not an '
              'acknowledgement or proof of a connected session.',
            ),
            _actions([
              _primary(
                'Copy / export frame',
                'signal-export-$index',
                () => _export('Connection frame ${index + 1}', text),
                icon: Icons.outgoing_mail,
              ),
              _button('Remove from queue', 'signal-remove-$index', () async {
                if (await _confirm(
                  'Remove this export frame?',
                  'Remove only after the intended person imported it. This '
                      'cleans the local queue; it does not confirm protocol '
                      'acknowledgement or establish a connection.',
                  action: 'Remove frame',
                )) {
                  r.manual?.removeExport(text);
                  _changed();
                }
              }),
            ]),
          ]),
    ] else
      _section('Automatic signaling, direct delivery', [
        const Text(
          'The configured TLS broker exchanges encrypted connection frames. '
          'It is not a chat mailbox or media relay. Neither signaling mode '
          'guarantees a usable direct network route.',
        ),
      ]),
  ];

  List<Widget> _discovery() => [
    _taskIntro(
      'Optional public listings are not contacts or library permission.',
    ),
    _section('Your public choices', [
      const Text(
        'Listings expose public identity/binding, display name and indexed '
        'item count to broker subscribers. They contain no private filenames, '
        'paths, posters, media or approval.',
      ),
      const SizedBox(height: 12),
      Text(
        r.config.transport == 'mqtt'
            ? 'Names are unverified. Compare the complete '
                  'fingerprint before adding.'
            : 'Public discovery needs configured MQTT TLS signaling. '
                  'Manual exchange does not support this directory.',
      ),
      _actions([
        _button(
          r.discovering ? 'Stop discovery' : 'Listen for listings',
          'discovery-listen',
          () => r.setDiscovering(enabled: !r.discovering),
          enabled: r.config.transport == 'mqtt',
        ),
        _button(
          r.publiclyListed ? 'Stop my public listing' : 'List me publicly',
          'discovery-publish',
          () async {
            if (!r.publiclyListed &&
                !await _confirm(
                  'List your identity publicly?',
                  'Your public identity/fingerprint, name and indexed item '
                      'count become visible to broker subscribers. This does '
                      'not share media or approve anyone. Stopping listing '
                      'cannot erase announcements already received.',
                  action: 'Publish listing',
                )) {
              return;
            }
            await r.setPubliclyListed(enabled: !r.publiclyListed);
          },
          enabled: r.config.transport == 'mqtt',
        ),
      ]),
      const SizedBox(height: 12),
      Text(
        'Listening ${r.discovering ? 'on' : 'off'} · '
        'Your public listing ${r.publiclyListed ? 'on' : 'off'}',
      ),
    ]),
    if (r.transportError != null) _error(r.transportError!),
    if (r.discovering) ...[
      TextFormField(
        key: const ValueKey('discovery-search'),
        initialValue: _discoveryQuery,
        maxLength: 128,
        decoration: const InputDecoration(
          labelText: 'Search received listings',
          prefixIcon: Icon(Icons.search),
          counterText: '',
        ),
        onChanged: (value) => setState(() => _discoveryQuery = value),
      ),
      const SizedBox(height: 20),
      for (final record in r.publicDirectory!.search(_discoveryQuery))
        _section(record.name, [
          Text(
            '${record.sharedCount} indexed items · Fingerprint not compared',
          ),
          const SizedBox(height: 12),
          SelectableText(record.nodeId),
          const SizedBox(height: 8),
          Text('Expires ${_formatExpiry(record.expiresAt)}'),
          _actions([
            _button('Compare & add', 'discover-add-${record.nodeId}', () async {
              final card = await r.publicDirectory!.contactFor(
                record,
                name: record.name,
              );
              if (await _confirm(
                'Compare the complete fingerprint',
                '${card.name}\n\n${card.nodeId}\n\n'
                    'Compare every character over an independent trusted '
                    'channel. A matching name proves nothing. Adding permits '
                    'direct messages, not library access.',
                action: 'Compared — add contact',
              )) {
                await r.addContact(card);
              }
            }),
          ]),
        ]),
      const Text(
        'Results cover only recently received, unexpired broker listings, '
        'not everyone or the whole Internet. No automatic contact, connection '
        'or approval is created.',
      ),
    ],
    _utilityLink(
      'Connection settings',
      'Choose your own signaling configuration',
      Icons.settings_ethernet,
      _VaultUtility.network,
    ),
  ];

  String _sessionLabel(PeerSession? session) => switch (session?.state) {
    PeerSessionState.negotiating => 'Connecting…',
    PeerSessionState.authenticating => 'Authenticating connection…',
    PeerSessionState.connected => 'Direct connection',
    PeerSessionState.failed => 'Connection failed',
    PeerSessionState.closed || null => 'Not connected',
  };

  Future<void> _openLibrary(ContactCard card, {bool refresh = false}) async {
    final session = r.sessions[card.nodeId];
    if (session == null || session.state != PeerSessionState.connected) {
      throw StateError('Connect to ${card.name} first.');
    }
    final generation = ++_navigationGeneration;
    if (refresh ||
        !r.remote.containsKey(card.nodeId) ||
        _libraryFailures.containsKey(card.nodeId)) {
      try {
        await r.browse(session);
        _libraryFailures.remove(card.nodeId);
      } on Object catch (error) {
        _libraryFailures[card.nodeId] = 'Library unavailable: $error';
        _changed();
        rethrow;
      }
    }
    if (mounted && generation == _navigationGeneration) {
      setState(() {
        final utilities = _contactUtilityOrigin ?? _utilityTrail;
        if (_page != 1 || utilities.isNotEmpty) {
          _libraryOrigin = (
            page: _page,
            chat: _selectedChat,
            utilities: utilities.isEmpty ? const [] : List.of(utilities),
          );
        }
        _page = 1;
        _selectedLibrary = card.nodeId;
        _contactPeerId = null;
        _contactUtilityOrigin = null;
        _utilityTrail.clear();
      });
    }
  }

  Future<void> _requestLibrary(ContactCard card) async {
    final session = r.sessions[card.nodeId];
    if (session == null || session.state != PeerSessionState.connected) {
      throw StateError('Connect to ${card.name} first.');
    }
    final generation = ++_navigationGeneration;
    _notice(
      'Asking ${card.name} for access. Keep both apps open for approval.',
    );
    await r.delivery.requestAccess(session);
    if (!mounted || generation != _navigationGeneration) return;
    await _openLibrary(card, refresh: true);
  }

  Widget _libraryAction(ContactCard card) {
    final session = r.sessions[card.nodeId];
    if (session == null ||
        session.state == PeerSessionState.closed ||
        session.state == PeerSessionState.failed) {
      return _primary(
        'Connect',
        'peer-${card.nodeId}',
        () => r.connect(card),
        icon: Icons.link,
      );
    }
    if (session.state != PeerSessionState.connected) {
      return FilledButton.icon(
        onPressed: null,
        icon: const Icon(Icons.hourglass_top),
        label: const Text('Connecting…'),
      );
    }
    if (_libraryReady(card)) {
      return _primary(
        'Open library',
        'browse-${card.nodeId}',
        () => _openLibrary(card),
        icon: Icons.arrow_forward_rounded,
      );
    }
    return _primary(
      _busy.contains('request-${card.nodeId}')
          ? 'Waiting for owner'
          : 'Request access',
      'request-${card.nodeId}',
      () => _requestLibrary(card),
      icon: Icons.lock_open_outlined,
    );
  }

  Widget _libraryCover(ContactCard card) {
    final session = r.sessions[card.nodeId];
    RemoteMedia? cover;
    if (_libraryReady(card) && session != null) {
      for (final item in r.remote[card.nodeId]!) {
        if (item.posterDigest != null) {
          cover = item;
          break;
        }
      }
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _libraryReady(card) && !_busy.contains('browse-${card.nodeId}')
              ? () => _run('browse-${card.nodeId}', () => _openLibrary(card))
              : null,
          child: Semantics(
            label: _libraryReady(card)
                ? 'Open ${card.name}’s library'
                : '${card.name}’s private library',
            button: _libraryReady(card),
            child: AspectRatio(
              aspectRatio: 1.8,
              child: cover == null || session == null
                  ? _libraryCoverPlaceholder(card)
                  : _remotePreview(session, cover),
            ),
          ),
        ),
      ),
    );
  }

  Widget _libraryCoverPlaceholder(ContactCard card) => Builder(
    builder: (context) {
      final ready = _libraryReady(card);
      final colors = Theme.of(context).colorScheme;
      return ColoredBox(
        color: colors.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                ready ? Icons.photo_library_outlined : Icons.lock_outline,
                size: 32,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(height: 10),
              Flexible(
                child: Text(
                  ready ? 'No preview loaded' : 'A private library',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  List<Widget> _selectedLibraryView(String peerId) {
    final card = _contactFor(peerId);
    if (card == null) {
      return [
        _section('This person is no longer in your contacts', [
          const Text('Add their public contact again to reconnect.'),
        ]),
      ];
    }
    final session = r.sessions[peerId];
    final ready = _libraryReady(card);
    final allItems = r.remote[peerId] ?? const <RemoteMedia>[];
    final items = _remoteVisibleItems(peerId);
    final page = _validPage(_remotePages[peerId] ?? 0, items.length);
    final offset = page * 100;
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _avatar(card.name),
          title: Text(card.name),
          subtitle: Text(_sessionLabel(session)),
          trailing: const Icon(Icons.info_outline),
          onTap: () => _showContactDetails(card),
        ),
      ),
      _taskIntro(
        ready
            ? '${allItems.length} authorized items loaded · '
                  'Access checked on every read'
            : 'Their library needs a direct connection and separate approval.',
        action: ready
            ? _button(
                'Refresh',
                'browse-$peerId',
                () => _openLibrary(card, refresh: true),
              )
            : _libraryAction(card),
      ),
      if (_libraryFailures[peerId] case final failure?) _error(failure),
      if (r.manual != null && r.manual!.pendingExports.isNotEmpty)
        _connectionTask(),
      if (!ready)
        _section(
          session?.state == PeerSessionState.connected
              ? 'No authorized library loaded'
              : 'Connect to this person',
          [
            Text(
              session?.state == PeerSessionState.connected
                  ? 'The owner must be sharing and your approval '
                        'must be valid. Request access deliberately, '
                        'or check an earlier approval.'
                  : 'Uncached remote media needs both apps '
                        'running and directly reachable. Your local '
                        'history and received copies are separate.',
            ),
            if (session?.state == PeerSessionState.connected)
              _actions([
                _button(
                  'Check earlier approval',
                  'browse-$peerId',
                  () => _openLibrary(card, refresh: true),
                ),
              ]),
          ],
        )
      else ...[
        _mediaFilters(
          identity: peerId,
          query: _remoteQueries[peerId] ?? '',
          type: _remoteTypes[peerId] ?? 'all',
          label: 'Search loaded filenames',
          onQuery: (value) => setState(() {
            _remoteQueries[peerId] = value;
            _remotePages[peerId] = 0;
          }),
          onType: (value) => setState(() {
            _remoteTypes[peerId] = value;
            _remotePages[peerId] = 0;
          }),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            '${items.length} of ${allItems.length} loaded items · '
            'Search covers this authorized index only.',
          ),
        ),
        if (allItems.isEmpty)
          _section('Nothing shared here yet', [
            Text(
              '${card.name} has no indexed media in this authorized library.',
            ),
          ])
        else if (items.isEmpty)
          _section('No matching media', [
            const Text('Try another filename or media type.'),
          ])
        else
          _VaultMediaGrid(
            itemCount: (items.length - offset).clamp(0, 100),
            itemBuilder: (context, index) =>
                _remoteItem(session!, items[offset + index]),
          ),
        if (items.length > 100)
          _pagination(
            items.length,
            page,
            (value) => setState(() => _remotePages[peerId] = value),
          ),
      ],
    ];
  }

  Widget _contact(ContactCard card) {
    final session = r.sessions[card.nodeId];
    final connected = session?.state == PeerSessionState.connected;
    final ready = _libraryReady(card);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _libraryCover(card),
            const SizedBox(height: 16),
            Row(
              children: [
                _avatar(card.name),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        card.name,
                        style: Theme.of(pageContext).textTheme.titleMedium,
                      ),
                      Text(
                        r.config.disconnectedPeerIds.contains(card.nodeId)
                            ? 'Disconnected by you'
                            : _sessionLabel(session),
                        style: Theme.of(pageContext).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Contact details and fingerprint',
                  onPressed: () => _showContactDetails(card),
                  icon: const Icon(Icons.info_outline),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              ready
                  ? '${r.remote[card.nodeId]!.length} items · Ready to browse'
                  : connected
                  ? 'A connection is not library approval.'
                  : 'Connect, then ask what they would like to share.',
            ),
            if (_libraryFailures[card.nodeId] case final failure?)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(failure),
              ),
            _actions([
              _libraryAction(card),
              if (connected && !ready)
                TextButton(
                  onPressed: _busy.contains('browse-${card.nodeId}')
                      ? null
                      : () => _run(
                          'browse-${card.nodeId}',
                          () => _openLibrary(card, refresh: true),
                        ),
                  child: const Text('Check earlier approval'),
                ),
            ]),
          ],
        ),
      ),
    );
  }

  List<Widget> _contactDetails(ContactCard card) {
    final session = r.sessions[card.nodeId];
    final active =
        session != null &&
        session.state != PeerSessionState.closed &&
        session.state != PeerSessionState.failed;
    final connected = session?.state == PeerSessionState.connected;
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Row(
          children: [
            _avatar(card.name),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                card.name,
                style: Theme.of(pageContext).textTheme.titleLarge,
              ),
            ),
          ],
        ),
      ),
      _section('Fingerprint comparison', [
        SelectableText(
          card.nodeId,
          key: PageStorageKey('contact-fingerprint-${card.nodeId}'),
        ),
        const SizedBox(height: 12),
        const Text(
          'This contact was added after complete-fingerprint comparison. '
          'Compare every character again through an independent trusted '
          'channel if you are unsure. A name is not identity proof.',
        ),
      ]),
      _section('Direct connection', [
        Text(
          r.config.disconnectedPeerIds.contains(card.nodeId)
              ? 'Disconnected by you. Incoming offers stay '
                    'blocked until Connect.'
              : _sessionLabel(session),
        ),
        if (r.problemFor(card.nodeId) case final problem?)
          ConnectionProblemNotice(
            problem: problem,
            who: card.name,
            busy: _busy.contains('peer-${card.nodeId}'),
            onAction: (_) => _run('peer-${card.nodeId}', () => r.connect(card)),
            onDismiss: problem == ConnectionProblem.youDisconnected
                ? () => r.dismissBlockedOffer(card.nodeId)
                : null,
          )
        else if (session?.failureReason != null)
          _error(session!.failureReason!),
        _actions([
          if (active)
            _button(
              'Disconnect',
              'peer-${card.nodeId}',
              () => r.disconnect(session),
            )
          else
            _primary(
              'Connect',
              'peer-${card.nodeId}',
              () => r.connect(card),
              icon: Icons.link,
            ),
          TextButton(
            onPressed: _showConnectionSetup,
            child: const Text('Connection setup'),
          ),
        ]),
        const SizedBox(height: 12),
        const Text(
          'Both apps must be running and directly reachable. '
          'Local drafts never send automatically after reconnection.',
        ),
      ]),
      _section('Your access to their library', [
        Text(
          _libraryReady(card)
              ? 'Authorized index loaded; every new media '
                    'read still checks access.'
              : 'No authorized library loaded. This does not prove that an '
                    'earlier approval is absent or expired.',
        ),
        if (connected)
          _actions([
            _libraryAction(card),
            if (!_libraryReady(card))
              _button(
                'Check earlier approval',
                'browse-${card.nodeId}',
                () => _openLibrary(card, refresh: true),
              ),
          ]),
      ]),
      _section('Their access to your library', [
        const Text(
          'Approval is separate from contact verification and connection. '
          'It covers browse, play and download of your whole selected library, '
          'including future refreshes/imports, for 24 hours.',
        ),
        if (r.approvedThisRun.contains(card.nodeId))
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'Approved during this run. '
              'This is not a live grant-expiry status.',
            ),
          ),
        _actions([
          _button('Revoke their access', 'revoke-${card.nodeId}', () async {
            if (await _confirm(
              'Revoke ${card.name}’s access?',
              '${card.nodeId}\n\nPersistently invalidate their media grants '
                  'and stop serving them. Received, cached, saved or captured '
                  'copies cannot be erased.',
              action: 'Revoke access',
            )) {
              await r.revoke(card.nodeId);
            }
          }),
        ]),
      ]),
      _section('Contact options', [
        _actions([
          _button('Export public contact', 'export-${card.nodeId}', () async {
            await _export(
              'Public contact — no private keys',
              await card.encode(),
            );
          }),
          TextButton(
            onPressed: _busy.contains('forget-${card.nodeId}')
                ? null
                : () => _run('forget-${card.nodeId}', () async {
                    if (!await _confirm(
                      'Remove ${card.name}?',
                      'Revoke their access, disconnect and forget their public '
                          'contact. Local conversation history is not deleted; '
                          'received copies cannot be recalled.',
                      action: 'Remove contact',
                    )) {
                      return;
                    }
                    await r.removeContact(card);
                    if (mounted) {
                      final restoreContact =
                          _contactPeerId == card.nodeId &&
                          _utilityTrail.isEmpty;
                      setState(() {
                        if (_contactPeerId == card.nodeId) {
                          _contactPeerId = null;
                          final origin = _contactUtilityOrigin;
                          _contactUtilityOrigin = null;
                          if (origin != null) {
                            _utilityTrail.insertAll(0, origin);
                          }
                        }
                        if (_selectedChat == card.nodeId) _selectedChat = null;
                        if (_selectedLibrary == card.nodeId) {
                          _selectedLibrary = null;
                        }
                      });
                      if (restoreContact) {
                        _restoreFocus(
                          _utilityTrail.isEmpty
                              ? _contactOpener
                              : _utilityFocus,
                        );
                      }
                    }
                  }),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(pageContext).colorScheme.error,
            ),
            child: const Text('Remove contact'),
          ),
        ]),
      ]),
    ];
  }

  Widget _remotePreview(PeerSession session, RemoteMedia item) {
    final key = '${session.sessionId}/${item.id}/${item.posterDigest}';
    if (item.posterDigest == null) {
      return _previewFallback(item.mimeType, label: 'No peer preview');
    }
    return _RemotePreview(
      key: ValueKey(key),
      cached: _remotePosters[key],
      load: (active) => _queuePoster(session, item, active),
      fallback: _previewFallback(item.mimeType, label: 'Preview unavailable'),
    );
  }

  Future<Uint8List?> _queuePoster(
    PeerSession session,
    RemoteMedia item,
    bool Function() active,
  ) {
    final key = '${session.sessionId}/${item.id}/${item.posterDigest}';
    final lane = _posterLane;
    _posterLane = (lane + 1) % _posterTails.length;
    final result = _posterTails[lane].then((_) async {
      if (!mounted ||
          !active() ||
          session.state != PeerSessionState.connected) {
        return null;
      }
      final cached = _remotePosters[key];
      if (cached != null) return cached;
      try {
        final bytes = await r.delivery.poster(session, item);
        if (!mounted ||
            !active() ||
            session.state != PeerSessionState.connected) {
          return null;
        }
        if (bytes == null) {
          _posterFailures.add(key);
        } else {
          _posterFailures.remove(key);
          if (_remotePosters.length >= 32) {
            _remotePosters.remove(_remotePosters.keys.first);
          }
          _remotePosters[key] = bytes;
        }
        _changed();
        return bytes;
      } on Object {
        if (mounted && active()) {
          _posterFailures.add(key);
          _changed();
        }
        rethrow;
      }
    });
    _posterTails[lane] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _loadPoster(PeerSession session, RemoteMedia item) async {
    final bytes = await _queuePoster(session, item, () => mounted);
    if (bytes == null && mounted) {
      _notice('Peer has no available preview for this item.');
    }
  }

  Widget _remoteItem(PeerSession session, RemoteMedia item) {
    final key = '${session.peerId}/${item.id}';
    final posterKey = '${session.sessionId}/${item.id}/${item.posterDigest}';
    final connected = session.state == PeerSessionState.connected;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: connected && !_busy.contains('play-$key')
            ? () => _run('play-$key', () => _showRemote(session, item))
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _remotePreview(session, item),
                  Positioned.fill(
                    child: Tooltip(
                      message: 'Open ${item.name}',
                      child: const Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: CircleAvatar(
                            radius: 16,
                            backgroundColor: Colors.black54,
                            child: Icon(
                              Icons.open_in_full,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_posterFailures.contains(posterKey))
                    Center(
                      child: FilledButton.tonal(
                        onPressed:
                            connected && !_busy.contains('poster-$posterKey')
                            ? () => _run(
                                'poster-$posterKey',
                                () => _loadPoster(session, item),
                              )
                            : null,
                        child: Text(
                          _busy.contains('poster-$posterKey')
                              ? 'Loading…'
                              : 'Retry preview',
                        ),
                      ),
                    ),
                  if (_busy.contains('play-$key'))
                    const Center(child: CircularProgressIndicator()),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(_fileSize(item.size)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Open & download options',
                    onPressed: () => _remoteDetails(session, item),
                    icon: const Icon(Icons.more_horiz),
                  ),
                ],
              ),
            ),
            if (_progress[key] case final progress?)
              ValueListenableBuilder(
                valueListenable: progress,
                builder: (context, value, child) =>
                    LinearProgressIndicator(value: _transferFraction(value)),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _remoteDetails(PeerSession session, RemoteMedia item) {
    final key = '${session.peerId}/${item.id}';
    return showDialog<void>(
      context: pageContext,
      builder: (context) => AlertDialog(
        title: Text(item.name),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${item.mimeType} · ${_fileSize(item.size)}'),
                const SizedBox(height: 12),
                Text(
                  _metadataText(item.width, item.height, item.durationMillis),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Viewing an image downloads a verified cache copy. '
                  'Cache downloads are not saved to your files until you '
                  'choose Save copy in Activity.',
                ),
                _actions([
                  _primary(
                    item.mimeType.startsWith('image/')
                        ? 'View image'
                        : 'Play video',
                    'play-$key',
                    () async {
                      Navigator.pop(context);
                      await _showRemote(session, item);
                    },
                    icon: Icons.play_arrow,
                    enabled: session.state == PeerSessionState.connected,
                  ),
                  _button('Download to cache', 'download-$key', () async {
                    Navigator.pop(context);
                    await _download(session, item);
                  }, enabled: session.state == PeerSessionState.connected),
                  if (_transfers.containsKey(key))
                    OutlinedButton(
                      onPressed: () {
                        _transfers[key]?.cancel();
                        Navigator.pop(context);
                      },
                      child: const Text('Cancel download'),
                    ),
                ]),
                const SizedBox(height: 20),
                const Text('Content ID'),
                SelectableText(item.id),
              ],
            ),
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

  String _peerName(String nodeId) {
    for (final card in r.contacts) {
      if (card.nodeId == nodeId) return card.name;
    }
    return 'Authenticated viewer';
  }

  List<Widget> _activity() => [
    _taskIntro(
      'Your decisions and transfers · Current run, '
      'not a permanent activity history',
    ),
    if (r.manual != null && r.manual!.pendingExports.isNotEmpty)
      _connectionTask(),
    if (r.requests.isEmpty)
      _section('No pending access requests', [
        const Text(
          'New requests appear here and in My library. '
          'Nothing is approved automatically.',
        ),
      ]),
    for (final request in r.requests)
      _section('${_peerName(request.peerId)} wants library access', [
        const Text(
          'Compare this authenticated fingerprint with the intended person.',
        ),
        const SizedBox(height: 12),
        SelectableText(
          request.peerId,
          key: PageStorageKey('request-fingerprint-${request.requestId}'),
        ),
        if (_contactFor(request.peerId) case final contact?)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _showContactDetails(contact),
              icon: const Icon(Icons.person_outline),
              label: const Text('Contact details'),
            ),
          ),
        const SizedBox(height: 16),
        const Text('Whole library · Browse, play & download · 24 hours'),
        const SizedBox(height: 8),
        const Text(
          'Includes every selected folder, future refreshes and imports. '
          'Recipients can keep received, saved or captured copies. '
          'Revoking access cannot erase those copies.',
        ),
        if (!r.delivery.publishing) ...[
          const SizedBox(height: 12),
          const Text(
            'Start sharing before approving. '
            'Starting does not approve this request.',
          ),
          _actions([_button('Start sharing', 'publish', _toggleSharing)]),
        ],
        _actions([
          _primary(
            'Approve for 24 hours',
            'request-decision-${request.requestId}',
            () async {
              if (!r.requests.contains(request) ||
                  !r.delivery.publishing ||
                  r.sessions[request.peerId]?.state !=
                      PeerSessionState.connected) {
                throw StateError(
                  'This request is no longer eligible. '
                  'Check the current connection and sharing state.',
                );
              }
              await r.approve(request);
            },
            icon: Icons.check,
            enabled: r.delivery.publishing,
          ),
          _button('Deny', 'request-decision-${request.requestId}', () async {
            if (!r.requests.contains(request)) {
              throw StateError('This request has already ended.');
            }
            await r.deny(request);
          }),
        ]),
      ]),
    _section('Transfers & app cache', [
      if (_transfers.isEmpty && _downloads.isEmpty && _failedTransfers.isEmpty)
        const Text(
          'No downloads this run. Browse an approved library to view or '
          'download media. Cache is separate from copies saved to your files.',
        ),
      for (final entry in _transfers.entries)
        ValueListenableBuilder(
          valueListenable: _progress[entry.key]!,
          builder: (context, progress, child) => Column(
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.downloading_outlined),
                title: Text(_transferNames[entry.key] ?? 'Media download'),
                subtitle: Text(
                  '${progress.received} / ${progress.total} bytes',
                ),
                trailing: IconButton(
                  tooltip: 'Cancel download',
                  onPressed: entry.value.cancel,
                  icon: const Icon(Icons.close),
                ),
              ),
              LinearProgressIndicator(value: _transferFraction(progress)),
              const SizedBox(height: 12),
            ],
          ),
        ),
      for (final entry in _failedTransfers.entries) ...[
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            entry.value.cancelled ? Icons.cancel_outlined : Icons.error_outline,
          ),
          title: Text(entry.value.name),
          subtitle: Text(entry.value.message),
        ),
        const Text(
          'Matching interrupted data may resume when you download again '
          'from the library. Further reads still require current approval.',
        ),
        TextButton(
          onPressed: () => _selectDestination(1),
          child: const Text('Open Libraries'),
        ),
        const Divider(height: 24),
      ],
      if (_downloads.isNotEmpty)
        const Text(
          'Completed this run · Available in app cache, '
          'not saved to your files',
        ),
      for (final entry in _downloads.entries) ...[
        const Divider(height: 28),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.task_alt),
          title: Text(entry.value.name),
          subtitle: const Text(
            'Verified app cache · May be deleted independently',
          ),
        ),
        _actions([
          _primary(
            'Save copy…',
            'save-${entry.key}',
            () => _save(entry.value),
            icon: Icons.save_alt,
          ),
          _button('Delete cache', 'delete-${entry.key}', () async {
            if (await _confirm(
              'Delete cached download?',
              'Remove only the app-managed cache. Originals, exported files '
                  'and copies held by other people are not affected.',
              action: 'Delete cache',
            )) {
              final stat = await FileStat.stat(entry.value.file.path);
              if (stat.type == FileSystemEntityType.file) {
                await entry.value.file.delete();
              }
              _downloads.removeWhere(
                (_, download) => download.file.path == entry.value.file.path,
              );
              _changed();
            }
          }),
        ]),
      ],
    ]),
    _expandable(
      'Approvals made this run',
      [
        const Text(
          'This is not a complete grant history or a live expiry status. '
          'Earlier approvals can survive restart until expiry/revocation. '
          'Revoke any known person’s future media access from Contact details.',
        ),
        for (final peerId in r.approvedThisRun)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_peerName(peerId)),
            subtitle: const Text('Approved during this run'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final contact = _contactFor(peerId);
              if (contact != null) {
                _showContactDetails(contact);
              }
            },
          ),
      ],
      subtitle: '${r.approvedThisRun.length} decisions recorded this run',
      icon: Icons.verified_user_outlined,
    ),
  ];

  List<Widget> _settings() => [
    _taskIntro(
      'Your identity stays on this device. No account or cloud profile.',
    ),
    _utilityLink(
      'Your identity',
      r.config.name,
      Icons.person_outline,
      _VaultUtility.identity,
    ),
    _utilityLink(
      'Appearance',
      r.config.dark ? 'Dark' : 'Light',
      Icons.contrast,
      _VaultUtility.appearance,
    ),
    _utilityLink(
      'Connection settings',
      r.config.transport == 'manual'
          ? 'Manual exchange · No server'
          : 'Your configured MQTT TLS broker',
      Icons.settings_ethernet,
      _VaultUtility.network,
    ),
    _utilityLink(
      'Connection setup',
      '${r.manual?.pendingExports.length ?? 0} frames waiting · '
          'Direct sessions are separate',
      Icons.swap_horiz,
      _VaultUtility.connection,
    ),
    _utilityLink(
      'Availability',
      r.delivery.publishing
          ? 'Sharing on · Best-effort OS availability'
          : 'Sharing off',
      Icons.power_settings_new,
      _VaultUtility.availability,
    ),
    _utilityLink(
      'Privacy & security',
      'Local identity, consent, history and received copies',
      Icons.shield_outlined,
      _VaultUtility.privacy,
    ),
    _utilityLink(
      'About this build',
      'Experimental · Native feasibility gates remain open',
      Icons.info_outline,
      _VaultUtility.about,
    ),
  ];

  List<Widget> _identitySettings() => [
    _section('Your display name', [
      Row(
        children: [
          _avatar(r.config.name),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              r.config.name,
              style: Theme.of(pageContext).textTheme.titleLarge,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      const Text('A display name is not a unique username or identity proof.'),
      _actions([
        _primary(
          'Share my contact',
          'my-contact',
          _shareMyContact,
          icon: Icons.ios_share,
        ),
        _button('Edit name', 'rename', () async {
          final value = await _input(
            'Display name',
            initial: r.config.name,
            label: 'Your name',
            multiline: false,
            keyboardType: TextInputType.name,
          );
          if (value != null) {
            await r.saveConfig(
              PublicConfig.decode(r.config.copyWith(name: value).encode()),
            );
          }
        }),
      ]),
    ]),
    _section('Your complete fingerprint', [
      SelectableText(
        r.nodeId,
        key: const PageStorageKey('my-fingerprint-text'),
      ),
      const SizedBox(height: 12),
      const Text(
        'Compare every character through an independent trusted channel. '
        'Contact export contains public data only, never your private keys.',
      ),
    ]),
    const Text(
      'Private identity keys use protected OS storage. There is no automatic '
      'recovery or private-key export. Clearing application storage or '
      'reinstalling can permanently lose this identity and its approvals.',
    ),
  ];

  List<Widget> _appearanceSettings() => [
    _taskIntro('The same warm surfaces and readable controls, in both themes.'),
    Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final option in const [(false, 'Light'), (true, 'Dark')])
          ChoiceChip(
            label: Text(option.$2),
            selected: r.config.dark == option.$1,
            onSelected: (_) => _run(
              'appearance',
              () => r.saveConfig(r.config.copyWith(dark: option.$1)),
            ),
          ),
      ],
    ),
    const SizedBox(height: 24),
    const Text(
      'Text size and reduced-animation preferences follow the platform.',
    ),
  ];

  List<Widget> _networkSettings() => [
    _taskIntro(
      r.config.transport == 'manual'
          ? 'Manual exchange · No server'
          : 'MQTT TLS · ${r.config.brokerHost}:${r.config.brokerPort}',
    ),
    if (r.signalingProblem case final problem?)
      ConnectionProblemNotice(
        problem: problem,
        who: 'other devices',
        busy: _busy.contains('transport'),
        onAction: (_) => _run('transport', r.start),
      )
    else if (r.transportError != null)
      _error(r.transportError!),
    _section('Signaling transport', [
      Text(
        r.running
            ? 'Stop connections before changing transport '
                  'or importing configuration.'
            : 'Connect only when you choose. Nothing starts automatically.',
      ),
      _actions([
        if (!r.config.usesInternetPreset)
          _primary(
            'Connect over the internet',
            'internet-preset',
            _connectOverInternet,
            icon: Icons.public,
          ),
        _button(
          'Use manual exchange',
          'manual-config',
          () => r.saveConfig(r.config.copyWith(transport: 'manual')),
          enabled: !r.running,
        ),
        _button('Use my own broker', 'mqtt-config', () async {
          final value = await showDialog<PublicConfig>(
            context: pageContext,
            builder: (context) => _MqttConfigDialog(initial: r.config),
          );
          if (value != null) await r.saveConfig(value);
        }, enabled: !r.running),
      ]),
      _actions([
        _button(
          'Export public config',
          'config-export',
          () => _export('Public configuration', r.config.encode()),
        ),
        _button('Import public config', 'config-import', () async {
          final text = await _input(
            'Import public configuration',
            explanation:
                'Preferences only, not contacts or private keys. '
                'Existing explicit disconnect intent is preserved.',
          );
          if (text != null) await r.saveConfig(PublicConfig.decode(text));
        }, enabled: !r.running),
      ]),
    ]),
    const Text(
      'MQTT carries encrypted connection signaling and optional public '
      'listings, never chat text, media or grants. A broker can observe '
      'connection metadata. Midnight does not operate a broker. The internet '
      'preset uses broker.emqx.io, a third-party public service with no '
      'availability guarantee, only after you choose it.\n\n'
      'Manual exchange requires every offer, answer and acknowledgement '
      'before deadlines. Both modes use direct WebRTC without TURN; '
      'neither guarantees a network route or an offline mailbox.',
    ),
    const SizedBox(height: 24),
    _utilityLink(
      'Connection setup',
      'Start/stop connections and exchange pending frames',
      Icons.swap_horiz,
      _VaultUtility.connection,
    ),
  ];

  List<Widget> _availabilitySettings() => [
    _taskIntro(
      'OS availability is best-effort, not unattended '
      'hosting or guaranteed reachability.',
    ),
    if (r.availabilityNotice != null) _error(r.availabilityNotice!),
    _section('Observed native status', [
      Text(
        'Background mode: ${r.availabilityState.backgroundMode}\n'
        'Native publishing: '
        '${r.availabilityState.publishing ? 'active' : 'inactive'}\n'
        'Sleep prevention request: '
        '${r.availabilityState.wakeLockHeld ? 'held' : 'not held'}',
      ),
      if (r.availabilityState.detail != null) ...[
        const SizedBox(height: 12),
        Text(r.availabilityState.detail!),
      ],
      _actions([
        _button('Refresh status', 'availability-status', r.refreshAvailability),
        if (r.availabilityState.canMinimizeToTray)
          _button(
            'Minimize to tray',
            'availability-tray',
            r.minimizeToTray,
            enabled: r.delivery.publishing,
          ),
        if (r.availabilityState.canAutostart)
          _button(
            r.availabilityState.autostart
                ? 'Disable login launch'
                : 'Enable login launch',
            'availability-autostart',
            () async {
              if (!r.availabilityState.autostart &&
                  !await _confirm(
                    'Open Midnight at Windows login?',
                    'This opens the app only. It never starts sharing, '
                        'public discovery or connections automatically.',
                    action: 'Enable login launch',
                  )) {
                return;
              }
              await r.setAutostart(enabled: !r.availabilityState.autostart);
            },
          ),
      ]),
    ]),
    _section('Android', [
      const Text(
        'Notification permission is requested only when starting sharing. '
        'The visible data-sync service provides Stop '
        'and stops on task removal. '
        'A local budget under six hours, shared quotas, Doze, force-stop and '
        'vendor restrictions can interrupt it. '
        'No automatic publication or boot restart.',
      ),
    ]),
    _section('Windows', [
      const Text(
        'Sharing creates a notification-area icon and requests automatic-sleep '
        'prevention. Explicit sleep, shutdown and policy remain in control. '
        'Closing while sharing asks whether to continue in the tray; Open, '
        'Stop and Quit remain available. Login launch only opens the app.',
      ),
    ]),
  ];

  List<Widget> _privacySettings() => [
    _section('Identity and history are different', [
      const Text(
        'Private identity keys and owner authorization '
        'use protected OS storage. '
        'Conversation history is application-private SQLite, not encrypted at '
        'rest. Device/disk access protections still matter. There is no '
        'automatic identity recovery or private-key export.',
      ),
    ]),
    _section('Sharing is a separate decision', [
      const Text(
        'Adding a verified contact permits direct messages, not media access. '
        'Publication, owner approval and public discovery are independent. '
        'No operated backend, account, TURN relay, '
        'remote push or telemetry is used.',
      ),
    ]),
    _section('Received copies cannot be recalled', [
      const Text(
        'Revocation stops future protected delivery. It cannot erase received, '
        'cached, exported or captured bytes. Delete cache affects local '
        'app-managed copies only, never source originals or exported files.',
      ),
    ]),
    _section('Only the sources you select', [
      const Text(
        'Midnight does not scan your device or request broad storage, camera '
        'or microphone access. Android retains selected folder permissions. '
        'Missing, changed, revoked or non-seekable sources fail explicitly '
        'instead of serving stale or fabricated content.',
      ),
    ]),
  ];

  List<Widget> _aboutSettings() => [
    _section('Midnight · Experimental', [
      const Text(
        'Native interface and core services are experimental, not a production '
        'release. Physical-device, hostile-network, background lifecycle, '
        'performance and release-security gates remain open. Developer '
        'packages use debug signing.',
      ),
    ]),
  ];
}

class _VaultMediaGrid extends StatelessWidget {
  const new({required this.itemCount, required this.itemBuilder});

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
      final columns = (constraints.crossAxisExtent / (190 + (scale - 1) * 70))
          .floor()
          .clamp(1, 5);
      final width =
          (constraints.crossAxisExtent - (columns - 1) * 16) / columns;
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: width / (210 + 76 * scale),
        ),
        delegate: SliverChildBuilderDelegate(
          itemBuilder,
          childCount: itemCount,
        ),
      );
    },
  );
}

class _MqttConfigDialog extends StatefulWidget {
  const new({required this.initial});
  final PublicConfig initial;

  @override
  State<_MqttConfigDialog> createState() => _MqttConfigDialogState();
}

class _MqttConfigDialogState extends State<_MqttConfigDialog> {
  late final _host = TextEditingController(text: widget.initial.brokerHost);
  late final _port = TextEditingController(
    text: '${widget.initial.brokerPort}',
  );
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final next = widget.initial.copyWith(
        transport: 'mqtt',
        brokerHost: _host.text.trim(),
        brokerPort: int.parse(_port.text.trim()),
      );
      Navigator.pop(context, PublicConfig.decode(next.encode()));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Configure MQTT TLS'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Use your own reachable TLS broker with a trusted certificate '
              'and permitted anonymous access. For the public preset, choose '
              'Connect over the internet instead.',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _host,
              autofocus: true,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Hostname',
                helperText: 'Without a scheme or path',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(labelText: 'TLS port'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save configuration')),
    ],
  );
}

/// One bounded preview per rendered item; parent rebuilds do not refetch it.
class _RemotePreview extends StatefulWidget {
  const new({
    required this.load,
    required this.fallback,
    this.cached,
    super.key,
  });
  final Future<Uint8List?> Function(bool Function() active) load;
  final Widget fallback;
  final Uint8List? cached;

  @override
  State<_RemotePreview> createState() => _RemotePreviewState();
}

class _RemotePreviewState extends State<_RemotePreview> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.cached == null
        ? widget.load(() => mounted)
        : Future.value(widget.cached);
  }

  @override
  void didUpdateWidget(_RemotePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cached != null && !identical(widget.cached, oldWidget.cached)) {
      _future = Future.value(widget.cached);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _future,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes != null) {
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          cacheWidth: 720,
          errorBuilder: (context, error, stack) => widget.fallback,
        );
      }
      if (snapshot.connectionState == ConnectionState.waiting) {
        return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: const Center(
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      }
      return widget.fallback;
    },
  );
}

/// Storage/bootstrap errors are visible and fail closed: no simulated shell or
/// fresh identity is substituted. Retry is explicit and repeats the real load.
class VaultStartupFailure extends StatelessWidget {
  const new({required this.retry, this.alreadyRunning = false, super.key});
  final VoidCallback retry;
  final bool alreadyRunning;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Midnight',
    theme: vaultTheme(dark: false),
    highContrastTheme: vaultTheme(dark: false, highContrast: true),
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alreadyRunning
                        ? 'Midnight is already running'
                        : 'Midnight could not safely open storage',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  if (alreadyRunning)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: Text(
                        'Close the other Midnight window/process and retry. '
                        'The OS must grant an exclusive app-storage lock '
                        'before private identity or authorization state '
                        'is accessed. No keys have been reset.',
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Text(
                    'No network or library publication has started. '
                    'Protected identity, contact, authorization, configuration '
                    'or library storage could not be loaded. '
                    'Unlock the device and check available storage '
                    'and OS secure-storage access, then retry. '
                    'Do not clear app data unless you intend to permanently '
                    'lose this identity and its approvals. '
                    'Midnight will not replace inaccessible keys '
                    'with a new identity or a plaintext fallback.',
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: retry,
                    child: const Text('Retry storage load'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
