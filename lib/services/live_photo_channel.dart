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
  }) async {
    final response = await _methodChannel.invokeMapMethod<Object?, Object?>(
      'convertAndSave',
      <String, Object?>{
        'videoPath': videoPath,
        'coverTimeMs': coverTimeMs,
        'quality': quality.wireValue,
        'keepAudio': keepAudio,
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
}
