part of '../vault_net.dart';

/// One mutually authenticated, generation-bound direct native RTC session.
class PeerSession {
  new _({
    required this._identity,
    required this._peer,
    required this.peerId,
    required Uint8List id,
    required this._offerer,
    required this._stunUrls,
    required this._signaling,
    required this._resolveBinding,
    required this._onTerminal,
    required this._onExplicitDisconnect,
  }) : _id = Uint8List.fromList(id) {
    _packets = StreamController<PeerPacket>(
      sync: true,
      onPause: () => _fail(const PeerFailure('Packet consumer paused')),
    );
    _armDeadline();
  }

  final Identity _identity;
  final KeyBinding _peer;
  final Uint8List _id;
  final bool _offerer;
  final List<String> _stunUrls;
  final SignalingClient _signaling;
  final Future<KeyBinding?> Function(String) _resolveBinding;
  final void Function(PeerSession) _onTerminal;
  final void Function() _onExplicitDisconnect;

  /// Canonical node ID of the expected trusted remote identity.
  final String peerId;

  /// Printable random session identifier, stable across allowed ICE restarts.
  String get sessionId => sessionText(_id);

  /// Current lifecycle snapshot; only connected sessions accept sends.
  PeerSessionState get state => _state;

  /// Sanitized terminal failure reason, or null when no failure was recorded.
  String? get failureReason => _failureReason;

  /// Person-facing classification of the terminal failure, when known.
  ConnectionProblem? get problem => _problem;

  /// Broadcast lifecycle changes; read [state] for the initial snapshot.
  Stream<PeerSessionState> get states => _states.stream;

  /// Single-consumer bounded authenticated packets; consumers must not pause.
  Stream<PeerPacket> get packets => _packets.stream;

  /// Last validated route types; never candidate addresses or SDP.
  /// Empty before verification, during recovery, and after closure.
  Map<String, String> get selectedCandidateTypes => _selectedCandidateTypes;

  /// Local cumulative counts and monotonic microseconds, without packet data.
  /// Snapshot before/after an operation to measure queue, trust and native costs.
  Map<String, int> get transportDiagnostics => Map<String, int>.unmodifiable({
    'trustChecks': _trustTiming.count,
    'trustMicros': _trustTiming.totalMicros,
    'trustMaxMicros': _trustTiming.maxMicros,
    'routeChecks': _routeTiming.count,
    'routeMicros': _routeTiming.totalMicros,
    'routeMaxMicros': _routeTiming.maxMicros,
    'bufferPolls': _bufferTiming.count,
    'bufferMicros': _bufferTiming.totalMicros,
    'bufferMaxMicros': _bufferTiming.maxMicros,
    'nativeSends': _sendTiming.count,
    'nativeSendMicros': _sendTiming.totalMicros,
    'nativeSendMaxMicros': _sendTiming.maxMicros,
    'sendQueueMicros': _sendQueueTiming.totalMicros,
    'sendQueueMaxMicros': _sendQueueTiming.maxMicros,
    'receiveDispatches': _receiveTiming.count,
    'receiveMicros': _receiveTiming.totalMicros,
    'receiveMaxMicros': _receiveTiming.maxMicros,
    'receiveQueueMicros': _receiveQueueTiming.totalMicros,
    'receiveQueueMaxMicros': _receiveQueueTiming.maxMicros,
    'applicationSentFrames': _applicationSentFrames,
    'applicationSentBytes': _applicationSentBytes,
    'applicationReceivedFrames': _applicationReceivedFrames,
    'applicationReceivedBytes': _applicationReceivedBytes,
  });

