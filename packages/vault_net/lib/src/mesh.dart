part of '../vault_net.dart';

/// A connection problem attributed to one authenticated remote identity.
class PeerProblem {
  /// Associates [problem] with the canonical node identifier [peerId].
  const new(this.peerId, this.problem);

  /// Canonical node identifier of the authenticated remote signer.
  final String peerId;

  /// What went wrong, from the closed person-facing set.
  final ConnectionProblem problem;
}

/// Owns trusted direct-only peer sessions and their authenticated signaling.
class PeerMesh {
  /// Restores public disconnect policy before starting any inbound reception.
  new({
    required this.identity,
    required this.signaling,
    required this._resolveBinding,
    List<String> stunUrls = const ['stun:stun.l.google.com:19302'],
    Iterable<String> initiallyDisconnectedPeerIds = const [],
  }) : _stunUrls = validateStunUrls(stunUrls),
       _disconnectedPeers = Set<String>.of(initiallyDisconnectedPeerIds);

  /// Local signing/encryption identity used by every session in this mesh.
  final Identity identity;

  /// Exclusively owned signaling client, started and closed with the mesh.
  final SignalingClient signaling;
  final Future<KeyBinding?> Function(String) _resolveBinding;
  final List<String> _stunUrls;
  final _sessions = <String, PeerSession>{};
  final _closedIds = <String, DateTime>{};
  final Set<String> _disconnectedPeers;
  final _events = StreamController<PeerSession>.broadcast(sync: true);
  final _problems = StreamController<PeerProblem>.broadcast();

  /// Inbound attempts that were ignored, so the person can see why.
  Stream<PeerProblem> get problems => _problems.stream;

  /// Newly created incoming and outgoing sessions, emitted once per session.
  Stream<PeerSession> get sessions => _events.stream;

  /// Public policy snapshot; persist intentional disconnects before shutdown.
  Set<String> get disconnectedPeerIds =>
      Set<String>.unmodifiable(_disconnectedPeers);
  StreamSubscription<Envelope>? _messages;
  StreamSubscription<SignalingFailure>? _failures;
  Future<void> _incomingTail = Future<void>.value();
  Future<void>? _starting;
  Future<void>? _closing;
  int _pending = 0;
  bool _closed = false;

  /// Starts trusted signaling reception without initiating a peer connection.
  Future<void> start() {
    if (_closed) return Future<void>.error(const PeerFailure('Mesh is closed'));
    return _starting ??= () async {
      _messages = signaling.messages.listen(
        _receive,
        onError: (Object error) {
          for (final session in _sessions.values.toList()) {
            session._fail(error);
          }
        },
      );
      _failures = signaling.failures.listen((failure) {
        final id = failure.sessionId;
        if (id != null) _sessions[sessionText(id)]?._signalingFailure(failure);
        final sender = failure.peerId;
        if (failure.kind == SignalingFailureKind.unknownSender &&
            sender != null &&
            !_closed) {
          _problems.add(PeerProblem(sender, ConnectionProblem.notAContact));
        }
      });
      try {
        await signaling.start();
        if (_closed) throw const PeerFailure('Mesh closed while starting');
      } on Object {
        await _messages?.cancel();
        await _failures?.cancel();
        _starting = null;
        rethrow;
      }
    }();
  }

  Future<KeyBinding> _trusted(String peerId, [KeyBinding? expected]) async {
    final binding = await _resolveBinding(peerId);
    if (binding == null ||
        !await binding.verify() ||
        nodeIdText(await nodeIdOf(binding.signingKey)) != peerId ||
        (expected != null && !sameBinding(binding, expected))) {
      throw const PeerFailure('Unknown peer or changed trusted key binding');
    }
    if (peerId == nodeIdText(identity.nodeId)) {
      throw const PeerFailure('Cannot connect identity to itself');
    }
    return binding;
  }

  /// Accepts offers from [peerId] again after an explicit disconnect,
  /// without dialing it.
  void allow(String peerId) => _disconnectedPeers.remove(peerId);

