enum QualityPreset {
  passthrough(
    wireValue: 'passthrough',
    segmentLabel: '原画秒转',
    title: '原画直通 · 零重压',
    subtitle: '保留原片码率直接封装，1～3 秒出图',
    shortSideLimit: null,
    videoBitrate: null,
  ),
  p1080(
    wireValue: '1080p',
    segmentLabel: '1080p 均衡',
    title: '1080p 高清均衡',
    subtitle: '硬件编码约 6 Mbps，高清且滑动流畅',
    shortSideLimit: 1080,
    videoBitrate: 6000000,
  ),
  p720(
    wireValue: '720p',
    segmentLabel: '720p 省流',
    title: '720p 轻量省空间',
    subtitle: '硬件编码约 2.8 Mbps，适合超长视频',
    shortSideLimit: 720,
    videoBitrate: 2800000,
  );

  const QualityPreset({
    required this.wireValue,
    required this.segmentLabel,
    required this.title,
    required this.subtitle,
    required this.shortSideLimit,
    required this.videoBitrate,
  });

  final String wireValue;
  final String segmentLabel;
  final String title;
  final String subtitle;
  final int? shortSideLimit;
  final int? videoBitrate;

  /// Estimates output Live Photo size based on source bytes, duration, and audio toggle.
  int estimateOutputBytes({
    required int sourceSizeBytes,
    required Duration duration,
    required bool keepAudio,
    Duration? totalDuration,
  }) {
    const int coverJpegOverhead = 650 * 1024;
    if (videoBitrate == null) {
      if (sourceSizeBytes <= 0) return 0;
      final audioFactor = keepAudio ? 1.0 : 0.94;
      final double trimFactor;
      if (totalDuration != null && totalDuration.inMilliseconds > 0) {
        trimFactor = (duration.inMilliseconds / totalDuration.inMilliseconds)
            .clamp(0.02, 1.0);
      } else {
        trimFactor = 1.0;
      }
      return (sourceSizeBytes * audioFactor * trimFactor).round() +
          coverJpegOverhead;
    }
    final seconds = duration.inMilliseconds / 1000.0;
    if (seconds <= 0) return sourceSizeBytes;
    final audioBps = keepAudio ? 160000 : 0;
    final rawEncoded = ((videoBitrate! + audioBps) / 8.0 * seconds).round();
    final estimated = rawEncoded + coverJpegOverhead;
    if (sourceSizeBytes > 0 && estimated > (sourceSizeBytes * 1.15).round()) {
      return sourceSizeBytes + coverJpegOverhead;
    }
    return estimated;
  }
}

/// Pure helpers for clamping video trim bounds and cover timestamps.
abstract final class VideoTrimMath {
  static const int minClipMs = 500;

  static ({int startMs, int endMs}) clampTrimRange({
    required int startMs,
    required int endMs,
    required int totalMs,
  }) {
    if (totalMs <= 0) {
      return (startMs: 0, endMs: 0);
    }
    if (totalMs <= minClipMs) {
      return (startMs: 0, endMs: totalMs);
    }
    var s = startMs.clamp(0, totalMs - minClipMs);
    var e = endMs.clamp(minClipMs, totalMs);
    if (e - s < minClipMs) {
      if (s + minClipMs <= totalMs) {
        e = s + minClipMs;
      } else {
        s = totalMs - minClipMs;
        e = totalMs;
      }
    }
    return (startMs: s, endMs: e);
  }

  static int clampCoverToTrim({
    required int coverMs,
    required int startMs,
    required int endMs,
  }) {
    if (endMs <= startMs) return startMs;
    return coverMs.clamp(startMs, endMs);
  }

  static bool isEffectivelyTrimmed({
    required int startMs,
    required int endMs,
    required int totalMs,
  }) {
    if (totalMs <= 0) return false;
    return startMs > 50 || endMs < totalMs - 50;
  }
}

class ConversionProgress {
  const ConversionProgress({
    required this.stage,
    required this.progress,
    required this.message,
  });

  factory ConversionProgress.fromMap(Map<Object?, Object?> map) {
    final rawProgress = map['progress'];
    final numProgress = rawProgress is num ? rawProgress.toDouble() : 0.0;
    return ConversionProgress(
      stage: (map['stage'] as String?) ?? 'processing',
      progress: numProgress.clamp(0.0, 1.0),
      message: (map['message'] as String?) ?? '正在处理视频...',
    );
  }

  final String stage;
  final double progress;
  final String message;
}

class ConversionResult {
  const ConversionResult({
    required this.savedTarget,
    required this.outputSizeBytes,
    required this.elapsedMs,
    required this.platformFormat,
  });

  factory ConversionResult.fromMap(Map<Object?, Object?> map) {
    final sizeRaw = map['outputSizeBytes'];
    final elapsedRaw = map['elapsedMs'];
    return ConversionResult(
      savedTarget: (map['savedTarget'] as String?) ?? '',
      outputSizeBytes: sizeRaw is num ? sizeRaw.toInt() : 0,
      elapsedMs: elapsedRaw is num ? elapsedRaw.toInt() : 0,
      platformFormat: (map['platformFormat'] as String?) ?? 'Live Photo',
    );
  }

  final String savedTarget;
  final int outputSizeBytes;
  final int elapsedMs;
  final String platformFormat;
}

String formatPreciseDuration(Duration d) {
  final totalMs = d.inMilliseconds < 0 ? 0 : d.inMilliseconds;
  final hours = totalMs ~/ 3600000;
  final minutes = (totalMs % 3600000) ~/ 60000;
  final seconds = (totalMs % 60000) ~/ 1000;
  final tenths = (totalMs % 1000) ~/ 100;

  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    final hh = hours.toString().padLeft(2, '0');
    return '$hh:$mm:$ss.$tenths';
  }
  return '$mm:$ss.$tenths';
}

String formatFileSize(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
