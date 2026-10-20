import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';
import 'package:typed_data/typed_buffers.dart';
import 'package:vault_wire_spike/envelope.dart';

/// Throwaway Phase 0 signaling over MQTT 5. Not the production vault_signaling.
class Endpoint {
  const Endpoint(
    this.host,
    this.port, {
    this.caPem,
    this.user,
    this.password,
    this.secure = true,
  });
  final String host;
  final int port;
  final Uint8List? caPem;
  final String? user;
  final String? password;
  final bool secure;
  String get label => '$host:$port';
}

const privateTopicPrefix = 'vault/v1/in/';
const presenceTopicPrefix = 'vault/v1/presence/';
const maxInboundBytes = 24 * 1024;

String privateTopic(Uint8List nodeId) =>
    privateTopicPrefix + nodeIdText(nodeId);

class SignalingStats {
  int connects = 0;
  int connectFailures = 0;
  int disconnects = 0;
  int publishes = 0;
  int publishSuppressed = 0;
  int inboundFrames = 0;
  int delivered = 0;
  int duplicatesReacked = 0;
  int droppedOversize = 0;
  int droppedRateLimited = 0;
  final rejected = <String, int>{};
  void reject(String reason) =>
      rejected.update(reason, (v) => v + 1, ifAbsent: () => 1);
  Map<String, Object?> toJson() => {
    'connects': connects,
    'connectFailures': connectFailures,
    'disconnects': disconnects,
    'publishes': publishes,
    'publishSuppressed': publishSuppressed,
    'inboundFrames': inboundFrames,
    'delivered': delivered,
    'duplicatesReacked': duplicatesReacked,
    'droppedOversize': droppedOversize,
    'droppedRateLimited': droppedRateLimited,
    'rejected': rejected,
  };
}

/// Token bucket over frames and bytes per second.
class InboundLimiter {
  InboundLimiter({
    this.framesPerSecond = 100,
    this.bytesPerSecond = 512 * 1024,
  });
  final int framesPerSecond;
  final int bytesPerSecond;
  int _second = -1;
  int _frames = 0;
  int _bytes = 0;

  bool allow(int bytes, DateTime now) {
    final second = now.millisecondsSinceEpoch ~/ 1000;
    if (second != _second) {
      _second = second;
      _frames = 0;
      _bytes = 0;
    }
    if (_frames + 1 > framesPerSecond || _bytes + bytes > bytesPerSecond) {
      return false;
    }
    _frames++;
    _bytes += bytes;
    return true;
  }
}

class Inbound {
  Inbound(this.topic, this.payload);
  final String topic;
  final Uint8List payload;
}

/// One MQTT connection with endpoint failover and bounded jittered backoff.
class MqttLink {
  MqttLink({
    required this.endpoints,
    required this.subscriptions,
    required this.label,
    this.dropOutboundRate = 0,
    int seed = 1,
    this.backoffBase = const Duration(milliseconds: 400),
    this.backoffMax = const Duration(seconds: 6),
  }) : _random = Random(seed);

  final List<Endpoint> endpoints;
  final List<String> subscriptions;
  final String label;
  final double dropOutboundRate;
  final Duration backoffBase;
  final Duration backoffMax;
  final Random _random;
  final stats = SignalingStats();
  final _inbound = StreamController<Inbound>.broadcast();
  final connectionLog = <Map<String, Object?>>[];
  MqttServerClient? _client;
  Endpoint? current;
  bool _stopped = false;
  bool _connecting = false;
  int _endpointIndex = 0;
  int _attempt = 0;
  Timer? _retry;
  Completer<void> _connected = Completer<void>();

  Stream<Inbound> get inbound => _inbound.stream;
  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;
  Future<void> get connected => _connected.future;

  void _log(String event, [Object? detail]) {
    connectionLog.add({
      'atMs': DateTime.now().millisecondsSinceEpoch,
      'event': event,
      'endpoint': current?.label,
      'detail': ?detail?.toString(),
    });
    if (connectionLog.length > 100) connectionLog.removeAt(0);
  }

  Future<void> start() async {
    _stopped = false;
    unawaited(_connectLoop());
  }

  Future<void> _connectLoop() async {
    if (_stopped || _connecting) return;
    _connecting = true;
    try {
      final endpoint = endpoints[_endpointIndex % endpoints.length];
      current = endpoint;
      final client =
          MqttServerClient.withPort(
              endpoint.host,
              '$label-${_random.nextInt(1 << 31).toRadixString(16)}',
              endpoint.port,
            )
            ..secure = endpoint.secure
            ..keepAlivePeriod = 15
            ..autoReconnect = false
            ..logging(on: false);
      if (endpoint.secure && endpoint.caPem != null) {
        client.securityContext = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(endpoint.caPem!);
      }
      client.onDisconnected = () => _onDisconnected(client);
      client.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(client.clientIdentifier)
          .startClean()
          .authenticateAs(endpoint.user, endpoint.password);
      await client.connect().timeout(const Duration(seconds: 5));
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        throw StateError('not connected: ${client.connectionStatus}');
      }
      _client = client;
      stats.connects++;
      _attempt = 0;
      _log('connected');
      client.updates!.listen((batch) {
        for (final message in batch) {
          final publish = message.payload;
          if (publish is! MqttPublishMessage) continue;
          final bytes = publish.payload.message;
          if (bytes == null) continue;
          _inbound.add(Inbound(message.topic ?? '', Uint8List.fromList(bytes)));
        }
      });
      for (final topic in subscriptions) {
        client.subscribe(topic, MqttQos.atLeastOnce);
      }
      if (!_connected.isCompleted) _connected.complete();
    } on Object catch (error) {
      stats.connectFailures++;
      _log('connect failed', error.runtimeType);
      _endpointIndex++;
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  void _onDisconnected(MqttServerClient client) {
    if (!identical(client, _client)) return;
    _client = null;
    stats.disconnects++;
    _log('disconnected');
    if (_connected.isCompleted) _connected = Completer<void>();
    if (!_stopped) {
      _endpointIndex++;
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_stopped) return;
    _retry?.cancel();
    final cap = backoffMax.inMilliseconds;
    final ceiling = min(
      cap,
      backoffBase.inMilliseconds * (1 << min(_attempt, 10)),
    );
    _attempt++;
    // Full jitter keeps a fleet of reconnecting clients from synchronizing.
    final delay = Duration(milliseconds: _random.nextInt(ceiling) + 1);
    _retry = Timer(delay, () => unawaited(_connectLoop()));
  }

  /// Returns true when the frame was handed to the connected client.
  bool publish(String topic, Uint8List payload) {
    final client = _client;
    if (client == null || !isConnected) return false;
    if (dropOutboundRate > 0 && _random.nextDouble() < dropOutboundRate) {
      stats.publishSuppressed++;
      return true;
    }
    final buffer = Uint8Buffer()..addAll(payload);
    client.publishMessage(topic, MqttQos.atLeastOnce, buffer);
    stats.publishes++;
    return true;
  }

  Future<void> stop() async {
    _stopped = true;
    _retry?.cancel();
    final client = _client;
    _client = null;
    client?.disconnect();
    await _inbound.close();
  }

  /// Simulates a network drop without telling the broker.
  void dropConnection() => _client?.disconnect();
}

String utf8Text(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);
