import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import 'models/conversion_options.dart';
import 'services/live_photo_channel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LongLivePhotoApp());
}

class LongLivePhotoApp extends StatelessWidget {
  const LongLivePhotoApp({super.key, this.gateway});

  final LivePhotoConverterGateway? gateway;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '长实况',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF60A5FA),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: ConverterHomePage(gateway: gateway ?? NativeLivePhotoChannel()),
    );
  }
}

class ConverterHomePage extends StatefulWidget {
  const ConverterHomePage({super.key, required this.gateway});

  final LivePhotoConverterGateway gateway;

  @override
  State<ConverterHomePage> createState() => _ConverterHomePageState();
}

class _ConverterHomePageState extends State<ConverterHomePage> {
  final ImagePicker _imagePicker = ImagePicker();

  VideoPlayerController? _videoController;
  StreamSubscription<ConversionProgress>? _progressSub;

  String? _selectedVideoPath;
  String? _selectedFileName;
  int _sourceSizeBytes = 0;

  Duration _videoDuration = Duration.zero;
  Duration _currentPosition = Duration.zero;
  int _coverTimeMs = 0;

  QualityPreset _quality = QualityPreset.p1080;
  bool _keepAudio = true;

  bool _isLoadingVideo = false;
  bool _isConverting = false;
  ConversionProgress? _progress;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _progressSub = widget.gateway.progressStream.listen((event) {
      if (mounted && _isConverting) {
        setState(() {
          _progress = event;
        });
      }
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _videoController?.removeListener(_onVideoTick);
    _videoController?.dispose();
    super.dispose();
  }

  void _onVideoTick() {
    final ctrl = _videoController;
    if (ctrl == null || !mounted) return;
    final pos = ctrl.value.position;
    if ((pos - _currentPosition).inMilliseconds.abs() >= 80 ||
        !ctrl.value.isPlaying) {
      setState(() {
        _currentPosition = pos;
      });
    }
  }

  String get _platformDescription {
    if (kIsWeb) return 'Web 预览模式';
    if (Platform.isIOS) {
      return 'iPhone 模式 · 直出 Apple Live Photo 存入“照片”';
    }
    if (Platform.isAndroid) {
      return '安卓模式 · 直出 Motion Photo 动态照片存入系统相册';
    }
    return '桌面调试模式';
  }

  Future<void> _pickFromGallery() async {
    if (_isConverting) return;
    try {
      setState(() {
        _errorMessage = null;
      });
      final XFile? picked = await _imagePicker.pickVideo(
        source: ImageSource.gallery,
      );
      if (picked == null) return;
      await _loadVideoFile(picked.path, displayName: picked.name);
    } on PlatformException catch (e) {
      setState(() {
        _errorMessage = '读取相册视频失败：${e.message ?? e.code}';
      });
    } catch (e) {
      setState(() {
        _errorMessage = '读取相册视频失败：$e';
      });
    }
  }

  Future<void> _pickFromFiles() async {
    if (_isConverting) return;
    try {
      setState(() {
        _errorMessage = null;
      });
      final List<PlatformFile> files = await FilePicker.pickFiles(
        type: FileType.video,
      );
      if (files.isEmpty || files.first.path == null) return;
      await _loadVideoFile(
        files.first.path!,
        displayName: files.first.name,
      );
    } on PlatformException catch (e) {
      setState(() {
        _errorMessage = '读取视频文件失败：${e.message ?? e.code}';
      });
    } catch (e) {
      setState(() {
        _errorMessage = '读取视频文件失败：$e';
      });
    }
  }

  Future<void> _loadVideoFile(String path, {String? displayName}) async {
    setState(() {
      _isLoadingVideo = true;
      _errorMessage = null;
    });

    final oldController = _videoController;
    oldController?.removeListener(_onVideoTick);

    try {
      final file = File(path);
      final size = await file.length();
      final ctrl = VideoPlayerController.file(file);
      await ctrl.initialize();
      ctrl.addListener(_onVideoTick);

      final totalMs = ctrl.value.duration.inMilliseconds;
      final defaultCoverMs = totalMs > 600 ? 500 : 0;
      if (defaultCoverMs > 0) {
        await ctrl.seekTo(Duration(milliseconds: defaultCoverMs));
      }

      if (!mounted) {
        await ctrl.dispose();
        return;
      }

      setState(() {
        _videoController = ctrl;
        _selectedVideoPath = path;
        _selectedFileName =
            displayName ?? path.split(RegExp(r'[/\\]')).last;
        _sourceSizeBytes = size;
        _videoDuration = ctrl.value.duration;
        _currentPosition = Duration(milliseconds: defaultCoverMs);
        _coverTimeMs = defaultCoverMs;
        _isLoadingVideo = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _videoController = null;
          _isLoadingVideo = false;
          _errorMessage = '无法解析该视频格式：$e';
        });
      }
    } finally {
      await oldController?.dispose();
    }
  }