  PeerSessionState _state = PeerSessionState.negotiating;
  String? _failureReason;
  ConnectionProblem? _problem;
  Map<String, String> _selectedCandidateTypes = const {};
  final _states = StreamController<PeerSessionState>.broadcast();
  late final StreamController<PeerPacket> _packets;
  NativePeer? _native;
  final _channels = <String, NativeChannel>{};
  final _sendTails = <String, Future<void>>{};
  final _queuedBytes = <String, int>{};
  final _queuedPackets = <String, int>{};
  Future<void> _negotiationTail = Future<void>.value();
  Future<void> _receiveTail = Future<void>.value();
  int _pendingNegotiations = 0;
  int _receiveBytes = 0;
  int _receiveCount = 0;
  int _generation = 0;
  int _restarts = 0;
  int _pausedGeneration = -1;
  bool _recovering = false;
  bool _interrupted = false;
  int _routeEpoch = 0;
  bool _closed = false;
  bool _monitorBusy = false;
  bool _sentReady = false;
  String? _offerSdp;
  String? _answerSdp;
  SessionAuthenticator? _auth;
  Completer<void> _authAvailable = Completer<void>();
  Future<void>? _localChallengeSent;
  Timer? _deadline;
  Timer? _monitor;
  Timer? _interruptionDeadline;
  Timer? _routeProbe;
  Future<void>? _cleanup;
  final _stopped = Completer<void>();
  final _clock = Stopwatch()..start();
  final _trustTiming = _OperationTiming();
  final _routeTiming = _OperationTiming();
  final _bufferTiming = _OperationTiming();
  final _sendTiming = _OperationTiming();
  final _sendQueueTiming = _OperationTiming();
  final _receiveTiming = _OperationTiming();
  final _receiveQueueTiming = _OperationTiming();
  int _applicationSentFrames = 0;
  int _applicationSentBytes = 0;
  int _applicationReceivedFrames = 0;
  int _applicationReceivedBytes = 0;

  void _setState(PeerSessionState next) {
    if (_state == next || _closed) return;
    _state = next;
    _states.add(next);
  }

  void _armDeadline() {
    if (_closed) return;
    _deadline?.cancel();
    // Recovery may spend two minutes waiting for signaling before the normal
    // three-minute offer/answer gathering and authentication budget begins.
    _deadline = Timer(Duration(minutes: _recovering ? 5 : 3), () {
      _fail(
        const PeerFailure(
          'Negotiation timed out; exchange current signaling exports',
          problem: ConnectionProblem.negotiationTimedOut,
        ),
      );
    });
  }

  void _serialize(Future<void> Function() operation) {
    if (_closed) return;
    if (++_pendingNegotiations > 8) {
      _pendingNegotiations--;
      _fail(const PeerFailure('Negotiation queue limit exceeded'));
      return;
    }
    _negotiationTail = _negotiationTail.then((_) async {
      try {
        if (!_closed) await operation();
      } on Object catch (error) {
        _fail(error);
      } finally {
        _pendingNegotiations--;
      }
    });
  }

  Future<void> _ensureTrust() async {
    final started = _clock.elapsedMicroseconds;
    try {
      final current = await _resolveBinding(peerId);
      // Mesh setup already cryptographically verified this immutable complete
      // binding and derived peerId. Exact comparison pins that result; hashing
      // and verifying the identical binding per fragment adds no assurance.
      if (_closed || current == null || !sameBinding(current, _peer)) {
        throw const PeerFailure('Peer is untrusted or its key binding changed');
      }
    } finally {
      _trustTiming.record(_clock.elapsedMicroseconds - started);
    }
  }

  Future<void> _createNative() async {
    await _ensureTrust();
    if (_closed) {
      throw const PeerFailure('Session closed before native allocation');
    }
    final native = NativePeer(
      onChannel: (label, channel) => _channels[label] = channel,
      onMessage: _onMessage,
      onDisconnected: _onDisconnected,
      onFailure: _fail,
    );
    _native = native;
    await native.create(_stunUrls);
    if (_closed) {
      await native.close();
      throw const PeerFailure('Session closed during native allocation');
    }
  }

  void _beginOffer() => _serialize(() async {
    await _createNative();
    if (_closed) return;
    _offerSdp = await _native!.offer();
    if (_closed) return;
    await _signaling.send(
      peer: _peer,
      type: MsgType.offer,
      sessionId: _id,
      payload: {'sdp': _offerSdp},
      iceGeneration: _generation,
    );
  });

