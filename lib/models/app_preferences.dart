import 'batch_task.dart';
import 'conversion_options.dart';

/// Persisted user defaults for new Live Photo synthesis & batch tasks.
class AppPreferences {
  const AppPreferences({
    this.defaultQuality = QualityPreset.p1080,
    this.defaultKeepAudio = true,
    this.defaultPreserveMetadata = true,
    this.defaultBatchCover = BatchCoverStrategy.halfSecond,
  });

  static const AppPreferences defaults = AppPreferences();

  factory AppPreferences.fromJson(Map<Object?, Object?> json) {
    final rawQuality = json['defaultQuality'];
    final rawKeepAudio = json['defaultKeepAudio'];
    final rawPreserveMetadata = json['defaultPreserveMetadata'];
    final rawBatchCover = json['defaultBatchCover'];

    return AppPreferences(
      defaultQuality: rawQuality is String
          ? QualityPreset.fromWireValue(rawQuality)
          : QualityPreset.p1080,
      defaultKeepAudio: rawKeepAudio is bool ? rawKeepAudio : true,
      defaultPreserveMetadata:
          rawPreserveMetadata is bool ? rawPreserveMetadata : true,
      defaultBatchCover: _batchCoverFromWire(rawBatchCover),
    );
  }

  final QualityPreset defaultQuality;
  final bool defaultKeepAudio;
  final bool defaultPreserveMetadata;
  final BatchCoverStrategy defaultBatchCover;

  AppPreferences copyWith({
    QualityPreset? defaultQuality,
    bool? defaultKeepAudio,
    bool? defaultPreserveMetadata,
    BatchCoverStrategy? defaultBatchCover,
  }) {
    return AppPreferences(
      defaultQuality: defaultQuality ?? this.defaultQuality,
      defaultKeepAudio: defaultKeepAudio ?? this.defaultKeepAudio,
      defaultPreserveMetadata:
          defaultPreserveMetadata ?? this.defaultPreserveMetadata,
      defaultBatchCover: defaultBatchCover ?? this.defaultBatchCover,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'defaultQuality': defaultQuality.wireValue,
      'defaultKeepAudio': defaultKeepAudio,
      'defaultPreserveMetadata': defaultPreserveMetadata,
      'defaultBatchCover': _batchCoverToWire(defaultBatchCover),
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is AppPreferences &&
            other.defaultQuality == defaultQuality &&
            other.defaultKeepAudio == defaultKeepAudio &&
            other.defaultPreserveMetadata == defaultPreserveMetadata &&
            other.defaultBatchCover == defaultBatchCover);
  }

  @override
  int get hashCode => Object.hash(
        defaultQuality,
        defaultKeepAudio,
        defaultPreserveMetadata,
        defaultBatchCover,
      );

  static String _batchCoverToWire(BatchCoverStrategy strategy) {
    return switch (strategy) {
      BatchCoverStrategy.firstFrame => 'first_frame',
      BatchCoverStrategy.halfSecond => 'half_second',
    };
  }

  static BatchCoverStrategy _batchCoverFromWire(Object? raw) {
    if (raw == 'first_frame') {
      return BatchCoverStrategy.firstFrame;
    }
    return BatchCoverStrategy.halfSecond;
  }
}
