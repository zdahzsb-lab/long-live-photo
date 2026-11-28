import 'dart:async';

import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../models/batch_task.dart';
import '../models/conversion_history.dart';
import '../models/conversion_options.dart';
import '../services/conversion_history_store.dart';
import '../services/live_photo_channel.dart';
import '../theme/ui_tokens.dart';
import 'buttons.dart';
import 'pressable.dart';
import 'segmented_tabs.dart';

/// Restrained darkroom bottom-sheet queue for sequential multi-video conversion.
Future<void> showBatchQueueSheet({
  required BuildContext context,
  required List<BatchQueueItem> initialItems,
  required LivePhotoConverterGateway gateway,
  required ConversionHistoryStore historyStore,
  required QualityPreset initialQuality,
  required PlaybackSpeedPreset initialSpeed,
  required bool initialKeepAudio,
  required bool initialPreserveMetadata,
  BatchCoverStrategy initialCoverStrategy = BatchCoverStrategy.halfSecond,
  ValueChanged<List<ConversionHistoryEntry>>? onHistoryUpdated,
  Future<void> Function(String? savedTarget)? onOpenGallery,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Ui.surface,
    barrierColor: const Color(0xA6000000),
    builder: (BuildContext sheetContext) {
      return _BatchQueueSheetContent(
        initialItems: initialItems,
        gateway: gateway,
        historyStore: historyStore,
        initialQuality: initialQuality,
        initialSpeed: initialSpeed,
        initialKeepAudio: initialKeepAudio,
        initialPreserveMetadata: initialPreserveMetadata,
        initialCoverStrategy: initialCoverStrategy,
        onHistoryUpdated: onHistoryUpdated,
        onOpenGallery: onOpenGallery,
      );
    },
  );
}

class _BatchQueueSheetContent extends StatefulWidget {
  const _BatchQueueSheetContent({
    required this.initialItems,
    required this.gateway,
    required this.historyStore,
    required this.initialQuality,
    required this.initialSpeed,
    required this.initialKeepAudio,
    required this.initialPreserveMetadata,
    this.initialCoverStrategy = BatchCoverStrategy.halfSecond,
    this.onHistoryUpdated,
    this.onOpenGallery,
  });

  final List<BatchQueueItem> initialItems;
  final LivePhotoConverterGateway gateway;
  final ConversionHistoryStore historyStore;
  final QualityPreset initialQuality;
  final PlaybackSpeedPreset initialSpeed;
  final bool initialKeepAudio;
  final bool initialPreserveMetadata;
  final BatchCoverStrategy initialCoverStrategy;
  final ValueChanged<List<ConversionHistoryEntry>>? onHistoryUpdated;
  final Future<void> Function(String? savedTarget)? onOpenGallery;

  @override
  State<_BatchQueueSheetContent> createState() =>
      _BatchQueueSheetContentState();
}

class _BatchQueueSheetContentState extends State<_BatchQueueSheetContent> {
  late List<BatchQueueItem> _items;
  late QualityPreset _quality;
  late PlaybackSpeedPreset _speed;
  late bool _keepAudio;
  late bool _preserveMetadata;
  BatchCoverStrategy _coverStrategy = BatchCoverStrategy.halfSecond;

  bool _isRunning = false;
  bool _cancelRequested = false;
  bool _hasCompletedRun = false;
  String? _activeItemId;
  int _batchSeq = 0;
  StreamSubscription<ConversionProgress>? _progressSub;