  void _accept(Envelope envelope) => _serialize(() async {
    await _ensureTrust();
    if (_closed) return;
    if (envelope.iceGeneration < _generation) return;
    if (envelope.type == MsgType.bye) {
      final reason = envelope.payload['reason'];
      if (reason is String &&
          (reason == _failedBye || reason.startsWith('$_failedBye: '))) {
        // The other device failed. Without this the attempt would end as an
        // ordinary close and the person would see no reason.
        _problem = _sharedProblems.asNameMap()[reason.split(': ').last];
        _failureReason = 'The connection failed on the other device';
        await _terminate(PeerSessionState.failed, notify: false);
      } else {
        await _terminate(PeerSessionState.closed, notify: false);
      }
      return;
    }
    if (envelope.type == MsgType.candidate) {
      throw const PeerFailure(
        'Trickled candidates rejected; exchange complete ICE SDP',
      );
    }
    if (envelope.type == MsgType.hello) {
      if (_offerer &&
          envelope.iceGeneration == _generation &&
          (_state == PeerSessionState.connected || _interrupted)) {
        _prepareRecovery();
        await _restartOffer();
      }
      return;
    }
    if (envelope.type == MsgType.offer) {
      if (_offerer ||
          envelope.iceGeneration > _generation + 1 ||
          (_offerSdp != null && envelope.iceGeneration == _generation)) {
        throw const PeerFailure('Unexpected or conflicting offer generation');
      }
      if (_native == null) {
        if (envelope.iceGeneration != 0) {
          throw const PeerFailure('Initial ICE generation must be zero');
        }
        await _createNative();
        if (_closed) return;
      } else {
        if (envelope.iceGeneration != _generation + 1) {
          throw const PeerFailure('ICE generation did not advance');
        }
        if (!_recovering) _prepareRecovery();
        _generation = envelope.iceGeneration;
      }
      _offerSdp = envelope.payload['sdp']! as String;
      SdpBinding.parse(_offerSdp!);
      _answerSdp = await _native!.answer(_offerSdp!);
      if (_closed) return;
      _installAuth();
      await _signaling.send(
        peer: _peer,
        type: MsgType.answer,
        sessionId: _id,
        payload: {'sdp': _answerSdp},
        iceGeneration: _generation,
      );
    } else if (envelope.type == MsgType.answer) {
      if (!_offerer ||
          envelope.iceGeneration != _generation ||
          _offerSdp == null ||
          _answerSdp != null) {
        throw const PeerFailure('Unexpected or conflicting answer generation');
      }
      _answerSdp = envelope.payload['sdp']! as String;
      await _native!.acceptAnswer(_answerSdp!);
      if (!_closed) _installAuth();
    }
  });

  void _installAuth() {
    _auth = SessionAuthenticator(
      identity: _identity,
      peer: _peer,
      session: _id,
      generation: _generation,
      offererId: _offerer ? nodeIdText(_identity.nodeId) : peerId,
      offer: _offerSdp!,
      answer: _answerSdp!,
    );
    _setState(PeerSessionState.authenticating);
    if (_closed) return;
    final generation = _generation;
    final localChallengeSent = _startAuth(generation);
    _localChallengeSent = localChallengeSent;
    _authAvailable.complete();
    unawaited(
      localChallengeSent.catchError((Object error) {
        if (!_closed && generation == _generation && _auth != null) {
          _fail(error);
        }
      }),
    );
  }

