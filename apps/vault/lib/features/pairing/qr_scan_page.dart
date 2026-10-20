import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vault/production/pairing_code.dart';
import 'package:vault_protocol/vault_protocol.dart' show pairingInvitePrefix;

/// Full-screen camera scanner that pops with the first pairing-code text.
///
/// The camera starts only on this page, which is when Android asks for the
/// camera permission. Frames are decoded on-device by a pure-Dart reader;
/// no Google Play services or ML Kit component is involved.
class QrScanPage extends StatefulWidget {
  const new({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

typedef _Frame = (Uint8List luminance, int width, int height, int stride);

String? _decode(_Frame frame) =>
    decodeQrLuminance(frame.$1, frame.$2, frame.$3, frame.$4);

class _QrScanPageState extends State<QrScanPage> with WidgetsBindingObserver {
  CameraController? _camera;
  String? _problem;
  bool _decoding = false;
  bool _finished = false;
  Future<void> _opening = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _opening = _open();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      unawaited(_close());
    } else if (state == AppLifecycleState.resumed && _camera == null) {
      _opening = _opening.then((_) => _open());
    }
  }

  Future<void> _open() async {
    if (_finished || !mounted) return;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _show('This device has no camera. Paste the pairing code instead.');
        return;
      }
      final camera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted || _finished) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _problem = null;
      });
      await controller.startImageStream(_frame);
    } on CameraException catch (error) {
      _show(
        error.code.contains('Access')
            ? 'Midnight needs camera access to scan the code. Allow it in '
                  'Android settings, or paste the pairing code instead.'
            : 'The camera could not start. Paste the pairing code instead.',
      );
    }
  }

  void _show(String problem) {
    if (mounted) setState(() => _problem = problem);
  }

  void _frame(CameraImage image) {
    if (_decoding || _finished || image.planes.isEmpty) return;
    _decoding = true;
    final luma = image.planes.first;
    // The plugin reuses its buffer, so copy before leaving this callback.
    final frame = (
      Uint8List.fromList(luma.bytes),
      image.width,
      image.height,
      luma.bytesPerRow,
    );
    unawaited(
      compute(_decode, frame)
          .then((text) {
            if (text != null && text.startsWith(pairingInvitePrefix)) {
              _finish(text);
            }
          })
          .whenComplete(() => _decoding = false),
    );
  }

  void _finish(String text) {
    if (_finished || !mounted) return;
    _finished = true;
    unawaited(_close());
    Navigator.pop(context, text);
  }

  Future<void> _close() async {
    final camera = _camera;
    _camera = null;
    if (camera == null) return;
    if (mounted) setState(() {});
    try {
      if (camera.value.isStreamingImages) await camera.stopImageStream();
    } finally {
      await camera.dispose();
    }
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (text != null && text.startsWith(pairingInvitePrefix)) {
      _finish(text);
    } else {
      _show('The clipboard does not hold a Midnight pairing code.');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _finished = true;
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing code')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: _problem != null
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _problem!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white),
                          ),
                        )
                      : camera != null && camera.value.isInitialized
                      ? CameraPreview(camera)
                      : const CircularProgressIndicator(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'On the other device, choose Pair a phone, then point '
                    'this camera at the code it shows.',
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _paste,
                    icon: const Icon(Icons.content_paste),
                    label: const Text('Paste code instead'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
