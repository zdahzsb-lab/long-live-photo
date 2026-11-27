import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import 'constants/app_branding.dart';
import 'models/conversion_options.dart';
import 'services/live_photo_channel.dart';
import 'theme/ui_tokens.dart';
import 'ui/buttons.dart';
import 'ui/pressable.dart';
import 'ui/result_sheet.dart';
import 'ui/segmented_tabs.dart';
import 'widgets/empty_studio_view.dart';
import 'widgets/filmstrip_scrubber.dart';
import 'widgets/video_stage_card.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Color(0x00000000),
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Ui.bg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const LongLivePhotoApp());
}

class LongLivePhotoApp extends StatelessWidget {
  const LongLivePhotoApp({
    super.key,
    this.gateway,
    this.debugInitialController,
    this.debugInitialVideoPath,
    this.debugInitialSizeBytes = 0,
  });

  final LivePhotoConverterGateway? gateway;
  final VideoPlayerController? debugInitialController;
  final String? debugInitialVideoPath;
  final int debugInitialSizeBytes;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppBranding.appName,
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: Ui.theme(),
      builder: (BuildContext context, Widget? child) {
        return DefaultTextStyle(
          style: Ui.body.copyWith(color: Ui.textPrimary),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: ConverterHomePage(
        gateway: gateway ?? NativeLivePhotoChannel(),
        initialController: debugInitialController,
        initialVideoPath: debugInitialVideoPath,
        initialSizeBytes: debugInitialSizeBytes,
      ),
    );
  }
}

class ConverterHomePage extends StatefulWidget {
  const ConverterHomePage({
    super.key,
    required this.gateway,
    this.initialController,
    this.initialVideoPath,
    this.initialSizeBytes = 0,
  });

  final LivePhotoConverterGateway gateway;
  final VideoPlayerController? initialController;
  final String? initialVideoPath;
  final int initialSizeBytes;

  @override
  State<ConverterHomePage> createState() => _ConverterHomePageState();
}

class _ConverterHomePageState extends State<ConverterHomePage> {
  final ImagePicker _imagePicker = ImagePicker();

  VideoPlayerController? _videoController;
  bool _ownsController = false;
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
    final seeded = widget.initialController;
    if (seeded != null && seeded.value.isInitialized) {
      _videoController = seeded;
      _ownsController = false;
      _selectedVideoPath = widget.initialVideoPath ?? 'mock://seeded.mp4';
      _sourceSizeBytes = widget.initialSizeBytes;
      _videoDuration = seeded.value.duration;
      _currentPosition = seeded.value.position;
      _coverTimeMs = _videoDuration.inMilliseconds > 600 ? 500 : 0;
      seeded.addListener(_onVideoTick);
    }

    _progressSub = widget.gateway.progressStream.listen((ConversionProgress ev) {
      if (mounted && _isConverting) {
        setState(() => _progress = ev);
      }
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _videoController?.removeListener(_onVideoTick);
    if (_ownsController) {
      _videoController?.dispose();
    }
    super.dispose();
  }

  void _onVideoTick() {
    final ctrl = _videoController;
    if (ctrl == null || !mounted) return;
    final pos = ctrl.value.position;
    if ((pos - _currentPosition).inMilliseconds.abs() >= 80 ||
        !ctrl.value.isPlaying) {
      setState(() => _currentPosition = pos);
    }
  }

  String get _platformTag {
    if (kIsWeb) return 'Web 预览模式';
    if (Platform.isIOS) return 'Apple Live Photo · 原生直入系统照片';
    if (Platform.isAndroid) return 'Android 动态照片 · 双标准兼容各大品牌相册';
    return 'Studio 预览模式';
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
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
      _showMessage('读取相册失败：${e.message ?? e.code}');
    } catch (e) {
      _showMessage('读取相册失败：$e');
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
      _showMessage('导入视频失败：${e.message ?? e.code}');
    } catch (e) {
      _showMessage('导入视频失败：$e');
    }
  }