  Future<void> _startAuth(int generation) async {
    final watch = Stopwatch()..start();
    while (!_closed &&
        generation == _generation &&
        (_channels.length != 3 || _channels.values.any((c) => !c.open))) {
      if (watch.elapsed > const Duration(seconds: 30)) {
        throw const PeerFailure('Data channels did not open');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (_closed || generation != _generation) return;
    await _ensureTrust();
    await _verifyDirectPath();
    if (_closed || generation != _generation || _auth == null) return;
    await _sendFrame('critical', 1, _auth!.challenge, protected: false);
    if (_closed ||
        generation != _generation ||
        _state == PeerSessionState.connected) {
      return;
    }
    _deadline?.cancel();
    _deadline = Timer(const Duration(seconds: 30), () {
      if (_state != PeerSessionState.connected) {
        _fail(const PeerFailure('Mutual session authentication timed out'));
      }
    });
  }

  Future<void> _sendFrame(
    String channelName,
    int type,
    Uint8List bytes, {
    required bool protected,
  }) {
    if (_closed ||
        _interrupted ||
        (protected && _state != PeerSessionState.connected)) {
      return Future<void>.error(
        const PeerFailure('Session is not authenticated and connected'),
      );
    }
    final generation = _generation;
    final routeEpoch = _routeEpoch;
    final frame = PeerFrame.encode(type, generation, bytes);
    final queued = _queuedBytes[channelName] ?? 0;
    final count = _queuedPackets[channelName] ?? 0;
    final limit = channelName == 'bulk' ? 256 * 1024 : 64 * 1024;
    if (queued + frame.length > limit || count >= 64) {
      return Future<void>.error(
        const PeerFailure('Local channel queue is full'),
      );
    }
    _queuedBytes[channelName] = queued + frame.length;
    _queuedPackets[channelName] = count + 1;
    final previous = _sendTails[channelName] ?? Future<void>.value();
    final queuedAt = _clock.elapsedMicroseconds;
    final result = previous.then((_) async {
      _sendQueueTiming.record(_clock.elapsedMicroseconds - queuedAt);
      final watch = Stopwatch()..start();
      try {
        final channel = _channels[channelName];
        if (channel == null) {
          throw const PeerFailure('Data channel unavailable');
        }
        while (true) {
          if (_closed ||
              generation != _generation ||
              _interrupted ||
              routeEpoch != _routeEpoch ||
              (_recovering && generation == _pausedGeneration) ||
              (protected && _state != PeerSessionState.connected)) {
            throw const PeerFailure('Send cancelled by session transition');
          }
          // Query the native counter: cached values and low-buffer callbacks
          // are not dependable on every supported native platform.
          if (channel.open) {
            final pollStarted = _clock.elapsedMicroseconds;
            late final int buffered;
            try {
              buffered = await channel.bufferedAmount();
            } finally {
              _bufferTiming.record(_clock.elapsedMicroseconds - pollStarted);
            }
            if (buffered + frame.length <= limit) break;
          }
          if (watch.elapsed > const Duration(seconds: 20)) {
            throw const PeerFailure('Native data channel buffer stalled');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await _ensureTrust();
        await _verifyDirectPath();
        if (_closed ||
            generation != _generation ||
            _interrupted ||
            routeEpoch != _routeEpoch ||
            (_recovering && generation == _pausedGeneration) ||
            (protected && _state != PeerSessionState.connected)) {
          throw const PeerFailure('Send cancelled after route verification');
        }
        final sendStarted = _clock.elapsedMicroseconds;
        try {
          await channel.send(frame);
          if (protected) {
            _applicationSentFrames++;
            _applicationSentBytes += bytes.length;
          }
        } finally {
          _sendTiming.record(_clock.elapsedMicroseconds - sendStarted);
        }
      } on Object catch (error) {
        if (!_closed &&
            generation == _generation &&
            routeEpoch == _routeEpoch &&
            !(_recovering && generation == _pausedGeneration)) {
          _transportError(error);
        }
        rethrow;
      } finally {
        _queuedBytes[channelName] =
            (_queuedBytes[channelName] ?? frame.length) - frame.length;
        _queuedPackets[channelName] = (_queuedPackets[channelName] ?? 1) - 1;
      }
    });
    // Keep the serialization tail successful; return the actual failure to the
    // caller, without orphan errors or breaking subsequent queued cancellation.
    _sendTails[channelName] = result.catchError((Object _) {});
    return result;
  }

  /// Sends reliable ordered JSON within the complete 16 KiB packet budget.
  Future<void> sendControl(Map<String, Object?> message) => _sendFrame(
    'critical',
    16,
    encodeControl(message, overhead: 5),
    protected: true,
  );

  /// Sends one reliable binary fragment; delivery owns fragmentation/resumption.
  Future<void> sendBulk(Uint8List bytes) =>
      _sendFrame('bulk', 16, bytes, protected: true);

  /// Sends bounded unordered JSON with native maxRetransmits exactly zero.
  Future<void> sendEphemeral(Map<String, Object?> message) => _sendFrame(
    'ephemeral',
    16,
    encodeControl(message, overhead: 5),
    protected: true,
  );

  void _onMessage(String channel, Uint8List frame) {
    if (_closed) return;
    if (_interrupted) return;
    late final PeerFrame decoded;
    try {
      decoded = PeerFrame.decode(frame);
      if (!decoded.isCurrent(
        _generation,
        pausedGeneration: _recovering ? _pausedGeneration : null,
      )) {
        return;
      }
    } on Object catch (error) {
      _fail(error);
      return;
    }
    final generation = decoded.generation;
    final routeEpoch = _routeEpoch;
    if (_receiveCount >= 64 || _receiveBytes + frame.length > 256 * 1024) {
      _fail(const PeerFailure('Receive queue limit exceeded'));
      return;
    }
    final copy = Uint8List.fromList(frame);
    _receiveCount++;
    _receiveBytes += copy.length;
    final queuedAt = _clock.elapsedMicroseconds;
    _receiveTail = _receiveTail.then((_) async {
      final started = _clock.elapsedMicroseconds;
      _receiveQueueTiming.record(started - queuedAt);
      try {
        if (!_closed && generation == _generation) {
          if (_interrupted || routeEpoch != _routeEpoch) return;
          await _handleFrame(channel, copy);
        }
      } on Object catch (error) {
        if (!_closed &&
            generation == _generation &&
            routeEpoch == _routeEpoch &&
            !(_recovering && generation == _pausedGeneration)) {
          _transportError(error);
        }
      } finally {
        _receiveTiming.record(_clock.elapsedMicroseconds - started);
        _receiveCount--;
        _receiveBytes -= copy.length;
      }
    });
  }

  Future<void> _handleFrame(String channel, Uint8List frame) async {
    final generation = ByteData.sublistView(frame).getUint32(1);
    final routeEpoch = _routeEpoch;
    if (_closed || (_recovering && generation == _pausedGeneration)) return;
    final type = frame[0];
    final body = Uint8List.sublistView(frame, 5);
    if (channel == 'critical' && type >= 1 && type <= 3) {
      await _authAvailable.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw const PeerFailure(
          'Signed SDP authentication context unavailable after 30 seconds',
        ),
      );
      if (_closed ||
          generation != _generation ||
          (_recovering && generation == _pausedGeneration)) {
        return;
      }
      final auth = _auth;
      if (auth == null) return;
      if (type == 1) {
        auth.acceptChallenge(body);
        // The critical channel may receive a challenge before the other local
        // channels open. Keep our challenge ahead of our proof on the ordered
        // stream, even while native readiness/trust checks are still awaiting.
        await _localChallengeSent;
        if (_closed || !identical(_auth, auth)) return;
        final proof = await auth.createProof();
        if (_closed || !identical(_auth, auth)) return;
        await _sendFrame('critical', 2, proof, protected: false);
        if (_closed || !identical(_auth, auth)) return;
        auth.markProofSent();
      } else if (type == 2) {
        await _ensureTrust();
        await auth.acceptProof(body);
        if (_closed || !identical(_auth, auth)) return;
      } else {
        if (body.isNotEmpty) throw const PeerFailure('Invalid readiness frame');
        auth.acceptReady();
      }
      if (auth.authenticated && !_sentReady) {
        _sentReady = true;
        await _sendFrame('critical', 3, Uint8List(0), protected: false);
      }
      if (auth.connected) {
        await _verifyDirectPath();
        if (_closed || !identical(_auth, auth)) return;
        _deadline?.cancel();
        _recovering = false;
        _restarts = 0;
        _setState(PeerSessionState.connected);
        _startMonitor();
      }
      return;
    }
    if (type != 16 || _auth?.authenticated != true) {
      throw const PeerFailure(
        'Application packet before mutual authentication',
      );
    }
    await _ensureTrust();
    await _verifyDirectPath();
    if (_closed ||
        _interrupted ||
        routeEpoch != _routeEpoch ||
        generation != _generation ||
        _auth?.authenticated != true) {
      return;
    }
    if (!_packets.hasListener || _packets.isPaused) {
      throw const PeerFailure('No active packet consumer');
    }
    final packet = switch (channel) {
      'critical' => PeerPacket.control(decodeControl(body)),
      'bulk' => PeerPacket.bulk(body),
      'ephemeral' => PeerPacket.ephemeral(decodeControl(body)),
      _ => throw const PeerFailure('Unknown application channel'),
    };
    _applicationReceivedFrames++;
    _applicationReceivedBytes += body.length;
    _packets.add(packet);
  }

  Future<void> _verifyDirectPath() async {
    final generation = _generation;
    final routeEpoch = _routeEpoch;
    final native = _native;
    if (_closed || native == null) {
      throw const PeerFailure('Native peer is closed');
    }
    final started = _clock.elapsedMicroseconds;
    try {
      final path = await native.directPath();
      if (_closed ||
          generation != _generation ||
          routeEpoch != _routeEpoch ||
          (_recovering && generation == _pausedGeneration)) {
        return;
      }
      if (_selectedCandidateTypes['local'] != path.localType ||
          _selectedCandidateTypes['remote'] != path.remoteType) {
        _selectedCandidateTypes = Map<String, String>.unmodifiable({
          'local': path.localType,
          'remote': path.remoteType,
        });
      }
    } on Object {
      if (generation == _generation && routeEpoch == _routeEpoch) {
        _selectedCandidateTypes = const {};
      }
      rethrow;
    } finally {
      _routeTiming.record(_clock.elapsedMicroseconds - started);
    }
  }

  void _startMonitor() {
    if (_closed || _state != PeerSessionState.connected) return;
    _monitor?.cancel();
    _monitor = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_closed || _monitorBusy || _state != PeerSessionState.connected) {
        return;
      }
      _monitorBusy = true;
      final generation = _generation;
      final routeEpoch = _routeEpoch;
      unawaited(() async {
        try {
          await _ensureTrust();
          if (_closed ||
              generation != _generation ||
              _state != PeerSessionState.connected) {
            return;
          }
          await _verifyDirectPath();
        } on DirectPathPending {
          if (routeEpoch == _routeEpoch) _onDisconnected();
        } on Object catch (error) {
          if (generation == _generation &&
              routeEpoch == _routeEpoch &&
              _state == PeerSessionState.connected) {
            _fail(error);
          }
        } finally {
          _monitorBusy = false;
        }
      }());
    });
  }

