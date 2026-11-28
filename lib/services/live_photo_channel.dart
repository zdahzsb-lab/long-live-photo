import 'dart:async';

import 'package:flutter/services.dart';

import '../models/conversion_options.dart';

abstract class LivePhotoConverterGateway {
  Stream<ConversionProgress> get progressStream;

  Stream<List<SharedMediaItem>> get sharedMediaStream;

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

  Future<List<SharedMediaItem>> consumeInitialSharedMedia();

  Future<bool> openSystemGallery({String? savedTarget});

  Future<UnpackedLivePhoto?> pickAndUnpackLivePhoto();

  Future<UnpackedLivePhoto> unpackLivePhotoFile({required String filePath});

  Future<ConversionResult> exportStandaloneMedia({
    required StandaloneExportMode mode,
    required String videoPath,
    required int coverTimeMs,
    QualityPreset quality = QualityPreset.passthrough,
    bool keepAudio = true,
    String? customCoverPath,
    int? trimStartMs,
    int? trimEndMs,
    bool preserveMetadata = true,
    double playbackSpeed = 1.0,
  });
}

class NativeLivePhotoChannel implements LivePhotoConverterGateway {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.longlive.long_live_photo/converter',
  );

  static const EventChannel _progressChannel = EventChannel(
    'com.longlive.long_live_photo/progress',
  );

  static const EventChannel _sharedMediaChannel = EventChannel(
    'com.longlive.long_live_photo/shared_media',
  );

  Stream<ConversionProgress>? _cachedStream;
  Stream<List<SharedMediaItem>>? _cachedSharedMediaStream;

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
  Stream<List<SharedMediaItem>> get sharedMediaStream {
    return _cachedSharedMediaStream ??= _sharedMediaChannel
        .receiveBroadcastStream()
        .where((event) => event is List)
        .map((event) => _parseSharedMediaList(event as List<Object?>))
        .where((List<SharedMediaItem> items) => items.isNotEmpty);
  }

  static List<SharedMediaItem> _parseSharedMediaList(List<Object?> raw) {
    final items = <SharedMediaItem>[];
    for (final item in raw) {
      if (item is Map) {
        final parsed = SharedMediaItem.fromMap(
          Map<Object?, Object?>.from(item),
        );
        if (parsed.path.isNotEmpty) {
          items.add(parsed);
        }
      }
    }
    return items;
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

  @override
  Future<List<SharedMediaItem>> consumeInitialSharedMedia() async {
    try {
      final rawList = await _methodChannel.invokeListMethod<Object?>(
        'consumeInitialSharedMedia',
      );
      if (rawList == null) return const <SharedMediaItem>[];
      return _parseSharedMediaList(rawList);
    } catch (_) {
      return const <SharedMediaItem>[];
    }
  }

  @override
  Future<bool> openSystemGallery({String? savedTarget}) async {
    try {
      final opened = await _methodChannel.invokeMethod<bool>(
        'openSystemGallery',
        <String, Object?>{
          'savedTarget': savedTarget,
        },
      );
      return opened ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<UnpackedLivePhoto?> pickAndUnpackLivePhoto() async {
    final response = await _methodChannel.invokeMapMethod<Object?, Object?>(
      'pickAndUnpackLivePhoto',
    );
    if (response == null) return null;
    final unpacked = UnpackedLivePhoto.fromMap(response);
    if (unpacked.videoPath.isEmpty) {
      throw PlatformException(
        code: 'EMPTY_RESPONSE',
        message: '未获取到实况内嵌视频轨',
      );
    }
    return unpacked;
  }

  @override
  Future<UnpackedLivePhoto> unpackLivePhotoFile({
    required String filePath,
  }) async {
    final response = await _methodChannel.invokeMapMethod<Object?, Object?>(
      'unpackLivePhotoFile',
      <String, Object?>{'filePath': filePath},
    );
    if (response == null) {
      throw PlatformException(
        code: 'NOT_LIVE_PHOTO',
        message: '所选文件不包含可拆解的实况视频轨道',
      );
    }
    final unpacked = UnpackedLivePhoto.fromMap(response);
    if (unpacked.videoPath.isEmpty) {
      throw PlatformException(
        code: 'NOT_LIVE_PHOTO',
        message: '所选文件不包含可拆解的实况视频轨道',
      );
    }
    return unpacked;
  }

  @override
  Future<ConversionResult> exportStandaloneMedia({
    required StandaloneExportMode mode,
    required String videoPath,
    required int coverTimeMs,
    QualityPreset quality = QualityPreset.passthrough,
    bool keepAudio = true,
    String? customCoverPath,
    int? trimStartMs,
    int? trimEndMs,
    bool preserveMetadata = true,
    double playbackSpeed = 1.0,
  }) async {
    final response = await _methodChannel.invokeMapMethod<Object?, Object?>(
      'exportStandaloneMedia',
      <String, Object?>{
        'mode': mode.wireValue,
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
        message: '原生导出模块未返回结果',
      );
    }
    return ConversionResult.fromMap(response);
  }
}
