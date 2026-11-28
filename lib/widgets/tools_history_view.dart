import 'dart:async';

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../models/conversion_history.dart';
import '../theme/ui_tokens.dart';
import '../ui/history_drawer_sheet.dart';
import '../ui/pressable.dart';

/// Second tab view combining secondary workflows (`批量转实况`, `实况拆解`)
/// with the persistent recent synthesis history list.
class ToolsHistoryView extends StatefulWidget {
  const ToolsHistoryView({
    super.key,
    required this.isBusy,
    required this.historyEntries,
    required this.onPickBatch,
    required this.onPickLiveUnpack,
    required this.onSelectHistory,
    required this.onDeleteHistory,
    required this.onClearHistory,
  });

  final bool isBusy;
  final List<ConversionHistoryEntry> historyEntries;
  final VoidCallback onPickBatch;
  final VoidCallback onPickLiveUnpack;
  final void Function(ConversionHistoryEntry entry) onSelectHistory;
  final Future<void> Function(String id) onDeleteHistory;
  final Future<void> Function() onClearHistory;

  @override
  State<ToolsHistoryView> createState() => _ToolsHistoryViewState();
}

class _ToolsHistoryViewState extends State<ToolsHistoryView> {
  bool _confirmingClear = false;
  bool _clearing = false;
  Timer? _confirmResetTimer;

  @override
  void didUpdateWidget(covariant ToolsHistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.historyEntries.isEmpty && _confirmingClear) {
      _confirmResetTimer?.cancel();
      _confirmingClear = false;
    }
  }

  @override
  void dispose() {
    _confirmResetTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleClearTap() async {
    if (widget.isBusy || _clearing || widget.historyEntries.isEmpty) return;
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
    setState(() => _clearing = true);
    try {
      await widget.onClearHistory();
      if (mounted) {
        setState(() => _confirmingClear = false);
      }
    } finally {
      if (mounted) {
        setState(() => _clearing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.historyEntries;
    final interactionsEnabled = !widget.isBusy && !_clearing;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final horizontalPad = constraints.maxWidth >= 500 ? 24.0 : 18.0;

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            horizontalPad,
            Ui.s2,
            horizontalPad,
            Ui.s6,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: Ui.s2),
                child: Text('扩展工具', style: Ui.caption),
              ),
              Container(
                decoration: BoxDecoration(
                  color: Ui.surface,
                  borderRadius: BorderRadius.circular(Ui.rLg),
                  border: Border.all(color: Ui.hairline),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _ToolRow(
                      key: const Key('pick_batch_button'),
                      icon: LucideIcons.layers,
                      title: '批量转实况',
                      subtitle: '多选视频按统一参数顺序合成',
                      enabled: interactionsEnabled,
                      onTap: widget.onPickBatch,
                    ),
                    Container(height: 1, color: Ui.hairline),
                    _ToolRow(
                      key: const Key('pick_live_unpack_button'),
                      icon: LucideIcons.sparkles,
                      title: '实况拆解',
                      subtitle: '拆出动态照片视频与封面，支持二次编辑或导出 MP4',
                      enabled: interactionsEnabled,
                      onTap: widget.onPickLiveUnpack,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Ui.s6),

              // Section 2: Recent Synthesis History
              SizedBox(
                height: 36,
                child: Row(
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.only(left: 2),
                      child: Text('最近记录', style: Ui.label),
                    ),
                    if (entries.isNotEmpty) ...<Widget>[
                      const SizedBox(width: Ui.s2),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Ui.surface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Ui.hairline),
                        ),
                        child: Text(
                          '${entries.length}',
                          style: Ui.mono.copyWith(
                            fontSize: 11.5,
                            color: Ui.textSecondary,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (entries.isNotEmpty)
                      Pressable(
                        key: const Key('history_clear_all_button'),
                        enabled: interactionsEnabled,
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
                                : Ui.surface,
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

              if (entries.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Ui.s5,
                    vertical: Ui.s6,
                  ),
                  decoration: BoxDecoration(
                    color: Ui.surface,
                    borderRadius: BorderRadius.circular(Ui.rLg),
                    border: Border.all(color: Ui.hairline),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Ui.bg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Ui.hairline),
                        ),
                        child: const Icon(
                          LucideIcons.clock,
                          size: 19,
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
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: List<Widget>.generate(entries.length, (int idx) {
                    final entry = entries[idx];
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: idx == entries.length - 1 ? 0 : Ui.s2,
                      ),
                      child: HistoryEntryTile(
                        entry: entry,
                        surfaceColor: Ui.surface,
                        enabled: interactionsEnabled,
                        onTap: () => widget.onSelectHistory(entry),
                        onDelete: () => unawaited(widget.onDeleteHistory(entry.id)),
                      ),
                    );
                  }),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      enabled: enabled,
      expandWidth: true,
      maxInsetPx: 3.5,
      minSize: const Size(0, 64),
      semanticLabel: '$title，$subtitle',
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Ui.s4,
          vertical: Ui.s3 + 2,
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Ui.bg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Ui.hairline),
              ),
              child: Icon(icon, size: 17, color: Ui.textPrimary),
            ),
            const SizedBox(width: Ui.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ui.label.copyWith(fontSize: 14.5),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Ui.caption.copyWith(color: Ui.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Ui.s2),
            const Icon(
              LucideIcons.chevronRight,
              size: 16,
              color: Ui.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
