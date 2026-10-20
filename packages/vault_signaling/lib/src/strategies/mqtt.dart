import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:typed_data/typed_buffers.dart';
import 'package:vault_signaling/src/mqtt_bounded_client.dart';
import 'package:vault_signaling/src/mqtt_packet_buffer.dart';
import 'package:vault_signaling/src/presence.dart';
import 'package:vault_signaling/src/strategy.dart';

/// A hostname-verified TLS-only MQTT5 broker.
class MqttEndpoint {
  /// Uses a trusted TLS listener; plaintext port 1883 is rejected.
  new(this.host, {this.port = 8883}) {
    if (host.isEmpty ||
        host.contains('/') ||
        host.contains(':') ||
        port < 1 ||
        port > 65535 ||
        port == 1883) {
      throw ArgumentError('A TLS broker hostname and TLS port are required');
    }
  }

  /// TLS server hostname, without scheme, path or embedded port.
  final String host;

  /// TLS listener port; 8883 by default.
  final int port;

  /// Public endpoint label, containing no credentials or message data.
  String get label => '$host:$port';
}

/// Sanitized endpoint lifecycle event.
class MqttDiagnostic {
  /// Records an operation without retaining private payloads.
  const new(this.endpoint, this.event);

  /// Broker hostname and port.
  final String endpoint;

  /// Lifecycle description or failure category.
  final String event;
}

/// TLS with platform trust roots, QoS1, clean sessions, never retained.
/// Endpoints are alternatives, NOT a federated broker network.
class MqttSignaling implements SignalingStrategy, PublicPresenceTransport {
  /// Rotates through one to eight alternatives, without assuming federation.
  new(List<MqttEndpoint> endpoints) : endpoints = List.unmodifiable(endpoints) {
    if (endpoints.isEmpty || endpoints.length > 8) {
      throw ArgumentError('Supply between one and eight TLS endpoints');
    }
  }

  /// ADR 0004's probed public test listeners, not availability guarantees.
  static List<MqttEndpoint> get publicTestEndpoints => [
    MqttEndpoint('broker.emqx.io'),
    MqttEndpoint('test.mosquitto.org', port: 8886),
  ];

  /// Immutable ordered failover alternatives shared with the peer.
  final List<MqttEndpoint> endpoints;
  final _inbound = StreamController<SignalFrame>.broadcast();
  final _connections = StreamController<bool>.broadcast();
  final _diagnostics = StreamController<MqttDiagnostic>.broadcast();
  final _publicFrames = StreamController<SignalFrame>.broadcast();
  bool _publicEnabled = false;
  Future<void>? _presenceChange;
  Completer<void>? _presencePolicyCancel;
  int _publicSecond = -1;
  int _publicFramesThisSecond = 0;
  int _publicBytesThisSecond = 0;
  int _failureSecond = -1;
  int _failureCount = 0;
  final _random = Random.secure();
  final _cancel = Completer<void>();
  final _ready = Completer<void>();
  BoundedMqttClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;
  Timer? _retry;
  String? _nodeId;
  Future<void>? _startFuture;
  bool _closed = false;
  bool _connecting = false;
  bool _connected = false;
  int _index = 0;
  int _attempt = 0;
  @override
  Stream<SignalFrame> get inbound => _inbound.stream;
  @override
  Stream<bool> get connectionChanges => _connections.stream;

  /// Sanitized endpoint lifecycle events; private frames are never logged.
  Stream<MqttDiagnostic> get diagnostics => _diagnostics.stream;
  @override
  bool get connected => _connected && !_closed;

  @override
  Stream<SignalFrame> get publicFrames => _publicFrames.stream;

  @override
  bool get publicPresenceEnabled => _publicEnabled && !_closed;

  @override
  Future<void> setPublicPresenceEnabled(bool enabled) {
    if (_closed) return Future.error(StateError('MQTT signaling is closed'));
    if (_publicEnabled == enabled) return _presenceChange ?? Future.value();
    final previousCancel = _presencePolicyCancel;
    if (previousCancel != null && !previousCancel.isCompleted) {
      previousCancel.complete();
    }
    final policyCancel = Completer<void>();
    _presencePolicyCancel = policyCancel;
    _publicEnabled = enabled;
    if (_nodeId == null) return Future.value();
    final change = _changePresenceSubscription(policyCancel.future);
    _presenceChange = change;
    return change.whenComplete(() {
      if (identical(_presenceChange, change)) _presenceChange = null;
    });
  }

  Future<void> _changePresenceSubscription(Future<void> policyChanged) async {
    final ready = Completer<void>();
    final subscription = _publicEnabled
        ? _connections.stream.listen((value) {
            if (value && !ready.isCompleted) ready.complete();
          })
        : null;
    _disconnectCurrent();
    _retry?.cancel();
    _retry = null;
    if (_connecting) {
      _scheduleRetry();
    } else {
      _launch();
    }
    if (subscription == null) return;
    try {
      await Future.any([
        ready.future,
        _cancel.future.then<void>(
          (_) => throw StateError('MQTT signaling closed'),
        ),
        policyChanged.then<void>(
          (_) => throw StateError('Public presence policy changed'),
        ),
      ]).timeout(const Duration(seconds: 20));
    } finally {
      await subscription.cancel();
    }
  }

