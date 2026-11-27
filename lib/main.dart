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
    this.debugInitialCustomCoverPath,
  });

  final LivePhotoConverterGateway? gateway;
  final VideoPlayerController? debugInitialController;
  final String? debugInitialVideoPath;
  final int debugInitialSizeBytes;
  final String? debugInitialCustomCoverPath;

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
        initialCustomCoverPath: debugInitialCustomCoverPath,
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
    this.initialCustomCoverPath,
  });

  final LivePhotoConverterGateway gateway;
  final VideoPlayerController? initialController;
  final String? initialVideoPath;
  final int initialSizeBytes;
  final String? initialCustomCoverPath;

  @override
  State<ConverterHomePage> createState() => _ConverterHomePageState();
}

class _ConverterHomePageState extends State<ConverterHomePage> {
  final ImagePicker _imagePicker = ImagePicker();

  VideoPlayerController? _videoController;
  bool _ownsController = false;
  StreamSubscription<ConversionProgress>? _progressSub;

  String? _selectedVideoPath;
  String? _customCoverPath;
  int _sourceSizeBytes = 0;
  List<Uint8List> _thumbnails = const <Uint8List>[];

  Duration _videoDuration = Duration.zero;
  Duration _currentPosition = Duration.zero;
  int _coverTimeMs = 0;
  int _trimStartMs = 0;
  int _trimEndMs = 0;

  QualityPreset _quality = QualityPreset.p1080;
  bool _keepAudio = true;
  bool _preserveMetadata = true;

  bool _isLoadingVideo = false;
  bool _isConverting = false;
  bool _isLiveHolding = false;
  bool _wasPlayingBeforeHold = false;
  ConversionProgress? _progress;