  void _transportError(Object error) {
    if (error is DirectPathPending && _state == PeerSessionState.connected) {
      _onDisconnected();
    } else {
      _fail(error);
    }
  }

  void _prepareRecovery() {
    if (_closed || _recovering) return;
    if (++_restarts > 3) {
      throw const PeerFailure(
        'ICE recovery limit reached; reconnect explicitly',
      );
    }
    _interrupted = false;
    _routeEpoch++;
    _interruptionDeadline?.cancel();
    _routeProbe?.cancel();
    _recovering = true;
    _selectedCandidateTypes = const {};
    _pausedGeneration = _generation;
    _monitor?.cancel();
    _auth = null;
    _authAvailable = Completer<void>();
    _localChallengeSent = null;
    _sentReady = false;
    _answerSdp = null;
    _setState(PeerSessionState.negotiating);
    _armDeadline();
  }

  void _onDisconnected() {
    if (_closed ||
        _recovering ||
        _interrupted ||
        _state != PeerSessionState.connected) {
      return;
    }
    // A short native outage can recover on the same authenticated SCTP route.
    // Pause traffic immediately; retain its transcript until restart is needed.
    _interrupted = true;
    final epoch = ++_routeEpoch;
    _selectedCandidateTypes = const {};
    _monitor?.cancel();
    _setState(PeerSessionState.negotiating);
    _interruptionDeadline = Timer(const Duration(seconds: 10), () {
      if (!_closed && _interrupted && epoch == _routeEpoch) _recover();
    });
    var probing = false;
    Future<void> probe() async {
      if (probing || _closed || !_interrupted || epoch != _routeEpoch) return;
      probing = true;
      try {
        await _ensureTrust();
        await _verifyDirectPath();
        if (_closed || !_interrupted || epoch != _routeEpoch) return;
        _interrupted = false;
        _routeEpoch++;
        _interruptionDeadline?.cancel();
        _routeProbe?.cancel();
        _setState(PeerSessionState.connected);
        _startMonitor();
      } on DirectPathPending {
        // No bytes may flow until a fresh succeeded direct pair is verified.
      } on Object catch (error) {
        if (!_closed && _interrupted && epoch == _routeEpoch) _fail(error);
      } finally {
        probing = false;
      }
    }

    _routeProbe = Timer.periodic(const Duration(milliseconds: 250), (_) {
      unawaited(probe());
    });
    unawaited(probe());
  }

