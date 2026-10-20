import 'dart:typed_data';

/// Actual decoder results. Unsupported formats/providers return an explicit
/// unavailableReason; no dimensions, duration or poster are synthesized.
class MediaMetadata {
  /// Creates actual decoder output or an explicit unsupported result.
  const new({
    this.width,
    this.height,
    this.durationMillis,
    this.poster,
    this.unavailableReason,
  });

  /// Restores extracted scalar metadata without resident poster bytes.
  factory fromJson(Map<String, Object?> value) => MediaMetadata(
    width: value['width'] as int?,
    height: value['height'] as int?,
    durationMillis: value['duration'] as int?,
    unavailableReason: value['unavailable'] as String?,
  );

  /// Actual media width in pixels, when available.
  final int? width;

  /// Actual media height in pixels, when available.
  final int? height;

  /// Actual media duration in milliseconds, when available.
  final int? durationMillis;

  /// Encoded JPEG/PNG at most 256 KiB and 512 pixels on either axis.
  ///
  /// Persisted metadata omits bytes; use the library item's poster path.
  final Uint8List? poster;

  /// Explicit codec/provider absence rather than invented metadata.
  final String? unavailableReason;

  /// Serializes extracted scalars without encoded poster bytes.
  Map<String, Object?> toJson() => {
    'width': width,
    'height': height,
    'duration': durationMillis,
    'unavailable': unavailableReason,
  };
}

/// Bounds decoded poster surfaces as well as compressed bytes before either
/// extraction or authenticated peer bytes reach the UI decoder.
void validateMediaPoster(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 256 * 1024) {
    throw const FormatException('Poster byte budget exceeded');
  }
  final data = ByteData.sublistView(bytes);
  if (bytes.length >= 24 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71 &&
      bytes[4] == 13 &&
      bytes[5] == 10 &&
      bytes[6] == 26 &&
      bytes[7] == 10 &&
      bytes[12] == 73 &&
      bytes[13] == 72 &&
      bytes[14] == 68 &&
      bytes[15] == 82) {
    final width = data.getUint32(16);
    final height = data.getUint32(20);
    if (width > 0 && height > 0 && width <= 512 && height <= 512) return;
    throw const FormatException('Poster decoded surface exceeds 512px');
  }
  if (bytes.length >= 4 && bytes[0] == 255 && bytes[1] == 216) {
    var offset = 2;
    while (offset + 3 < bytes.length) {
      if (bytes[offset++] != 255) break;
      while (offset < bytes.length && bytes[offset] == 255) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      if (marker == 217 || marker == 218) break;
      if (marker == 1 || (marker >= 208 && marker <= 215)) continue;
      if (offset + 2 > bytes.length) break;
      final length = data.getUint16(offset);
      if (length < 2 || offset + length > bytes.length) break;
      if ((const <int>{
        192,
        193,
        194,
        195,
        197,
        198,
        199,
        201,
        202,
        203,
        205,
        206,
        207,
      }).contains(marker)) {
        if (length < 8) break;
        final height = data.getUint16(offset + 3);
        final width = data.getUint16(offset + 5);
        if (width > 0 && height > 0 && width <= 512 && height <= 512) return;
        throw const FormatException('Poster decoded surface exceeds 512px');
      }
      offset += length;
    }
  }
  throw const FormatException('Malformed or unsupported bounded poster');
}
