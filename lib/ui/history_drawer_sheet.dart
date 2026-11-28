import 'dart:async';
import 'dart:io';

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../models/conversion_history.dart';
import '../models/conversion_options.dart';
import '../theme/ui_tokens.dart';
import 'buttons.dart';
import 'pressable.dart';

/// Restrained darkroom bottom-sheet drawer showing recent synthesized Live Photos.
Future<void> showHistoryDrawerSheet({
  required BuildContext context,
  required List<ConversionHistoryEntry> initialEntries,
  required Future<List<ConversionHistoryEntry>> Function(String id)
      onDeleteEntry,
  required Future<void> Function() onClearAll,
  required void Function(ConversionHistoryEntry entry) onSelectEntry,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ui.surface,
    barrierColor: const Color(0xA6000000),
    builder: (BuildContext sheetContext) {
      return _HistoryDrawerContent(
        initialEntries: initialEntries,
        onDeleteEntry: onDeleteEntry,
        onClearAll: onClearAll,
        onSelectEntry: (ConversionHistoryEntry entry) {
          Navigator.of(sheetContext).pop();
          onSelectEntry(entry);
        },
      );
    },
  );
}

class _HistoryDrawerContent extends StatefulWidget {
  const _HistoryDrawerContent({
    required this.initialEntries,
    required this.onDeleteEntry,
    required this.onClearAll,
    required this.onSelectEntry,
  });

  final List<ConversionHistoryEntry> initialEntries;
  final Future<List<ConversionHistoryEntry>> Function(String id) onDeleteEntry;
  final Future<void> Function() onClearAll;
  final void Function(ConversionHistoryEntry entry) onSelectEntry;

  @override
  State<_HistoryDrawerContent> createState() => _HistoryDrawerContentState();
}

class _HistoryDrawerContentState extends State<_HistoryDrawerContent> {
  late List<ConversionHistoryEntry> _entries;
  bool _confirmingClear = false;
  bool _busy = false;
  Timer? _confirmResetTimer;

  @override
  void initState() {
    super.initState();
    _entries = List<ConversionHistoryEntry>.from(widget.initialEntries);
  }

