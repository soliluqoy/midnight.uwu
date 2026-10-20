import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:vault_net/vault_net.dart';

/// One real library entry. Opening is lazy and scoped to the selected item.
class ViewerItem {
  const new({
    required this.name,
    required this.mimeType,
    required this.open,
    this.cancelOpen,
    this.size,
    this.width,
    this.height,
    this.durationMillis,
  });

  final String name;
  final String mimeType;
  final Future<ViewerSource> Function() open;

  /// Cancel an in-flight load and await its teardown before opening another.
  /// Sources without cancellation are released when their late result arrives.
  final Future<void> Function()? cancelOpen;
  final int? size;
  final int? width;
  final int? height;
  final int? durationMillis;
}

/// An opened source and its optional, source-specific ownership cleanup.
class ViewerSource {
  const new({required this.uri, this.release});

  final Uri uri;
  final Future<void> Function()? release;
}

/// A bounded gallery of real local media or authenticated peer media.
class MediaViewer extends StatefulWidget {
  const new({
    required this.items,
    required this.sourceLabel,
    this.initialIndex = 0,
    this.session,
    super.key,
  }) : assert(
         initialIndex >= 0 && initialIndex < items.length,
         'The selected index must identify an item in a nonempty gallery.',
       );

  final List<ViewerItem> items;
  final int initialIndex;
  final String sourceLabel;
  final PeerSession? session;

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

/// Native playback must stop before a loopback server or temp file is released.
class _OpenedItem {
  new(this.source);

  final ViewerSource source;
  Player? player;
  VideoController? video;
  final videoKey = GlobalKey<VideoState>();
  Future<void>? decoding;
  FileImage? image;
  StreamSubscription<String>? errors;
  Future<void>? _closing;

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await errors?.cancel();
      try {
        final state = videoKey.currentState;
        if (state != null && state.mounted && state.isFullscreen()) {
          await state.exitFullscreen();
        }
      } finally {
        await player?.dispose();
      }
    } finally {
      try {
        // File decoding may still hold a Windows file handle after navigation.
        await decoding;
        await image?.evict();
      } finally {
        await source.release?.call();
      }
    }
  }
}

class _MediaViewerState extends State<MediaViewer> with WidgetsBindingObserver {
  final _transform = TransformationController();
  final _focus = FocusNode(debugLabel: 'Media gallery');
  late final List<ViewerItem> _items;
  late int _index;
  _OpenedItem? _opened;
  Future<void> Function()? _cancelOpening;
  StreamSubscription<PeerSessionState>? _states;
  Future<void> _teardown = Future.value();
  int _generation = 0;
  bool _loading = true;
  bool _unavailable = false;
  bool _recovering = false;
  bool _foreground = true;
  ({Duration position, bool playing, double volume})? _resume;
  bool _details = false;
  String? _error;

  static const _desktopControls = MaterialDesktopVideoControlsThemeData(
    visibleOnMount: true,
    automaticallyImplySkipNextButton: false,
    automaticallyImplySkipPreviousButton: false,
    seekBarPositionColor: Color(0xFFB8D5C4),
    seekBarThumbColor: Color(0xFFB8D5C4),
    bottomButtonBar: [
      Tooltip(
        message: 'Play or pause (Space)',
        child: MaterialDesktopPlayOrPauseButton(),
      ),
      Expanded(child: MaterialDesktopPositionIndicator()),
      Tooltip(
        message: 'Toggle fullscreen',
        child: MaterialDesktopFullscreenButton(),
      ),
    ],
  );

  static const _touchControls = MaterialVideoControlsThemeData(
    visibleOnMount: true,
    automaticallyImplySkipNextButton: false,
    automaticallyImplySkipPreviousButton: false,
    seekBarPositionColor: Color(0xFFB8D5C4),
    seekBarThumbColor: Color(0xFFB8D5C4),
    primaryButtonBar: [
      Spacer(),
      Tooltip(
        message: 'Play or pause',
        child: MaterialPlayOrPauseButton(iconSize: 48),
      ),
      Spacer(),
    ],
    bottomButtonBar: [
      Expanded(child: MaterialPositionIndicator()),
      Tooltip(message: 'Toggle fullscreen', child: MaterialFullscreenButton()),
    ],
  );

