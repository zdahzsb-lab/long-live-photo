import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../models/conversion_options.dart';
import '../theme/ui_tokens.dart';
import 'buttons.dart';

/// Minimalist bottom sheet shown when Live Photo synthesis completes,
/// keeping the primary dismissal action comfortably in the thumb zone.
Future<void> showConversionResultSheet({
  required BuildContext context,
  required Duration duration,
  required ConversionResult result,
  PlaybackSpeedPreset playbackSpeed = PlaybackSpeedPreset.normal,
}) {
  final elapsedSec = (result.elapsedMs / 1000).toStringAsFixed(1);
  final hasSpeed = playbackSpeed.isModified;

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ui.surface,
    barrierColor: const Color(0xA6000000),
    builder: (BuildContext sheetContext) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Ui.s6, Ui.s2, Ui.s6, Ui.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0x1F34D399),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0x4D34D399)),
                    ),
                    child: const Icon(
                      LucideIcons.check,
                      size: 18,
                      color: Ui.liveActive,
                    ),
                  ),
                  const SizedBox(width: Ui.s3),
                  const Expanded(
                    child: Text('已存入系统相册', style: Ui.title),
                  ),
                  if (hasSpeed)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Ui.bg,
                        borderRadius: BorderRadius.circular(Ui.rSm),
                        border: Border.all(color: Ui.hairlineStrong),
                      ),
                      child: Text(
                        playbackSpeed.shortTag,
                        style: Ui.mono.copyWith(
                          fontSize: 11.5,
                          color: Ui.textPrimary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Ui.s5),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Ui.s4,
                  vertical: Ui.s3 + 2,
                ),
                decoration: BoxDecoration(
                  color: Ui.bg,
                  borderRadius: BorderRadius.circular(Ui.rMd),
                  border: Border.all(color: Ui.hairline),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: _MetricCell(
                        label: hasSpeed ? '输出时长' : '完整时长',
                        value: formatPreciseDuration(duration),
                      ),
                    ),
                    Container(width: 1, height: 28, color: Ui.hairline),
                    Expanded(
                      child: _MetricCell(
                        label: '实况体积',
                        value: formatFileSize(result.outputSizeBytes),
                      ),
                    ),
                    Container(width: 1, height: 28, color: Ui.hairline),
                    Expanded(
                      child: _MetricCell(
                        label: '合成耗时',
                        value: '${elapsedSec}s',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Ui.s4),
              const Text(
                '打开系统「照片 / 相册」，按住画面即可从头播放到尾。',
                style: Ui.body,
              ),
              const SizedBox(height: Ui.s5),
              PrimaryButton(
                key: const Key('result_done_button'),
                label: '完成',
                onTap: () => Navigator.of(sheetContext).pop(),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _MetricCell extends StatelessWidget {
  const _MetricCell({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: Ui.caption),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Ui.mono.copyWith(fontSize: 14),
        ),
      ],
    );
  }
}