  Future<void> _openSourceSheet() async {
    if (_isConverting) return;
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Ui.surface,
      barrierColor: const Color(0xA6000000),
      builder: (BuildContext sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Ui.s5, Ui.s1, Ui.s5, Ui.s5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: Ui.s1,
                    vertical: Ui.s2,
                  ),
                  child: Text('更换视频素材', style: Ui.title),
                ),
                const SizedBox(height: Ui.s2),
                SecondaryButton(
                  key: const Key('sheet_pick_gallery'),
                  label: '从系统相册选择',
                  icon: LucideIcons.images,
                  onTap: () => Navigator.of(sheetContext).pop('gallery'),
                ),
                const SizedBox(height: Ui.s2 + 2),
                SecondaryButton(
                  key: const Key('sheet_pick_files'),
                  label: '从文件管理器导入',
                  icon: LucideIcons.folderOpen,
                  onTap: () => Navigator.of(sheetContext).pop('files'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || choice == null) return;
    if (choice == 'gallery') {
      await _pickFromGallery();
    } else if (choice == 'files') {
      await _pickFromFiles();
    }
  }

  Future<void> _loadVideoFile(String path) async {
    setState(() {
      _isLoadingVideo = true;
      _thumbnails = const <Uint8List>[];
    });

    final oldController = _videoController;
    final oldOwned = _ownsController;
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
        _ownsController = true;
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
          _ownsController = false;
          _isLoadingVideo = false;
        });
        _showMessage('无法解析该视频：$e');
      }
    } finally {
      if (oldOwned) {
        await oldController?.dispose();
      }
    }
  }

  Future<void> _loadThumbnails(String path) async {
    final frames = await widget.gateway.extractThumbnails(
      videoPath: path,
      count: 8,
    );
    if (mounted && _selectedVideoPath == path) {
      setState(() => _thumbnails = frames);
    }
  }

  Future<void> _seekCoverTo(int targetMs) async {
    final ctrl = _videoController;
    if (ctrl == null) return;
    final maxMs = _videoDuration.inMilliseconds;
    final clamped = targetMs.clamp(0, maxMs > 0 ? maxMs : 0);
    setState(() {
      _coverTimeMs = clamped;
      _currentPosition = Duration(milliseconds: clamped);
    });
    if (ctrl.value.isPlaying) {
      await ctrl.pause();
    }
    await ctrl.seekTo(Duration(milliseconds: clamped));
  }

  Future<void> _togglePlay() async {
    final ctrl = _videoController;
    if (ctrl == null || _isConverting) return;
    playHaptic(Haptic.selection);
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
        progress: 0.04,
        message: '正在准备实况合成...',
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
      playHaptic(Haptic.medium);
      setState(() {
        _isConverting = false;
        _progress = null;
      });

      await showConversionResultSheet(
        context: context,
        duration: _videoDuration,
        result: result,
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _progress = null;
      });
      _showMessage(e.message ?? '合成失败（${e.code}）');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _progress = null;
      });
      _showMessage('合成出错：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _videoController;
    final hasVideo = ctrl != null && ctrl.value.isInitialized;
    final scaledPx = MediaQuery.textScalerOf(context).scale(14.0);

    return Scaffold(
      backgroundColor: Ui.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // Minimalist 52pt Top Header — strictly separated from stage
                Padding(
                  padding: const EdgeInsets.fromLTRB(Ui.s5, Ui.s1, Ui.s4, Ui.s1),
                  child: SizedBox(
                    height: 44,
                    child: Row(
                      children: <Widget>[
                        const Text(AppBranding.appName, style: Ui.wordmark),
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
                            'LIVE',
                            style: Ui.mono.copyWith(
                              fontSize: 10.5,
                              letterSpacing: 0.6,
                              color: Ui.textSecondary,
                            ),
                          ),
                        ),
                        const Spacer(),
                        if (hasVideo)
                          PillAction(
                            key: const Key('replace_video_button'),
                            label: '更换',
                            semanticLabel: '更换视频素材',
                            icon: LucideIcons.arrowLeftRight,
                            enabled: !_isConverting,
                            onTap: _openSourceSheet,
                          ),
                      ],
                    ),
                  ),
                ),

                // Main Studio Body
                Expanded(
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints constraints) {
                      final horizontalPad =
                          constraints.maxWidth >= 500 ? 24.0 : 18.0;
                      final isCompact =
                          constraints.maxHeight < 520 || scaledPx > 18.0;

                      final content = AnimatedSwitcher(
                        duration: Ui.motion(context, Ui.base),
                        switchInCurve: Ui.easeOut,
                        switchOutCurve: Ui.easeIn,
                        child: _buildActiveView(
                          ctrl: ctrl,
                          hasVideo: hasVideo,
                          useFlexibleStage: !isCompact,
                        ),
                      );

                      final padded = Padding(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPad,
                          Ui.s1,
                          horizontalPad,
                          Ui.s4,
                        ),
                        child: content,
                      );

                      if (isCompact) {
                        return SingleChildScrollView(child: padded);
                      }
                      return padded;
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActiveView({
    required VideoPlayerController? ctrl,
    required bool hasVideo,
    required bool useFlexibleStage,
  }) {
    if (_isLoadingVideo) {
      return Center(
        key: const ValueKey<String>('state_loading'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(height: Ui.s3),
            Text('正在读取视频...', style: Ui.body),
          ],
        ),
      );
    }

    if (!hasVideo || ctrl == null) {
      return KeyedSubtree(
        key: const ValueKey<String>('state_empty'),
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

    final pct = ((_progress?.progress ?? 0.0) * 100).round().clamp(0, 100);
    final busyLabel = _progress != null
        ? '${_progress!.message}  $pct%'
        : '正在合成实况照片...';

    final stage = VideoStageCard(
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
      key: const ValueKey<String>('state_editor'),
      mainAxisSize: useFlexibleStage ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (useFlexibleStage)
          Expanded(child: stage)
        else
          SizedBox(height: 260, child: stage),
        const SizedBox(height: Ui.s3),

        // 1. Filmstrip Cover Picker
        FilmstripScrubber(
          thumbnails: _thumbnails,
          coverTimeMs: _coverTimeMs,
          totalDurationMs: _videoDuration.inMilliseconds,
          enabled: !_isConverting,
          onScrubToMs: _seekCoverTo,
          onUseCurrentFrame: () =>
              _seekCoverTo(_currentPosition.inMilliseconds),
        ),
        const SizedBox(height: Ui.s3 + 2),

        // 2. Minimalist Sliding Quality Tabs
        SegmentedTabs<QualityPreset>(
          key: const Key('quality_segmented_tabs'),
          items: QualityPreset.values,
          selectedIndex: _quality.index,
          enabled: !_isConverting,
          labelBuilder: (QualityPreset p) => p.segmentLabel,
          onChanged: (int index) {
            setState(() => _quality = QualityPreset.values[index]);
          },
        ),
        const SizedBox(height: Ui.s2),

        // 3. Preset Subtitle + Estimated Output Size
        AnimatedSwitcher(
          duration: Ui.motion(context, Ui.fast),
          switchInCurve: Ui.easeOut,
          child: Row(
            key: ValueKey<String>('${_quality.wireValue}_$_keepAudio'),
            children: <Widget>[
              Expanded(
                child: Text(
                  _quality.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ui.caption,
                ),
              ),
              if (estimatedBytes > 0) ...<Widget>[
                const SizedBox(width: Ui.s2),
                Text(
                  '约 ${formatFileSize(estimatedBytes)}',
                  style: Ui.mono.copyWith(
                    fontSize: 12,
                    color: Ui.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Ui.s4),

        // 4. Primary Action Button (morphs into inline progress sweep when busy)
        PrimaryButton(
          key: const Key('convert_save_button'),
          label: '生成实况并存入相册',
          icon: LucideIcons.arrowDownToLine,
          enabled: !_isConverting,
          progress: _isConverting ? (_progress?.progress ?? 0.04) : null,
          progressLabel: busyLabel,
          onTap: _startConversion,
        ),
      ],
    );
  }
}
