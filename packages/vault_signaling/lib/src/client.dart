import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/vault_protocol.dart'
    show
        Envelope,
        Introduction,
        MsgType,
        WireReject,
        decodeEnvelope,
        encodeEnvelope,
        open,
        seal;
import 'package:vault_signaling/src/presence.dart';
import 'package:vault_signaling/src/schema.dart';
import 'package:vault_signaling/src/strategies/manual.dart';
import 'package:vault_signaling/src/strategy.dart';

/// Known-contact signed HPKE signaling with bounded retries and replay defense.
class SignalingClient {
  /// Creates a client using the current approved contact binding resolver.
  new({
    required this.identity,
    required this.strategy,
    required this.resolveBinding,
    this.onIntroduce,
    this.retryDelay = const Duration(milliseconds: 600),
    Duration? retryDeadline,
  }) : retryDeadline =
           retryDeadline ??
           (strategy is ManualSignaling
               ? const Duration(minutes: 10)
               : const Duration(minutes: 2)) {
    if (retryDelay <= Duration.zero ||
        this.retryDeadline <= Duration.zero ||
        this.retryDeadline > const Duration(minutes: 15)) {
      throw ArgumentError('Invalid signaling retry bounds');
    }
  }

  /// Local signing and encryption identity.
  final Identity identity;

  /// Exclusively owned addressed transport, closed with this client.
  final SignalingStrategy strategy;

  /// Resolves approved contact keys by canonical node identifier.
  final Future<KeyBinding?> Function(String nodeId) resolveBinding;

  /// Decides whether a noncontact's verified [Introduction] proves the
  /// active pairing secret. Only accepted introductions are acknowledged.
  /// Without it, introductions are rejected like any unknown sender.
  final Future<bool> Function(Introduction introduction)? onIntroduce;

  /// Initial retry delay before exponential backoff and jitter.
  final Duration retryDelay;

  /// Maximum time a published message may await its authenticated ACK.
  final Duration retryDeadline;
  final _messages = StreamController<Envelope>.broadcast();
  final _failures = StreamController<SignalingFailure>.broadcast();
  final _queue = Queue<SignalFrame>();
  final _pending = <String, _Pending>{};
  final _seen = <String, int>{};
  final _random = Random.secure();
  final _cancel = Completer<void>();
  StreamSubscription<SignalFrame>? _subscription;
  Future<void>? _startFuture;
  bool _closed = false;
  bool _started = false;
  bool _pumping = false;
  int _building = 0;
  int _rateSecond = -1;
  int _rateFrames = 0;
  int _rateBytes = 0;
  int _failureSecond = -1;
  int _failureCount = 0;
  int _introduceSecond = -1;
  int _introduceCount = 0;
  final _publicPresence = StreamController<PublicPresenceRecord>.broadcast();
  final _publicQueue = Queue<SignalFrame>();
  final _publicRecords = <String, PublicPresenceRecord>{};
  final _publicReplay = <String, (int, int, int)>{};
  final int _publicEpoch = DateTime.now().microsecondsSinceEpoch;
  StreamSubscription<SignalFrame>? _publicSubscription;
  bool _publicEnabled = false;
  bool _publicPumping = false;
  bool _publicPublishing = false;
  int _publicGeneration = 0;
  int _publicSequence = 0;
  int _publicRateSecond = -1;
  int _publicRateFrames = 0;
  int _publicRateBytes = 0;

  /// Validated contact messages, delivered at most once during their validity.
  Stream<Envelope> get messages => _messages.stream;

  /// Sanitized stream, receive and asynchronous retry failures.
  Stream<SignalingFailure> get failures => _failures.stream;

  /// Number of published messages awaiting authenticated acknowledgment.
  int get pendingCount => _pending.length;
  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Whether this transport supports actual public metadata discovery.
  bool get supportsPublicDiscovery => strategy is PublicPresenceTransport;

  /// Explicit public subscription policy; false by default.
  bool get publicDiscoveryEnabled => _publicEnabled && !_closed;

  /// Verified unencrypted metadata from public signers, including noncontacts.
  /// These records never authorize private signaling or media access.
  Stream<PublicPresenceRecord> get publicPresence => _publicPresence.stream;

  /// Current bounded public records, excluding records with expired signatures.
  List<PublicPresenceRecord> get publicPresenceRecords {
    _publicRecords.removeWhere((_, record) => record.expiresAt <= _now);
    return List.unmodifiable(_publicRecords.values);
  }