  Future<void> _seekCoverTo(int targetMs) async {
    final ctrl = _videoController;
    if (ctrl == null) return;
    final maxMs = _videoDuration.inMilliseconds;
    final clamped = targetMs.clamp(0, maxMs > 0 ? maxMs : 0);
    setState(() {
      _coverTimeMs = clamped;
    });
    if (ctrl.value.isPlaying) {
      await ctrl.pause();
    }
    await ctrl.seekTo(Duration(milliseconds: clamped));
  }

  Future<void> _startConversion() async {
    final path = _selectedVideoPath;
    if (path == null || _isConverting) return;

    final ctrl = _videoController;
    if (ctrl != null && ctrl.value.isPlaying) {
      await ctrl.pause();
    }

    setState(() {
      _isConverting = true;
      _errorMessage = null;
      _progress = const ConversionProgress(
        stage: 'preparing',
        progress: 0.02,
        message: '正在准备视频与实况元数据...',
      );
    });

    try {
      final result = await widget.gateway.convertAndSave(
        videoPath: path,
        coverTimeMs: _coverTimeMs,
        quality: _quality,
        keepAudio: _keepAudio,
      );

      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _progress = null;
      });

      await _showSuccessDialog(result);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _progress = null;
        _errorMessage = e.message ?? '转换失败（${e.code}）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _progress = null;
        _errorMessage = '转换出错：$e';
      });
    }
  }

  Future<void> _showSuccessDialog(ConversionResult result) async {
    final seconds = (result.elapsedMs / 1000).toStringAsFixed(1);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(
          Icons.check_circle_rounded,
          size: 48,
          color: Colors.green,
        ),
        title: const Text('已成功存入手机相册'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('输出格式：${result.platformFormat}'),
            const SizedBox(height: 6),
            Text('视频总长：${formatPreciseDuration(_videoDuration)}（完整未截断）'),
            const SizedBox(height: 6),
            Text('成品体积：${formatFileSize(result.outputSizeBytes)}'),
            const SizedBox(height: 6),
            Text('处理耗时：$seconds 秒'),
            const SizedBox(height: 12),
            Text(
              '现在打开手机自带“照片/相册”，找到最新一张实况照片，按住屏幕即可从头到尾完整播放。',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ctrl = _videoController;
    final hasVideo = ctrl != null && ctrl.value.isInitialized;

    return Scaffold(
      appBar: AppBar(
        title: const Text('长实况 · 全时长视频转实况'),
        centerTitle: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            _buildPlatformBanner(theme),
            const SizedBox(height: 12),
            _buildSourcePickerRow(),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              _buildErrorCard(theme, _errorMessage!),
            ],
            const SizedBox(height: 16),
            if (_isLoadingVideo)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (!hasVideo)
              _buildEmptyGuideCard(theme)
            else ...[
              _buildVideoPreviewCard(theme, ctrl),
              const SizedBox(height: 16),
              _buildCoverSelectorCard(theme),
            ],
            const SizedBox(height: 16),
            _buildQualitySelectorCard(theme),
            const SizedBox(height: 12),
            _buildAudioSwitchCard(theme),
            const SizedBox(height: 20),
            if (_isConverting && _progress != null) ...[
              _buildProgressCard(theme, _progress!),
              const SizedBox(height: 16),
            ],
            SizedBox(
              height: 54,
              child: FilledButton.icon(
                key: const Key('convert_save_button'),
                onPressed:
                    hasVideo && !_isConverting ? _startConversion : null,
                icon: _isConverting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : const Icon(Icons.motion_photos_on_rounded),
                label: Text(
                  _isConverting ? '正在合成实况照片...' : '一键生成并存入系统相册',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlatformBanner(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.verified_rounded,
            size: 18,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _platformDescription,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourcePickerRow() {
    return Row(
      children: [
        Expanded(
          child: FilledButton.tonalIcon(
            key: const Key('pick_gallery_button'),
            onPressed: _isConverting ? null : _pickFromGallery,
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('从相册选视频'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('pick_file_button'),
            onPressed: _isConverting ? null : _pickFromFiles,
            icon: const Icon(Icons.folder_open_rounded),
            label: const Text('从文件选视频'),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorCard(ThemeData theme, String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyGuideCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
        child: Column(
          children: [
            Icon(
              Icons.video_collection_outlined,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              '导入任意长度的视频开始制作',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '不设 3 秒或 5 秒限制，几秒到几十分钟均可完整合成单张实况图，存入系统相册长按从头播到尾。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPreviewCard(ThemeData theme, VideoPlayerController ctrl) {
    final size = ctrl.value.size;
    final aspect = ctrl.value.aspectRatio > 0 ? ctrl.value.aspectRatio : 16 / 9;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: AspectRatio(
                aspectRatio: aspect,
                child: VideoPlayer(ctrl),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                IconButton.filledTonal(
                  onPressed: _isConverting
                      ? null
                      : () async {
                          if (ctrl.value.isPlaying) {
                            await ctrl.pause();
                          } else {
                            await ctrl.play();
                          }
                          setState(() {});
                        },
                  icon: Icon(
                    ctrl.value.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _selectedFileName ?? '已选视频',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${formatPreciseDuration(_currentPosition)} / ${formatPreciseDuration(_videoDuration)}'
                        '  ·  ${size.width.toInt()}×${size.height.toInt()}'
                        '  ·  ${formatFileSize(_sourceSizeBytes)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoverSelectorCard(ThemeData theme) {
    final maxMs = _videoDuration.inMilliseconds;
    final sliderMax = maxMs > 0 ? maxMs.toDouble() : 1.0;
    final sliderVal = _coverTimeMs.clamp(0, maxMs > 0 ? maxMs : 1).toDouble();

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '静态封面帧时间点',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  formatPreciseDuration(Duration(milliseconds: _coverTimeMs)),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            Slider(
              value: sliderVal,
              min: 0,
              max: sliderMax,
              onChanged: _isConverting
                  ? null
                  : (val) {
                      _seekCoverTo(val.round());
                    },
            ),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _isConverting
                      ? null
                      : () => _seekCoverTo(_coverTimeMs - 100),
                  child: const Text('-0.1s'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _isConverting
                      ? null
                      : () => _seekCoverTo(_coverTimeMs + 100),
                  child: const Text('+0.1s'),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _isConverting
                      ? null
                      : () => _seekCoverTo(_currentPosition.inMilliseconds),
                  icon: const Icon(Icons.push_pin_outlined, size: 18),
                  label: const Text('取当前画面为封面'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQualitySelectorCard(ThemeData theme) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                '画质与体积策略',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            RadioGroup<QualityPreset>(
              groupValue: _quality,
              onChanged: (QualityPreset? val) {
                if (!_isConverting && val != null) {
                  setState(() {
                    _quality = val;
                  });
                }
              },
              child: Column(
                children: [
                  for (final preset in QualityPreset.values)
                    RadioListTile<QualityPreset>(
                      value: preset,
                      enabled: !_isConverting,
                      title: Text(
                        preset.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(preset.subtitle),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioSwitchCard(ThemeData theme) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SwitchListTile(
        value: _keepAudio,
        onChanged: _isConverting
            ? null
            : (val) {
                setState(() {
                  _keepAudio = val;
                });
              },
        secondary: Icon(
          _keepAudio ? Icons.volume_up_rounded : Icons.volume_off_rounded,
          color: theme.colorScheme.primary,
        ),
        title: const Text(
          '保留原视频声音',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: const Text('长按实况照片时同步播放视频原声'),
      ),
    );
  }

  Widget _buildProgressCard(ThemeData theme, ConversionProgress prog) {
    final pct = (prog.progress * 100).clamp(0, 100).toStringAsFixed(0);
    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    prog.message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '$pct%',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: prog.progress > 0 ? prog.progress : null,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
          ],
        ),
      ),
    );
  }
}