  ViewerItem get _item => _items[_index];
  bool get _isImage => _item.mimeType.startsWith('image/');
  bool get _connected =>
      widget.session == null ||
      widget.session!.state == PeerSessionState.connected;

  @override
  void initState() {
    super.initState();
    _items = List.unmodifiable(widget.items);
    _index = widget.initialIndex;
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final state = widget.session?.state;
    _unavailable =
        state == PeerSessionState.closed || state == PeerSessionState.failed;
    _recovering = !_unavailable && !_connected;
    _states = widget.session?.states.listen(_sessionChanged);
    if (!_unavailable && !_recovering) unawaited(_load());
  }

  void _sessionChanged(PeerSessionState state) {
    if (state == PeerSessionState.closed || state == PeerSessionState.failed) {
      _endSession();
    } else if (state != PeerSessionState.connected) {
      if (!mounted || _unavailable || _recovering) return;
      final player = _opened?.player;
      if (player != null && !_loading) {
        _resume = (
          position: player.state.position,
          playing: _foreground && player.state.playing,
          volume: player.state.volume,
        );
      }
      ++_generation;
      setState(() {
        _recovering = true;
        _loading = false;
        _error = null;
      });
      unawaited(_releaseCurrent());
    } else if (mounted && !_unavailable && _recovering) {
      setState(() => _recovering = false);
      unawaited(_load(restore: true));
    }
  }

  bool _current(int generation) =>
      mounted &&
      !_unavailable &&
      !_recovering &&
      _connected &&
      generation == _generation;