  @override
  void initState() {
    super.initState();
    _items = List<BatchQueueItem>.from(widget.initialItems);
    _quality = widget.initialQuality;
    _speed = widget.initialSpeed;
    _keepAudio = widget.initialKeepAudio;
    _preserveMetadata = widget.initialPreserveMetadata;
    _coverStrategy = widget.initialCoverStrategy;
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  void _removeItem(String id) {
    if (_isRunning || _items.length <= 1) return;
    setState(() {
      _items.removeWhere((BatchQueueItem e) => e.id == id);
    });
  }

  void _retryFailed() {
    if (_isRunning) return;
    setState(() {
      _items = _items
          .map(
            (BatchQueueItem e) => (e.status == BatchItemStatus.failed ||
                    e.status == BatchItemStatus.cancelled)
                ? e.copyWith(
                    status: BatchItemStatus.queued,
                    progress: 0.0,
                    clearError: true,
                  )
                : e,
          )
          .toList(growable: false);
    });
    unawaited(_startBatch());
  }

  Future<void> _cancelBatch() async {
    if (!_isRunning) return;
    _cancelRequested = true;
    await widget.gateway.cancelConversion();
  }

  Future<void> _startBatch() async {
    if (_isRunning) return;
    final hasQueued =
        _items.any((BatchQueueItem e) => e.status == BatchItemStatus.queued);
    if (!hasQueued) return;

    setState(() {
      _isRunning = true;
      _cancelRequested = false;
    });

    final prevSub = _progressSub;
    _progressSub = null;
    if (prevSub != null) {
      unawaited(prevSub.cancel());
    }
    _progressSub =
        widget.gateway.progressStream.listen((ConversionProgress ev) {
      final activeId = _activeItemId;
      if (!mounted || !_isRunning || activeId == null) return;
      final idx = _items.indexWhere((BatchQueueItem e) => e.id == activeId);
      if (idx >= 0) {
        setState(() {
          _items[idx] = _items[idx].copyWith(progress: ev.progress);
        });
      }
    });

    try {
      for (int i = 0; i < _items.length; i++) {
        if (!mounted) break;
        final item = _items[i];
        if (item.status != BatchItemStatus.queued) continue;

        if (_cancelRequested) {
          setState(() {
            _items[i] = item.copyWith(
              status: BatchItemStatus.cancelled,
              progress: 0.0,
            );
          });
          continue;
        }

        setState(() {
          _activeItemId = item.id;
          _items[i] = item.copyWith(
            status: BatchItemStatus.converting,
            progress: 0.04,
            clearError: true,
          );
        });

        try {
          final result = await widget.gateway.convertAndSave(
            videoPath: item.videoPath,
            coverTimeMs: _coverStrategy.targetMs,
            quality: _quality,
            keepAudio: _keepAudio,
            preserveMetadata: _preserveMetadata,
            playbackSpeed: _speed.rate,
          );

          if (!mounted) break;
          setState(() {
            _items[i] = _items[i].copyWith(
              status: BatchItemStatus.completed,
              progress: 1.0,
              outputSizeBytes: result.outputSizeBytes,
              savedTarget: result.savedTarget,
            );
          });

          Uint8List? thumbBytes;
          try {
            final thumbs = await widget.gateway.extractThumbnails(
              videoPath: item.videoPath,
              count: 1,
            );
            if (thumbs.isNotEmpty) {
              thumbBytes = thumbs.first;
            }
          } catch (_) {
            // Optional thumbnail.
          }

          final nowMs = DateTime.now().millisecondsSinceEpoch;
          _batchSeq++;
          final historyEntry = ConversionHistoryEntry(
            id: 'batch_${nowMs}_$_batchSeq',
            createdAtMs: nowMs,
            sourceVideoPath: item.videoPath,
            savedTarget: result.savedTarget,
            platformFormat: result.platformFormat,
            sourceDurationMs: 0,
            outputDurationMs: 0,
            outputSizeBytes: result.outputSizeBytes,
            elapsedMs: result.elapsedMs,
            qualityWireValue: _quality.wireValue,
            playbackSpeed: _speed.rate,
            keepAudio: _keepAudio,
            preserveMetadata: _preserveMetadata,
            wasTrimmed: false,
            coverTimeMs: _coverStrategy.targetMs,
          );
          try {
            final updated = await widget.historyStore.add(
              historyEntry,
              thumbnailBytes: thumbBytes,
            );
            widget.onHistoryUpdated?.call(updated);
          } catch (_) {
            // Best-effort history recording.
          }
        } on PlatformException catch (e) {
          if (!mounted) break;
          if (e.code == 'CANCELLED' || _cancelRequested) {
            _cancelRequested = true;
            setState(() {
              _items[i] = _items[i].copyWith(
                status: BatchItemStatus.cancelled,
                progress: 0.0,
              );
            });
          } else {
            setState(() {
              _items[i] = _items[i].copyWith(
                status: BatchItemStatus.failed,
                progress: 0.0,
                errorMessage: e.message ?? '合成失败（${e.code}）',
              );
            });
          }
        } catch (e) {
          if (!mounted) break;
          setState(() {
            _items[i] = _items[i].copyWith(
              status: BatchItemStatus.failed,
              progress: 0.0,
              errorMessage: '合成出错：$e',
            );
          });
        }
      }
    } finally {
      final sub = _progressSub;
      _progressSub = null;
      _activeItemId = null;
      if (sub != null) {
        unawaited(sub.cancel());
      }
      if (mounted) {
        playHaptic(_cancelRequested ? Haptic.light : Haptic.medium);
        setState(() {
          _isRunning = false;
          _hasCompletedRun = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.84;
    final doneCount = _items
        .where((BatchQueueItem e) => e.status == BatchItemStatus.completed)
        .length;
    final retryCount = _items
        .where((BatchQueueItem e) =>
            e.status == BatchItemStatus.failed ||
            e.status == BatchItemStatus.cancelled)
        .length;
    final queuedCount = _items
        .where((BatchQueueItem e) => e.status == BatchItemStatus.queued)
        .length;

    final double overallProgress;
    if (_items.isEmpty) {
      overallProgress = 0.0;
    } else {
      final sum = _items.fold<double>(
        0.0,
        (double acc, BatchQueueItem item) =>
            acc +
            (item.status == BatchItemStatus.completed
                ? 1.0
                : (item.status == BatchItemStatus.converting
                    ? item.progress.clamp(0.0, 1.0)
                    : 0.0)),
      );
      overallProgress = (sum / _items.length).clamp(0.02, 1.0);
    }

    final activeIdx = _items
        .indexWhere((BatchQueueItem e) => e.status == BatchItemStatus.converting);
    final activeItem = activeIdx >= 0 ? _items[activeIdx] : null;
    final lastSavedTarget = _items
        .where((BatchQueueItem e) =>
            e.status == BatchItemStatus.completed &&
            (e.savedTarget?.isNotEmpty ?? false))
        .map((BatchQueueItem e) => e.savedTarget)
        .lastOrNull;

    return PopScope(
      canPop: !_isRunning,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Ui.s5, Ui.s1, Ui.s5, Ui.s5),
            child: _buildSheetBody(
              context: context,
              compactHeight: maxHeight < 500,
              doneCount: doneCount,
              retryCount: retryCount,
              queuedCount: queuedCount,
              overallProgress: overallProgress,
              activeIdx: activeIdx,
              activeItem: activeItem,
              lastSavedTarget: lastSavedTarget,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSheetBody({
    required BuildContext context,
    required bool compactHeight,
    required int doneCount,
    required int retryCount,
    required int queuedCount,
    required double overallProgress,
    required int activeIdx,
    required BatchQueueItem? activeItem,
    required String? lastSavedTarget,
  }) {
    final listWidget = ListView.separated(
      shrinkWrap: true,
      physics: compactHeight ? const NeverScrollableScrollPhysics() : null,
      itemCount: _items.length,
      separatorBuilder: (_, _) => const SizedBox(height: Ui.s2),
      itemBuilder: (BuildContext context, int index) {
        final item = _items[index];
        return _BatchItemTile(
          item: item,
          canRemove: !_isRunning &&
              _items.length > 1 &&
              item.status == BatchItemStatus.queued,
          onRemove: () => _removeItem(item.id),
        );
      },
    );

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Header
        SizedBox(
          height: 44,
          child: Row(
            children: <Widget>[
              const Text('批量转实况', style: Ui.title),
              const SizedBox(width: Ui.s2),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: Ui.bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Ui.hairline),
                ),
                child: Text(
                  '${_items.length}',
                  style: Ui.mono.copyWith(
                    fontSize: 11.5,
                    color: Ui.textSecondary,
                  ),
                ),
              ),
              const Spacer(),
              IconAction(
                key: const Key('batch_close_button'),
                icon: LucideIcons.x,
                size: 18,
                semanticLabel: '关闭批量转换队列',
                enabled: !_isRunning,
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const SizedBox(height: Ui.s2),

        // Batch parameters
        SegmentedTabs<PlaybackSpeedPreset>(
          key: const Key('batch_speed_tabs'),
          items: PlaybackSpeedPreset.values,
          selectedIndex: _speed.index,
          height: 36,
          fontSize: 12.5,
          monospace: true,
          enabled: !_isRunning,
          labelBuilder: (PlaybackSpeedPreset p) => p.label,
          onChanged: (int idx) {
            setState(() => _speed = PlaybackSpeedPreset.values[idx]);
          },
        ),
        const SizedBox(height: Ui.s1 + 2),
        SegmentedTabs<QualityPreset>(
          key: const Key('batch_quality_tabs'),
          items: QualityPreset.values,
          selectedIndex: _quality.index,
          height: 40,
          enabled: !_isRunning,
          labelBuilder: (QualityPreset p) => p.segmentLabel,
          onChanged: (int idx) {
            setState(() => _quality = QualityPreset.values[idx]);
          },
        ),
        const SizedBox(height: Ui.s1),

        // Compact option pills row (cover / audio / metadata)
        Row(
          children: <Widget>[
            Expanded(
              child: _BatchOptionPill(
                key: const Key('batch_cover_strategy_button'),
                label: _coverStrategy.label,
                active: true,
                enabled: !_isRunning,
                onTap: () {
                  setState(() {
                    _coverStrategy =
                        _coverStrategy == BatchCoverStrategy.halfSecond
                            ? BatchCoverStrategy.firstFrame
                            : BatchCoverStrategy.halfSecond;
                  });
                },
              ),
            ),
            const SizedBox(width: Ui.s1 + 2),
            Expanded(
              child: _BatchOptionPill(
                key: const Key('batch_audio_toggle'),
                label: _keepAudio ? '保留原声' : '静音',
                active: _keepAudio,
                enabled: !_isRunning,
                onTap: () => setState(() => _keepAudio = !_keepAudio),
              ),
            ),
            const SizedBox(width: Ui.s1 + 2),
            Expanded(
              child: _BatchOptionPill(
                key: const Key('batch_metadata_toggle'),
                label: _preserveMetadata ? '原拍摄时间' : '当前时间',
                active: _preserveMetadata,
                enabled: !_isRunning,
                onTap: () => setState(
                  () => _preserveMetadata = !_preserveMetadata,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Ui.s2),

        // Video queue list
        if (compactHeight) listWidget else Flexible(child: listWidget),
        const SizedBox(height: Ui.s3),

        // Action footer
        if (_isRunning) ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: PrimaryButton(
                  key: const Key('batch_run_button'),
                  label: '批量合成中',
                  progress: overallProgress,
                  progressLabel: activeItem != null
                      ? '正在转换 ${activeIdx + 1}/${_items.length} · ${(activeItem.progress * 100).round()}%'
                      : '正在准备批量合成...',
                  onTap: null,
                ),
              ),
              const SizedBox(width: Ui.s2),
              Pressable(
                key: const Key('batch_cancel_button'),
                semanticLabel: '取消批量合成',
                haptic: Haptic.light,
                maxInsetPx: 4.0,
                minSize: const Size(80, Ui.buttonHeight),
                onTap: _cancelBatch,
                child: Container(
                  width: 80,
                  height: Ui.buttonHeight,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Ui.surfaceRaised,
                    borderRadius: BorderRadius.circular(Ui.rMd + 2),
                    border: Border.all(color: Ui.hairlineStrong),
                  ),
                  child: Text(
                    '取消',
                    style: Ui.label.copyWith(color: Ui.textPrimary),
                  ),
                ),
              ),
            ],
          ),
        ] else if (_hasCompletedRun && queuedCount == 0) ...<Widget>[
          Text(
            retryCount > 0
                ? '已完成 $doneCount / ${_items.length} 段 · $retryCount 段未完成'
                : '全部 $doneCount 段实况已存入系统相册',
            textAlign: TextAlign.center,
            style: Ui.caption.copyWith(
              color: doneCount > 0 ? Ui.textPrimary : Ui.textSecondary,
              fontFeatures: Ui.tabular,
            ),
          ),
          const SizedBox(height: Ui.s3),
          if ((widget.onOpenGallery != null && doneCount > 0) ||
              retryCount > 0) ...<Widget>[
            Row(
              children: <Widget>[
                if (widget.onOpenGallery != null && doneCount > 0)
                  Expanded(
                    child: SecondaryButton(
                      key: const Key('batch_open_gallery_button'),
                      label: '打开相册',
                      icon: LucideIcons.images,
                      onTap: () => unawaited(
                        widget.onOpenGallery!(lastSavedTarget),
                      ),
                    ),
                  ),
                if (widget.onOpenGallery != null &&
                    doneCount > 0 &&
                    retryCount > 0)
                  const SizedBox(width: Ui.s2),
                if (retryCount > 0)
                  Expanded(
                    child: SecondaryButton(
                      key: const Key('batch_retry_failed_button'),
                      label: '重试失败项',
                      icon: LucideIcons.rotateCcw,
                      onTap: _retryFailed,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Ui.s2 + 2),
          ],
          PrimaryButton(
            key: const Key('batch_done_button'),
            label: '完成',
            onTap: () => Navigator.of(context).pop(),
          ),
        ] else ...<Widget>[
          PrimaryButton(
            key: const Key('batch_start_button'),
            label: '开始批量转换（${_items.length} 段）',
            icon: LucideIcons.layers,
            enabled: _items.isNotEmpty,
            onTap: _startBatch,
          ),
        ],
      ],
    );

    if (compactHeight) {
      return SingleChildScrollView(child: column);
    }
    return column;
  }
}

class _BatchOptionPill extends StatelessWidget {
  const _BatchOptionPill({
    super.key,
    required this.label,
    required this.active,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      enabled: enabled,
      expandWidth: true,
      toggled: active,
      semanticLabel: label,
      maxInsetPx: 3.0,
      minSize: const Size(0, Ui.minTarget),
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Ui.bg,
          borderRadius: BorderRadius.circular(Ui.rSm),
          border: Border.all(
            color: active ? Ui.hairlineStrong : Ui.hairline,
          ),
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 5.5,
                  height: 5.5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active ? Ui.liveActive : Ui.textTertiary,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  maxLines: 1,
                  style: Ui.caption.copyWith(
                    fontSize: 11.5,
                    color: active ? Ui.textPrimary : Ui.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BatchItemTile extends StatelessWidget {
  const _BatchItemTile({
    required this.item,
    required this.canRemove,
    required this.onRemove,
  });

  final BatchQueueItem item;
  final bool canRemove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final String subtitle;
    final Color statusColor;
    final IconData statusIcon;

    switch (item.status) {
      case BatchItemStatus.queued:
        subtitle = item.sourceSizeBytes > 0
            ? '待处理 · ${formatFileSize(item.sourceSizeBytes)}'
            : '待处理';
        statusColor = Ui.textSecondary;
        statusIcon = LucideIcons.clock;
      case BatchItemStatus.converting:
        subtitle = '合成中 ${(item.progress * 100).round()}%';
        statusColor = Ui.textPrimary;
        statusIcon = LucideIcons.loaderCircle;
      case BatchItemStatus.completed:
        subtitle = '已存入相册 · ${formatFileSize(item.outputSizeBytes)}';
        statusColor = Ui.liveActive;
        statusIcon = LucideIcons.check;
      case BatchItemStatus.failed:
        subtitle = item.errorMessage ?? '合成失败';
        statusColor = Ui.danger;
        statusIcon = LucideIcons.circleAlert;
      case BatchItemStatus.cancelled:
        subtitle = '已取消';
        statusColor = Ui.textTertiary;
        statusIcon = LucideIcons.x;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Ui.s3, vertical: Ui.s2 + 2),
      decoration: BoxDecoration(
        color: Ui.bg,
        borderRadius: BorderRadius.circular(Ui.rMd),
        border: Border.all(
          color: item.status == BatchItemStatus.converting
              ? Ui.hairlineStrong
              : Ui.hairline,
        ),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Ui.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Ui.hairline),
            ),
            child: Icon(statusIcon, size: 15, color: statusColor),
          ),
          const SizedBox(width: Ui.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  item.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ui.callout.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ui.caption.copyWith(
                    color: item.status == BatchItemStatus.failed
                        ? Ui.danger
                        : Ui.textSecondary,
                    fontFeatures: Ui.tabular,
                  ),
                ),
              ],
            ),
          ),
          if (item.status == BatchItemStatus.converting)
            Padding(
              padding: const EdgeInsets.only(left: Ui.s2),
              child: Text(
                '${(item.progress * 100).round()}%',
                style: Ui.mono.copyWith(fontSize: 12),
              ),
            )
          else if (canRemove)
            IconAction(
              key: Key('batch_remove_${item.id}'),
              icon: LucideIcons.trash2,
              size: 15,
              semanticLabel: '从队列移除',
              onTap: onRemove,
            ),
        ],
      ),
    );
  }
}