  /// Opts into public MQTT metadata; unavailable for manual exchange.
  // Setter-style API is shared with directory and app consumers.
  // ignore: avoid_positional_boolean_parameters
  Future<void> setPublicDiscoveryEnabled(bool enabled) async {
    if (_closed) throw StateError('Signaling client closed');
    final transport = strategy;
    if (transport is! PublicPresenceTransport) {
      if (enabled) {
        throw UnsupportedError('Manual signaling has no public discovery');
      }
      return;
    }
    final presence = transport as PublicPresenceTransport;
    _publicEnabled = enabled;
    final generation = ++_publicGeneration;
    if (!enabled) {
      _publicQueue.clear();
      _publicRecords.clear();
    }
    try {
      await _cancellable(presence.setPublicPresenceEnabled(enabled));
    } on Object catch (error) {
      if (generation == _publicGeneration) {
        _publicEnabled = false;
        _publicGeneration++;
        _publicQueue.clear();
        _publicRecords.clear();
      }
      _fail('public discovery policy change failed', cause: error.runtimeType);
      rethrow;
    }
  }

  /// Signs only public metadata, never SDP, media, ACLs or IP hints.
  Future<void> announcePublicPresence({
    required String name,
    List<String> tags = const [],
    int sharedCount = 0,
  }) async {
    final transport = strategy;
    if (transport is! PublicPresenceTransport) {
      throw UnsupportedError('Manual signaling has no public discovery');
    }
    final presence = transport as PublicPresenceTransport;
    if (!_started ||
        !publicDiscoveryEnabled ||
        !presence.publicPresenceEnabled) {
      throw StateError('Public discovery is not opted in and ready');
    }
    if (_publicPublishing) {
      throw StateError('Public announcement already pending');
    }
    _publicPublishing = true;
    final generation = _publicGeneration;
    try {
      final now = _now;
      final binding = await _cancellable(identity.binding(issuedAt: now));
      final payload = <Object, Object?>{
        'presence': true,
        'name': name,
        'tags': List<String>.of(tags),
        'sharedCount': sharedCount,
        'epoch': _publicEpoch,
        'sequence': ++_publicSequence,
        'expires': now + 90,
        'encryptionKey': binding.encryptionKey,
        'bindingIssuedAt': binding.issuedAt,
        'bindingSignature': binding.signature,
      };
      validatePublicPresencePayload(payload, now: now);
      final bytes = await _cancellable(
        encodeEnvelope(
          identity,
          Envelope(
            type: MsgType.announce,
            sender: identity.signingPublic,
            recipient: null,
            messageId: _id16(),
            sessionId: Uint8List(16),
            issuedAt: now,
            expiresAt: now + 90,
            iceGeneration: 0,
            payload: payload,
          ),
        ),
      );
      if (bytes.length > maxPublicPresenceBytes) {
        throw const WireReject('public presence frame size');
      }
      if (_closed || !_publicEnabled || generation != _publicGeneration) {
        throw StateError('Public discovery policy changed');
      }
      await _cancellable(
        presence
            .publishPublicPresence(nodeIdText(identity.nodeId), bytes)
            .timeout(const Duration(seconds: 5)),
      );
    } on Object catch (error) {
      _fail('public presence publish failed', cause: error.runtimeType);
      rethrow;
    } finally {
      _publicPublishing = false;
    }
  }

  void _enqueuePublic(SignalFrame frame) {
    if (!publicDiscoveryEnabled) return;
    final now = _now;
    if (_publicRateSecond != now) {
      _publicRateSecond = now;
      _publicRateFrames = 0;
      _publicRateBytes = 0;
    }
    if (!signalNodeIdPattern.hasMatch(frame.recipient) ||
        frame.bytes.isEmpty ||
        frame.bytes.length > maxPublicPresenceBytes ||
        _publicQueue.length >= 16 ||
        _publicRateFrames >= 16 ||
        _publicRateBytes + frame.bytes.length > 32 * 1024) {
      _fail('public presence receive budget rejected');
      return;
    }
    _publicRateFrames++;
    _publicRateBytes += frame.bytes.length;
    _publicQueue.add(frame);
    if (!_publicPumping) unawaited(_pumpPublic());
  }

