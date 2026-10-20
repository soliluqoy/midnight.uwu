import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:vault_net/src/policy.dart';

/// Off by default. The spike's separately pinned native patch is required for
/// the Android phone-hosted-hotspot experiment; production keeps monitoring on.
const experimentalHotspot = bool.fromEnvironment('VAULT_HOTSPOT');
Future<void>? _initialization;

/// Initializes the native factory once, preserving normal network monitoring.
Future<void> initializeNativeWebRtc() => _initialization ??= () async {
  if (Platform.isAndroid) {
    await WebRTC.initialize(
      options: {'disableNetworkMonitor': experimentalHotspot},
    );
  }
}();

/// Preserves the plugin's otherwise omitted zero-retransmission setting.
class EphemeralInit extends RTCDataChannelInit {
  /// Configures an unordered binary channel with no retransmissions.
  new() {
    ordered = false;
    maxRetransmits = 0;
    binaryType = 'binary';
  }

  // webrtc_interface 1.5.1 incorrectly omits zero from its serializer.
  @override
  Map<String, dynamic> toMap() => {...super.toMap(), 'maxRetransmits': 0};
}

/// Plugin-independent operations for one owned native data channel.
class NativeChannel {
  /// Wraps an existing native channel without allocating a second channel.
  new(this._channel);
  final RTCDataChannel _channel;

  /// Whether the native channel has actually reached its open state.
  bool get open => _channel.state == RTCDataChannelState.RTCDataChannelOpen;

  /// Queries the live native buffer counter with a bounded platform wait.
  Future<int> bufferedAmount() => _channel.getBufferedAmount().timeout(
    const Duration(seconds: 3),
    onTimeout: () => throw const PeerFailure(
      'Native data-channel buffered-amount query timed out after 3 seconds',
    ),
  );

  /// Sends one already-bounded binary frame through the native channel.
  Future<void> send(Uint8List bytes) => _channel
      .send(RTCDataChannelMessage.fromBinary(bytes))
      .timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw const PeerFailure(
          'Native data-channel send timed out after 5 seconds',
        ),
      );

  /// Clears callbacks and closes the owned native channel.
  Future<void> close() async {
    _channel
      ..onMessage = null
      ..onDataChannelState = null;
    await _channel.close().timeout(const Duration(seconds: 3));
  }
}

/// Plugin types never cross this seam. The policy and authenticator are pure.
class NativePeer {
  /// Creates the data-only native adapter with explicit lifecycle callbacks.
  new({
    required this.onChannel,
    required this.onMessage,
    required this.onDisconnected,
    required this.onFailure,
  });

  /// Receives each validated channel label and its native wrapper once.
  final void Function(String, NativeChannel) onChannel;

  /// Receives bounded binary native frames without exposing plugin types.
  final void Function(String, Uint8List) onMessage;

  /// Signals loss of an established ICE route so the owner can pause sends.
  final void Function() onDisconnected;

  /// Reports a sanitized transport or direct-only policy failure.
  final void Function(Object) onFailure;
  RTCPeerConnection? _pc;
  final _channels = <String, NativeChannel>{};
  bool _closed = false;
  bool _everConnected = false;
  bool _routeDisconnected = false;

  static const _dataOnly = <String, dynamic>{
    'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
    'optional': <dynamic>[],
  };

