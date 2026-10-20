import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Native eligibility state, never proof that a peer can reach this device.
class PublishingAvailabilityStatus {
  const new({
    required this.supported,
    required this.platform,
    required this.publishing,
    required this.autostart,
    required this.canAutostart,
    required this.canMinimizeToTray,
    required this.backgroundMode,
    required this.wakeLockHeld,
    required this.detail,
  });

  factory fromMap(Map<Object?, Object?> map) {
    return PublishingAvailabilityStatus(
      supported: map['supported']! as bool,
      platform: map['platform']! as String,
      publishing: map['publishing']! as bool,
      autostart: map['autostart']! as bool,
      canAutostart: map['canAutostart']! as bool,
      canMinimizeToTray: map['canMinimizeToTray']! as bool,
      backgroundMode: map['backgroundMode']! as String,
      wakeLockHeld: map['wakeLockHeld']! as bool,
      detail: map['detail'] as String?,
    );
  }

  final bool supported;
  final String platform;
  final bool publishing;
  final bool autostart;
  final bool canAutostart;
  final bool canMinimizeToTray;
  final String backgroundMode;
  final bool wakeLockHeld;
  final String? detail;
}

/// Explicit foreground publication controls shared by Android and Windows.
///
/// Call [start] only for the user's Publish action, before enabling delivery.
/// Failures must leave delivery off. Neither login nor process restoration is a
/// publishing instruction. Native stop callbacks must disable delivery before
/// their acknowledgment; Windows Quit waits for this acknowledgment.
class PublishingAvailability {
  new() {
    if (_supported) _channel.setMethodCallHandler(_handleMethod);
  }

  static const _channel = MethodChannel('dev.vault/availability');
  final _stops = StreamController<String>.broadcast();
  bool _disposed = false;

  /// Awaited before native Stop/Quit is acknowledged; do not call [stop] here.
  Future<void> Function(String reason)? onStopped;

  /// Native stop reasons, emitted after [onStopped] has disabled delivery.
  Stream<String> get stops => _stops.stream;

  bool get _supported => Platform.isAndroid || Platform.isWindows;

  Future<Object?> _handleMethod(MethodCall call) async {
    if (call.method != 'stopped') throw MissingPluginException(call.method);
    final reason = call.arguments;
    if (reason is! String) {
      throw const FormatException('Native stopped callback requires a reason.');
    }
    await onStopped?.call(reason);
    if (!_disposed) _stops.add(reason);
    return null;
  }

  /// Reads current native state without prompting or starting publication.
  Future<PublishingAvailabilityStatus> status() async {
    if (!_supported) {
      return PublishingAvailabilityStatus(
        supported: false,
        platform: Platform.operatingSystem,
        publishing: false,
        autostart: false,
        canAutostart: false,
        canMinimizeToTray: false,
        backgroundMode: 'unsupported',
        wakeLockHeld: false,
        detail:
            'Publishing availability is supported only on Android and Windows.',
      );
    }
    return await _invoke('status');
  }

  /// Requests OS eligibility, including Android's explicit notification prompt.
  Future<PublishingAvailabilityStatus> start() => _invoke('start');

  /// Stops native publication eligibility and releases its resources.
  Future<PublishingAvailabilityStatus> stop() => _invoke('stop');

  /// Windows-only login launch; login launch never enables publication.
  Future<PublishingAvailabilityStatus> setAutostart({required bool enabled}) =>
      _invoke('setAutostart', <String, Object?>{'enabled': enabled});

  /// Windows-only minimization while the existing UI engine stays alive.
  Future<PublishingAvailabilityStatus> minimizeToTray() =>
      _invoke('minimizeToTray');

  Future<PublishingAvailabilityStatus> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (_disposed) {
      throw StateError('PublishingAvailability has been disposed.');
    }
    if (!_supported) {
      throw UnsupportedError(
        'Publishing availability is unavailable on this OS.',
      );
    }
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      method,
      arguments,
    );
    if (result == null) {
      throw const FormatException('Native availability returned no status.');
    }
    return PublishingAvailabilityStatus.fromMap(result);
  }

  /// Disable delivery and call [stop] before disposing the application runtime.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_supported) _channel.setMethodCallHandler(null);
    onStopped = null;
    await _stops.close();
  }
}
