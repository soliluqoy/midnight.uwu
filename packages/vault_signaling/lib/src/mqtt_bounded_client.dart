import 'dart:async';
import 'dart:io';

import 'package:event_bus/event_bus.dart';
import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';
import 'package:typed_data/typed_buffers.dart';
import 'package:vault_signaling/src/mqtt_packet_buffer.dart';

/// mqtt5_client connection adapter that guards input before packet allocation.
class BoundedMqttClient extends MqttClient {
  /// Always connects using platform-trusted hostname-verified TLS.
  new(super.server, super.clientIdentifier, super.port) : super.withPort();

  @override
  Future<MqttConnectionStatus?> connect([String? username, String? password]) {
    instantiationCorrect = true;
    final bus = EventBus();
    clientEventBus = MqttEventBus.fromEventBus(bus);
    bus.on<DisconnectOnNoPingResponse>().listen(disconnectOnNoPingResponse);
    connectionHandler = _BoundedHandler(bus);
    return super.connect(username, password);
  }

  @override
  int publishMessage(
    String topic,
    MqttQos qualityOfService,
    Uint8Buffer data, {
    bool retain = false,
    List<MqttUserProperty>? userProperties,
  }) {
    if ((publishingManager?.publishedMessages.length ?? 0) >= 128) {
      throw StateError('MQTT publication acknowledgment queue full');
    }
    return super.publishMessage(
      topic,
      qualityOfService,
      data,
      retain: retain,
      userProperties: userProperties,
    );
  }
}

class _BoundedHandler extends MqttSynchronousServerConnectionHandler {
  new(super.clientEventBus)
    : super(
        maxConnectionAttempts: 1,
        socketOptions: const <RawSocketOption>[],
        socketTimeout: const Duration(seconds: 4),
      ) {
    connectTimer = MqttCancellableAsyncSleep(5000);
  }
  bool _stopped = false;
  _BoundedConnection? _activeConnection;

  @override
  Future<MqttConnectionStatus> internalConnect(
    String? hostname,
    int? port,
    MqttConnectMessage? message,
  ) async {
    if (hostname == null || port == null || message == null || _stopped) {
      throw StateError('Invalid or stopped MQTT connection');
    }
    final secureConnection = _BoundedConnection(
      clientEventBus!,
      onDisconnected,
    );
    _activeConnection = secureConnection;
    connection = secureConnection;
    connectionStatus.state = MqttConnectionState.connecting;
    await secureConnection.connect(hostname, port);
    if (_stopped) {
      secureConnection.disposeClient();
      throw StateError('MQTT connection stopped');
    }
    sendMessage(message);
    await connectTimer.sleep();
    if (_stopped || connectionStatus.state != MqttConnectionState.connected) {
      secureConnection.disposeClient();
      throw StateError('MQTT connection acknowledgment failed');
    }
    initialConnectionComplete = true;
    return connectionStatus;
  }

  @override
  MqttConnectionState disconnect([MqttDisconnectMessage? disconnectMessage]) {
    _stopped = true;
    connectTimer.cancel();
    try {
      return super.disconnect(disconnectMessage);
    } finally {
      _activeConnection?.disposeClient();
    }
  }
}

class _BoundedConnection extends MqttServerSecureConnection {
  new(EventBus bus, this._onEnd)
    : super(
        null,
        bus,
        null,
        const <RawSocketOption>[],
        const Duration(seconds: 4),
      ) {
    messageStream = BoundedMqttPacketBuffer();
  }
  bool _disposed = false;
  final void Function()? _onEnd;

  @override
  void onDone() {
    super.onDone();
    _onEnd?.call();
  }

  @override
  void onError(Object? error) {
    super.onError(error);
    _onEnd?.call();
  }

  @override
  Future<MqttConnectionStatus?> connect(String server, int port) async {
    final status = await super.connect(server, port);
    if (_disposed) {
      super.disposeClient();
      throw StateError('Late MQTT TLS connection disposed');
    }
    return status;
  }

  @override
  Future<MqttConnectionStatus?> connectAuto(String server, int port) =>
      connect(server, port);

  @override
  void disposeClient() {
    _disposed = true;
    super.disposeClient();
  }
}
