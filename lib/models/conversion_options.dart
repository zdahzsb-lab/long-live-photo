enum QualityPreset {
  passthrough(
    wireValue: 'passthrough',
    segmentLabel: '原画秒转',
    shortLabel: '原画',
    title: '原画直通 · 零重压',
    subtitle: '保留原片码率直接封装，1～3 秒出图',
    shortSideLimit: null,
    videoBitrate: null,
  ),
  p1080(
    wireValue: '1080p',
    segmentLabel: '1080p 均衡',
    shortLabel: '1080p',
    title: '1080p 高清均衡',
    subtitle: '硬件编码约 6 Mbps，高清且滑动流畅',
    shortSideLimit: 1080,
    videoBitrate: 6000000,
  ),
  p720(
    wireValue: '720p',
    segmentLabel: '720p 省流',
    shortLabel: '720p',
    title: '720p 轻量省空间',
    subtitle: '硬件编码约 2.8 Mbps，适合超长视频',
    shortSideLimit: 720,
    videoBitrate: 2800000,
  );

  const QualityPreset({
    required this.wireValue,
    required this.segmentLabel,
    required this.shortLabel,
    required this.title,
    required this.subtitle,
    required this.shortSideLimit,
    required this.videoBitrate,
  });

  final String wireValue;
  final String segmentLabel;
  final String shortLabel;
  final String title;
  final String subtitle;
  final int? shortSideLimit;
  final int? videoBitrate;

  static QualityPreset fromWireValue(String value) {
    for (final preset in QualityPreset.values) {
      if (preset.wireValue == value) return preset;
    }
    return QualityPreset.p1080;
  }

  /// Estimates output Live Photo size based on source bytes, duration, speed, and audio toggle.
  int estimateOutputBytes({
    required int sourceSizeBytes,
    required Duration duration,
    required bool keepAudio,
    Duration? totalDuration,
    double playbackSpeed = 1.0,
  }) {
    const int coverJpegOverhead = 650 * 1024;
    final safeSpeed = VideoSpeedMath.clampSpeed(playbackSpeed);
    final hasSpeed = VideoSpeedMath.isEffectivelyScaled(safeSpeed);
    final outputDuration = VideoSpeedMath.scaledDuration(duration, safeSpeed);

    if (videoBitrate == null) {
      if (!hasSpeed) {
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

      // Speed changes force hardware re-encoding (~14 Mbps high-bitrate profile).
      final seconds = outputDuration.inMilliseconds / 1000.0;
      if (seconds <= 0) return sourceSizeBytes;
      final audioBps = keepAudio ? 160000 : 0;
      final rawEncoded = ((14000000 + audioBps) / 8.0 * seconds).round();
      final estimated = rawEncoded + coverJpegOverhead;
      if (safeSpeed >= 1.0 &&
          sourceSizeBytes > 0 &&
          estimated > (sourceSizeBytes * 1.15).round() + coverJpegOverhead) {
        return (sourceSizeBytes * 1.15).round() + coverJpegOverhead;
      }
      return estimated;
    }

    final seconds = outputDuration.inMilliseconds / 1000.0;
    if (seconds <= 0) return sourceSizeBytes;
    final audioBps = keepAudio ? 160000 : 0;
    final rawEncoded = ((videoBitrate! + audioBps) / 8.0 * seconds).round();
    final estimated = rawEncoded + coverJpegOverhead;
    if (safeSpeed >= 1.0 &&
        sourceSizeBytes > 0 &&
        estimated > (sourceSizeBytes * 1.15).round()) {
      return sourceSizeBytes + coverJpegOverhead;
    }
    return estimated;
  }
}

enum PlaybackSpeedPreset {
  slowHalf(rate: 0.5, label: '0.5x', shortTag: '0.5x 慢放'),
  normal(rate: 1.0, label: '1x', shortTag: '原速'),
  fast15(rate: 1.5, label: '1.5x', shortTag: '1.5x 轻快'),
  fast2(rate: 2.0, label: '2x', shortTag: '2x 倍速'),
  timelapse4(rate: 4.0, label: '4x', shortTag: '4x 延时');

  const PlaybackSpeedPreset({
    required this.rate,
    required this.label,
    required this.shortTag,
  });

  final double rate;
  final String label;
  final String shortTag;

  bool get isModified => (rate - 1.0).abs() > 0.01;

  static PlaybackSpeedPreset fromRate(double rate) {
    final safe = VideoSpeedMath.clampSpeed(rate);
    var best = PlaybackSpeedPreset.normal;
    var bestDiff = double.infinity;
    for (final preset in PlaybackSpeedPreset.values) {
      final diff = (preset.rate - safe).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = preset;
      }
    }
    return best;
  }
}

/// Pure helpers for clamping and scaling timestamps under speed adjustments.
abstract final class VideoSpeedMath {
  static const double minSpeed = 0.5;
  static const double maxSpeed = 4.0;

  static double clampSpeed(double speed) =>
      speed.isFinite ? speed.clamp(minSpeed, maxSpeed) : 1.0;

  static bool isEffectivelyScaled(double speed) =>
      (clampSpeed(speed) - 1.0).abs() > 0.01;

  static Duration scaledDuration(Duration sourceDuration, double speed) {
    if (sourceDuration.inMilliseconds <= 0) {
      return Duration.zero;
    }
    final ms = (sourceDuration.inMilliseconds / clampSpeed(speed))
        .round()
        .clamp(100, 24 * 3600 * 1000);
    return Duration(milliseconds: ms);
  }

  static int scaledCoverOffsetMs({
    required int coverMs,
    required int trimStartMs,
    required int trimEndMs,
    required double speed,
  }) {
    final span = (trimEndMs - trimStartMs).clamp(0, 1 << 30);
    final rel = (coverMs - trimStartMs).clamp(0, span);
    return (rel / clampSpeed(speed)).round();
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

enum StandaloneExportMode {
  video(wireValue: 'video'),
  cover(wireValue: 'cover');

  const StandaloneExportMode({required this.wireValue});

  final String wireValue;
}

enum SharedMediaKind { video, image }

class SharedMediaItem {
  const SharedMediaItem({
    required this.path,
    required this.kind,
  });

  factory SharedMediaItem.fromMap(Map<Object?, Object?> map) {
    final rawKind = (map['kind'] as String?) ?? 'video';
    return SharedMediaItem(
      path: (map['path'] as String?) ?? '',
      kind: rawKind == 'image' ? SharedMediaKind.image : SharedMediaKind.video,
    );
  }

  final String path;
  final SharedMediaKind kind;
}

class UnpackedLivePhoto {
  const UnpackedLivePhoto({
    required this.videoPath,
    this.coverImagePath,
    this.coverTimeMs = 0,
  });

  factory UnpackedLivePhoto.fromMap(Map<Object?, Object?> map) {
    final rawCoverMs = map['coverTimeMs'];
    final coverPath = map['coverImagePath'] as String?;
    return UnpackedLivePhoto(
      videoPath: (map['videoPath'] as String?) ?? '',
      coverImagePath:
          (coverPath != null && coverPath.isNotEmpty) ? coverPath : null,
      coverTimeMs: rawCoverMs is num ? rawCoverMs.toInt().clamp(0, 1 << 30) : 0,
    );
  }

  final String videoPath;
  final String? coverImagePath;
  final int coverTimeMs;
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