  void _recover() {
    try {
      _prepareRecovery();
      _serialize(() async {
        if (_offerer) {
          await _restartOffer();
        } else {
          await _waitForSignaling();
          if (_closed) return;
          await _signaling.send(
            peer: _peer,
            type: MsgType.hello,
            sessionId: _id,
            payload: {'nonce': freshBytes(32)},
            iceGeneration: _generation,
          );
        }
      });
    } on Object catch (error) {
      _fail(error);
    }
  }

  Future<void> _waitForSignaling() async {
    if (_closed) throw const PeerFailure('Session closed during recovery');
    final strategy = _signaling.strategy;
    if (strategy.connected) return;
    final ready = Completer<void>();
    final subscription = strategy.connectionChanges.listen(
      (connected) {
        if (connected && !ready.isCompleted) ready.complete();
      },
      onError: (Object error) {
        if (!ready.isCompleted) {
          ready.completeError(
            const PeerFailure('Signaling readiness stream failed'),
          );
        }
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(
            const PeerFailure('Signaling closed during recovery'),
          );
        }
      },
    );
    if (strategy.connected && !ready.isCompleted) ready.complete();
    try {
      await Future.any<void>([
        ready.future,
        _stopped.future.then<void>(
          (_) => throw const PeerFailure('Session closed during recovery'),
        ),
      ]).timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          throw const PeerFailure('Signaling recovery readiness timed out');
        },
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _restartOffer() async {
    await _waitForSignaling();
    await _ensureTrust();
    if (_closed) return;
    _generation++;
    _offerSdp = await _native!.offer(restart: true);
    if (_closed) return;
    await _signaling.send(
      peer: _peer,
      type: MsgType.offer,
      sessionId: _id,
      payload: {'sdp': _offerSdp},
      iceGeneration: _generation,
    );
  }

