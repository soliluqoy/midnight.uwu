import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'remote_range.dart';

// Spike-local import seam. Does not implement the production identity/protocol.
// Test bytes are generated patterns; SDP is exchanged only over local USB control.
const hotspotProbe = bool.fromEnvironment('VAULT_HOTSPOT');

Future<void> initializeProbeWebRTC() async {
  if (Platform.isAndroid) {
    await WebRTC.initialize(options: {'disableNetworkMonitor': hotspotProbe});
  }
}

class EphemeralInit extends RTCDataChannelInit {
  EphemeralInit() {
    ordered = false;
    maxRetransmits = 0;
  }
  // webrtc_interface 1.5.1 drops zero in toMap() because it tests >0.
  @override
  Map<String, dynamic> toMap() => {...super.toMap(), 'maxRetransmits': 0};
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

/// Block-verified transfer: 1MiB blocks, per-block SHA-256 checked against the
/// sender's claim, resume from the last verified block, root over block digests.
const xBlockBytes = 1024 * 1024;
const xMessageBytes = 16 * 1024;
const xMaxBytes = 4 * 1024 * 1024 * 1024;
final _xBase = Uint8List.fromList(
  List<int>.generate(xMessageBytes + 251, (i) => i % 251),
);

/// Deterministic, position-dependent test bytes. [offset] is message-aligned.
/// Each block starts with its big-endian index so blocks never share digests.
Uint8List xPatternMessage(int offset, int count) {
  final shift = ((offset ~/ xMessageBytes) * 7) % 251;
  final view = Uint8List.sublistView(_xBase, shift, shift + count);
  if (offset % xBlockBytes != 0) return view;
  final stamped = Uint8List.fromList(view);
  ByteData.sublistView(stamped).setUint64(0, offset ~/ xBlockBytes);
  return stamped;
}

String xRoot(List<String> blockDigests) =>
    sha256.convert(utf8.encode(blockDigests.join(','))).toString();

int xBlockCount(int total) => (total + xBlockBytes - 1) ~/ xBlockBytes;

class _XRecv {
  _XRecv(this.id, this.total);
  final String id;
  final int total;
  final verified = <String>[];
  final computed = <int, String>{};
  final claimed = <int, String>{};
  ByteConversionSink? sink;
  _DigestSink? digest;
  int blockBytes = 0;
  int attemptBytes = 0;
  int? cancelAt;
  String? endRoot;
  bool active = false;
  bool failed = false;
  int peakRss = 0;
  int get nextBlock => verified.length + computed.length;
}

class ProbePeer {
  static const dataOnlyConstraints = <String, dynamic>{
    'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
    'optional': <dynamic>[],
  };
  RTCPeerConnection? _pc;
  RTCDataChannel? _control;
  RTCDataChannel? _bulk;
  RTCDataChannel? _range;
  Map<String, Uint8List> _hostFixtures = {};
  final _rangePending = <int, _RangeAssembly>{};
  final _rangeCancelled = <int>{};
  final _rangeOutstanding = <int>{};
  Future<void> _rangeSendTail = Future<void>.value();
  int _rangeId = 0;
  int _generation = 0;
  int rangeBytesSent = 0;
  int rangeRequestsServed = 0;
  int rangeCancelled = 0;
  final Map<String, Completer<Map<String, dynamic>>> _acks = {};
  final List<Map<String, Object?>> events = [];
  _DigestSink? _digest;
  ByteConversionSink? _incoming;
  int _received = 0;
  int _expected = 0;
  String? _receiveId;
  String? _expectedHash;
  bool _sending = false;
  _XRecv? _xr;

