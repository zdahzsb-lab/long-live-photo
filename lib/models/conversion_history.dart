import 'conversion_options.dart';

/// Immutable record of a completed Live Photo synthesis for history reuse.
class ConversionHistoryEntry {
  const ConversionHistoryEntry({
    required this.id,
    required this.createdAtMs,
    required this.sourceVideoPath,
    required this.savedTarget,
    required this.platformFormat,
    required this.sourceDurationMs,
    required this.outputDurationMs,
    required this.outputSizeBytes,
    required this.elapsedMs,
    required this.qualityWireValue,
    required this.playbackSpeed,
    required this.keepAudio,
    required this.preserveMetadata,
    required this.wasTrimmed,
    required this.coverTimeMs,
    this.trimStartMs,
    this.trimEndMs,
    this.customCoverPath,
    this.thumbnailPath,
  });

  factory ConversionHistoryEntry.fromJson(Map<Object?, Object?> json) {
    return ConversionHistoryEntry(
      id: _asString(json['id']),
      createdAtMs: _asInt(json['createdAtMs']),
      sourceVideoPath: _asString(json['sourceVideoPath']),
      savedTarget: _asString(json['savedTarget']),
      platformFormat: _asString(json['platformFormat'], fallback: 'Live Photo'),
      sourceDurationMs: _asInt(json['sourceDurationMs']),
      outputDurationMs: _asInt(json['outputDurationMs']),
      outputSizeBytes: _asInt(json['outputSizeBytes']),
      elapsedMs: _asInt(json['elapsedMs']),
      qualityWireValue: _asString(json['qualityWireValue'], fallback: '1080p'),
      playbackSpeed: VideoSpeedMath.clampSpeed(
        _asDouble(json['playbackSpeed'], fallback: 1.0),
      ),
      keepAudio: _asBool(json['keepAudio'], fallback: true),
      preserveMetadata: _asBool(json['preserveMetadata'], fallback: true),
      wasTrimmed: _asBool(json['wasTrimmed'], fallback: false),
      trimStartMs: _asNullableInt(json['trimStartMs']),
      trimEndMs: _asNullableInt(json['trimEndMs']),
      coverTimeMs: _asInt(json['coverTimeMs']),
      customCoverPath: _asNullableString(json['customCoverPath']),
      thumbnailPath: _asNullableString(json['thumbnailPath']),
    );
  }

  final String id;
  final int createdAtMs;
  final String sourceVideoPath;
  final String savedTarget;
  final String platformFormat;
  final int sourceDurationMs;
  final int outputDurationMs;
  final int outputSizeBytes;
  final int elapsedMs;
  final String qualityWireValue;
  final double playbackSpeed;
  final bool keepAudio;
  final bool preserveMetadata;
  final bool wasTrimmed;
  final int? trimStartMs;
  final int? trimEndMs;
  final int coverTimeMs;
  final String? customCoverPath;
  final String? thumbnailPath;

  QualityPreset get quality => QualityPreset.fromWireValue(qualityWireValue);

  PlaybackSpeedPreset get speedPreset =>
      PlaybackSpeedPreset.fromRate(playbackSpeed);

  Duration get outputDuration => Duration(milliseconds: outputDurationMs);

  bool get usedCustomCover =>
      customCoverPath != null && customCoverPath!.isNotEmpty;

  ConversionHistoryEntry copyWith({String? thumbnailPath}) {
    return ConversionHistoryEntry(
      id: id,
      createdAtMs: createdAtMs,
      sourceVideoPath: sourceVideoPath,
      savedTarget: savedTarget,
      platformFormat: platformFormat,
      sourceDurationMs: sourceDurationMs,
      outputDurationMs: outputDurationMs,
      outputSizeBytes: outputSizeBytes,
      elapsedMs: elapsedMs,
      qualityWireValue: qualityWireValue,
      playbackSpeed: playbackSpeed,
      keepAudio: keepAudio,
      preserveMetadata: preserveMetadata,
      wasTrimmed: wasTrimmed,
      trimStartMs: trimStartMs,
      trimEndMs: trimEndMs,
      coverTimeMs: coverTimeMs,
      customCoverPath: customCoverPath,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'createdAtMs': createdAtMs,
      'sourceVideoPath': sourceVideoPath,
      'savedTarget': savedTarget,
      'platformFormat': platformFormat,
      'sourceDurationMs': sourceDurationMs,
      'outputDurationMs': outputDurationMs,
      'outputSizeBytes': outputSizeBytes,
      'elapsedMs': elapsedMs,
      'qualityWireValue': qualityWireValue,
      'playbackSpeed': playbackSpeed,
      'keepAudio': keepAudio,
      'preserveMetadata': preserveMetadata,
      'wasTrimmed': wasTrimmed,
      'trimStartMs': trimStartMs,
      'trimEndMs': trimEndMs,
      'coverTimeMs': coverTimeMs,
      'customCoverPath': customCoverPath,
      'thumbnailPath': thumbnailPath,
    };
  }

  static String _asString(Object? v, {String fallback = ''}) =>
      v is String ? v : fallback;

  static String? _asNullableString(Object? v) =>
      v is String && v.isNotEmpty ? v : null;

  static int _asInt(Object? v) => v is num ? v.toInt() : 0;

  static int? _asNullableInt(Object? v) => v is num ? v.toInt() : null;

  static double _asDouble(Object? v, {double fallback = 0.0}) =>
      v is num ? v.toDouble() : fallback;

  static bool _asBool(Object? v, {bool fallback = false}) =>
      v is bool ? v : fallback;
}

String formatHistoryTimestamp(int createdAtMs, {DateTime? now}) {
  final dt = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
  final ref = now ?? DateTime.now();
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');

  final today = DateTime(ref.year, ref.month, ref.day);
  final targetDay = DateTime(dt.year, dt.month, dt.day);
  final dayDiff = today.difference(targetDay).inDays;

  if (dayDiff == 0) {
    return '今天 $hh:$mm';
  }
  if (dayDiff == 1) {
    return '昨天 $hh:$mm';
  }
  if (dt.year == ref.year) {
    final mon = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '$mon-$day $hh:$mm';
  }
  final yyyy = dt.year.toString().padLeft(4, '0');
  final mon = dt.month.toString().padLeft(2, '0');
  final day = dt.day.toString().padLeft(2, '0');
  return '$yyyy-$mon-$day';
}