  @override
  void dispose() {
    _confirmResetTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleDelete(String id) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final next = await widget.onDeleteEntry(id);
      if (mounted) {
        setState(() {
          _entries = List<ConversionHistoryEntry>.from(next);
          _confirmingClear = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleClearTap() async {
    if (_busy || _entries.isEmpty) return;
    if (!_confirmingClear) {
      _confirmResetTimer?.cancel();
      setState(() => _confirmingClear = true);
      _confirmResetTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() => _confirmingClear = false);
        }
      });
      return;
    }

    _confirmResetTimer?.cancel();
    setState(() => _busy = true);
    try {
      await widget.onClearAll();
      if (mounted) {
        setState(() {
          _entries = <ConversionHistoryEntry>[];
          _confirmingClear = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.72;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Ui.s5, Ui.s1, Ui.s5, Ui.s5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Header
              SizedBox(
                height: 44,
                child: Row(
                  children: <Widget>[
                    const Text('合成记录', style: Ui.title),
                    if (_entries.isNotEmpty) ...<Widget>[
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
                          '${_entries.length}',
                          style: Ui.mono.copyWith(
                            fontSize: 11.5,
                            color: Ui.textSecondary,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (_entries.isNotEmpty)
                      Pressable(
                        key: const Key('history_clear_all_button'),
                        enabled: !_busy,
                        semanticLabel: _confirmingClear ? '确认清空全部记录' : '清空合成记录',
                        haptic: Haptic.light,
                        maxInsetPx: 3.5,
                        minSize: const Size(56, Ui.minTarget),
                        onTap: _handleClearTap,
                        child: AnimatedContainer(
                          duration: Ui.motion(context, Ui.fast),
                          curve: Ui.easeOut,
                          height: 30,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: _confirmingClear
                                ? const Color(0x1FFF6961)
                                : Ui.bg,
                            borderRadius: BorderRadius.circular(Ui.rSm),
                            border: Border.all(
                              color: _confirmingClear
                                  ? Ui.danger
                                  : Ui.hairline,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              _confirmingClear ? '确认清空' : '清空',
                              style: Ui.callout.copyWith(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: _confirmingClear
                                    ? Ui.danger
                                    : Ui.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Ui.s2),

              // Body (empty state vs scrollable darkroom history list)
              if (_entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Ui.s8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Ui.bg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Ui.hairline),
                        ),
                        child: const Icon(
                          LucideIcons.clock,
                          size: 20,
                          color: Ui.textTertiary,
                        ),
                      ),
                      const SizedBox(height: Ui.s3),
                      Text(
                        '暂无合成记录',
                        style: Ui.label.copyWith(color: Ui.textPrimary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '完成的实况参数与封面会自动留存，点击可一键复用。',
                        textAlign: TextAlign.center,
                        style: Ui.caption.copyWith(color: Ui.textSecondary),
                      ),
                    ],
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _entries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: Ui.s2),
                    itemBuilder: (BuildContext context, int index) {
                      final entry = _entries[index];
                      return _HistoryEntryTile(
                        entry: entry,
                        enabled: !_busy,
                        onTap: () => widget.onSelectEntry(entry),
                        onDelete: () => _handleDelete(entry.id),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryEntryTile extends StatelessWidget {
  const _HistoryEntryTile({
    required this.entry,
    required this.enabled,
    required this.onTap,
    required this.onDelete,
  });

  final ConversionHistoryEntry entry;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final speed = entry.speedPreset;
    final traits = <String>[
      formatHistoryTimestamp(entry.createdAtMs),
      if (speed.isModified) speed.shortTag,
      if (!entry.keepAudio) '静音',
      if (entry.usedCustomCover) '自选封面',
      if (entry.wasTrimmed) '已裁剪',
    ];

    final coverCandidate = entry.thumbnailPath ?? entry.customCoverPath;

    return Row(
      children: <Widget>[
        Expanded(
          child: Pressable(
            key: Key('history_entry_${entry.id}'),
            enabled: enabled,
            expandWidth: true,
            maxInsetPx: 4.0,
            semanticLabel:
                '载入 ${formatPreciseDuration(entry.outputDuration)} ${entry.quality.shortLabel} 历史配置',
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(Ui.s2 + 2),
              decoration: BoxDecoration(
                color: Ui.bg,
                borderRadius: BorderRadius.circular(Ui.rMd),
                border: Border.all(color: Ui.hairline),
              ),
              child: Row(
                children: <Widget>[
                  _HistoryThumbnail(
                    imagePath: coverCandidate,
                    speedLabel: speed.isModified ? speed.label : null,
                  ),
                  const SizedBox(width: Ui.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '${formatPreciseDuration(entry.outputDuration)} · ${formatFileSize(entry.outputSizeBytes)} · ${entry.quality.shortLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Ui.mono.copyWith(fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          traits.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Ui.caption.copyWith(
                            color: Ui.textSecondary,
                            fontFeatures: Ui.tabular,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Ui.s1),
                  IconAction(
                    key: Key('history_delete_${entry.id}'),
                    icon: LucideIcons.trash2,
                    size: 16,
                    semanticLabel: '删除该条记录',
                    enabled: enabled,
                    onTap: onDelete,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HistoryThumbnail extends StatelessWidget {
  const _HistoryThumbnail({
    required this.imagePath,
    required this.speedLabel,
  });

  final String? imagePath;
  final String? speedLabel;

  @override
  Widget build(BuildContext context) {
    final hasFile = imagePath != null && imagePath!.isNotEmpty;
    return Container(
      width: 44,
      height: 54,
      decoration: BoxDecoration(
        color: Ui.surfaceRaised,
        borderRadius: BorderRadius.circular(Ui.rSm),
        border: Border.all(color: Ui.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (hasFile)
            Image.file(
              File(imagePath!),
              fit: BoxFit.cover,
              cacheWidth: 160,
              errorBuilder: (_, _, _) => const Center(
                child: Icon(
                  LucideIcons.aperture,
                  size: 18,
                  color: Ui.textTertiary,
                ),
              ),
            )
          else
            const Center(
              child: Icon(
                LucideIcons.aperture,
                size: 18,
                color: Ui.textTertiary,
              ),
            ),
          if (speedLabel != null)
            Positioned(
              right: 2,
              bottom: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Ui.hudScrim,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Ui.hairlineStrong, width: 0.6),
                ),
                child: Text(
                  speedLabel!,
                  style: Ui.mono.copyWith(fontSize: 9.5, height: 1.1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
