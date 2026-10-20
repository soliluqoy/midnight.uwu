import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:vault/platform/library_sources.dart';
import 'package:vault_media_index/vault_media_index.dart';

/// Real per-source probing; unsupported codecs are explicitly unavailable.
abstract final class NativeMediaMetadata {
  static final _image = RegExp(
    r'\.(jpe?g|png|webp|gif|heic|heif|bmp)$',
    caseSensitive: false,
  );
  static final _video = RegExp(
    r'\.(mp4|mov|mkv|webm|m4v|avi)$',
    caseSensitive: false,
  );

  static Future<MediaMetadata> extract(SourceEntry source) async {
    final image = _image.hasMatch(source.name);
    final video = _video.hasMatch(source.name);
    if (!image && !video) {
      return const MediaMetadata(unavailableReason: 'Unsupported media type.');
    }
    try {
      if (Platform.isAndroid) {
        final row = await AndroidSourceAccess.channel
            .invokeMapMethod<String, Object?>('inspectMedia', {
              'uri': source.uri,
              'mimeType': image ? 'image/*' : 'video/*',
            });
        if (row == null) throw StateError('No native media metadata returned.');
        return MediaMetadata(
          width: row['width'] as int?,
          height: row['height'] as int?,
          durationMillis: row['durationMillis'] as int?,
          poster: row['poster'] as Uint8List?,
          unavailableReason: row['unavailable'] as String?,
        );
      }
      if (Uri.parse(source.uri).scheme != 'file') {
        return const MediaMetadata(
          unavailableReason:
              'Native metadata requires a local file source on this OS.',
        );
      }
      if (image) return await _imageFile(File.fromUri(Uri.parse(source.uri)));
      if (Platform.isWindows) return await _videoFile(source.uri);
      return const MediaMetadata(
        unavailableReason:
            'Video metadata extraction is supported on Android and Windows.',
      );
    } on Object {
      return const MediaMetadata(
        unavailableReason:
            'Source unavailable or this codec could not be inspected.',
      );
    }
  }

  static Future<MediaMetadata> _imageFile(File file) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width < 1 || height < 1 || width > 32768 || height > 32768) {
        return const MediaMetadata(
          unavailableReason:
              'Image dimensions exceed supported preview limits.',
        );
      }
      var bound = 256;
      while (true) {
        final largest = width > height ? width : height;
        final scale = largest > bound ? bound / largest : 1.0;
        final targetWidth = (width * scale).round();
        final targetHeight = (height * scale).round();
        final codec = await descriptor.instantiateCodec(
          targetWidth: targetWidth < 1 ? 1 : targetWidth,
          targetHeight: targetHeight < 1 ? 1 : targetHeight,
        );
        try {
          final frame = await codec.getNextFrame();
          try {
            final data = await frame.image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (data == null) {
              return MediaMetadata(
                width: width,
                height: height,
                unavailableReason: 'Image preview encoding unavailable.',
              );
            }
            if (data.lengthInBytes <= 256 * 1024) {
              return MediaMetadata(
                width: width,
                height: height,
                poster: data.buffer.asUint8List(
                  data.offsetInBytes,
                  data.lengthInBytes,
                ),
              );
            }
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
        if (bound <= 32) {
          return MediaMetadata(
            width: width,
            height: height,
            unavailableReason: 'Image preview exceeds bounded encoded size.',
          );
        }
        bound ~/= 2;
      }
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  static Future<MediaMetadata> _videoFile(String uri) async {
    final player = Player(
      configuration: const PlayerConfiguration(
        muted: true,
        bufferSize: 2 * 1024 * 1024,
        protocolWhitelist: ['file'],
      ),
    );
    try {
      final native = player.platform;
      if (native is! NativePlayer) {
        return const MediaMetadata(
          unavailableReason: 'Native video probing unavailable.',
        );
      }
      // Scale the decoded screenshot before it crosses into Dart memory.
      await native.setProperty(
        'vf',
        'scale=320:320:force_original_aspect_ratio=decrease',
      );
      final controller = VideoController(
        player,
        configuration: const VideoControllerConfiguration(
          width: 320,
          height: 320,
        ),
      );
      WidgetsBinding.instance.scheduleFrame();
      await controller.platform.future.timeout(const Duration(seconds: 10));
      await player.open(Media(uri)).timeout(const Duration(seconds: 10));
      Uint8List? poster;
      String? unavailable;
      try {
        await controller.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 10),
        );
        await player.pause();
        poster = await player.screenshot().timeout(const Duration(seconds: 10));
      } on Object {
        unavailable =
            'Video metadata loaded but no bounded frame could be decoded.';
      }
      final params = player.state.videoParams;
      final duration = player.state.duration;
      return MediaMetadata(
        width: params.w,
        height: params.h,
        durationMillis: duration > Duration.zero
            ? duration.inMilliseconds
            : null,
        poster: poster != null && poster.length <= 256 * 1024 ? poster : null,
        unavailableReason:
            unavailable ??
            (poster == null || poster.length > 256 * 1024
                ? 'Video decoded but a bounded screenshot was unavailable.'
                : null),
      );
    } finally {
      await player.dispose();
    }
  }
}