  Future<void> _pumpPublic() async {
    _publicPumping = true;
    try {
      while (publicDiscoveryEnabled && _publicQueue.isNotEmpty) {
        final frame = _publicQueue.removeFirst();
        final generation = _publicGeneration;
        try {
          final record = await _cancellable(
            verifyPublicPresenceRecord(
              frame.bytes,
              now: _now,
              expectedNodeId: frame.recipient,
            ),
          );
          if (!publicDiscoveryEnabled || generation != _publicGeneration) {
            continue;
          }
          if (record.nodeId == nodeIdText(identity.nodeId)) continue;
          final now = _now;
          if (record.expiresAt <= now) continue;
          _publicRecords.removeWhere((_, value) => value.expiresAt <= now);
          _publicReplay.removeWhere((_, value) => value.$3 <= now);
          final previous = _publicReplay[record.nodeId];
          if (previous != null &&
              (record.epoch < previous.$1 ||
                  (record.epoch == previous.$1 &&
                      record.sequence <= previous.$2))) {
            throw const WireReject('public presence replay');
          }
          if ((!_publicRecords.containsKey(record.nodeId) &&
                  _publicRecords.length >= 256) ||
              (previous == null && _publicReplay.length >= 512)) {
            throw const WireReject('public presence record budget rejected');
          }
          _publicReplay[record.nodeId] = (
            record.epoch,
            record.sequence,
            record.expiresAt + 120,
          );
          _publicRecords[record.nodeId] = record;
          _publicPresence.add(record);
        } on Object catch (error) {
          _fail(
            error is WireReject
                ? error.reason
                : 'public presence receive failed',
            cause: error.runtimeType,
          );
        }
      }
    } finally {
      _publicPumping = false;
    }
  }

  /// Starts transport reception and awaits subscription readiness.
  Future<void> start() {
    if (_closed) return Future.error(StateError('Signaling client closed'));
    return _startFuture ??= _start();
  }

  Future<void> _start() async {
    _subscription = strategy.inbound.listen(
      _enqueue,
      onError: (Object error, StackTrace stack) {
        _fail(
          'transport stream failed',
          cause: error.runtimeType,
          kind: SignalingFailureKind.transportUnavailable,
        );
      },
      onDone: () {
        if (!_closed) {
          _fail(
            'transport stream ended',
            kind: SignalingFailureKind.transportUnavailable,
          );
        }
      },
    );
    final transport = strategy;
    if (transport is PublicPresenceTransport) {
      final presence = transport as PublicPresenceTransport;
      _publicSubscription = presence.publicFrames.listen(
        _enqueuePublic,
        onError: (Object error, StackTrace stack) {
          _fail(
            'public presence transport stream failed',
            cause: error.runtimeType,
          );
        },
        onDone: () {
          if (publicDiscoveryEnabled) {
            _fail('public presence transport stream ended');
          }
        },
      );
    }
    try {
      await _cancellable(strategy.start(nodeIdText(identity.nodeId)));
      if (!_closed) _started = true;
    } on Object catch (error) {
      _fail(
        'transport start failed',
        cause: error.runtimeType,
        terminal: true,
        kind: SignalingFailureKind.transportUnavailable,
      );
      rethrow;
    }
  }

  Future<T> _cancellable<T>(Future<T> operation) => Future.any<T>([
    operation,
    _cancel.future.then<T>((_) => throw StateError('Signaling client closed')),
  ]);

  /// Publishes an allowlisted signal, returning before its asynchronous ACK.
  Future<void> send({
    required KeyBinding peer,
    required int type,
    required Uint8List sessionId,
    required Map<Object, Object?> payload,
    int iceGeneration = 0,
  }) => _send(
    peer: peer,
    type: type,
    sessionId: sessionId,
    payload: payload,
    iceGeneration: iceGeneration,
  );

  /// Sends [introduction] to the contact [host] and completes only when the
  /// host acknowledges it, which it does only after accepting the pairing.
  Future<void> introduce({
    required KeyBinding host,
    required Introduction introduction,
  }) async {
    final acknowledged = Completer<void>();
    // Close can fail it before the caller listens; the caller still sees it.
    acknowledged.future.ignore();
    await _send(
      peer: host,
      type: MsgType.introduce,
      sessionId: _id16(),
      payload: introduction.toPayload(),
      acknowledged: acknowledged,
    );
    await acknowledged.future;
  }

