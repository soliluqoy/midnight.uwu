import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:zxing2/qrcode.dart';

/// Square QR module grid; `dark[row * size + column]` is 1 for a dark module.
typedef QrModules = ({int size, Uint8List dark});

/// Encodes [text] as a QR code. Low error correction keeps the code small
/// enough for a phone camera to read from a laptop screen.
QrModules encodeQr(String text) {
  final matrix = Encoder.encode(text, ErrorCorrectionLevel.l).matrix!;
  final size = matrix.width;
  final dark = Uint8List(size * size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      dark[y * size + x] = matrix.get(x, y) == 1 ? 1 : 0;
    }
  }
  return (size: size, dark: dark);
}

/// Decodes a QR code from an 8-bit luminance frame (a camera Y plane), or
/// returns null when none is readable. Pure, so it can run in an isolate.
String? decodeQrLuminance(
  Uint8List luminance,
  int width,
  int height,
  int rowStride,
) {
  if (width <= 0 ||
      height <= 0 ||
      rowStride < width ||
      luminance.length < rowStride * (height - 1) + width) {
    return null;
  }
  try {
    return QRCodeReader()
        .decode(
          BinaryBitmap(
            HybridBinarizer(_Luminance(luminance, width, height, rowStride)),
          ),
          hints: DecodeHints()..put(DecodeHintType.tryHarder),
        )
        .text;
  } on ReaderException {
    return null;
  }
}

class _Luminance extends LuminanceSource {
  new(this._bytes, int width, int height, this._stride) : super(width, height);

  final Uint8List _bytes;
  final int _stride;

  @override
  Int8List getRow(int y, Int8List? row) =>
      Int8List.sublistView(_bytes, y * _stride, y * _stride + width);

  @override
  Int8List getMatrix() {
    if (_stride == width) {
      return Int8List.sublistView(_bytes, 0, width * height);
    }
    final matrix = Int8List(width * height);
    for (var y = 0; y < height; y++) {
      matrix.setRange(y * width, (y + 1) * width, getRow(y, null));
    }
    return matrix;
  }
}

/// A black-on-white QR code with its quiet zone, in every theme.
class PairingCode extends StatefulWidget {
  const new(this.text, {this.size = 300, super.key});

  final String text;
  final double size;

  @override
  State<PairingCode> createState() => _PairingCodeState();
}

class _PairingCodeState extends State<PairingCode> {
  late QrModules _modules = encodeQr(widget.text);

  @override
  void didUpdateWidget(PairingCode old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _modules = encodeQr(widget.text);
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Pairing QR code',
    image: true,
    child: CustomPaint(
      size: Size.square(widget.size),
      painter: _QrPainter(_modules),
    ),
  );
}

class _QrPainter extends CustomPainter {
  new(this.modules);

  final QrModules modules;
  static const _quietZone = 4;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final cell = size.shortestSide / (modules.size + 2 * _quietZone);
    final dark = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var y = 0; y < modules.size; y++) {
      for (var x = 0; x < modules.size; x++) {
        if (modules.dark[y * modules.size + x] == 1) {
          canvas.drawRect(
            Rect.fromLTWH(
              (x + _quietZone) * cell,
              (y + _quietZone) * cell,
              cell,
              cell,
            ),
            dark,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => !identical(old.modules, modules);
}