  /// Allows [peer] and returns its asynchronously negotiating session.
  Future<PeerSession> connect(ContactCard peer) async {
    await start();
    final binding = await _trusted(peer.nodeId, peer.binding);
    if (_closed) throw const PeerFailure('Mesh is closed');
    allow(peer.nodeId);
    for (final existing in _sessions.values) {
      if (existing.peerId == peer.nodeId) return existing;
    }
    if (_sessions.length >= 16) {
      throw const PeerFailure('Peer session limit reached');
    }
    final session = _make(peer.nodeId, binding, freshBytes(16), offerer: true)
      .._beginOffer();
    return session;
  }

  PeerSession _make(
    String peerId,
    KeyBinding binding,
    Uint8List id, {
    required bool offerer,
  }) {
    final session = PeerSession._(
      identity: identity,
      peer: binding,
      peerId: peerId,
      id: id,
      offerer: offerer,
      stunUrls: _stunUrls,
      signaling: signaling,
      resolveBinding: _resolveBinding,
      onExplicitDisconnect: () {
        _disconnectedPeers.add(peerId);
      },
      onTerminal: (session) {
        _sessions.remove(session.sessionId);
        _closedIds[session.sessionId] = DateTime.now();
        while (_closedIds.length > 256) {
          _closedIds.remove(_closedIds.keys.first);
        }
      },
    );
    _sessions[session.sessionId] = session;
    _events.add(session);
    return session;
  }

  void _receive(Envelope envelope) {
    if (_closed) return;
    if (_pending >= 64) {
      // Do not accumulate authenticated signaling work without a bound.
      final session = _sessions[sessionText(envelope.sessionId)];
      session?._fail(
        const PeerFailure('Inbound signaling queue limit exceeded'),
      );
      return;
    }
    _pending++;
    _incomingTail = _incomingTail.then((_) async {
      try {
        if (!_closed) await _handle(envelope);
      } on Object {
        // Signaling already verifies signatures/schema; trust lookup rejection
        // must not turn another peer's error into a mesh-wide disconnect.
      } finally {
        _pending--;
      }
    });
  }

  Future<void> _handle(Envelope envelope) async {
    if (envelope.sessionId.length != 16) return;
    final peerId = nodeIdText(await nodeIdOf(envelope.sender));
    final binding = await _trusted(peerId);
    if (!sameBytes(envelope.sender, binding.signingKey) || _closed) return;
    final id = sessionText(envelope.sessionId);
    final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
    _closedIds.removeWhere((_, time) => time.isBefore(cutoff));
    if (_closedIds.containsKey(id)) return;
    final existing = _sessions[id];
    if (existing != null) {
      if (existing.peerId != peerId || !sameBinding(binding, existing._peer)) {
        existing._fail(
          const PeerFailure('Session identity or key binding changed'),
        );
        return;
      }
      existing._accept(envelope);
      return;
    }
    if (envelope.type != MsgType.offer || envelope.iceGeneration != 0) return;
    if (_disconnectedPeers.contains(peerId)) {
      _problems.add(PeerProblem(peerId, ConnectionProblem.youDisconnected));
      return;
    }
    final conflicts = _sessions.values
        .where((s) => s.peerId == peerId)
        .toList();
    if (conflicts.isNotEmpty) {
      final previous = conflicts.single;
      // Simultaneous offers converge deterministically without native rollback:
      // the lexicographically smaller identity remains the offerer.
      if (!previous._offerer ||
          nodeIdText(identity.nodeId).compareTo(peerId) < 0) {
        _closedIds[id] = DateTime.now();
        while (_closedIds.length > 256) {
          _closedIds.remove(_closedIds.keys.first);
        }
        await signaling.send(
          peer: binding,
          type: MsgType.bye,
          sessionId: envelope.sessionId,
          payload: {'reason': 'simultaneous offer'},
        );
        return;
      }
      await previous._terminate(PeerSessionState.closed, notify: true);
    }
    if (_sessions.length >= 16 || _closed) return;
    _make(
      peerId,
      binding,
      envelope.sessionId,
      offerer: false,
    )._accept(envelope);
  }

  /// Cancels all sessions and signaling without adding disconnect intentions.
  Future<void> close() => _closing ??= () async {
    _closed = true;
    await _messages?.cancel();
    await _failures?.cancel();
    await Future.wait(
      _sessions.values.toList().map(
        (session) => session._terminate(PeerSessionState.closed, notify: true),
      ),
    );
    _sessions.clear();
    await signaling.close();
    unawaited(_events.close());
    unawaited(_problems.close());
  }();
}