  Future<void> _send({
    required KeyBinding peer,
    required int type,
    required Uint8List sessionId,
    required Map<Object, Object?> payload,
    int iceGeneration = 0,
    Completer<void>? acknowledged,
  }) async {
    if (_closed || !_started) {
      throw StateError('Signaling client is not started');
    }
    validateSignalPayload(type, payload, now: _now);
    if (sessionId.length != 16 ||
        iceGeneration < 0 ||
        iceGeneration > 0x7fffffff) {
      throw const WireReject('signaling session fields');
    }
    if (_pending.length + _building >= 128) {
      throw StateError('Signaling pending queue full');
    }
    // Snapshot caller-owned mutable data before crossing an await.
    final session = Uint8List.fromList(sessionId);
    final body = <Object, Object?>{
      for (final entry in payload.entries)
        entry.key: entry.value is Uint8List
            ? Uint8List.fromList(entry.value! as Uint8List)
            : entry.value,
    };
    _building++;
    _Pending? pending;
    try {
      if (!await _cancellable(peer.verify())) {
        throw const WireReject('peer binding invalid');
      }
      final peerBytes = await _cancellable(nodeIdOf(peer.signingKey));
      final peerId = nodeIdText(peerBytes);
      final known = await _cancellable(
        resolveBinding(peerId).timeout(const Duration(seconds: 5)),
      );
      if (known == null ||
          !await _cancellable(known.verify()) ||
          !_equal(known.signingKey, peer.signingKey) ||
          !_equal(known.encryptionKey, peer.encryptionKey)) {
        throw const WireReject('unknown or changed contact binding');
      }
      final id = _id16();
      final wire = await _build(
        peer,
        peerBytes,
        type,
        session,
        body,
        messageId: id,
        iceGeneration: iceGeneration,
      );
      if (_closed) throw StateError('Signaling client closed');
      if (wire.length > maxSignalFrameBytes) {
        throw const WireReject('signaling frame size');
      }
      pending = _Pending(
        base64Url.encode(id),
        peerId,
        session,
        wire,
        DateTime.now().add(retryDeadline),
        acknowledged,
      );
      _pending[pending.key] = pending;
      await _publish(pending);
      _schedule(pending);
    } on Object catch (error) {
      if (pending != null) _remove(pending);
      _fail(
        'signal send failed',
        sessionId: session,
        cause: error.runtimeType,
        terminal: true,
        kind: error is WireReject || error is StateError
            ? SignalingFailureKind.other
            : SignalingFailureKind.transportUnavailable,
      );
      rethrow;
    } finally {
      _building--;
    }
  }

  Future<Uint8List> _build(
    KeyBinding peer,
    Uint8List recipient,
    int type,
    Uint8List session,
    Map<Object, Object?> payload, {
    required Uint8List messageId,
    int iceGeneration = 0,
  }) async {
    final now = _now;
    final expiry = type == MsgType.announce
        ? payload['expires']! as int
        : now + retryDeadline.inSeconds + 30;
    final envelope = Envelope(
      type: type,
      sender: identity.signingPublic,
      recipient: recipient,
      messageId: messageId,
      sessionId: session,
      issuedAt: now,
      expiresAt: expiry,
      iceGeneration: iceGeneration,
      payload: payload,
    );
    final inner = await _cancellable(encodeEnvelope(identity, envelope));
    return await _cancellable(seal(inner, recipient, peer));
  }

  Future<void> _publish(_Pending pending) => _cancellable(
    strategy
        .publish(pending.peerId, pending.wire)
        .timeout(const Duration(seconds: 5)),
  );

