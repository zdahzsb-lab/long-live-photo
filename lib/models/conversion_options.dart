enum QualityPreset {
  passthrough(
    wireValue: 'passthrough',
    segmentLabel: '原画秒转',
    title: '原画直通（秒转 · 零重压）',
    subtitle: '不重新压制视频画面，仅封装实况容器与元数据，1～3 秒极速出图',
    shortSideLimit: null,
    videoBitrate: null,
  ),
  p1080(
    wireValue: '1080p',
    segmentLabel: '1080p 均衡',
    title: '1080p 高清均衡（推荐）',
    subtitle: '硬件加速控制在约 6 Mbps，画质通透且几分钟长视频相册滑动不卡顿',
    shortSideLimit: 1080,
    videoBitrate: 6000000,
  ),
  p720(
    wireValue: '720p',
    segmentLabel: '720p 省流',
    title: '720p 省空间（超长视频专用）',
    subtitle: '硬件加速控制在约 2.8 Mbps，适合 5～30 分钟超长视频完整收藏',
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