  Future<void> _close(_OpenedItem? opened) async {
    try {
      await opened?.close();
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Vault media viewer',
          context: ErrorDescription('while releasing a media source'),
        ),
      );
    }
  }

  Future<void> _releaseCurrent() {
    final cancel = _cancelOpening;
    final opened = _opened;
    _cancelOpening = null;
    _opened = null;
    // Reconnection must not open a new transfer/listener before old teardown.
    return _teardown = _teardown.then((_) async {
      try {
        await cancel?.call();
      } on Object catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'Vault media viewer',
            context: ErrorDescription('while cancelling a media load'),
          ),
        );
      } finally {
        await _close(opened);
      }
    });
  }

  Future<void> _load({bool restore = false}) async {
    if (_unavailable || _recovering || !_connected) return;
    if (!restore) _resume = null;
    final generation = ++_generation;
    final item = _item;
    final teardown = _releaseCurrent();
    setState(() {
      _loading = true;
      _error = null;
      if (!restore) _transform.value = Matrix4.identity();
    });
    await teardown;
    if (!_current(generation)) return;
    _OpenedItem? opened;
    try {
      // Do not request adjacent items or prefetch a gallery's media bytes.
      _cancelOpening = item.cancelOpen;
      opened = _OpenedItem(await item.open());
      if (!mounted || !_current(generation)) {
        await _close(opened);
        return;
      }
      _cancelOpening = null;
      _opened = opened;
      if (item.mimeType.startsWith('image/')) {
        opened.image = FileImage(File.fromUri(opened.source.uri));
        Object? decodeError;
        opened.decoding = precacheImage(
          opened.image!,
          context,
          onError: (error, stack) => decodeError = error,
        );
        await opened.decoding;
        if (decodeError != null) {
          throw StateError('Image could not be decoded.');
        }
      } else {
        final player = opened.player = Player();
        opened
          ..video = VideoController(player)
          ..errors = player.stream.error.listen((error) {
            if (_current(generation)) {
              unawaited(player.pause());
              setState(() => _error = 'This video could not be played.');
            }
          });
        // Navigation starts paused; recovery retains foreground playback only.
        await player.open(
          Media(opened.source.uri.toString(), start: _resume?.position),
          play: false,
        );
        if (!_current(generation)) {
          await _close(opened);
          return;
        }
        final resume = _resume;
        if (resume != null) {
          await player.setVolume(resume.volume);
          if (_current(generation) && _foreground && _resume!.playing) {
            await player.play();
          }
        }
      }
      if (!_current(generation)) {
        await _close(opened);
        return;
      }
      setState(() {
        _loading = false;
        _resume = null;
      });
    } on Object {
      await _close(opened);
      if (_current(generation)) {
        _cancelOpening = null;
        setState(() {
          _opened = null;
          _loading = false;
          _error =
              'Media unavailable, unsupported, or access has ended. '
              'The original is unchanged.';
        });
      }
    }
  }

  void _endSession() {
    if (!mounted || _unavailable) return;
    ++_generation;
    _resume = null;
    setState(() {
      _unavailable = true;
      _recovering = false;
      _loading = false;
    });
    unawaited(_releaseCurrent());
  }

  void _move(int delta) {
    final next = _index + delta;
    if (_unavailable ||
        _recovering ||
        !_connected ||
        next < 0 ||
        next >= _items.length) {
      return;
    }
    _index = next;
    unawaited(_load());
  }

  void _zoom(double multiplier) {
    final size = _photoSize;
    if (!_isImage || _opened?.image == null || size.isEmpty) return;
    final matrix = _transform.value;
    final scale = matrix.getMaxScaleOnAxis();
    final next = (scale * multiplier).clamp(1.0, 8.0);
    if (next == 1) {
      _resetZoom();
      return;
    }
    final ratio = next / scale;
    final offset = matrix.getTranslation();
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        size.width / 2 + (offset.x - size.width / 2) * ratio,
        size.height / 2 + (offset.y - size.height / 2) * ratio,
        0,
        1,
      )
      ..scaleByDouble(next, next, 1, 1);
  }

  Size _photoSize = Size.zero;

  void _resetZoom() => _transform.value = Matrix4.identity();

  void _pan(double x, double y) {
    if (_transform.value.getMaxScaleOnAxis() <= 1) return;
    final matrix = _transform.value.clone();
    matrix.setTranslationRaw(matrix.storage[12] + x, matrix.storage[13] + y, 0);
    _transform.value = matrix;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      final resume = _resume;
      if (resume != null) {
        _resume = (
          position: resume.position,
          playing: false,
          volume: resume.volume,
        );
      }
      unawaited(_opened?.player?.pause());
    }
  }

  @override
  void dispose() {
    ++_generation;
    unawaited(_releaseCurrent());
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_states?.cancel());
    _transform.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFB8D5C4),
        brightness: Brightness.dark,
        surface: const Color(0xFF171B19),
      ),
      scaffoldBackgroundColor: const Color(0xFF0B0E0D),
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
    );
    return Theme(
      data: theme,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
          const SingleActivator(LogicalKeyboardKey.pageUp): () => _move(-1),
          const SingleActivator(LogicalKeyboardKey.pageDown): () => _move(1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () =>
              _move(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () =>
              _move(1),
          if (_isImage) ...{
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _move(-1),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _move(1),
            const SingleActivator(LogicalKeyboardKey.equal): () => _zoom(1.5),
            const SingleActivator(LogicalKeyboardKey.equal, shift: true): () =>
                _zoom(1.5),
            const SingleActivator(LogicalKeyboardKey.minus): () =>
                _zoom(1 / 1.5),
            const SingleActivator(LogicalKeyboardKey.digit0): _resetZoom,
            const SingleActivator(
              LogicalKeyboardKey.arrowLeft,
              shift: true,
            ): () =>
                _pan(64, 0),
            const SingleActivator(
              LogicalKeyboardKey.arrowRight,
              shift: true,
            ): () =>
                _pan(-64, 0),
            const SingleActivator(
              LogicalKeyboardKey.arrowUp,
              shift: true,
            ): () =>
                _pan(0, 64),
            const SingleActivator(
              LogicalKeyboardKey.arrowDown,
              shift: true,
            ): () =>
                _pan(0, -64),
          },
        },
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          child: Scaffold(
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide =
                      constraints.maxWidth >= 1000 &&
                      constraints.maxHeight >= 480;
                  return Column(
                    children: [
                      _header(context),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  ExcludeFocus(
                                    excluding: _details && !wide,
                                    child: ExcludeSemantics(
                                      excluding: _details && !wide,
                                      child: Column(
                                        children: [
                                          Expanded(child: _stage()),
                                          _toolbar(context),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (_details && !wide) _metadata(context),
                                ],
                              ),
                            ),
                            if (_details && wide)
                              SizedBox(
                                width: constraints.maxWidth * 0.36,
                                child: _metadata(context),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) => Material(
    color: const Color(0xFF111413),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back to library (Escape)',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              header: true,
              label: '${_item.name}, ${widget.sourceLabel}',
              excludeSemantics: true,
              child: Tooltip(
                message: '${_item.name}\n${widget.sourceLabel}',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      widget.sourceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: const Color(0xFFBCC7C1)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: _details ? 'Hide media details' : 'Show media details',
            isSelected: _details,
            onPressed: () => setState(() => _details = !_details),
            icon: const Icon(Icons.info_outline),
            selectedIcon: const Icon(Icons.close),
          ),
        ],
      ),
    ),
  );

  Widget _stage() {
    if (_unavailable) {
      return _message(
        Icons.link_off,
        'This connection has ended',
        'Playback has stopped. Return to the library to reconnect or request '
            'access. No further media will be requested in this viewer. '
            'Already received bytes and saved copies are not erased.',
      );
    }
    if (_recovering) {
      return _message(
        Icons.sync,
        'Reconnecting to the library',
        'Playback is paused while the direct connection recovers. '
            'This item will reopen after the connection is ready and access '
            'is checked again.',
      );
    }
    if (_error != null) {
      return _message(
        Icons.broken_image_outlined,
        'Unable to open media',
        _error!,
        retry: true,
      );
    }
    if (_loading || _opened == null) {
      return const Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                semanticsLabel: 'Opening verified media',
              ),
              SizedBox(height: 16),
              Text('Opening verified media…', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    final opened = _opened!;
    if (!_isImage) {
      // Keep media_kit's proven adaptive seek/time/play/fullscreen controls.
      // Gallery chrome is outside the video, never over its control strip.
      return MaterialDesktopVideoControlsTheme(
        normal: _desktopControls,
        fullscreen: _desktopControls.copyWith(
          bottomButtonBar: const [
            Tooltip(
              message: 'Play or pause (Space)',
              child: MaterialDesktopPlayOrPauseButton(),
            ),
            Tooltip(message: 'Volume', child: MaterialDesktopVolumeButton()),
            Expanded(child: MaterialDesktopPositionIndicator()),
            Tooltip(
              message: 'Exit fullscreen',
              child: MaterialDesktopFullscreenButton(),
            ),
          ],
        ),
        child: MaterialVideoControlsTheme(
          normal: _touchControls,
          fullscreen: _touchControls.copyWith(
            volumeGesture: true,
            initialVolume: opened.player!.state.volume / 100,
            onVolumeChanged: (value) =>
                unawaited(opened.player!.setVolume(value * 100)),
          ),
          child: Video(key: opened.videoKey, controller: opened.video!),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _photoSize = constraints.biggest;
        return InteractiveViewer(
          key: ObjectKey(opened),
          transformationController: _transform,
          minScale: 1,
          maxScale: 8,
          child: SizedBox.expand(
            child: Image(
              image: opened.image!,
              fit: BoxFit.contain,
              semanticLabel: _item.name,
              frameBuilder: (context, child, frame, synchronous) =>
                  frame != null || synchronous
                  ? child
                  : const Center(child: CircularProgressIndicator()),
              errorBuilder: (context, error, stack) => _message(
                Icons.broken_image_outlined,
                'Image unavailable',
                'This file could not be decoded. The original is unchanged.',
                retry: true,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _message(
    IconData icon,
    String title,
    String message, {
    bool retry = false,
  }) => Semantics(
    liveRegion: true,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(child: Icon(icon, size: 36)),
              const SizedBox(height: 12),
              Semantics(
                header: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
              if (retry) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => unawaited(_load()),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Widget _toolbar(BuildContext context) => Material(
    color: const Color(0xFF111413),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final showNavigationLabels =
            MediaQuery.textScalerOf(context).scale(14) <= 20 &&
            constraints.maxWidth >= 340;
        final previous = !_unavailable && !_recovering && _index > 0
            ? () => _move(-1)
            : null;
        final next = !_unavailable && !_recovering && _index + 1 < _items.length
            ? () => _move(1)
            : null;
        final navigation = Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Tooltip(
              message: 'Previous item (Page Up or Alt + Left)',
              child: showNavigationLabels
                  ? TextButton.icon(
                      onPressed: previous,
                      icon: const Icon(Icons.chevron_left),
                      label: const Text('Previous'),
                    )
                  : IconButton(
                      onPressed: previous,
                      icon: const Icon(Icons.chevron_left),
                    ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Semantics(
                  liveRegion: true,
                  label: 'Item ${_index + 1} of ${_items.length}',
                  excludeSemantics: true,
                  child: Text(
                    '${_index + 1} of ${_items.length}',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
            Tooltip(
              message: 'Next item (Page Down or Alt + Right)',
              child: showNavigationLabels
                  ? TextButton.icon(
                      onPressed: next,
                      icon: const Icon(Icons.chevron_right),
                      label: const Text('Next'),
                    )
                  : IconButton(
                      onPressed: next,
                      icon: const Icon(Icons.chevron_right),
                    ),
            ),
          ],
        );
        final controls = _mediaControls();
        if (constraints.maxWidth >= 720) {
          return Row(
            children: [
              SizedBox(width: 340, child: navigation),
              Expanded(child: controls),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [navigation, controls],
        );
      },
    ),
  );

  Widget _mediaControls() {
    if (_unavailable || _recovering) return const SizedBox.shrink();
    if (_isImage) {
      final ready = _opened?.image != null;
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Zoom out (−)',
            onPressed: ready ? () => _zoom(1 / 1.5) : null,
            icon: const Icon(Icons.zoom_out),
          ),
          ValueListenableBuilder<Matrix4>(
            valueListenable: _transform,
            builder: (context, matrix, child) => Semantics(
              label: 'Photo zoom',
              value: '${(matrix.getMaxScaleOnAxis() * 100).round()} percent',
              child: Text('${(matrix.getMaxScaleOnAxis() * 100).round()}%'),
            ),
          ),
          IconButton(
            tooltip: 'Zoom in (+)',
            onPressed: ready ? () => _zoom(1.5) : null,
            icon: const Icon(Icons.zoom_in),
          ),
          IconButton(
            tooltip: 'Fit photo · reset zoom (0)',
            onPressed: ready ? _resetZoom : null,
            icon: const Icon(Icons.fit_screen),
          ),
          PopupMenuButton<Offset>(
            tooltip: 'Pan photo',
            enabled: ready,
            icon: const Icon(Icons.open_with),
            onSelected: (offset) => _pan(offset.dx, offset.dy),
            itemBuilder: (context) => const [
              PopupMenuItem(value: Offset(64, 0), child: Text('Pan left')),
              PopupMenuItem(value: Offset(-64, 0), child: Text('Pan right')),
              PopupMenuItem(value: Offset(0, 64), child: Text('Pan up')),
              PopupMenuItem(value: Offset(0, -64), child: Text('Pan down')),
            ],
          ),
        ],
      );
    }
    final opened = _opened;
    final player = opened?.player;
    if (opened == null || player == null) return const SizedBox.shrink();
    return Row(
      children: [
        StreamBuilder<bool>(
          stream: player.stream.playing,
          initialData: player.state.playing,
          builder: (context, snapshot) {
            final playing = snapshot.data ?? false;
            return IconButton.filledTonal(
              tooltip: playing ? 'Pause (Space)' : 'Play (Space)',
              onPressed: () => unawaited(player.playOrPause()),
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            );
          },
        ),
        Expanded(child: _volume(player)),
        IconButton(
          tooltip: 'Fullscreen',
          onPressed: () =>
              unawaited(opened.videoKey.currentState?.enterFullscreen()),
          icon: const Icon(Icons.fullscreen),
        ),
      ],
    );
  }

  Widget _volume(Player player) => StreamBuilder<double>(
    stream: player.stream.volume,
    initialData: player.state.volume,
    builder: (context, snapshot) {
      final volume = (snapshot.data ?? 100).clamp(0.0, 100.0);
      return Row(
        children: [
          IconButton(
            tooltip: volume == 0 ? 'Unmute' : 'Mute',
            onPressed: () => unawaited(player.setVolume(volume == 0 ? 100 : 0)),
            icon: Icon(volume == 0 ? Icons.volume_off : Icons.volume_up),
          ),
          Expanded(
            child: Semantics(
              label: 'Video volume',
              child: Slider(
                value: volume,
                max: 100,
                label: '${volume.round()}%',
                semanticFormatterCallback: (value) =>
                    '${value.round()} percent',
                onChanged: (value) => unawaited(player.setVolume(value)),
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _metadata(BuildContext context) => Material(
    color: const Color(0xFF171B19),
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Media details',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 20),
          _detail('Name', _item.name),
          _detail('Library', widget.sourceLabel),
          _detail('Position', 'Item ${_index + 1} of ${_items.length}'),
          _detail('Type', _item.mimeType),
          if (_item.size != null) _detail('Size', _bytes(_item.size!)),
          if (_item.width != null && _item.height != null)
            _detail('Dimensions', '${_item.width} × ${_item.height} pixels'),
          if (_item.durationMillis != null)
            _detail('Duration', _duration(_item.durationMillis!)),
          const Divider(height: 28),
          Text(
            widget.session == null
                ? 'Viewing your library. '
                      'Temporary previews are not saved copies.'
                : 'Direct peer media. Seeking may request more verified '
                      'chunks. Ending access stops future reads; received '
                      'bytes cannot be remotely erased. '
                      'App cache is not a saved copy.',
          ),
          const SizedBox(height: 20),
          const Text('Keyboard', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'Page Up / Down or Alt + ← / →: previous / next\n'
            'Escape: back to library\n',
          ),
          Text(
            _isImage
                ? '← / →: previous / next\n'
                      '+ / −: zoom · 0: fit\nShift + arrows: pan\n'
                      'Drag or pinch the photo to explore.'
                : 'Space: play / pause\n'
                      '← / →: seek (with video focused)\n'
                      'Use the video fullscreen button '
                      'for an unobstructed view.',
          ),
        ],
      ),
    ),
  );

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Color(0xFFB5C4BA), fontSize: 12),
        ),
        const SizedBox(height: 4),
        SelectableText(value),
      ],
    ),
  );

  String _bytes(int bytes) {
    if (bytes < 1024) return '$bytes bytes';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _duration(int millis) {
    final duration = Duration(milliseconds: millis);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return duration.inHours > 0
        ? '${duration.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
  }
}