  Map<String, Object?> get status => {
    'connection': _pc?.connectionState?.name,
    'ice': _pc?.iceConnectionState?.name,
    'control': _control?.state?.name,
    'bulk': _bulk?.state?.name,
    'range': _range?.state?.name,
    'rangeBytesSent': rangeBytesSent,
    'rangeRequestsServed': rangeRequestsServed,
    'rangeCancelled': rangeCancelled,
    'rangePending': _rangePending.length,
    'rangeOutstanding': _rangeOutstanding.length,
    'receivedBytes': _received,
    'xRecv': _xr == null
        ? null
        : {
            'id': _xr!.id,
            'verifiedBlocks': _xr!.verified.length,
            'failed': _xr!.failed,
            'peakRssBytes': _xr!.peakRss,
          },
    'events': events,
  };

  Future<void> create() async {
    await close();
    _pc = await createPeerConnection({
      'iceServers': <Map<String, Object?>>[],
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'iceTransportPolicy': 'all',
    });
    _pc!.onConnectionState = (state) => _event('connection', state.name);
    _pc!.onDataChannel = _attach;
  }

  void _event(String kind, String value) {
    events.add({'kind': kind, 'value': value});
    if (events.length > 30) events.removeAt(0);
  }

  void _attach(RTCDataChannel channel) {
    switch (channel.label) {
      case 'critical':
        _control = channel;
        channel.onMessage = (message) {
          if (!message.isBinary) {
            _onControl(jsonDecode(message.text) as Map<String, dynamic>);
          }
        };
      case 'bulk':
        _bulk = channel;
        channel.onMessage = (message) {
          if (message.isBinary && _xr?.active == true) {
            _onXBulk(message.binary);
            return;
          }
          if (!message.isBinary || _incoming == null) return;
          _received += message.binary.length;
          if (_received > _expected) {
            _event('error', 'Received more bytes than requested');
            return;
          }
          _incoming!.add(message.binary);
          _finishReceive();
        };
      case 'range':
        _range = channel;
        channel.onMessage = (message) {
          if (message.isBinary) _onRangeFrame(message.binary);
        };
    }
    channel.onDataChannelState = (state) =>
        _event(channel.label ?? '?', state.name);
  }

  void _onControl(Map<String, dynamic> message) {
    final id = message['id'] as String;
    switch (message['type']) {
      case 'xrejected':
        for (final key
            in _acks.keys.where((k) => k.endsWith(':$id')).toList()) {
          _acks.remove(key)!.completeError(StateError('${message['reason']}'));
        }
      case 'xbegin':
        _onXBegin(id, message['bytes']);
      case 'xblock':
        final index = message['index'];
        final digest = message['sha256'];
        final x = _xr;
        if (x != null && x.id == id && index is int && digest is String) {
          x.claimed[index] = digest;
          _xVerify(x);
        }
      case 'xcancel':
        final x = _xr;
        final sent = message['sent'];
        if (x != null && x.id == id && sent is int) {
          x.cancelAt = sent;
          _xMaybeCancel(x);
        }
      case 'xend':
        final x = _xr;
        final root = message['root'];
        if (x != null && x.id == id && root is String) {
          x.endRoot = root;
          _xVerify(x);
        }
      case 'rangeManifestRequest':
        _sendControl({
          'type': 'rangeManifest',
          'id': id,
          'lengths': {
            for (final e in _hostFixtures.entries) e.key: e.value.length,
          },
        });
      case 'rangeManifest':
        final ack = _acks.remove('rangeManifest:$id');
        if (ack != null && !ack.isCompleted) ack.complete(message);
      case 'rangeRequest':
        final number = int.tryParse(id);
        final fixture = message['fixture'];
        final index = message['chunk'];
        final bytes = fixture is String ? _hostFixtures[fixture] : null;
        final channel = _range;
        if (number == null ||
            number < 1 ||
            number > 0xffffffff ||
            _rangeOutstanding.length >= 8 ||
            _rangeOutstanding.contains(number) ||
            index is! int ||
            index < 0 ||
            bytes == null ||
            index * rangeChunkBytes >= bytes.length ||
            channel == null) {
          _sendControl({
            'type': 'rangeError',
            'id': id,
            'reason': 'Invalid range request',
          });
          return;
        }
        final generation = _generation;
        _rangeOutstanding.add(number);
        _rangeSendTail = _rangeSendTail.then((_) async {
          try {
            if (generation == _generation) {
              await _sendRangeChunk(channel, generation, number, bytes, index);
            }
          } catch (error) {
            if (generation == _generation) {
              _sendControl({
                'type': 'rangeError',
                'id': id,
                'reason': '$error',
              });
            }
          } finally {
            if (_rangeCancelled.remove(number)) rangeCancelled++;
            _rangeOutstanding.remove(number);
          }
        });
      case 'rangeCancel':
        final number = int.tryParse(id);
        if (number != null && _rangeOutstanding.contains(number)) {
          _rangeCancelled.add(number);
        }
      case 'rangeError':
        final pending = _rangePending[int.tryParse(id)];
        if (pending != null && !pending.done.isCompleted) {
          pending.done.completeError(StateError('${message['reason']}'));
        }
      case 'begin':
        _receiveId = id;
        _expected = message['bytes'] as int;
        if (_expected < 1 || _expected > 256 * 1024 * 1024) {
          _sendControl({
            'type': 'error',
            'id': id,
            'reason': 'Invalid test size',
          });
          return;
        }
        _received = 0;
        _expectedHash = null;
        _digest = _DigestSink();
        _incoming = sha256.startChunkedConversion(_digest!);
        _sendControl({'type': 'ready', 'id': id});
      case 'end':
        if (id != _receiveId) return;
        _expectedHash = message['sha256'] as String;
        _finishReceive();
      case 'ready':
      case 'xready':
      case 'xcancelled':
      case 'xcomplete':
      case 'complete':
      case 'pong':
      case 'error':
        final ack = _acks.remove('${message['type']}:$id');
        if (ack != null && !ack.isCompleted) ack.complete(message);
      case 'ping':
        _sendControl({'type': 'pong', 'id': id});
    }
  }

