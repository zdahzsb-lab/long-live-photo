enum BatchCoverStrategy {
  halfSecond(label: '0.5s 封面', targetMs: 500),
  firstFrame(label: '首帧封面', targetMs: 0);

  const BatchCoverStrategy({
    required this.label,
    required this.targetMs,
  });

  final String label;
  final int targetMs;
}

enum BatchItemStatus {
  queued,
  converting,
  completed,
  failed,
  cancelled,
}

class BatchQueueItem {
  const BatchQueueItem({
    required this.id,
    required this.videoPath,
    required this.displayName,
    required this.sourceSizeBytes,
    this.status = BatchItemStatus.queued,
    this.progress = 0.0,
    this.outputSizeBytes = 0,
    this.savedTarget,
    this.errorMessage,
  });

  final String id;
  final String videoPath;
  final String displayName;
  final int sourceSizeBytes;
  final BatchItemStatus status;
  final double progress;
  final int outputSizeBytes;
  final String? savedTarget;
  final String? errorMessage;

  BatchQueueItem copyWith({
    BatchItemStatus? status,
    double? progress,
    int? outputSizeBytes,
    String? savedTarget,
    String? errorMessage,
    bool clearError = false,
  }) {
    return BatchQueueItem(
      id: id,
      videoPath: videoPath,
      displayName: displayName,
      sourceSizeBytes: sourceSizeBytes,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      outputSizeBytes: outputSizeBytes ?? this.outputSizeBytes,
      savedTarget: savedTarget ?? this.savedTarget,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
