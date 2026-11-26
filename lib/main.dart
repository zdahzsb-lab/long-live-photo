import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import 'constants/app_branding.dart';
import 'models/conversion_options.dart';
import 'services/live_photo_channel.dart';
import 'widgets/empty_studio_view.dart';
import 'widgets/filmstrip_scrubber.dart';
import 'widgets/studio_background.dart';
import 'widgets/video_stage_card.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassWidgets.initialize();

  runApp(
    LiquidGlassWidgets.wrap(
      adaptiveQuality: true,
      respectSystemAccessibility: true,
      brightnessResolver: Theme.maybeBrightnessOf,
      theme: const GlassThemeData.ios27(),
      child: const LongLivePhotoApp(),
    ),
  );
}

class LongLivePhotoApp extends StatelessWidget {
  const LongLivePhotoApp({super.key, this.gateway});

  final LivePhotoConverterGateway? gateway;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppBranding.appName,
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A84FF),
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
  int _sourceSizeBytes = 0;
  List<Uint8List> _thumbnails = const <Uint8List>[];

  Duration _videoDuration = Duration.zero;
  Duration _currentPosition = Duration.zero;
  int _coverTimeMs = 0;

  QualityPreset _quality = QualityPreset.p1080;
  bool _keepAudio = true;

  bool _isLoadingVideo = false;
  bool _isConverting = false;
  ConversionProgress? _progress;

  @override
  void initState() {
    super.initState();
    _progressSub = widget.gateway.progressStream.listen((ConversionProgress ev) {
      if (mounted && _isConverting) {
        setState(() {
          _progress = ev;
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

  String get _platformTag {
    if (kIsWeb) return 'Web 预览环境';
    if (Platform.isIOS) return 'iPhone · Apple Live Photo 直入相册';
    if (Platform.isAndroid) return 'Android · 双标准 Motion Photo 动态照片';
    return 'Studio 预览模式';
  }

  void _showErrorToast(String msg) {
    if (!mounted) return;
    GlassToast.show(
      context,
      message: msg,
      type: GlassToastType.error,
      position: GlassToastPosition.top,
    );
  }

  Future<void> _pickFromGallery() async {
    if (_isConverting) return;
    try {
      final XFile? picked = await _imagePicker.pickVideo(
        source: ImageSource.gallery,
      );
      if (picked == null) return;
      await _loadVideoFile(picked.path);
    } on PlatformException catch (e) {
      _showErrorToast('读取相册失败：${e.message ?? e.code}');
    } catch (e) {
      _showErrorToast('读取相册失败：$e');
    }
  }

  Future<void> _pickFromFiles() async {
    if (_isConverting) return;
    try {
      final List<PlatformFile> files = await FilePicker.pickFiles(
        type: FileType.video,
      );
      if (files.isEmpty || files.first.path == null) return;
      await _loadVideoFile(files.first.path!);
    } on PlatformException catch (e) {
      _showErrorToast('导入视频失败：${e.message ?? e.code}');
    } catch (e) {
      _showErrorToast('导入视频失败：$e');
    }
  }

  Future<void> _loadVideoFile(String path) async {
    setState(() {
      _isLoadingVideo = true;
      _thumbnails = const <Uint8List>[];
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
        _sourceSizeBytes = size;
        _videoDuration = ctrl.value.duration;
        _currentPosition = Duration(milliseconds: defaultCoverMs);
        _coverTimeMs = defaultCoverMs;
        _isLoadingVideo = false;
      });

      // Extract filmstrip frames asynchronously without blocking preview
      unawaited(_loadThumbnails(path));
    } catch (e) {
      if (mounted) {
        setState(() {
          _videoController = null;
          _isLoadingVideo = false;
        });
        _showErrorToast('无法解析该视频：$e');
      }
    } finally {
      await oldController?.dispose();
    }
  }

  Future<void> _loadThumbnails(String path) async {
    final frames = await widget.gateway.extractThumbnails(
      videoPath: path,
      count: 8,
    );
    if (mounted && _selectedVideoPath == path) {
      setState(() {
        _thumbnails = frames;
      });
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

  Future<void> _togglePlay() async {
    final ctrl = _videoController;
    if (ctrl == null || _isConverting) return;
    if (ctrl.value.isPlaying) {
      await ctrl.pause();
    } else {
      await ctrl.play();
    }
    if (mounted) setState(() {});
  }

  void _toggleAudio() {
    if (_isConverting) return;
    setState(() {
      _keepAudio = !_keepAudio;
      _videoController?.setVolume(_keepAudio ? 1.0 : 0.0);
    });
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
      _progress = const ConversionProgress(
        stage: 'preparing',
        progress: 0.03,
        message: '正在初始化实况合成管线...',
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

      final seconds = (result.elapsedMs / 1000).toStringAsFixed(1);
      await GlassDialog.show(
        context: context,
        title: '已存入系统相册',
        message: '总时长 ${formatPreciseDuration(_videoDuration)} 完整未截断\n'
            '成品体积 ${formatFileSize(result.outputSizeBytes)} · 耗时 $seconds 秒\n\n'
            '打开手机“照片/相册”按住画面即可从头播放到尾。',
        actions: <GlassDialogAction>[
          GlassDialogAction(
            label: '完成',
            isPrimary: true,
            tintColor: const Color(0xFF0A84FF),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _progress = null;
      });
      _showErrorToast(e.message ?? '合成失败（${e.code}）');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _progress = null;
      });
      _showErrorToast('合成出错：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _videoController;
    final hasVideo = ctrl != null && ctrl.value.isInitialized;

    return GlassScaffold(
      background: const StudioBackground(),
      statusBarStyle: GlassStatusBarStyle.light,
      appBar: GlassAppBar(
        surfaceStyle: GlassAppBarSurfaceStyle.transparent,
        title: const Text(
          AppBranding.appName,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Color(0xFFF8FAFC),
            letterSpacing: -0.2,
          ),
        ),
        actions: <Widget>[
          if (hasVideo)
            GlassPullDownButton(
              icon: const Icon(
                LucideIcons.folderPlus,
                size: 18,
                color: Color(0xFFF8FAFC),
              ),
              semanticLabel: '更换视频素材',
              items: <Widget>[
                GlassMenuItem(
                  title: '从相册重选视频',
                  icon: const Icon(LucideIcons.images, size: 18),
                  onTap: _pickFromGallery,
                ),
                GlassMenuItem(
                  title: '从文件管理器导入',
                  icon: const Icon(LucideIcons.folderOpen, size: 18),
                  onTap: _pickFromFiles,
                ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // Adaptive one-screen layout on portrait phones; scrollable fallback on tiny/landscape viewports
              final isCompactViewport = constraints.maxHeight < 520;
              final content = _buildStudioBody(
                ctrl: ctrl,
                hasVideo: hasVideo,
                useFlexibleStage: !isCompactViewport,
              );
              if (isCompactViewport) {
                return SingleChildScrollView(child: content);
              }
              return content;
            },
          ),
        ),
      ),
    );
  }

  Widget _buildStudioBody({
    required VideoPlayerController? ctrl,
    required bool hasVideo,
    required bool useFlexibleStage,
  }) {
    final Widget stageArea;
    if (_isLoadingVideo) {
      stageArea = Center(
        child: GlassProgressIndicator.circular(
          size: 36,
          useOwnLayer: true,
          semanticLabel: '正在解析视频',
        ),
      );
    } else if (!hasVideo || ctrl == null) {
      stageArea = EmptyStudioView(
        platformTag: _platformTag,
        isBusy: _isConverting,
        onPickGallery: _pickFromGallery,
        onPickFiles: _pickFromFiles,
      );
    } else {
      stageArea = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (useFlexibleStage)
            Expanded(
              child: VideoStageCard(
                controller: ctrl,
                currentPosition: _currentPosition,
                totalDuration: _videoDuration,
                sourceSizeBytes: _sourceSizeBytes,
                keepAudio: _keepAudio,
                isConverting: _isConverting,
                onTogglePlay: _togglePlay,
                onToggleAudio: _toggleAudio,
              ),
            )
          else
            SizedBox(
              height: 240,
              child: VideoStageCard(
                controller: ctrl,
                currentPosition: _currentPosition,
                totalDuration: _videoDuration,
                sourceSizeBytes: _sourceSizeBytes,
                keepAudio: _keepAudio,
                isConverting: _isConverting,
                onTogglePlay: _togglePlay,
                onToggleAudio: _toggleAudio,
              ),
            ),
          const SizedBox(height: 14),
          FilmstripScrubber(
            thumbnails: _thumbnails,
            coverTimeMs: _coverTimeMs,
            totalDurationMs: _videoDuration.inMilliseconds,
            enabled: !_isConverting,
            onScrubToMs: _seekCoverTo,
            onUseCurrentFrame: () =>
                _seekCoverTo(_currentPosition.inMilliseconds),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: useFlexibleStage ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (useFlexibleStage) Expanded(child: stageArea) else stageArea,
        const SizedBox(height: 16),

        // Single-row Liquid Glass Segmented Control (placed directly on platter per Rule 2)
        GlassSegmentedControl(
          height: 40,
          borderRadius: 20,
          useOwnLayer: true,
          selectedIndex: _quality.index,
          onSegmentSelected: (int index) {
            if (_isConverting) return;
            setState(() {
              _quality = QualityPreset.values[index];
            });
          },
          segments: <GlassSegment>[
            for (final preset in QualityPreset.values)
              GlassSegment(label: preset.segmentLabel),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _quality.subtitle,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 11.5,
            color: Color(0x8CE2E8F0),
          ),
        ),
        const SizedBox(height: 14),

        if (_isConverting && _progress != null) ...<Widget>[
          GlassProgressIndicator.linear(
            value: _progress!.progress > 0 ? _progress!.progress : null,
            height: 6,
            useOwnLayer: true,
          ),
          const SizedBox(height: 8),
        ],

        // Primary Liquid Glass Action Pill
        GlassButton.custom(
          key: const Key('convert_save_button'),
          height: 54,
          enabled: hasVideo && !_isConverting,
          useOwnLayer: true,
          style: GlassButtonStyle.prominent,
          tintColor: const Color(0xFF0A84FF),
          shape: const LiquidRoundedSuperellipse(borderRadius: 27),
          onTap: _startConversion,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                _isConverting ? LucideIcons.loader : LucideIcons.sparkles,
                size: 18,
                color: Colors.white,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _isConverting
                      ? (_progress?.message ?? '正在合成实况照片...')
                      : '生成实况并存入系统相册',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
