import 'dart:async';

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../constants/app_branding.dart';
import '../models/app_preferences.dart';
import '../models/batch_task.dart';
import '../models/conversion_options.dart';
import '../theme/ui_tokens.dart';
import '../ui/minimal_switch.dart';
import '../ui/pressable.dart';
import '../ui/segmented_tabs.dart';

/// Third tab view for persisted synthesis defaults, local cache metrics,
/// and quick platform/share guidance.
class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.preferences,
    required this.onPreferencesChanged,
    required this.historyCount,
    required this.historyStorageBytes,
    required this.onClearHistory,
    required this.platformFormatSummary,
    this.enabled = true,
  });

  final AppPreferences preferences;
  final ValueChanged<AppPreferences> onPreferencesChanged;
  final int historyCount;
  final int historyStorageBytes;
  final Future<void> Function() onClearHistory;
  final String platformFormatSummary;
  final bool enabled;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  bool _confirmingClear = false;
  bool _clearing = false;
  Timer? _confirmResetTimer;

  @override
  void didUpdateWidget(covariant SettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.historyCount == 0 && _confirmingClear) {
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
    if (!widget.enabled || _clearing || widget.historyCount <= 0) return;
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
    final prefs = widget.preferences;
    final canClear = widget.enabled && !_clearing && widget.historyCount > 0;
    final storageSubtitle = widget.historyCount == 0
        ? '暂无本地缓存'
        : '${widget.historyCount} 条记录 · ${formatFileSize(widget.historyStorageBytes)}';

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
              // Group 1: Default Synthesis Preferences
              const _SectionHeader(label: '默认合成偏好'),
              _GroupedCard(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.all(Ui.s4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          '默认画质',
                          style: Ui.callout.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: Ui.s2),
                        SegmentedTabs<QualityPreset>(
                          key: const Key('settings_default_quality'),
                          items: QualityPreset.values,
                          selectedIndex: prefs.defaultQuality.index,
                          enabled: widget.enabled,
                          labelBuilder: (QualityPreset p) => p.segmentLabel,
                          onChanged: (int idx) {
                            widget.onPreferencesChanged(
                              prefs.copyWith(
                                defaultQuality: QualityPreset.values[idx],
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: Ui.s2),
                        Text(
                          prefs.defaultQuality.subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Ui.caption.copyWith(color: Ui.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  const _RowDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Ui.s4,
                      vertical: Ui.s3,
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                '默认保留原声',
                                style: Ui.callout.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '新建任务默认开启实况声音',
                                style: Ui.caption.copyWith(
                                  color: Ui.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Ui.s3),
                        MinimalSwitch(
                          key: const Key('settings_default_audio'),
                          value: prefs.defaultKeepAudio,
                          enabled: widget.enabled,
                          semanticLabel: '默认保留原声',
                          onChanged: (bool next) {
                            widget.onPreferencesChanged(
                              prefs.copyWith(defaultKeepAudio: next),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const _RowDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Ui.s4,
                      vertical: Ui.s3,
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                '默认保留拍摄时间与地点',
                                style: Ui.callout.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '写入原片创建时间与位置信息',
                                style: Ui.caption.copyWith(
                                  color: Ui.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Ui.s3),
                        MinimalSwitch(
                          key: const Key('settings_default_metadata'),
                          value: prefs.defaultPreserveMetadata,
                          enabled: widget.enabled,
                          semanticLabel: '默认保留拍摄时间与地点',
                          onChanged: (bool next) {
                            widget.onPreferencesChanged(
                              prefs.copyWith(defaultPreserveMetadata: next),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const _RowDivider(),
                  Padding(
                    padding: const EdgeInsets.all(Ui.s4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          '批量默认封面',
                          style: Ui.callout.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: Ui.s2),
                        SegmentedTabs<BatchCoverStrategy>(
                          key: const Key('settings_default_batch_cover'),
                          items: BatchCoverStrategy.values,
                          selectedIndex: prefs.defaultBatchCover.index,
                          height: 36,
                          fontSize: 12.5,
                          enabled: widget.enabled,
                          labelBuilder: (BatchCoverStrategy s) => s.label,
                          onChanged: (int idx) {
                            widget.onPreferencesChanged(
                              prefs.copyWith(
                                defaultBatchCover:
                                    BatchCoverStrategy.values[idx],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Ui.s5),

              // Group 2: Storage & Cache
              const _SectionHeader(label: '存储与缓存'),
              _GroupedCard(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Ui.s4,
                      vertical: Ui.s3,
                    ),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: Ui.bg,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Ui.hairline),
                          ),
                          child: const Icon(
                            LucideIcons.hardDrive,
                            size: 16,
                            color: Ui.textSecondary,
                          ),
                        ),
                        const SizedBox(width: Ui.s3),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                '本地历史与封面缓存',
                                style: Ui.callout.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                storageSubtitle,
                                style: Ui.caption.copyWith(
                                  color: Ui.textSecondary,
                                  fontFeatures: Ui.tabular,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Ui.s2),
                        Pressable(
                          key: const Key('settings_clear_history_button'),
                          enabled: canClear,
                          semanticLabel:
                              _confirmingClear ? '确认清空本地历史缓存' : '清空本地历史缓存',
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
                ],
              ),
              const SizedBox(height: Ui.s5),

              // Group 3: Tips & About
              const _SectionHeader(label: '使用提示与关于'),
              _GroupedCard(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.all(Ui.s4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '系统分享直达',
                          style: Ui.callout.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '在系统相册或文件 App 中点击「分享」选择 Unclip，可直达暗房、批量队列或自动拆解实况。',
                          style: Ui.caption.copyWith(
                            color: Ui.textSecondary,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const _RowDivider(),
                  Padding(
                    padding: const EdgeInsets.all(Ui.s4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '平台兼容',
                          style: Ui.callout.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.platformFormatSummary,
                          style: Ui.caption.copyWith(color: Ui.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  const _RowDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Ui.s4,
                      vertical: Ui.s3 + 2,
                    ),
                    child: Row(
                      children: <Widget>[
                        Text(
                          '版本',
                          style: Ui.callout.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Text(
                          '${AppBranding.appName} ${AppBranding.versionLabel}',
                          style: Ui.mono.copyWith(
                            fontSize: 12.5,
                            color: Ui.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: Ui.s2),
      child: Text(label, style: Ui.caption),
    );
  }
}

class _GroupedCard extends StatelessWidget {
  const _GroupedCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Ui.surface,
        borderRadius: BorderRadius.circular(Ui.rLg),
        border: Border.all(color: Ui.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) => Container(height: 1, color: Ui.hairline);
}
