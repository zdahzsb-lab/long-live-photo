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
import 'theme/studio_tokens.dart';
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
    final baseDark = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: StudioTokens.bgDeep,
      colorScheme: ColorScheme.fromSeed(
        seedColor: StudioTokens.accentPrimary,
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    );

    return MaterialApp(
      title: AppBranding.appName,
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: baseDark.copyWith(
        textTheme: baseDark.textTheme.apply(
          bodyColor: StudioTokens.textPrimary,
          displayColor: StudioTokens.textPrimary,
          decoration: TextDecoration.none,
          decorationColor: const Color(0x00000000),
        ),
      ),
      // Guarantees Material + underline-free DefaultTextStyle above Navigator
      // & Overlay so GlassScaffold, GlassDialog, and GlassToast never inherit
      // WidgetsApp's yellow double-underline fallback text style.
      builder: (BuildContext context, Widget? child) {
        return DefaultTextStyle(
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            height: 1.45,
            color: StudioTokens.textPrimary,
            decoration: TextDecoration.none,
            decorationColor: Color(0x00000000),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
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
    if (Platform.isAndroid) return 'Android · 双标准动态照片直入相册';
    return 'Studio 预览模式';
  }

  void _showErrorToast(String msg) {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    GlassToast.show(
      context,
      message: msg,
      type: GlassToastType.error,
      position: GlassToastPosition.top,
    );
  }

  Future<void> _pickFromGallery() async {
    if (_isConverting) return;
    HapticFeedback.selectionClick();
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
    HapticFeedback.selectionClick();
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
      await ctrl.setVolume(_keepAudio ? 1.0 : 0.0);
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
    HapticFeedback.selectionClick();
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

    HapticFeedback.mediumImpact();
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
      HapticFeedback.mediumImpact();
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
            '打开手机“照片/相册”按住画面即可完整回放。',
        actions: <GlassDialogAction>[
          GlassDialogAction(
            label: '完成',
            isPrimary: true,
            tintColor: StudioTokens.accentPrimary,
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
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final scaledBodyPx = MediaQuery.textScalerOf(context).scale(14.0);

    return GlassScaffold(
      background: const StudioBackground(),
      statusBarStyle: GlassStatusBarStyle.light,
      // Critical fix: keep body strictly below AppBar so GlassAppBar never
      // overlaps VideoStageCard or intercepts top-left audio pill taps!
      extendBody: false,
      edgeFade: false,
      appBar: GlassAppBar(
        surfaceStyle: GlassAppBarSurfaceStyle.transparent,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ExcludeSemantics(
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      StudioTokens.accentCyan,
                      StudioTokens.accentPrimary,
                    ],
                  ),
                  border: Border.all(
                    color: StudioTokens.borderStrong,
                    width: 0.8,
                  ),
                ),
                child: const Icon(
                  LucideIcons.aperture,
                  size: 13,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              AppBranding.appName,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: StudioTokens.textPrimary,
                letterSpacing: -0.2,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          if (hasVideo && !_isConverting)
            GlassPullDownButton(
              icon: const Icon(
                LucideIcons.folderPlus,
                size: 18,
                color: StudioTokens.textPrimary,
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
        top: false,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final horizontalPad = constraints.maxWidth >= 600 ? 28.0 : 16.0;
            final isCompactViewport =
                constraints.maxHeight < 560 || scaledBodyPx > 18.0;

            final studioChild = AnimatedSwitcher(
              duration: reduceMotion
                  ? Duration.zero
                  : StudioTokens.stateDuration,
              switchInCurve: StudioTokens.curveOutExpo,
              switchOutCurve: Curves.easeInCubic,
              child: _buildActiveStateView(
                ctrl: ctrl,
                hasVideo: hasVideo,
                useFlexibleStage: !isCompactViewport,
                reduceMotion: reduceMotion,
              ),
            );

            final padded = Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPad,
                    8,
                    horizontalPad,
                    16,
                  ),
                  child: studioChild,
                ),
              ),
            );

            if (isCompactViewport) {
              return SingleChildScrollView(child: padded);
            }
            return padded;
          },
        ),
      ),
    );
  }

  Widget _buildActiveStateView({
    required VideoPlayerController? ctrl,
    required bool hasVideo,
    required bool useFlexibleStage,
    required bool reduceMotion,
  }) {
    if (_isLoadingVideo) {
      return Center(
        key: const ValueKey<String>('studio_loading'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            GlassProgressIndicator.circular(
              size: 38,
              useOwnLayer: true,
              semanticLabel: '正在解析视频',
            ),
            const SizedBox(height: 14),
            const Text(
              '正在解析视频帧与音轨...',
              style: TextStyle(
                fontSize: 13.5,
                color: StudioTokens.textSecondary,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      );
    }

    if (!hasVideo || ctrl == null) {
      return KeyedSubtree(
        key: const ValueKey<String>('studio_empty'),
        child: EmptyStudioView(
          platformTag: _platformTag,
          isBusy: _isConverting,
          onPickGallery: _pickFromGallery,
          onPickFiles: _pickFromFiles,
        ),
      );
    }

    final estimatedBytes = _quality.estimateOutputBytes(
      sourceSizeBytes: _sourceSizeBytes,
      duration: _videoDuration,
      keepAudio: _keepAudio,
    );

    final stageWidget = VideoStageCard(
      controller: ctrl,
      currentPosition: _currentPosition,
      totalDuration: _videoDuration,
      sourceSizeBytes: _sourceSizeBytes,
      keepAudio: _keepAudio,
      isConverting: _isConverting,
      onTogglePlay: _togglePlay,
      onToggleAudio: _toggleAudio,
    );

    return Column(
      key: const ValueKey<String>('studio_editor'),
      mainAxisSize: useFlexibleStage ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (useFlexibleStage)
          Expanded(child: stageWidget)
        else
          SizedBox(height: 260, child: stageWidget),
        const SizedBox(height: 12),

        // 1. Cover Filmstrip Console
        FilmstripScrubber(
          thumbnails: _thumbnails,
          coverTimeMs: _coverTimeMs,
          totalDurationMs: _videoDuration.inMilliseconds,
          enabled: !_isConverting,
          onScrubToMs: _seekCoverTo,
          onUseCurrentFrame: () =>
              _seekCoverTo(_currentPosition.inMilliseconds),
        ),
        const SizedBox(height: 12),

        // 2. Liquid Glass Quality Segmented Control (directly on platter per Rule 2)
        GlassSegmentedControl(
          height: 44,
          borderRadius: 22,
          useOwnLayer: true,
          selectedIndex: _quality.index,
          onSegmentSelected: (int index) {
            if (_isConverting) return;
            HapticFeedback.selectionClick();
            setState(() {
              _quality = QualityPreset.values[index];
            });
          },
          segments: <GlassSegment>[
            for (final preset in QualityPreset.values)
              GlassSegment(label: preset.segmentLabel),
          ],
        ),
        const SizedBox(height: 8),

        // 3. Animated Quality Description + Estimated Output Size Readout
        AnimatedSwitcher(
          duration: reduceMotion ? Duration.zero : StudioTokens.microDuration,
          switchInCurve: StudioTokens.curveOutExpo,
          child: Row(
            key: ValueKey<String>('${_quality.wireValue}_$_keepAudio'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Flexible(
                child: Text(
                  _quality.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: StudioTokens.textMuted,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              if (estimatedBytes > 0) ...<Widget>[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: StudioTokens.surfaceSubtle,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: StudioTokens.borderSubtle,
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    '预计 ${formatFileSize(estimatedBytes)}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontFeatures: <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                      fontWeight: FontWeight.w600,
                      color: StudioTokens.accentIce,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 4. Smooth Progress Bar During Conversion
        AnimatedSize(
          duration: reduceMotion ? Duration.zero : StudioTokens.microDuration,
          curve: StudioTokens.curveOutExpo,
          child: (_isConverting && _progress != null)
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      GlassProgressIndicator.linear(
                        value: _progress!.progress > 0
                            ? _progress!.progress
                            : null,
                        height: 6,
                        useOwnLayer: true,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              _progress!.message,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: StudioTokens.textSecondary,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                          Text(
                            '${(_progress!.progress * 100).round()}%',
                            style: const TextStyle(
                              fontSize: 12,
                              fontFeatures: <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                              fontWeight: FontWeight.w700,
                              color: StudioTokens.accentIce,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),

        // 5. Primary Liquid Glass Action Pill with Cinema Cobalt Glow
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(28)),
            boxShadow: _isConverting
                ? const <BoxShadow>[]
                : const <BoxShadow>[
                    BoxShadow(
                      color: StudioTokens.accentGlow,
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
          ),
          child: GlassButton.custom(
            key: const Key('convert_save_button'),
            height: 54,
            enabled: !_isConverting,
            useOwnLayer: true,
            style: GlassButtonStyle.prominent,
            tintColor: StudioTokens.accentPrimary,
            shape: const LiquidRoundedSuperellipse(borderRadius: 27),
            onTap: _startConversion,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                ExcludeSemantics(
                  child: Icon(
                    _isConverting ? LucideIcons.loader : LucideIcons.sparkles,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _isConverting ? '正在合成实况照片...' : '生成实况并存入系统相册',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