  @override
  void initState() {
    super.initState();
    final seeded = widget.initialController;
    if (seeded != null && seeded.value.isInitialized) {
      _videoController = seeded;
      _ownsController = false;
      _selectedVideoPath = widget.initialVideoPath ?? 'mock://seeded.mp4';
      _customCoverPath = widget.initialCustomCoverPath;
      _sourceSizeBytes = widget.initialSizeBytes;
      _videoDuration = seeded.value.duration;
      _currentPosition = seeded.value.position;
      _trimStartMs = 0;
      _trimEndMs = _videoDuration.inMilliseconds;
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
    if (ctrl.value.isPlaying &&
        _trimEndMs > 0 &&
        pos.inMilliseconds >= _trimEndMs) {
      if (_isLiveHolding) {
        unawaited(ctrl.seekTo(Duration(milliseconds: _trimStartMs)));
      } else {
        unawaited(ctrl.pause());
        unawaited(ctrl.seekTo(Duration(milliseconds: _trimStartMs)));
      }
    }
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

  void _showMessage(String msg, {bool isError = true}) {
    if (!mounted) return;
    if (isError) {
      HapticFeedback.heavyImpact();
    } else {
      playHaptic(Haptic.selection);
    }
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

  Future<void> _pickCustomCoverImage() async {
    if (_isConverting) return;
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
      );
      if (image == null || !mounted) return;
      setState(() => _customCoverPath = image.path);
    } on PlatformException catch (e) {
      _showMessage('读取图片失败：${e.message ?? e.code}');
    } catch (e) {
      _showMessage('读取图片失败：$e');
    }
  }

  Future<void> _handleCustomCoverButton() async {
    if (_isConverting) return;
    if (_customCoverPath == null) {
      await _pickCustomCoverImage();
      return;
    }

    final String? action = await showModalBottomSheet<String>(
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
                  child: Text('自定义静态封面', style: Ui.title),
                ),
                const SizedBox(height: Ui.s2),
                SecondaryButton(
                  key: const Key('sheet_replace_cover'),
                  label: '从相册重新选择图片',
                  icon: LucideIcons.images,
                  onTap: () => Navigator.of(sheetContext).pop('replace'),
                ),
                const SizedBox(height: Ui.s2 + 2),
                SecondaryButton(
                  key: const Key('sheet_restore_frame_cover'),
                  label: '恢复使用视频画面帧',
                  icon: LucideIcons.rotateCcw,
                  onTap: () => Navigator.of(sheetContext).pop('restore'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) return;
    if (action == 'replace') {
      await _pickCustomCoverImage();
    } else if (action == 'restore') {
      setState(() => _customCoverPath = null);
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
        _customCoverPath = null;
        _sourceSizeBytes = size;
        _videoDuration = ctrl.value.duration;
        _currentPosition = Duration(milliseconds: defaultCoverMs);
        _trimStartMs = 0;
        _trimEndMs = totalMs;
        _coverTimeMs = defaultCoverMs;
        _isLiveHolding = false;
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
    final clamped = VideoTrimMath.clampCoverToTrim(
      coverMs: targetMs,
      startMs: _trimStartMs,
      endMs: _trimEndMs,
    );
    setState(() {
      _coverTimeMs = clamped;
      _currentPosition = Duration(milliseconds: clamped);
    });
    if (ctrl.value.isPlaying) {
      await ctrl.pause();
    }
    await ctrl.seekTo(Duration(milliseconds: clamped));
  }

  void _onTrimChanged(int startMs, int endMs) {
    final totalMs = _videoDuration.inMilliseconds;
    final clamped = VideoTrimMath.clampTrimRange(
      startMs: startMs,
      endMs: endMs,
      totalMs: totalMs,
    );
    final nextCover = VideoTrimMath.clampCoverToTrim(
      coverMs: _coverTimeMs,
      startMs: clamped.startMs,
      endMs: clamped.endMs,
    );
    final coverMoved = nextCover != _coverTimeMs;
    setState(() {
      _trimStartMs = clamped.startMs;
      _trimEndMs = clamped.endMs;
      _coverTimeMs = nextCover;
      if (coverMoved) {
        _currentPosition = Duration(milliseconds: nextCover);
      }
    });
    if (coverMoved) {
      unawaited(_videoController?.seekTo(Duration(milliseconds: nextCover)));
    }
  }

  void _resetTrim() {
    final totalMs = _videoDuration.inMilliseconds;
    setState(() {
      _trimStartMs = 0;
      _trimEndMs = totalMs;
    });
  }

  Future<void> _togglePlay() async {
    final ctrl = _videoController;
    if (ctrl == null || _isConverting) return;
    playHaptic(Haptic.selection);
    if (ctrl.value.isPlaying) {
      await ctrl.pause();
    } else {
      final posMs = ctrl.value.position.inMilliseconds;
      if (posMs < _trimStartMs || (_trimEndMs > 0 && posMs >= _trimEndMs - 50)) {
        await ctrl.seekTo(Duration(milliseconds: _trimStartMs));
      }
      await ctrl.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _onLiveHoldStart() async {
    final ctrl = _videoController;
    if (ctrl == null || _isConverting) return;
    playHaptic(Haptic.light);
    _wasPlayingBeforeHold = ctrl.value.isPlaying;
    setState(() => _isLiveHolding = true);
    await ctrl.seekTo(Duration(milliseconds: _trimStartMs));
    await ctrl.play();
    if (mounted) setState(() {});
  }

  Future<void> _onLiveHoldEnd() async {
    final ctrl = _videoController;
    if (!_isLiveHolding || ctrl == null) return;
    setState(() => _isLiveHolding = false);
    if (!_wasPlayingBeforeHold) {
      await ctrl.pause();
      await ctrl.seekTo(Duration(milliseconds: _coverTimeMs));
      if (mounted) {
        setState(() {
          _currentPosition = Duration(milliseconds: _coverTimeMs);
        });
      }
    }
  }

  void _toggleAudio() {
    if (_isConverting) return;
    setState(() {
      _keepAudio = !_keepAudio;
      _videoController?.setVolume(_keepAudio ? 1.0 : 0.0);
    });
  }

  Future<void> _cancelConversion() async {
    if (!_isConverting) return;
    await widget.gateway.cancelConversion();
  }

  Future<void> _startConversion() async {
    final path = _selectedVideoPath;
    if (path == null || _isConverting) return;

    final ctrl = _videoController;
    if (ctrl != null && ctrl.value.isPlaying) {
      await ctrl.pause();
    }

    final totalMs = _videoDuration.inMilliseconds;
    final isTrimmed = VideoTrimMath.isEffectivelyTrimmed(
      startMs: _trimStartMs,
      endMs: _trimEndMs,
      totalMs: totalMs,
    );
    final effectiveDuration = isTrimmed
        ? Duration(milliseconds: (_trimEndMs - _trimStartMs).clamp(0, totalMs))
        : _videoDuration;

    setState(() {
      _isConverting = true;
      _isLiveHolding = false;
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
        customCoverPath: _customCoverPath,
        trimStartMs: isTrimmed ? _trimStartMs : null,
        trimEndMs: isTrimmed ? _trimEndMs : null,
        preserveMetadata: _preserveMetadata,
      );

      if (!mounted) return;
      playHaptic(Haptic.medium);
      setState(() {
        _isConverting = false;
        _progress = null;
      });

      await showConversionResultSheet(
        context: context,
        duration: effectiveDuration,
        result: result,
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _progress = null;
      });
      if (e.code == 'CANCELLED') {
        _showMessage('已取消合成', isError: false);
      } else {
        _showMessage(e.message ?? '合成失败（${e.code}）');
      }
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
                // Minimalist Top Header — strictly separated from stage
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

    final totalMs = _videoDuration.inMilliseconds;
    final trimmedSpanMs = (_trimEndMs - _trimStartMs).clamp(0, totalMs);
    final effectiveDuration = trimmedSpanMs > 0
        ? Duration(milliseconds: trimmedSpanMs)
        : _videoDuration;

    final estimatedBytes = _quality.estimateOutputBytes(
      sourceSizeBytes: _sourceSizeBytes,
      duration: effectiveDuration,
      totalDuration: _videoDuration,
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
      customCoverPath: _customCoverPath,
      trimStartMs: _trimStartMs,
      trimEndMs: _trimEndMs,
      isLivePreviewing: _isLiveHolding,
      onTogglePlay: _togglePlay,
      onToggleAudio: _toggleAudio,
      onPickCustomCover: _handleCustomCoverButton,
      onLiveHoldStart: _onLiveHoldStart,
      onLiveHoldEnd: _onLiveHoldEnd,
    );

    final subtitleText = estimatedBytes > 0
        ? '${_quality.subtitle} · 约 ${formatFileSize(estimatedBytes)}'
        : _quality.subtitle;

    return Column(
      key: const ValueKey<String>('state_editor'),
      mainAxisSize: useFlexibleStage ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (useFlexibleStage)
          Expanded(child: stage)
        else
          SizedBox(height: 250, child: stage),
        const SizedBox(height: Ui.s2 + 2),

        // 1. Filmstrip Cover + Trim Range Scrubber
        FilmstripScrubber(
          thumbnails: _thumbnails,
          coverTimeMs: _coverTimeMs,
          totalDurationMs: totalMs,
          trimStartMs: _trimStartMs,
          trimEndMs: _trimEndMs,
          hasCustomCover: _customCoverPath != null,
          enabled: !_isConverting,
          onScrubToMs: _seekCoverTo,
          onUseCurrentFrame: () =>
              _seekCoverTo(_currentPosition.inMilliseconds),
          onTrimChanged: _onTrimChanged,
          onResetTrim: _resetTrim,
        ),
        const SizedBox(height: Ui.s3),

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
        const SizedBox(height: Ui.s1),

        // 3. Preset Subtitle + Size + Metadata Date/Location Toggle (44pt hit height)
        Row(
          children: <Widget>[
            Expanded(
              child: AnimatedSwitcher(
                duration: Ui.motion(context, Ui.fast),
                switchInCurve: Ui.easeOut,
                child: Align(
                  key: ValueKey<String>(subtitleText),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    subtitleText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ui.caption.copyWith(fontFeatures: Ui.tabular),
                  ),
                ),
              ),
            ),
            const SizedBox(width: Ui.s2),
            Pressable(
              key: const Key('preserve_metadata_toggle'),
              enabled: !_isConverting,
              toggled: _preserveMetadata,
              semanticLabel:
                  _preserveMetadata ? '保留原拍摄时间与地点，点击切换为当前时间' : '使用当前时间存入相册，点击改回原拍摄时间',
              haptic: Haptic.selection,
              maxInsetPx: 3.0,
              minSize: const Size(84, Ui.minTarget),
              onTap: () {
                setState(() => _preserveMetadata = !_preserveMetadata);
              },
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 9),
                decoration: BoxDecoration(
                  color: Ui.surface,
                  borderRadius: BorderRadius.circular(Ui.rSm),
                  border: Border.all(
                    color: _preserveMetadata ? Ui.hairlineStrong : Ui.hairline,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: 5.5,
                      height: 5.5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            _preserveMetadata ? Ui.liveActive : Ui.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _preserveMetadata ? '原拍摄时间' : '当前时间',
                      style: Ui.caption.copyWith(
                        fontSize: 11.5,
                        color: _preserveMetadata
                            ? Ui.textPrimary
                            : Ui.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Ui.s2),

        // 4. Primary Action Row (morphs to Progress + inline Cancel when converting)
        Row(
          children: <Widget>[
            Expanded(
              child: PrimaryButton(
                key: const Key('convert_save_button'),
                label: '生成实况并存入相册',
                icon: LucideIcons.arrowDownToLine,
                enabled: !_isConverting,
                progress: _isConverting ? (_progress?.progress ?? 0.04) : null,
                progressLabel: busyLabel,
                onTap: _startConversion,
              ),
            ),
            if (_isConverting) ...<Widget>[
              const SizedBox(width: Ui.s2),
              Pressable(
                key: const Key('cancel_convert_button'),
                semanticLabel: '取消当前实况合成',
                haptic: Haptic.light,
                maxInsetPx: 4.0,
                minSize: const Size(80, Ui.buttonHeight),
                onTap: _cancelConversion,
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
          ],
        ),
      ],
    );
  }
}
