import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'range_fixture.dart';
import 'remote_range.dart';
import 'webrtc_adapter.dart';

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  static const native = MethodChannel('vault.phase0/native');
  final peer = ProbePeer();
  final results = <String, Object?>{};
  Player? _player;
  VideoController? _video;
  HttpServer? _api;
  String _status = 'Starting local test control…';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_startApi());
  }

  Future<void> _startApi() async {
    try {
      _api = await HttpServer.bind(InternetAddress.loopbackIPv4, 48931);
      _api!.listen((request) async {
        try {
          if (request.headers.value('x-vault-probe') != 'phase0-local') {
            request.response.statusCode = HttpStatus.forbidden;
            await request.response.close();
            return;
          }
          final body = request.method == 'POST'
              ? jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, dynamic>
              : <String, dynamic>{};
          final Object? response;
          switch (request.uri.path) {
            case '/status':
              response = {
                'platform': Platform.operatingSystem,
                'androidNetworkMonitorDisabled':
                    Platform.isAndroid && hotspotProbe,
                'busy': _busy,
                'status': _status,
                'results': results,
                'rtc': peer.status,
              };
            case '/suite':
              response = await _suite();
            case '/encode':
              response = await native.invokeMethod<Object?>('encode720p');
            case '/lifecycle':
              response = await native.invokeMethod<Object?>('lifecycle');
            case '/lifecycle/start':
              response = await native.invokeMethod<Object?>(
                'startTransferService',
              );
            case '/lifecycle/stop':
              response = await native.invokeMethod<Object?>(
                'stopTransferService',
              );
            case '/rtc/offer':
              response = await peer.offer();
            case '/rtc/answer':
              response = await peer.answer(body);
            case '/rtc/accept':
              await peer.accept(body);
              response = {'accepted': true};
            case '/rtc/transfer':
              response = await peer.sendPattern(
                (body['bytes'] as int?) ?? 32 * 1024 * 1024,
              );
            case '/rtc/xtransfer':
              response = await peer.sendBlocks(
                body['id'] as String,
                body['bytes'] as int,
                stopAfterBytes: body['stopAfterBytes'] as int?,
              );
            case '/vod/host':
              peer.hostRangeFixtures(await _fixtures());
              response = {'hosting': true};
            case '/vod/remote':
              response = await _remoteVod(peer);
            case '/vod/loopback':
              response = await _loopbackVod();
            case '/rtc/reset':
              await peer.close();
              response = {'closed': true};
            default:
              request.response.statusCode = HttpStatus.notFound;
              response = {'error': 'Unknown test endpoint'};
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(response));
        } catch (error, stack) {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'error': error.toString(), 'stack': stack.toString()}),
          );
        } finally {
          await request.response.close();
        }
      });
      _setStatus(
        'Ready. Synthetic fixtures only; loopback test API on port 48931.',
      );
    } catch (error) {
      _setStatus('Control startup failed: $error');
    }
  }

  void _setStatus(String message) {
    if (mounted) setState(() => _status = message);
    debugPrint('VAULT_PROBE ${jsonEncode({'status': message})}');
  }

  Future<Map<String, Object?>> _suite() async {
    if (_busy) throw StateError('A suite is already running');
    _busy = true;
    results.clear();
    try {
      if (Platform.isAndroid) {
        _setStatus('Reading Android codec capabilities…');
        final android = await native.invokeMapMethod<String, dynamic>(
          'capabilities',
        );
        results['android'] = android;
        if (android?['networkStatePermissionGranted'] != true) {
          throw StateError(
            'ACCESS_NETWORK_STATE must be granted before native WebRTC initialization',
          );
        }
      }
      _setStatus('Testing native WebRTC data channels…');
      try {
        results['loopback'] = await runLoopback();
      } catch (error) {
        results['loopback'] = {'passed': false, 'error': error.toString()};
      }
      _setStatus('Testing front/tail MP4 playback and seeks…');
      try {
        results['vod'] = await _vod();
      } catch (error) {
        results['vod'] = {'passed': false, 'error': error.toString()};
      }
      _setStatus('Suite finished. See measured results below.');
      final snapshot = <String, Object?>{
        'checkedAt': DateTime.now().toUtc().toIso8601String(),
        'platform': Platform.operatingSystem,
        'scope': 'Native same-device transport and in-memory loopback range playback only',
        'results': Map<String, Object?>.from(results),
      };
      debugPrint('VAULT_PROBE_RESULT ${jsonEncode(snapshot)}');
      return snapshot;
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<VideoController> _attach(Player player) async {
    final previous = _player;
    final controller = VideoController(player);
    setState(() {
      _player = player;
      _video = controller;
    });
    await previous?.dispose();
    await WidgetsBinding.instance.endOfFrame;
    return controller;
  }

  Future<void> _until(bool Function() condition, Duration timeout) async {
    final watch = Stopwatch()..start();
    while (!condition()) {
      if (watch.elapsed > timeout) {
        throw TimeoutException('Playback state did not progress');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<Map<String, Uint8List>> _fixtures() async => {
    for (final name in ['front.mp4', 'tail.mp4'])
      name: (await rootBundle.load('assets/$name')).buffer.asUint8List(),
  };

  Future<Map<String, Object?>> _loopbackVod() async {
    final host = ProbePeer();
    final client = ProbePeer();
    try {
      host.hostRangeFixtures(await _fixtures());
      final offer = await client.offer();
      await client.accept(await host.answer(offer));
      return await _remoteVod(client);
    } finally {
      await client.close();
      await host.close();
    }
  }

  Future<Map<String, Object?>> _remoteVod(ProbePeer remote) async {
    if (_busy) throw StateError('A suite is already running');
    _busy = true;
    try {
      final lengths = await remote.remoteRangeManifest();
      final cache = RemoteRangeCache(lengths, remote.fetchRangeChunk);
      final server = RemoteRangeServer(cache, _session());
      await server.start();
      return await _playRanges(
        lengths.keys,
        server.url,
        () => server.requests,
        cache.clear,
        server.close,
        () => {
          'cacheChunks': cache.maxChunks,
          'chunkBytes': rangeChunkBytes,
          'maxResponseBytes': maxRangeResponseBytes,
          'hits': cache.hits,
          'misses': cache.misses,
          'evictions': cache.evictions,
          'peakResidentBytes': cache.peakBytes,
          'cancelledReads': server.cancelledReads,
          'peerRangeStatus': remote.status,
        },
        'Bounded sparse P2P chunk cache over WebRTC DataChannel; cache cleared before each seek',
      );
    } finally {
      _busy = false;
    }
  }

  String _session() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<Map<String, Object?>> _vod() async {
    final fixtureBytes = await _fixtures();
    final server = RangeFixtureServer(fixtureBytes, _session());
    await server.start();
    return _playRanges(
      fixtureBytes.keys,
      server.url,
      () => server.requests,
      () {},
      server.close,
      () => {},
      'Resident synthetic bytes via loopback HTTP; no P2P cache/seek latency claim',
    );
  }

  Future<Map<String, Object?>> _playRanges(
    Iterable<String> names,
    String Function(String) url,
    List<Map<String, Object?>> Function() requestLog,
    void Function() goCold,
    Future<void> Function() closeServer,
    Map<String, Object?> Function() stats,
    String scope,
  ) async {
    final samples = <Map<String, Object?>>[];
    try {
      for (final name in names) {
        final player = Player();
        final errors = <String>[];
        final subscription = player.stream.error.listen(errors.add);
        try {
          final video = await _attach(player);
          // Decode audio but mute output to avoid surprise test tones.
          await player.setVolume(0);
          final start = Stopwatch()..start();
          final requestStart = requestLog().length;
          await player.open(Media(url(name)));
          await video.waitUntilFirstFrameRendered.timeout(
            const Duration(seconds: 25),
          );
          await _until(
            () => player.state.position.inMilliseconds >= 200,
            const Duration(seconds: 10),
          );
          start.stop();
          final startupMs = start.elapsedMilliseconds;
          final seeks = <Map<String, Object?>>[];
          for (final target in [8, 2, 10]) {
            goCold();
            final watch = Stopwatch()..start();
            await player.seek(Duration(seconds: target));
            await _until(
              () =>
                  (player.state.position.inMilliseconds - target * 1000).abs() <
                      750 &&
                  !player.state.buffering,
              const Duration(seconds: 10),
            );
            final reached = player.state.position;
            await _until(
              () =>
                  player.state.position >
                  reached + const Duration(milliseconds: 120),
              const Duration(seconds: 5),
            );
            watch.stop();
            seeks.add({
              'targetSeconds': target,
              'resumeMilliseconds': watch.elapsedMilliseconds,
            });
          }
          final audio = player.state.audioParams;
          final passed =
              errors.isEmpty &&
              (player.state.width ?? 0) > 0 &&
              audio.sampleRate == 48000 &&
              audio.channelCount == 2;
          samples.add({
            'fixture': name,
            'passed': passed,
            'startupMilliseconds': startupMs,
            'seeks': seeks,
            'width': player.state.width,
            'height': player.state.height,
            'durationMilliseconds': player.state.duration.inMilliseconds,
            'audioSampleRate': audio.sampleRate,
            'audioChannelCount': audio.channelCount,
            'audibilityVerified': false,
            'muted': true,
            'errors': errors,
            'rangeRequests': requestLog().skip(requestStart).toList(),
          });
        } finally {
          await subscription.cancel();
          await player.stop();
        }
      }
      return {
        'passed': samples.every((s) => s['passed'] == true),
        'scope': scope,
        'samples': samples,
        'stats': stats(),
      };
    } finally {
      await _player?.dispose();
      if (mounted) {
        setState(() {
          _player = null;
          _video = null;
        });
      }
      await closeServer();
    }
  }

  @override
  void dispose() {
    unawaited(_api?.close(force: true));
    unawaited(peer.close());
    unawaited(_player?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Vault Phase 0 Probe',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(title: const Text('Vault · Phase 0 feasibility')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Synthetic test media only. No camera, microphone or library access.',
          ),
          const SizedBox(height: 12),
          Text(_status),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : () => unawaited(_suite()),
            child: const Text('Run native transport and playback probes'),
          ),
          if (_video != null)
            SizedBox(
              height: 220,
              child: Video(controller: _video!, controls: NoVideoControls),
            ),
          const SizedBox(height: 12),
          SelectableText(const JsonEncoder.withIndent('  ').convert(results)),
        ],
      ),
    ),
  );
}