  void _finishReceive() {
    if (_received != _expected || _expectedHash == null || _incoming == null) {
      return;
    }
    _incoming!.close();
    _incoming = null;
    final actual = _digest!.value.toString();
    _sendControl({
      'type': 'complete',
      'id': _receiveId!,
      'bytes': _received,
      'sha256': actual,
      'verified': actual == _expectedHash,
    });
  }

  void _sendControl(Map<String, Object?> body) {
    unawaited(_control!.send(RTCDataChannelMessage(jsonEncode(body))));
  }

  Future<Map<String, dynamic>> _waitAck(String kind, String id) {
    final completer = Completer<Map<String, dynamic>>();
    _acks['$kind:$id'] = completer;
    return completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        _acks.remove('$kind:$id');
        throw TimeoutException('No $kind acknowledgment');
      },
    );
  }

  Future<Map<String, String>> offer() async {
    await create();
    _attach(await _pc!.createDataChannel('critical', RTCDataChannelInit()));
    _attach(
      await _pc!.createDataChannel(
        'bulk',
        RTCDataChannelInit()..binaryType = 'binary',
      ),
    );
    await _pc!.createDataChannel('ephemeral', EphemeralInit());
    _attach(
      await _pc!.createDataChannel(
        'range',
        RTCDataChannelInit()..binaryType = 'binary',
      ),
    );
    await _pc!.setLocalDescription(await _pc!.createOffer(dataOnlyConstraints));
    return _gather();
  }

  Future<Map<String, String>> answer(Map<String, dynamic> offer) async {
    await create();
    await _pc!.setRemoteDescription(
      RTCSessionDescription(offer['sdp'] as String, 'offer'),
    );
    await _pc!.setLocalDescription(
      await _pc!.createAnswer(dataOnlyConstraints),
    );
    return _gather();
  }

  Future<Map<String, String>> _gather() async {
    final watch = Stopwatch()..start();
    while (await _pc!.getIceGatheringState() !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      if (watch.elapsed > const Duration(seconds: 15)) {
        throw TimeoutException('ICE gather');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final description = (await _pc!.getLocalDescription())!;
    if (RegExp(
      r'^m=(audio|video)\s',
      multiLine: true,
    ).hasMatch(description.sdp!)) {
      throw StateError(
        'Data-only probe unexpectedly negotiated a media section',
      );
    }
    if (RegExp(r' typ relay\b').hasMatch(description.sdp!)) {
      throw StateError('Relay candidate rejected');
    }
    return {'sdp': description.sdp!, 'type': description.type!};
  }

  Future<void> accept(Map<String, dynamic> answer) => _pc!.setRemoteDescription(
    RTCSessionDescription(answer['sdp'] as String, 'answer'),
  );

  Future<void> ready({bool range = false}) async {
    final watch = Stopwatch()..start();
    while (_control?.state != RTCDataChannelState.RTCDataChannelOpen ||
        _bulk?.state != RTCDataChannelState.RTCDataChannelOpen ||
        (range && _range?.state != RTCDataChannelState.RTCDataChannelOpen)) {
      if (watch.elapsed > const Duration(seconds: 30)) {
        throw TimeoutException('Data channels not open: $status');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  void hostRangeFixtures(Map<String, Uint8List> fixtures) {
    if (fixtures.keys.any(
      (name) => name != 'front.mp4' && name != 'tail.mp4',
    )) {
      throw ArgumentError('Only generated front/tail fixtures are allowed');
    }
    _hostFixtures = Map.of(fixtures);
  }

  Future<Map<String, int>> remoteRangeManifest() async {
    await ready(range: true);
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final reply = _waitAck('rangeManifest', id);
    _sendControl({'type': 'rangeManifestRequest', 'id': id});
    final raw = (await reply)['lengths'] as Map<String, dynamic>;
    final lengths = <String, int>{};
    for (final entry in raw.entries) {
      if ((entry.key != 'front.mp4' && entry.key != 'tail.mp4') ||
          entry.value is! int ||
          entry.value <= 0 ||
          entry.value > 16 * 1024 * 1024) {
        throw StateError('Invalid remote fixture manifest');
      }
      lengths[entry.key] = entry.value as int;
    }
    if (lengths.length != 2) {
      throw StateError('Incomplete remote fixture manifest');
    }
    return lengths;
  }

  Future<Uint8List> fetchRangeChunk(
    String fixture,
    int chunk,
    RangeCancellation cancellation,
  ) async {
    await ready(range: true);
    cancellation.check();
    if (_rangePending.length >= 8) {
      throw StateError('Too many pending Range requests');
    }
    final id = ++_rangeId;
    final generation = _generation;
    final assembly = _RangeAssembly();
    _rangePending[id] = assembly;
    _sendControl({
      'type': 'rangeRequest',
      'id': '$id',
      'fixture': fixture,
      'chunk': chunk,
    });
    try {
      return await Future.any<Uint8List>([
        assembly.done.future.timeout(const Duration(seconds: 20)),
        cancellation.cancelled.then((_) => throw const RangeCancelled()),
      ]);
    } finally {
      _rangePending.remove(id);
      if (!assembly.done.isCompleted && generation == _generation) {
        _sendControl({'type': 'rangeCancel', 'id': '$id'});
      }
    }
  }

  void _onRangeFrame(Uint8List frame) {
    if (frame.length < 16) return;
    final header = ByteData.sublistView(frame);
    if (header.getUint32(0) != 0x56524e47) return;
    final assembly = _rangePending[header.getUint32(4)];
    if (assembly == null || assembly.done.isCompleted) return;
    final offset = header.getUint32(8);
    final total = header.getUint32(12);
    if (total < 1 ||
        total > rangeChunkBytes ||
        frame.length > 16 * 1024 ||
        offset != assembly.received ||
        frame.length == 16 ||
        offset + frame.length - 16 > total ||
        (assembly.total != null && assembly.total != total)) {
      assembly.done.completeError(StateError('Invalid Range fragment'));
      return;
    }
    assembly.total = total;
    assembly.bytes ??= Uint8List(total);
    assembly.bytes!.setRange(offset, offset + frame.length - 16, frame, 16);
    assembly.received += frame.length - 16;
    if (assembly.received == total) assembly.done.complete(assembly.bytes!);
  }

  Future<void> _sendRangeChunk(
    RTCDataChannel channel,
    int generation,
    int id,
    Uint8List fixture,
    int index,
  ) async {
    final start = index * rangeChunkBytes;
    final total = min(rangeChunkBytes, fixture.length - start);
    const payload = 16 * 1024 - 16;
    for (var offset = 0; offset < total; offset += payload) {
      final count = min(payload, total - offset);
      final watch = Stopwatch()..start();
      while (true) {
        if (_generation != generation || _rangeCancelled.contains(id)) return;
        if (await channel.getBufferedAmount() + 16 + count <= 512 * 1024) break;
        if (watch.elapsed > const Duration(seconds: 20)) {
          throw TimeoutException('Range channel stalled');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (_generation != generation || _rangeCancelled.contains(id)) return;
      final frame = Uint8List(16 + count);
      final header = ByteData.sublistView(frame);
      header.setUint32(0, 0x56524e47);
      header.setUint32(4, id);
      header.setUint32(8, offset);
      header.setUint32(12, total);
      frame.setRange(16, frame.length, fixture, start + offset);
      await channel.send(RTCDataChannelMessage.fromBinary(frame));
      rangeBytesSent += count;
    }
    rangeRequestsServed++;
  }

  void _onXBegin(String id, Object? bytes) {
    if (bytes is! int || bytes < 1 || bytes > xMaxBytes) {
      _sendControl({'type': 'xrejected', 'id': id, 'reason': 'Invalid size'});
      return;
    }
    var x = _xr;
    if (x == null || x.id != id) {
      x = _xr = _XRecv(id, bytes);
    } else if (x.total != bytes) {
      _sendControl({'type': 'xrejected', 'id': id, 'reason': 'Size changed'});
      return;
    }
    x
      ..sink = null
      ..digest = null
      ..blockBytes = 0
      ..attemptBytes = 0
      ..cancelAt = null
      ..endRoot = null
      ..failed = false
      ..active = true
      ..computed.clear()
      ..claimed.clear();
    _sendControl({'type': 'xready', 'id': id, 'have': x.verified.length});
  }

  int _xBlockLength(_XRecv x, int block) =>
      min(xBlockBytes, x.total - block * xBlockBytes);

  void _onXBulk(Uint8List data) {
    final x = _xr!;
    var view = data;
    while (view.isNotEmpty && x.active) {
      final block = x.nextBlock;
      if (block >= xBlockCount(x.total)) {
        x.failed = true;
        x.active = false;
        _event('error', 'Bulk bytes beyond declared size');
        return;
      }
      if (x.sink == null) {
        x.digest = _DigestSink();
        x.sink = sha256.startChunkedConversion(x.digest!);
        x.blockBytes = 0;
      }
      final take = min(view.length, _xBlockLength(x, block) - x.blockBytes);
      x.sink!.add(Uint8List.sublistView(view, 0, take));
      x.blockBytes += take;
      x.attemptBytes += take;
      view = Uint8List.sublistView(view, take);
      if (x.blockBytes == _xBlockLength(x, block)) {
        x.sink!.close();
        x.sink = null;
        x.computed[block] = x.digest!.value.toString();
        x.blockBytes = 0;
        _xVerify(x);
      }
    }
    _xMaybeCancel(x);
  }

  void _xVerify(_XRecv x) {
    while (true) {
      final index = x.verified.length;
      final mine = x.computed[index];
      final theirs = x.claimed[index];
      if (mine == null || theirs == null) break;
      if (mine != theirs) {
        x.failed = true;
        x.active = false;
        _sendControl({
          'type': 'xrejected',
          'id': x.id,
          'reason': 'Block $index digest mismatch',
        });
        return;
      }
      x.verified.add(mine);
      x.computed.remove(index);
      x.claimed.remove(index);
      x.peakRss = max(x.peakRss, ProcessInfo.currentRss);
    }
    final root = x.endRoot;
    if (root != null && x.verified.length == xBlockCount(x.total)) {
      final actual = xRoot(x.verified);
      x
        ..endRoot = null
        ..active = false;
      _sendControl({
        'type': 'xcomplete',
        'id': x.id,
        'bytes': x.total,
        'blocks': x.verified.length,
        'root': actual,
        'verified': actual == root,
      });
    }
  }

  void _xMaybeCancel(_XRecv x) {
    final at = x.cancelAt;
    if (at == null || x.attemptBytes < at) return;
    // Every byte the sender sent has arrived: drop the unverified partial block.
    x.sink?.close();
    x
      ..sink = null
      ..computed.clear()
      ..cancelAt = null
      ..active = false;
    _sendControl({'type': 'xcancelled', 'id': x.id, 'have': x.verified.length});
  }

  /// Sends [bytes] of position-dependent test data as verified 1MiB blocks,
  /// resuming at the receiver's verified-block count for [id]. When
  /// [stopAfterBytes] is set the attempt is cancelled after that many bytes.
  Future<Map<String, Object?>> sendBlocks(
    String id,
    int bytes, {
    int? stopAfterBytes,
  }) async {
    if (_sending) throw StateError('One transfer at a time');
    if (bytes < 1 || bytes > xMaxBytes) throw ArgumentError('1..4GiB');
    _sending = true;
    var pinging = true;
    try {
      await ready();
      final ready0 = _waitAck('xready', id);
      _sendControl({'type': 'xbegin', 'id': id, 'bytes': bytes});
      final have = (await ready0)['have'] as int;
      final blocks = xBlockCount(bytes);
      final digests = List<String?>.filled(blocks, null);
      final rtts = <int>[];
      var rssPeak = ProcessInfo.currentRss;
      final rssStart = rssPeak;
      var highestBuffered = 0;
      var polls = 0;
      var sentThisAttempt = 0;
      final watch = Stopwatch()..start();
      final pinger = () async {
        var n = 0;
        while (pinging) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (!pinging) break;
          final pid = '$id-p${n++}';
          final ack = _waitAck('pong', pid);
          final sw = Stopwatch()..start();
          _sendControl({'type': 'ping', 'id': pid});
          try {
            await ack;
            rtts.add(sw.elapsedMicroseconds);
          } catch (_) {
            return;
          }
          rssPeak = max(rssPeak, ProcessInfo.currentRss);
        }
      }();
      var cancelled = false;
      var offset = have * xBlockBytes;
      while (offset < bytes) {
        final block = offset ~/ xBlockBytes;
        final blockEnd = min(bytes, offset + xBlockBytes);
        final digest = _DigestSink();
        final sink = sha256.startChunkedConversion(digest);
        for (var at = offset; at < blockEnd; at += xMessageBytes) {
          if (stopAfterBytes != null && sentThisAttempt >= stopAfterBytes) {
            cancelled = true;
            break;
          }
          final count = min(xMessageBytes, blockEnd - at);
          var buffered = await _bulk!.getBufferedAmount();
          polls++;
          while (buffered + count > 512 * 1024) {
            if (watch.elapsed > const Duration(minutes: 30)) {
              throw TimeoutException('Bulk stalled');
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
            buffered = await _bulk!.getBufferedAmount();
            polls++;
          }
          highestBuffered = max(highestBuffered, buffered);
          final message = xPatternMessage(at, count);
          sink.add(message);
          await _bulk!.send(RTCDataChannelMessage.fromBinary(message));
          sentThisAttempt += count;
        }
        if (cancelled) break;
        sink.close();
        digests[block] = digest.value.toString();
        _sendControl({
          'type': 'xblock',
          'id': id,
          'index': block,
          'sha256': digests[block],
        });
        offset = blockEnd;
      }
      if (cancelled) {
        final ack = _waitAck('xcancelled', id);
        _sendControl({'type': 'xcancel', 'id': id, 'sent': sentThisAttempt});
        final reply = await ack;
        pinging = false;
        await pinger;
        return {
          'cancelled': true,
          'bytes': bytes,
          'startedAtBlock': have,
          'sentBytesThisAttempt': sentThisAttempt,
          'receiverVerifiedBlocks': reply['have'],
          'milliseconds': watch.elapsedMilliseconds,
        };
      }
      for (var b = 0; b < have; b++) {
        digests[b] = _expectedBlockDigest(b, bytes);
      }
      final root = xRoot(digests.cast<String>());
      final done = _waitAck('xcomplete', id);
      _sendControl({'type': 'xend', 'id': id, 'root': root});
      final result = await done;
      pinging = false;
      await pinger;
      watch.stop();
      if (result['verified'] != true ||
          result['root'] != root ||
          result['bytes'] != bytes) {
        throw StateError('Integrity failed: $result');
      }
      rtts.sort();
      int pct(double p) => rtts.isEmpty
          ? 0
          : rtts[(rtts.length * p).floor().clamp(0, rtts.length - 1)];
      final sentMiB = sentThisAttempt / 1048576;
      return {
        'passed': true,
        'cancelled': false,
        'bytes': bytes,
        'root': root,
        'blocks': blocks,
        'resumedFromBlock': have,
        'sentBytesThisAttempt': sentThisAttempt,
        'milliseconds': watch.elapsedMilliseconds,
        'mibPerSecond': sentMiB / (watch.elapsedMicroseconds / 1000000),
        'highestNativeBufferedBytes': highestBuffered,
        'nativeBufferPolls': polls,
        'controlPingSamples': rtts.length,
        'controlRttMicrosP50': pct(0.5),
        'controlRttMicrosP95': pct(0.95),
        'controlRttMicrosMax': rtts.isEmpty ? 0 : rtts.last,
        'senderRssStartBytes': rssStart,
        'senderRssPeakBytes': rssPeak,
        'path': await selectedPair(),
      };
    } finally {
      pinging = false;
      _sending = false;
    }
  }

  String _expectedBlockDigest(int block, int total) {
    final digest = _DigestSink();
    final sink = sha256.startChunkedConversion(digest);
    final start = block * xBlockBytes;
    final end = min(total, start + xBlockBytes);
    for (var at = start; at < end; at += xMessageBytes) {
      sink.add(xPatternMessage(at, min(xMessageBytes, end - at)));
    }
    sink.close();
    return digest.value.toString();
  }

  Future<Map<String, Object?>> sendPattern(int bytes) async {
    if (_sending) throw StateError('One transfer at a time');
    if (bytes < 1 || bytes > 256 * 1024 * 1024) {
      throw ArgumentError('Test bound: 1..256MiB');
    }
    _sending = true;
    try {
      await ready();
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final readyAck = _waitAck('ready', id);
      _sendControl({'type': 'begin', 'id': id, 'bytes': bytes});
      await readyAck;
      final done = _waitAck('complete', id);
      final digest = _DigestSink();
      final incoming = sha256.startChunkedConversion(digest);
      final watch = Stopwatch()..start();
      const messageSize = 16 * 1024;
      final pattern = Uint8List.fromList(
        List<int>.generate(messageSize, (i) => i % 251),
      );
      var sent = 0;
      var highestNativeBuffer = 0;
      var nativePolls = 0;
      var lowCallbacks = 0;
      _bulk!.bufferedAmountLowThreshold = 256 * 1024;
      _bulk!.onBufferedAmountLow = (_) => lowCallbacks++;
      while (sent < bytes) {
        var buffered = await _bulk!.getBufferedAmount();
        nativePolls++;
        highestNativeBuffer = max(highestNativeBuffer, buffered);
        while (buffered + messageSize > 512 * 1024) {
          if (watch.elapsed > const Duration(seconds: 120)) {
            throw TimeoutException('Bulk stalled');
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
          buffered = await _bulk!.getBufferedAmount();
          nativePolls++;
          highestNativeBuffer = max(highestNativeBuffer, buffered);
        }
        final count = min(messageSize, bytes - sent);
        final chunk = Uint8List.sublistView(pattern, 0, count);
        incoming.add(chunk);
        await _bulk!.send(RTCDataChannelMessage.fromBinary(chunk));
        sent += count;
      }
      incoming.close();
      _sendControl({
        'type': 'end',
        'id': id,
        'sha256': digest.value.toString(),
      });
      final result = await done;
      watch.stop();
      if (result['verified'] != true || result['bytes'] != bytes) {
        throw StateError('Integrity failed: $result');
      }
      final stats = await selectedPair();
      return {
        'passed': true,
        'bytes': bytes,
        'sha256': result['sha256'],
        'milliseconds': watch.elapsedMilliseconds,
        'mibPerSecond': bytes / 1048576 / (watch.elapsedMicroseconds / 1000000),
        'highestNativeBufferedBytes': highestNativeBuffer,
        'nativeBufferPolls': nativePolls,
        'bufferLowCallbacks': lowCallbacks,
        'maxMessageBytes': messageSize,
        'path': stats,
      };
    } finally {
      _sending = false;
    }
  }

  Future<Map<String, Object?>> selectedPair() async {
    final reports = await _pc!.getStats();
    final byId = {for (final report in reports) report.id: report};
    final transport = reports.where((r) => r.type == 'transport').toList();
    final selectedId = transport.isEmpty
        ? null
        : transport.first.values['selectedCandidatePairId'];
    final pairs = reports
        .where(
          (r) =>
              r.type == 'candidate-pair' &&
              (r.id == selectedId ||
                  r.values['selected'] == true ||
                  r.values['nominated'] == true),
        )
        .toList();
    if (pairs.isEmpty) {
      return {'verified': false, 'reason': 'No selected pair reported'};
    }
    final pair = pairs.first;
    final local = byId[pair.values['localCandidateId']];
    final remote = byId[pair.values['remoteCandidateId']];
    final localType = local?.values['candidateType'];
    final remoteType = remote?.values['candidateType'];
    if (localType == 'relay' || remoteType == 'relay') {
      throw StateError('Relayed path rejected');
    }
    // Do not export candidate addresses or SDP in result files.
    return {
      'verified': localType != null && remoteType != null,
      'localType': localType,
      'remoteType': remoteType,
      'currentRoundTripTime': pair.values['currentRoundTripTime'],
    };
  }

  Future<void> close() async {
    _generation++;
    for (final pending in _rangePending.values) {
      if (!pending.done.isCompleted) {
        pending.done.completeError(StateError('Peer closed'));
      }
    }
    _rangePending.clear();
    await _rangeSendTail;
    _rangeOutstanding.clear();
    _rangeCancelled.clear();
    await _control?.close();
    await _bulk?.close();
    await _range?.close();
    await _pc?.close();
    await _pc?.dispose();
    _pc = null;
    _control = null;
    _bulk = null;
    _range = null;
    _incoming = null;
  }
}

class _RangeAssembly {
  final done = Completer<Uint8List>();
  Uint8List? bytes;
  int? total;
  int received = 0;
}

Future<Map<String, Object?>> runLoopback() async {
  final sender = ProbePeer();
  final receiver = ProbePeer();
  try {
    final offer = await sender.offer();
    final answer = await receiver.answer(offer);
    await sender.accept(answer);
    final forward = await sender.sendPattern(16 * 1024 * 1024);
    final reverse = await receiver.sendPattern(16 * 1024 * 1024);
    return {
      'passed': true,
      'scope': 'Same-device native WebRTC loopback, not LAN',
      'forward': forward,
      'reverse': reverse,
    };
  } finally {
    await sender.close();
    await receiver.close();
  }
}