  void _schedule(_Pending pending) {
    if (_closed || !identical(_pending[pending.key], pending)) return;
    final remaining = pending.deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _remove(pending, expired: true);
      _fail(
        'signal acknowledgment deadline exceeded',
        peerId: pending.peerId,
        sessionId: pending.session,
        terminal: true,
        kind: SignalingFailureKind.acknowledgmentTimeout,
      );
      return;
    }
    final millis = min(
      10000,
      retryDelay.inMilliseconds * (1 << min(pending.attempt, 5)),
    );
    final jitter = _random.nextInt(max(1, millis ~/ 3));
    final delay = Duration(
      milliseconds: min(remaining.inMilliseconds, millis + jitter),
    );
    pending.timer = Timer(delay, () => unawaited(_retry(pending)));
  }

  Future<void> _retry(_Pending pending) async {
    if (_closed || !identical(_pending[pending.key], pending)) return;
    if (!DateTime.now().isBefore(pending.deadline)) {
      _remove(pending, expired: true);
      _fail(
        'signal acknowledgment deadline exceeded',
        peerId: pending.peerId,
        sessionId: pending.session,
        terminal: true,
        kind: SignalingFailureKind.acknowledgmentTimeout,
      );
      return;
    }
    pending.attempt++;
    try {
      await _publish(pending);
    } on Object catch (error) {
      _fail(
        'signal retry publish failed',
        peerId: pending.peerId,
        sessionId: pending.session,
        cause: error.runtimeType,
        kind: SignalingFailureKind.transportUnavailable,
      );
    }
    _schedule(pending);
  }

  void _remove(
    _Pending pending, {
    bool acknowledged = false,
    bool expired = false,
  }) {
    pending.timer?.cancel();
    _pending.remove(pending.key);
    if (acknowledged && strategy is ManualSignaling) {
      (strategy as ManualSignaling).acknowledge(pending.peerId, pending.wire);
    }
    final waiter = pending.acknowledged;
    if (waiter == null || waiter.isCompleted) return;
    if (acknowledged) {
      waiter.complete();
    } else if (expired) {
      waiter.completeError(
        SignalingFailure(
          'signal acknowledgment deadline exceeded',
          peerId: pending.peerId,
          terminal: true,
          kind: SignalingFailureKind.acknowledgmentTimeout,
        ),
      );
    } else {
      waiter.completeError(StateError('Signal was not sent'));
    }
  }

  void _enqueue(SignalFrame frame) {
    if (_closed) return;
    final second = _now;
    if (_rateSecond != second) {
      _rateSecond = second;
      _rateFrames = 0;
      _rateBytes = 0;
    }
    if (frame.recipient != nodeIdText(identity.nodeId) ||
        frame.bytes.isEmpty ||
        frame.bytes.length > maxSignalFrameBytes ||
        _rateFrames >= 64 ||
        _rateBytes + frame.bytes.length > 256 * 1024 ||
        _queue.length >= 32) {
      _fail('inbound signal budget rejected');
      return;
    }
    _rateFrames++;
    _rateBytes += frame.bytes.length;
    _queue.add(frame);
    if (!_pumping) unawaited(_pump());
  }

  Future<void> _pump() async {
    _pumping = true;
    try {
      while (!_closed && _queue.isNotEmpty) {
        final frame = _queue.removeFirst();
        try {
          await _receive(frame);
        } on _UnknownSender catch (error) {
          _fail(
            error.reason,
            peerId: error.peerId,
            kind: SignalingFailureKind.unknownSender,
          );
        } on Object catch (error) {
          _fail(
            error is WireReject ? error.reason : 'inbound signaling failed',
            cause: error.runtimeType,
          );
        }
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _receive(SignalFrame frame) async {
    final inner = await _cancellable(open(frame.bytes, identity));
    final envelope = await _cancellable(decodeEnvelope(inner, now: _now));
    final recipient = envelope.recipient;
    if (recipient == null ||
        !_equal(recipient, identity.nodeId) ||
        envelope.expiresAt < _now ||
        envelope.iceGeneration > 0x7fffffff) {
      throw const WireReject('private envelope address or expiry');
    }
    validateSignalPayload(
      envelope.type,
      envelope.payload,
      now: _now,
      internalAck: true,
    );
    if (envelope.type == MsgType.announce &&
        envelope.expiresAt != envelope.payload['expires']) {
      throw const WireReject('presence expiry mismatch');
    }
    final senderId = await _cancellable(nodeIdOf(envelope.sender));
    final peerId = nodeIdText(senderId);
    if (envelope.type == MsgType.introduce) {
      await _receiveIntroduction(envelope, senderId, peerId);
      return;
    }
    final peer = await _cancellable(
      resolveBinding(peerId).timeout(const Duration(seconds: 5)),
    );
    if (peer == null) throw _UnknownSender(peerId);
    if (!await _cancellable(peer.verify()) ||
        !_equal(peer.signingKey, envelope.sender) ||
        !_equal(await _cancellable(nodeIdOf(peer.signingKey)), senderId)) {
      throw const WireReject('unknown or changed contact binding');
    }
    if (_closed) return;
    if (envelope.type == MsgType.ack) {
      final key = base64Url.encode(envelope.payload[1]! as Uint8List);
      final pending = _pending[key];
      if (pending != null &&
          pending.peerId == peerId &&
          _equal(pending.session, envelope.sessionId)) {
        _remove(pending, acknowledged: true);
      }
      return;
    }
    final now = _now;
    _seen.removeWhere((_, until) => until < now);
    final replayKey = '$peerId:${base64Url.encode(envelope.messageId)}';
    final duplicate = _seen.containsKey(replayKey);
    if (!duplicate) {
      if (_seen.length >= 4096) throw const WireReject('replay cache full');
      _seen[replayKey] = envelope.expiresAt;
      _messages.add(envelope);
    }
    // Duplicate accepted frames are ACKed again, without repeated side effects.
    await _acknowledge(peer, senderId, peerId, envelope);
  }

  /// Accepts a pairing introduction from a sender who may not be a contact.
  /// The binding comes from the signed payload card, never from contacts.
  Future<void> _receiveIntroduction(
    Envelope envelope,
    Uint8List senderId,
    String peerId,
  ) async {
    final accept = onIntroduce;
    if (accept == null) throw _UnknownSender(peerId);
    final introduction = await _cancellable(
      Introduction.fromPayload(envelope.payload, sender: envelope.sender),
    );
    if (_closed) return;
    final now = _now;
    _seen.removeWhere((_, until) => until < now);
    final replayKey = '$peerId:${base64Url.encode(envelope.messageId)}';
    if (!_seen.containsKey(replayKey)) {
      if (_introduceSecond != now) {
        _introduceSecond = now;
        _introduceCount = 0;
      }
      if (++_introduceCount > 4) {
        throw const WireReject('introduction rate limited');
      }
      if (!await _cancellable(accept(introduction))) {
        throw const WireReject('introduction rejected');
      }
      if (_closed) return;
      if (_seen.length >= 4096) throw const WireReject('replay cache full');
      _seen[replayKey] = envelope.expiresAt;
    }
    await _acknowledge(introduction.card.binding, senderId, peerId, envelope);
  }

  Future<void> _acknowledge(
    KeyBinding peer,
    Uint8List senderId,
    String peerId,
    Envelope envelope,
  ) async {
    try {
      final ack = await _build(
        peer,
        senderId,
        MsgType.ack,
        envelope.sessionId,
        {1: envelope.messageId},
        messageId: _id16(),
      );
      if (!_closed) {
        await _cancellable(
          strategy.publish(peerId, ack).timeout(const Duration(seconds: 5)),
        );
      }
    } on Object catch (error) {
      // Delivery is already accepted. A transport transition can race the ACK;
      // the sender retries and the replay path reACKs without redelivery.
      _fail(
        'signal acknowledgment publish failed',
        peerId: peerId,
        sessionId: envelope.sessionId,
        cause: error.runtimeType,
      );
    }
  }

  void _fail(
    String reason, {
    String? peerId,
    Uint8List? sessionId,
    Object? cause,
    bool terminal = false,
    SignalingFailureKind kind = SignalingFailureKind.other,
  }) {
    if (_closed) return;
    if (_failureSecond != _now) {
      _failureSecond = _now;
      _failureCount = 0;
    }
    if (!terminal && _failureCount++ >= 16) return;
    _failures.add(
      SignalingFailure(
        reason,
        peerId: peerId,
        sessionId: sessionId,
        cause: cause,
        terminal: terminal,
        kind: kind,
      ),
    );
  }

  Uint8List _id16() =>
      Uint8List.fromList(List.generate(16, (_) => _random.nextInt(256)));

  /// Cancels queued work, retry timers and transport permanently.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cancel.complete();
    _publicEnabled = false;
    _publicGeneration++;
    _publicQueue.clear();
    _publicRecords.clear();
    _publicReplay.clear();
    final publicCancellation = _publicSubscription?.cancel();
    if (publicCancellation != null) unawaited(publicCancellation);
    unawaited(_publicPresence.close());
    for (final pending in _pending.values) {
      pending.timer?.cancel();
      if (pending.acknowledged case final waiter? when !waiter.isCompleted) {
        waiter.completeError(StateError('Signaling client closed'));
      }
    }
    _pending.clear();
    _queue.clear();
    _seen.clear();
    final cancellation = _subscription?.cancel();
    if (cancellation != null) unawaited(cancellation);
    try {
      await strategy.close().timeout(const Duration(seconds: 2));
    } finally {
      unawaited(_messages.close());
      unawaited(_failures.close());
    }
  }
}

class _UnknownSender extends WireReject {
  const new(this.peerId) : super('unknown or changed contact binding');
  final String peerId;
}

class _Pending {
  new(
    this.key,
    this.peerId,
    this.session,
    this.wire,
    this.deadline, [
    this.acknowledged,
  ]);
  final String key;
  final String peerId;
  final Uint8List session;
  final Uint8List wire;
  final DateTime deadline;
  final Completer<void>? acknowledged;
  int attempt = 0;
  Timer? timer;
}

bool _equal(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var diff = 0;
  for (var i = 0; i < left.length; i++) {
    diff |= left[i] ^ right[i];
  }
  return diff == 0;
}
