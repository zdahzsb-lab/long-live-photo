import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/ui_tokens.dart';
import '../ui/buttons.dart';
import '../ui/pressable.dart';

/// Editorial Swiss-minimalist welcome screen.
///
/// Follows `taste.md` restraint rules: generous breathing room, zero gradients
/// or decorative animations, clear typographic hierarchy, and thumb-anchored
/// primary/secondary actions at the bottom of the screen.
class EmptyStudioView extends StatelessWidget {
  const EmptyStudioView({
    super.key,
    required this.platformTag,
    required this.isBusy,
    required this.onPickGallery,
    required this.onPickFiles,
    required this.onPickBatch,
    required this.onPickLiveUnpack,
  });

  final String platformTag;
  final bool isBusy;
  final VoidCallback onPickGallery;
  final VoidCallback onPickFiles;
  final VoidCallback onPickBatch;
  final VoidCallback onPickLiveUnpack;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final compact =
            !constraints.hasBoundedHeight || constraints.maxHeight < 460;

        final heroBlock = Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Precision geometric viewfinder mark
            ExcludeSemantics(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Ui.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Ui.hairlineStrong),
                ),
                child: const Icon(
                  LucideIcons.aperture,
                  size: 28,
                  color: Ui.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: Ui.s6),

            const Text(
              '长视频转实况照片',
              textAlign: TextAlign.center,
              style: Ui.largeTitle,
            ),
            const SizedBox(height: Ui.s2 + 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Ui.s4),
              child: Text(
                '突破 3 秒时长限制，完整保留画面与原声，直接存入系统相册长按播放。',
                textAlign: TextAlign.center,
                style: Ui.body,
              ),
            ),
            const SizedBox(height: Ui.s6),

            // Clean 3-column hairline spec strip (Swiss grid, no badge clutter)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Ui.s3,
                vertical: Ui.s3 + 2,
              ),
              decoration: BoxDecoration(
                color: Ui.surface,
                borderRadius: BorderRadius.circular(Ui.rMd),
                border: Border.all(color: Ui.hairline),
              ),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: _SpecItem(title: '不限时长', subtitle: '整段无裁剪'),
                  ),
                  Container(width: 1, height: 28, color: Ui.hairline),
                  const Expanded(
                    child: _SpecItem(title: '原画直通', subtitle: '秒级零重压'),
                  ),
                  Container(width: 1, height: 28, color: Ui.hairline),
                  const Expanded(
                    child: _SpecItem(title: '原生有声', subtitle: '直入系统相册'),
                  ),
                ],
              ),
            ),
          ],
        );

        final actionBlock = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              platformTag,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ui.caption,
            ),
            const SizedBox(height: Ui.s4),
            PrimaryButton(
              key: const Key('pick_gallery_button'),
              label: '从相册选视频',
              icon: LucideIcons.images,
              enabled: !isBusy,
              onTap: onPickGallery,
            ),
            const SizedBox(height: Ui.s3),
            Row(
              children: <Widget>[
                Expanded(
                  child: _CompactActionTile(
                    key: const Key('pick_batch_button'),
                    label: '批量多选',
                    icon: LucideIcons.layers,
                    enabled: !isBusy,
                    onTap: onPickBatch,
                  ),
                ),
                const SizedBox(width: Ui.s2),
                Expanded(
                  child: _CompactActionTile(
                    key: const Key('pick_live_unpack_button'),
                    label: '实况拆解',
                    icon: LucideIcons.sparkles,
                    enabled: !isBusy,
                    onTap: onPickLiveUnpack,
                  ),
                ),
                const SizedBox(width: Ui.s2),
                Expanded(
                  child: _CompactActionTile(
                    key: const Key('pick_file_button'),
                    label: '文件导入',
                    icon: LucideIcons.folderOpen,
                    enabled: !isBusy,
                    onTap: onPickFiles,
                  ),
                ),
              ],
            ),
          ],
        );

        if (compact) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: Ui.s3),
              heroBlock,
              const SizedBox(height: Ui.s6),
              actionBlock,
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: Center(child: heroBlock)),
            actionBlock,
          ],
        );
      },
    );
  }
}

class _CompactActionTile extends StatelessWidget {
  const _CompactActionTile({
    super.key,
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      enabled: enabled,
      expandWidth: true,
      maxInsetPx: 4.0,
      minSize: const Size(0, Ui.minTarget),
      semanticLabel: label,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: Ui.s2),
        decoration: BoxDecoration(
          color: Ui.surface,
          borderRadius: BorderRadius.circular(Ui.rMd),
          border: Border.all(color: Ui.hairline),
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 15, color: Ui.textSecondary),
                const SizedBox(width: 5),
                Text(
                  label,
                  maxLines: 1,
                  style: Ui.callout.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Ui.textPrimary,
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

class _SpecItem extends StatelessWidget {
  const _SpecItem({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Ui.callout.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Ui.caption.copyWith(fontSize: 11.5),
        ),
      ],
    );
  }
}
