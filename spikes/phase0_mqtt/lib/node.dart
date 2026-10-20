import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:vault_wire_spike/envelope.dart';

import 'signaling.dart';

int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class SendResult {
  SendResult(this.acked, this.attempts, this.elapsed);
  final bool acked;
  final int attempts;
  final Duration elapsed;
}

class Discovered {
  Discovered(
    this.nodeId,
    this.name,
    this.sequence,
    this.expiresAt,
    this.firstSeen,
  );
  final Uint8List nodeId;
  final String name;
  int sequence;
  int expiresAt;
  final DateTime firstSeen;
}

/// Authenticated, sealed signaling with ack/retry, replay defense and a bounded
/// signed presence directory. Throwaway Phase 0 code.
class SignalingNode {
  SignalingNode(
    this.identity,
    List<Endpoint> endpoints, {
    this.name = 'node',
    double dropOutboundRate = 0,
    int seed = 1,
    this.heartbeat = const Duration(seconds: 30),
    this.directoryLimit = 256,
    this.subscribePresence = true,
    String? label,
    Duration backoffBase = const Duration(milliseconds: 400),
    Duration backoffMax = const Duration(seconds: 6),
  }) : _random = Random(seed),
       link = MqttLink(
         endpoints: endpoints,
         label: label ?? name,
         dropOutboundRate: dropOutboundRate,
         seed: seed,
         backoffBase: backoffBase,
         backoffMax: backoffMax,
         subscriptions: [
           privateTopic(identity.nodeId),
           if (subscribePresence) '${presenceTopicPrefix}#',
         ],
       ),
       checks = EnvelopeChecks(identity);

  final Identity identity;
  final String name;
  final Duration heartbeat;
  final int directoryLimit;
  final bool subscribePresence;
  final MqttLink link;
  final EnvelopeChecks checks;
  final Random _random;
  final limiter = InboundLimiter();
  final directory = <String, KeyBinding>{};
  final discovered = <String, Discovered>{};
  final deliveredEnvelopes = StreamController<Envelope>.broadcast();
  final _pending = <String, Completer<void>>{};
  final _lastSequence = <String, int>{};
  Timer? _heartbeat;
  int _sequence = 0;
  late KeyBinding _binding;

  SignalingStats get stats => link.stats;

  Future<void> start() async {
    _binding = await identity.binding(issuedAt: nowSeconds());
    link.inbound.listen((m) => unawaited(_onInbound(m)));
    await link.start();
    await link.connected.timeout(const Duration(seconds: 20));
    if (subscribePresence) {
      _heartbeat = Timer.periodic(heartbeat, (_) => unawaited(announce()));
    }
  }

  Future<void> stop() async {
    _heartbeat?.cancel();
    await link.stop();
    await deliveredEnvelopes.close();
  }

  Uint8List _id16() =>
      Uint8List.fromList(List<int>.generate(16, (_) => _random.nextInt(256)));

  Future<Uint8List> _build(
    int type,
    Uint8List? recipient,
    Uint8List sessionId,
    Map<Object, Object?> payload, {
    int ttl = 120,
    int iceGeneration = 0,
    Uint8List? messageId,
  }) {
    final now = nowSeconds();
    return encodeEnvelope(
      identity,
      Envelope(
        type: type,
        sender: identity.signingPublic,
        recipient: recipient,
        messageId: messageId ?? _id16(),
        sessionId: sessionId,
        issuedAt: now,
        expiresAt: now + ttl,
        iceGeneration: iceGeneration,
        payload: payload,
      ),
    );
  }

  /// Signed, unencrypted broadcast presence. Public metadata only.
  Future<void> announce() async {
    _sequence++;
    final wire = await _build(MsgType.announce, null, Uint8List(16), {
      1: _binding.encryptionKey,
      2: _binding.signature,
      3: _binding.issuedAt,
      4: name,
      5: _sequence,
    }, ttl: 90);
    link.publish(presenceTopicPrefix + nodeIdText(identity.nodeId), wire);
  }

  /// Registers a verified binding under its nodeId.
  Future<void> addPeer(KeyBinding binding) async {
    if (!await binding.verify()) throw const WireReject('binding invalid');
    directory[base64.encode(await nodeIdOf(binding.signingKey))] = binding;
  }