  void _signalingFailure(SignalingFailure failure) {
    if (failure.terminal && !_closed && _state != PeerSessionState.connected) {
      _fail(
        PeerFailure(
          'Signaling failed: ${failure.reason}',
          problem: switch (failure.kind) {
            SignalingFailureKind.acknowledgmentTimeout =>
              ConnectionProblem.negotiationTimedOut,
            SignalingFailureKind.transportUnavailable =>
              ConnectionProblem.signalingUnavailable,
            SignalingFailureKind.unknownSender ||
            SignalingFailureKind.other => null,
          },
        ),
      );
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    if (error is PeerFailure) _problem = error.problem;
    _failureReason = error is PeerFailure
        ? error.reason
        : error is TimeoutException
        ? 'Native operation timed out'
        : 'Peer operation failed (${error.runtimeType})';
    unawaited(_terminate(PeerSessionState.failed, notify: true));
  }

  /// Explicitly disconnects this peer and disables automatic reconnection.
  Future<void> close() {
    _onExplicitDisconnect();
    return _terminate(PeerSessionState.closed, notify: true);
  }

  Future<void> _terminate(PeerSessionState terminal, {required bool notify}) {
    if (_cleanup != null) return _cleanup!;
    final done = Completer<void>();
    _cleanup = done.future;
    _closed = true;
    _selectedCandidateTypes = const {};
    _stopped.complete();
    _state = terminal;
    _deadline?.cancel();
    _interruptionDeadline?.cancel();
    _routeProbe?.cancel();
    _monitor?.cancel();
    _states.add(terminal);
    _onTerminal(this);
    // Unblock the bounded inbound tail; it checks _closed before using _auth.
    if (!_authAvailable.isCompleted) _authAvailable.complete();
    final native = _native;
    _native = null;
    final work = () async {
      if (notify) {
        try {
          await _signaling
              .send(
                peer: _peer,
                type: MsgType.bye,
                sessionId: _id,
                payload: {
                  'reason': switch ((terminal, _problem)) {
                    (PeerSessionState.closed, _) => 'disconnected',
                    (_, final problem?)
                        when _sharedProblems.contains(problem) =>
                      '$_failedBye: ${problem.name}',
                    _ => _failedBye,
                  },
                },
                iceGeneration: _generation,
              )
              .timeout(const Duration(seconds: 2));
        } on Object {
          // Explicit local closure never depends on signaling availability.
        }
      }
      try {
        await native?.close();
      } on Object {
        _failureReason ??= 'Native RTC cleanup failed';
      }
      _channels.clear();
      // close() must not wait forever for a paused/cancelled consumer.
      unawaited(_packets.close());
      unawaited(_states.close());
    }();
    unawaited(
      work.then<void>((_) => done.complete(), onError: done.completeError),
    );
    return _cleanup!;
  }
}

/// A `bye` reason that starts with this ends the receiver's session as failed.
const _failedBye = 'failed';

/// Failure causes that describe the attempt for both devices, so a `bye`
/// carries them. Signaling problems are local to the device that had them.
const List<ConnectionProblem> _sharedProblems = [
  ConnectionProblem.negotiationTimedOut,
  ConnectionProblem.noDirectRoute,
];

class _OperationTiming {
  int count = 0;
  int totalMicros = 0;
  int maxMicros = 0;

  void record(int elapsedMicros) {
    count++;
    totalMicros += elapsedMicros;
    if (elapsedMicros > maxMicros) maxMicros = elapsedMicros;
  }
}
