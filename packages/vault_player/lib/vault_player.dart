import 'package:media_kit/media_kit.dart';

export 'range_server.dart';

/// Owns a real native media_kit player, including its audio/video resources.
///
/// The application supplies media_kit's native libraries and attaches [player]
/// to its video widget. Initialization failures propagate without a fallback.
class VaultPlayer {
  /// Initializes the native backend and creates its owned audio/video player.
  new({PlayerConfiguration configuration = const PlayerConfiguration()}) {
    MediaKit.ensureInitialized();
    _player = Player(configuration: configuration);
  }

  late final Player _player;
  Future<void>? _closing;

  /// Native player used by the application's media_kit video widget.
  Player get player => _player;

  /// Opens a real media URI and starts playback using the native backend.
  Future<void> open(Uri uri) {
    if (_closing != null) {
      return Future<void>.error(StateError('VaultPlayer is closed'));
    }
    return _player.open(Media(uri.toString()));
  }

  /// Disposes the backend once. A closed wrapper cannot be reopened.
  Future<void> close() => _closing ??= _player.dispose();
}