  bool _allowPublic(int size) {
    final second = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_publicSecond != second) {
      _publicSecond = second;
      _publicFramesThisSecond = 0;
      _publicBytesThisSecond = 0;
    }
    if (_publicFramesThisSecond >= 16 ||
        _publicBytesThisSecond + size > 32 * 1024) {
      return false;
    }
    _publicFramesThisSecond++;
    _publicBytesThisSecond += size;
    return true;
  }

  @override
  Future<void> start(String nodeId) {
    if (_closed) return Future.error(StateError('MQTT signaling is closed'));
    if (!signalNodeIdPattern.hasMatch(nodeId)) {
      return Future.error(ArgumentError('Invalid node id'));
    }
    if (_nodeId != null && _nodeId != nodeId) {
      return Future.error(StateError('MQTT identity cannot change'));
    }
    if (_startFuture != null) return _startFuture!;
    _nodeId = nodeId;
    _startFuture = Future.any([
      _ready.future,
      _cancel.future.then<void>(
        (_) => throw StateError('MQTT signaling closed'),
      ),
    ]).timeout(const Duration(seconds: 20));
    _launch();
    return _startFuture!;
  }

  void _launch() {
    if (_closed || _connecting) return;
    // MQTT's socket write path can throw outside the returned connect future.
    // Create its timers, socket and listeners inside this zone too.
    runZonedGuarded(
      () {
        unawaited(_connect());
      },
      (error, stack) {
        if (_closed) return;
        _emitFailure('asynchronous library error', error);
        _disconnectCurrent();
        _scheduleRetry();
      },
    );
  }

  void _emitFailure(String event, [Object? error]) {
    if (_closed) return;
    final second = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_failureSecond != second) {
      _failureSecond = second;
      _failureCount = 0;
    }
    if (_failureCount++ >= 16) return;
    final endpoint = endpoints[_index % endpoints.length];
    _diagnostics.add(MqttDiagnostic(endpoint.label, event));
    _inbound.addError(SignalingFailure(event, cause: error?.runtimeType));
  }

  Future<void> _connect() async {
    _connecting = true;
    final endpoint = endpoints[_index % endpoints.length];
    final client =
        BoundedMqttClient(
            endpoint.host,
            'vault-${_random.nextInt(0x7fffffff).toRadixString(16)}',
            endpoint.port,
          )
          ..keepAlivePeriod = 15
          ..autoReconnect = false
          ..logging(on: false);
    _client = client;
    final topic = 'vault/v1/in/$_nodeId';
    final pendingSubscriptions = <String, Completer<bool>>{
      topic: Completer<bool>(),
      if (_publicEnabled) 'vault/v1/presence/#': Completer<bool>(),
    };
    client
      ..onSubscribed = (subscription) {
        final ready = pendingSubscriptions[subscription.topic.rawTopic];
        if (ready != null && !ready.isCompleted) ready.complete(true);
      }
      ..onSubscribeFail = (subscription) {
        final ready = pendingSubscriptions[subscription.topic.rawTopic];
        if (ready != null && !ready.isCompleted) ready.complete(false);
      }
      ..onDisconnected = () {
        for (final ready in pendingSubscriptions.values) {
          if (!ready.isCompleted) ready.complete(false);
        }
        if (_closed || !identical(_client, client)) return;
        _emitFailure('broker disconnected');
        _disconnectCurrent();
        _scheduleRetry();
      }
      ..connectionMessage = MqttConnectMessage()
          .withClientIdentifier(client.clientIdentifier)
          .withMaximumMessageSize(maxMqttPacketBytes)
          .startClean();
    try {
      final connecting = client.connect();
      // Future cancellation cannot cancel a Dart socket handshake. Dispose a
      // late successful connection as well, never resurrecting a closed link.
      unawaited(
        connecting.then<void>(
          (_) {
            if (_closed || !identical(_client, client)) client.disconnect();
          },
          onError: (Object error, StackTrace stack) {
            // The awaited bounded branch below owns reporting.
          },
        ),
      );
      await Future.any<Object?>([
        connecting.timeout(const Duration(seconds: 5)),
        _cancel.future,
      ]);
      if (_closed || !identical(_client, client)) return;
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        throw StateError('Broker rejected connection');
      }
      _updates = client.updates!.listen(
        (batch) {
          if (_closed || !identical(_client, client)) return;
          for (final message in batch) {
            final publish = message.payload;
            if (publish is! MqttPublishMessage) continue;
            final receivedTopic = message.topic ?? '';
            final isPublic = receivedTopic.startsWith('vault/v1/presence/');
            if (receivedTopic != topic && !(_publicEnabled && isPublic)) {
              continue;
            }
            if (publish.header?.retain ?? false) {
              _emitFailure('retained private frame rejected');
              continue;
            }
            final data = publish.payload.message;
            final limit = isPublic
                ? maxPublicPresenceBytes
                : maxSignalFrameBytes;
            if (data == null || data.isEmpty || data.length > limit) {
              _emitFailure('inbound frame size rejected');
              continue;
            }
            if (isPublic) {
              final signer = receivedTopic.substring(
                'vault/v1/presence/'.length,
              );
              if (!signalNodeIdPattern.hasMatch(signer) ||
                  !_allowPublic(data.length)) {
                _emitFailure('public presence transport budget rejected');
                continue;
              }
              _publicFrames.add(SignalFrame(signer, Uint8List.fromList(data)));
            } else {
              _inbound.add(SignalFrame(_nodeId!, Uint8List.fromList(data)));
            }
          }
        },
        onError: (Object error, StackTrace stack) {
          if (_closed || !identical(_client, client)) return;
          _emitFailure('MQTT update stream failed', error);
          _disconnectCurrent();
          _scheduleRetry();
        },
        onDone: () {
          if (_closed || !identical(_client, client)) return;
          _emitFailure('MQTT update stream ended');
          _disconnectCurrent();
          _scheduleRetry();
        },
      );
      for (final subscription in pendingSubscriptions.keys) {
        if (client.subscribe(subscription, MqttQos.atLeastOnce) == null) {
          throw StateError('Subscribe request failed');
        }
      }
      final subscribed = await Future.any<bool>([
        Future.wait(pendingSubscriptions.values.map((ready) => ready.future))
            .then((results) => results.every((result) => result))
            .timeout(const Duration(seconds: 5)),
        _cancel.future.then((_) => false),
      ]);
      if (_closed || !identical(_client, client)) return;
      if (!subscribed) throw StateError('Broker refused subscription');
      _connected = true;
      _attempt = 0;
      _connections.add(true);
      _diagnostics.add(MqttDiagnostic(endpoint.label, 'subscription ready'));
      if (!_ready.isCompleted) _ready.complete();
    } on Object catch (error) {
      if (!_closed && identical(_client, client)) {
        _emitFailure('connection or subscription failed', error);
        _disconnectCurrent();
        _scheduleRetry();
      }
    } finally {
      _connecting = false;
    }
  }

  void _disconnectCurrent() {
    final client = _client;
    _client = null;
    if (_connected && !_closed) _connections.add(false);
    _connected = false;
    final cancellation = _updates?.cancel();
    _updates = null;
    if (cancellation != null) unawaited(cancellation);
    try {
      client?.disconnect();
    } on Object catch (error) {
      if (!_closed) _emitFailure('disconnect failed', error);
    }
  }

  void _scheduleRetry() {
    if (_closed || _retry != null) return;
    _index++;
    final ceiling = min(6000, 400 * (1 << min(_attempt++, 5)));
    _retry = Timer(Duration(milliseconds: _random.nextInt(ceiling) + 1), () {
      _retry = null;
      if (_connecting) {
        _scheduleRetry();
      } else {
        _launch();
      }
    });
  }

  @override
  Future<void> publish(String recipient, Uint8List bytes) async {
    if (!connected || _client == null) throw StateError('MQTT is not ready');
    if (!signalNodeIdPattern.hasMatch(recipient) ||
        bytes.isEmpty ||
        bytes.length > maxSignalFrameBytes) {
      throw const FormatException('Invalid signal frame');
    }
    await _publishTopic('vault/v1/in/$recipient', bytes);
  }

  @override
  Future<void> publishPublicPresence(
    String signerNodeId,
    Uint8List bytes,
  ) async {
    if (!_publicEnabled) throw StateError('Public presence is not opted in');
    if (signerNodeId != _nodeId ||
        !connected ||
        _client == null ||
        bytes.isEmpty ||
        bytes.length > maxPublicPresenceBytes) {
      throw StateError('Invalid or unavailable public presence publication');
    }
    await _publishTopic('vault/v1/presence/$signerNodeId', bytes);
  }

  Future<void> _publishTopic(String topic, Uint8List bytes) async {
    final result = Completer<void>();
    runZonedGuarded(
      () {
        try {
          final payload = Uint8Buffer()..addAll(bytes);
          _client!.publishMessage(topic, MqttQos.atLeastOnce, payload);
          result.complete();
        } on Object catch (error, stack) {
          result.completeError(error, stack);
        }
      },
      (error, stack) {
        if (!result.isCompleted) result.completeError(error, stack);
        if (_closed) return;
        _emitFailure('asynchronous publish error', error);
        _disconnectCurrent();
        _scheduleRetry();
      },
    );
    await result.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retry?.cancel();
    _retry = null;
    _cancel.complete();
    _disconnectCurrent();
    _connections.add(false);
    unawaited(_connections.close());
    unawaited(_diagnostics.close());
    unawaited(_inbound.close());
    unawaited(_publicFrames.close());
  }
}
