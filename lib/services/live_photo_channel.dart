import 'dart:async';

import 'package:flutter/services.dart';

import '../models/conversion_options.dart';

abstract class LivePhotoConverterGateway {
  Stream<ConversionProgress> get progressStream;

  Future<ConversionResult> convertAndSave({
    required String videoPath,
    required int coverTimeMs,
    required QualityPreset quality,
    required bool keepAudio,
    String? customCoverPath,
    int? trimStartMs,
    int? trimEndMs,
    bool preserveMetadata = true,
    double playbackSpeed = 1.0,
  });

  Future<void> cancelConversion();

  Future<List<Uint8List>> extractThumbnails({
    required String videoPath,
    int count = 8,
  });
}

class NativeLivePhotoChannel implements LivePhotoConverterGateway {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.longlive.long_live_photo/converter',
  );

  static const EventChannel _progressChannel = EventChannel(
    'com.longlive.long_live_photo/progress',
  );

  Stream<ConversionProgress>? _cachedStream;

  @override
  Stream<ConversionProgress> get progressStream {
    return _cachedStream ??= _progressChannel
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map(
          (event) => ConversionProgress.fromMap(
            Map<Object?, Object?>.from(event as Map),
          ),
        );
  }

  @override
  Future<ConversionResult> convertAndSave({
    required String videoPath,
    required int coverTimeMs,
    required QualityPreset quality,
    required bool keepAudio,
    String? customCoverPath,
    int? trimStartMs,
    int? trimEndMs,
    bool preserveMetadata = true,
    double playbackSpeed = 1.0,
  }) async {
    final response = await _methodChannel.invokeMapMethod<Object?, Object?>(
      'convertAndSave',
      <String, Object?>{
        'videoPath': videoPath,
        'coverTimeMs': coverTimeMs,
        'quality': quality.wireValue,
        'keepAudio': keepAudio,
        'customCoverPath': customCoverPath,
        'trimStartMs': trimStartMs,
        'trimEndMs': trimEndMs,
        'preserveMetadata': preserveMetadata,
        'playbackSpeed': playbackSpeed,
      },
    );

    if (response == null) {
      throw PlatformException(
        code: 'EMPTY_RESPONSE',
        message: '原生转换模块未返回结果',
      );
    }

    return ConversionResult.fromMap(response);
  }

  @override
  Future<void> cancelConversion() async {
    try {
      await _methodChannel.invokeMethod<void>('cancelConversion');
    } catch (_) {
      // Ignore if no active conversion is running on native side.
    }
  }

  @override
  Future<List<Uint8List>> extractThumbnails({
    required String videoPath,
    int count = 8,
  }) async {
    try {
      final rawList = await _methodChannel.invokeListMethod<Object?>(
        'extractThumbnails',
        <String, Object?>{
          'videoPath': videoPath,
          'count': count,
        },
      );
      if (rawList == null) return const <Uint8List>[];
      return rawList.whereType<Uint8List>().toList(growable: false);
    } catch (_) {
      return const <Uint8List>[];
    }
  }
}