  /// Allocates a data-only native peer with validated STUN-only configuration.
  Future<void> create(List<String> stunUrls) async {
    await initializeNativeWebRtc();
    if (_closed) throw const PeerFailure('Native peer already closed');
    final pc = await createPeerConnection({
      'iceServers': [
        if (stunUrls.isNotEmpty) {'urls': validateStunUrls(stunUrls)},
      ],
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'iceTransportPolicy': 'all',
    });
    _pc = pc;
    if (_closed) {
      try {
        await pc.close().timeout(const Duration(seconds: 3));
      } finally {
        await pc.dispose().timeout(const Duration(seconds: 3));
        _pc = null;
      }
      throw const PeerFailure('Native peer closed during initialization');
    }
    pc
      ..onDataChannel = _attach
      ..onIceCandidate = (candidate) {
        if (_closed) return;
        final text = candidate.candidate ?? '';
        if (RegExp(r'\btyp\s+relay\b').hasMatch(text)) {
          onFailure(const PeerFailure('Native relay ICE candidate rejected'));
        }
      }
      ..onIceConnectionState = (state) {
        if (_closed) return;
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          _everConnected = true;
          _routeDisconnected = false;
        } else if (_everConnected &&
            (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
                state == RTCIceConnectionState.RTCIceConnectionStateFailed)) {
          _routeDisconnected = true;
          onDisconnected();
        }
      }
      ..onConnectionState = (state) {
        if (_closed) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _everConnected = true;
          _routeDisconnected = false;
        } else if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          if (_everConnected) {
            _routeDisconnected = true;
            onDisconnected();
          } else {
            onFailure(
              const PeerFailure(
                'Native peer connection failed',
                problem: ConnectionProblem.noDirectRoute,
              ),
            );
          }
        }
      };
  }

  void _attach(RTCDataChannel channel) {
    final label = channel.label ?? '';
    if (_closed ||
        !const {'critical', 'bulk', 'ephemeral'}.contains(label) ||
        _channels.containsKey(label)) {
      unawaited(
        channel
            .close()
            .timeout(const Duration(seconds: 3))
            .catchError((Object _) {}),
      );
      if (!_closed) onFailure(const PeerFailure('Unexpected data channel'));
      return;
    }
    final wrapped = NativeChannel(channel);
    _channels[label] = wrapped;
    channel
      ..onMessage = (message) {
        if (_closed) return;
        if (!message.isBinary || message.binary.length > maxPacketBytes) {
          onFailure(const PeerFailure('Invalid or oversized native packet'));
          return;
        }
        onMessage(label, message.binary);
      }
      ..onDataChannelState = (state) {
        if (!_closed && state == RTCDataChannelState.RTCDataChannelClosed) {
          onFailure(const PeerFailure('Native data channel closed'));
        }
      };
    onChannel(label, wrapped);
  }

  Future<void> _createChannels() async {
    _attach(
      await _pc!.createDataChannel(
        'critical',
        RTCDataChannelInit()..binaryType = 'binary',
      ),
    );
    _attach(
      await _pc!.createDataChannel(
        'bulk',
        RTCDataChannelInit()..binaryType = 'binary',
      ),
    );
    _attach(await _pc!.createDataChannel('ephemeral', EphemeralInit()));
  }

  /// Creates a gathered offer, optionally requesting native ICE restart.
  Future<String> offer({bool restart = false}) async {
    if (_pc == null || _closed) {
      throw const PeerFailure('Native peer not active');
    }
    if (restart) {
      await _pc!.restartIce();
    } else {
      await _createChannels();
    }
    final constraints = <String, dynamic>{
      ..._dataOnly,
      if (restart) 'iceRestart': true,
    };
    await _pc!.setLocalDescription(await _pc!.createOffer(constraints));
    return await _gather();
  }

  /// Applies the complete signed offer and gathers a data-only answer.
  Future<String> answer(String sdp) async {
    SdpBinding.parse(sdp);
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    await _pc!.setLocalDescription(await _pc!.createAnswer(_dataOnly));
    return await _gather();
  }

  /// Applies the expected complete answer to the existing native peer.
  Future<void> acceptAnswer(String sdp) async {
    SdpBinding.parse(sdp);
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  Future<String> _gather() async {
    final watch = Stopwatch()..start();
    while (!_closed &&
        await _pc!.getIceGatheringState() !=
            RTCIceGatheringState.RTCIceGatheringStateComplete) {
      // Native STUN retransmissions on unrouted interfaces can outlast 20s
      // even when another interface already has usable candidates. Wait for
      // complete gathering; never signal a silently truncated candidate set.
      if (watch.elapsed > const Duration(seconds: 60)) {
        throw const PeerFailure(
          'Native ICE gathering timed out after 60 seconds',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_closed) {
      throw const PeerFailure('Native peer closed during ICE gathering');
    }
    final sdp = (await _pc!.getLocalDescription())?.sdp;
    if (sdp == null) throw const PeerFailure('Native SDP missing');
    SdpBinding.parse(sdp);
    return sdp;
  }

  /// Requires a succeeded selected pair with two verifiable non-relay types.
  Future<DirectPath> directPath() async {
    final watch = Stopwatch()..start();
    const timeout = Duration(seconds: 3);
    while (true) {
      final pc = _pc;
      if (_closed || pc == null) {
        throw const PeerFailure('Native peer is closed');
      }
      final remaining = timeout - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw const DirectPathPending();
      }
      if (_routeDisconnected) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        continue;
      }
      final stats = await pc.getStats().timeout(
        remaining,
        onTimeout: () => throw const PeerFailure(
          'Native selected-pair statistics query timed out after 3 seconds',
        ),
      );
      try {
        return requireDirectPath([
          for (final report in stats)
            IceReport(report.id, report.type, <String, Object?>{
              for (final entry in report.values.entries)
                if (entry.key is String) entry.key as String: entry.value,
            }),
        ]);
      } on DirectPathPending {
        // Native nomination can switch the selected pair before its stats
        // reach succeeded. Send nothing; revalidate the entire fresh report.
        // Missing, ambiguous, failed and relayed routes remain terminal.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  /// Releases callbacks, channels and peer even if an individual close fails.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final pc = _pc;
    _pc = null;
    if (pc != null) {
      pc
        ..onDataChannel = null
        ..onIceCandidate = null
        ..onIceConnectionState = null
        ..onConnectionState = null;
    }
    Object? firstError;
    for (final channel in _channels.values) {
      try {
        await channel.close();
      } on Object catch (error) {
        firstError ??= error;
      }
    }
    _channels.clear();
    if (pc != null) {
      try {
        await pc.close().timeout(const Duration(seconds: 3));
      } on Object catch (error) {
        firstError ??= error;
      } finally {
        try {
          await pc.dispose().timeout(const Duration(seconds: 3));
        } on Object catch (error) {
          firstError ??= error;
        }
      }
    }
    if (firstError != null) {
      throw const PeerFailure('Native RTC cleanup failed');
    }
  }
}