  Future<SendResult> sendReliable(
    Uint8List peerNodeId,
    int type,
    Map<Object, Object?> payload, {
    required Uint8List sessionId,
    int iceGeneration = 0,
    Duration deadline = const Duration(seconds: 30),
    Duration firstDelay = const Duration(milliseconds: 600),
  }) async {
    final binding = directory[base64.encode(peerNodeId)];
    if (binding == null) throw const WireReject('unknown peer key');
    final messageId = _id16();
    final inner = await _build(
      type,
      peerNodeId,
      sessionId,
      payload,
      iceGeneration: iceGeneration,
      messageId: messageId,
    );
    final sealed = await seal(inner, peerNodeId, binding);
    final key = base64.encode(messageId);
    final done = _pending[key] = Completer<void>();
    final watch = Stopwatch()..start();
    var attempts = 0;
    var delay = firstDelay;
    try {
      while (watch.elapsed < deadline && !done.isCompleted) {
        attempts++;
        link.publish(privateTopic(peerNodeId), sealed);
        final jitter = Duration(
          milliseconds: _random.nextInt(delay.inMilliseconds ~/ 2 + 1),
        );
        await Future.any([done.future, Future<void>.delayed(delay + jitter)]);
        delay *= 2;
        if (delay > const Duration(seconds: 5))
          delay = const Duration(seconds: 5);
      }
      return SendResult(done.isCompleted, attempts, watch.elapsed);
    } finally {
      _pending.remove(key);
    }
  }

  Future<void> _onInbound(Inbound message) async {
    stats.inboundFrames++;
    if (message.payload.length > maxInboundBytes) {
      stats.droppedOversize++;
      return;
    }
    if (!limiter.allow(message.payload.length, DateTime.now())) {
      stats.droppedRateLimited++;
      return;
    }
    try {
      if (message.topic.startsWith(privateTopicPrefix)) {
        await _onPrivate(message);
      } else if (message.topic.startsWith(presenceTopicPrefix)) {
        await _onPresence(message);
      } else {
        stats.reject('unexpected topic');
      }
    } on WireReject catch (e) {
      stats.reject(e.reason);
    } on Object catch (e) {
      stats.reject('error ${e.runtimeType}');
    }
  }

  Future<void> _onPrivate(Inbound message) async {
    if (message.topic != privateTopic(identity.nodeId)) {
      throw const WireReject('private topic mismatch');
    }
    final inner = await open(message.payload, identity);
    final now = nowSeconds();
    final envelope = await decodeEnvelope(inner, now: now);
    if (envelope.recipient == null)
      throw const WireReject('private must be addressed');
    var duplicate = false;
    try {
      checks.accept(envelope, now: now);
    } on WireReject catch (e) {
      if (e.reason != 'replay') rethrow;
      duplicate = true;
    }
    if (envelope.type == MsgType.ack) {
      final acked = envelope.payload[1];
      if (acked is Uint8List) _pending[base64.encode(acked)]?.complete();
      return;
    }
    if (duplicate) {
      stats.duplicatesReacked++;
    } else {
      stats.delivered++;
      deliveredEnvelopes.add(envelope);
    }
    await _ack(envelope);
  }

  Future<void> _ack(Envelope envelope) async {
    final peerId = await nodeIdOf(envelope.sender);
    final binding = directory[base64.encode(peerId)];
    if (binding == null) return;
    final inner = await _build(MsgType.ack, peerId, envelope.sessionId, {
      1: envelope.messageId,
    });
    link.publish(privateTopic(peerId), await seal(inner, peerId, binding));
  }

  Future<void> _onPresence(Inbound message) async {
    final now = nowSeconds();
    final envelope = await decodeEnvelope(message.payload, now: now);
    if (envelope.type != MsgType.announce || envelope.recipient != null) {
      throw const WireReject('presence must be broadcast announce');
    }
    final senderId = await nodeIdOf(envelope.sender);
    if (message.topic != presenceTopicPrefix + nodeIdText(senderId)) {
      throw const WireReject('presence topic mismatch');
    }
    if (_equalBytes(senderId, identity.nodeId)) return;
    final p = envelope.payload;
    final enc = p[1];
    final sig = p[2];
    final issued = p[3];
    final display = p[4];
    final sequence = p[5];
    if (enc is! Uint8List ||
        enc.length != 32 ||
        sig is! Uint8List ||
        issued is! int ||
        display is! String ||
        display.length > 32 ||
        sequence is! int) {
      throw const WireReject('announce shape');
    }
    final binding = KeyBinding(envelope.sender, enc, issued, sig);
    if (!await binding.verify()) throw const WireReject('announce binding');
    final key = base64.encode(senderId);
    final last = _lastSequence[key];
    if (last != null && sequence <= last)
      throw const WireReject('stale sequence');
    if (!discovered.containsKey(key) && discovered.length >= directoryLimit) {
      throw const WireReject('directory full');
    }
    _lastSequence[key] = sequence;
    final existing = discovered[key];
    if (existing != null) {
      existing
        ..sequence = sequence
        ..expiresAt = envelope.expiresAt;
    } else {
      discovered[key] = Discovered(
        senderId,
        display,
        sequence,
        envelope.expiresAt,
        DateTime.now(),
      );
    }
    directory[key] = binding;
  }

  /// Entries whose signed expiry has passed are removed.
  int sweep() {
    final now = nowSeconds();
    final gone = discovered.entries
        .where((e) => e.value.expiresAt < now)
        .map((e) => e.key)
        .toList();
    for (final key in gone) {
      discovered.remove(key);
    }
    return gone.length;
  }
}

bool _equalBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
