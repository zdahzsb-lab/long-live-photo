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
import 'models/batch_task.dart';
import 'models/conversion_history.dart';
import 'models/conversion_options.dart';
import 'services/conversion_history_store.dart';
import 'services/live_photo_channel.dart';
import 'theme/ui_tokens.dart';
import 'ui/batch_queue_sheet.dart';
import 'ui/buttons.dart';
import 'ui/history_drawer_sheet.dart';
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
    this.historyStore,
    this.debugInitialController,
    this.debugInitialVideoPath,
    this.debugInitialSizeBytes = 0,
    this.debugInitialCustomCoverPath,
    this.debugFileExistsChecker,
    this.debugControllerBuilder,
    this.debugFileSizeReader,
  });

  final LivePhotoConverterGateway? gateway;
  final ConversionHistoryStore? historyStore;
  final VideoPlayerController? debugInitialController;
  final String? debugInitialVideoPath;
  final int debugInitialSizeBytes;
  final String? debugInitialCustomCoverPath;
  final Future<bool> Function(String path)? debugFileExistsChecker;
  final VideoPlayerController Function(String path)? debugControllerBuilder;
  final Future<int> Function(String path)? debugFileSizeReader;

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
        historyStore: historyStore,
        initialController: debugInitialController,
        initialVideoPath: debugInitialVideoPath,
        initialSizeBytes: debugInitialSizeBytes,
        initialCustomCoverPath: debugInitialCustomCoverPath,
        fileExistsChecker: debugFileExistsChecker,
        controllerBuilder: debugControllerBuilder,
        fileSizeReader: debugFileSizeReader,
      ),
    );
  }
}

class ConverterHomePage extends StatefulWidget {
  const ConverterHomePage({
    super.key,
    required this.gateway,
    this.historyStore,
    this.initialController,
    this.initialVideoPath,
    this.initialSizeBytes = 0,
    this.initialCustomCoverPath,
    this.fileExistsChecker,
    this.controllerBuilder,
    this.fileSizeReader,
  });

  final LivePhotoConverterGateway gateway;
  final ConversionHistoryStore? historyStore;
  final VideoPlayerController? initialController;
  final String? initialVideoPath;
  final int initialSizeBytes;
  final String? initialCustomCoverPath;
  final Future<bool> Function(String path)? fileExistsChecker;
  final VideoPlayerController Function(String path)? controllerBuilder;
  final Future<int> Function(String path)? fileSizeReader;

  @override
  State<ConverterHomePage> createState() => _ConverterHomePageState();
}

class _ConverterHomePageState extends State<ConverterHomePage> {
  final ImagePicker _imagePicker = ImagePicker();
  late final ConversionHistoryStore _historyStore;
  List<ConversionHistoryEntry> _historyEntries =
      const <ConversionHistoryEntry>[];
  int _historySeq = 0;

  VideoPlayerController? _videoController;
  bool _ownsController = false;
  StreamSubscription<ConversionProgress>? _progressSub;
  StreamSubscription<List<SharedMediaItem>>? _sharedMediaSub;

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
  PlaybackSpeedPreset _playbackSpeed = PlaybackSpeedPreset.normal;
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
    _historyStore = widget.historyStore ?? FileConversionHistoryStore();
    unawaited(_loadHistory());

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

    _sharedMediaSub =
        widget.gateway.sharedMediaStream.listen((List<SharedMediaItem> items) {
      unawaited(_handleIncomingSharedMedia(items));
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_consumeInitialSharedMedia());
    });
  }

  @override
  void dispose() {
    _sharedMediaSub?.cancel();
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

  Future<void> _consumeInitialSharedMedia() async {
    final items = await widget.gateway.consumeInitialSharedMedia();
    if (!mounted || items.isEmpty) return;
    await _handleIncomingSharedMedia(items);
  }

  Future<void> _handleIncomingSharedMedia(List<SharedMediaItem> items) async {
    final valid = items
        .where((SharedMediaItem e) => e.path.isNotEmpty)
        .toList(growable: false);
    if (valid.isEmpty || !mounted) return;
    if (_isConverting) {
      _showMessage('正在合成中，请稍后再导入分享素材');
      return;
    }

    final videos = valid
        .where((SharedMediaItem e) => e.kind == SharedMediaKind.video)
        .toList(growable: false);
    final images = valid
        .where((SharedMediaItem e) => e.kind == SharedMediaKind.image)
        .toList(growable: false);

    if (videos.length >= 2) {
      await _openBatchSheetFromPaths(
        videos.map((SharedMediaItem e) => e.path).toList(growable: false),
      );
      return;
    }
    if (videos.length == 1) {
      await _loadVideoFile(videos.first.path);
      return;
    }
    if (images.isNotEmpty) {
      await _unpackAndLoadFile(images.first.path);
    }
  }

  Future<void> _pickBatchVideos() async {
    if (_isConverting) return;
    try {
      final List<XFile> picked = await _imagePicker.pickMultiVideo();
      if (picked.isEmpty || !mounted) return;
      if (picked.length == 1) {
        await _loadVideoFile(picked.first.path);
        return;
      }
      await _openBatchSheetFromPaths(
        picked.map((XFile f) => f.path).toList(growable: false),
      );
    } on PlatformException catch (e) {
      _showMessage('批量选片失败：${e.message ?? e.code}');
    } catch (e) {
      _showMessage('批量选片失败：$e');
    }
  }

  Future<void> _openBatchSheetFromPaths(List<String> paths) async {
    if (paths.isEmpty || !mounted) return;
    final items = <BatchQueueItem>[];
    for (int i = 0; i < paths.length; i++) {
      final path = paths[i];
      if (path.isEmpty) continue;
      final sizeBytes = await _readFileSizeSafe(path);
      final name = _fileBasename(path, fallbackIndex: i + 1);
      items.add(
        BatchQueueItem(
          id: '${i}_${DateTime.now().microsecondsSinceEpoch}',
          videoPath: path,
          displayName: name,
          sourceSizeBytes: sizeBytes,
        ),
      );
    }
    if (!mounted || items.isEmpty) return;

    await showBatchQueueSheet(
      context: context,
      initialItems: items,
      gateway: widget.gateway,
      historyStore: _historyStore,
      initialQuality: _quality,
      initialSpeed: _playbackSpeed,
      initialKeepAudio: _keepAudio,
      initialPreserveMetadata: _preserveMetadata,
      onHistoryUpdated: (List<ConversionHistoryEntry> updated) {
        if (mounted) {
          setState(() => _historyEntries = updated);
        }
      },
      onOpenGallery: (String? savedTarget) =>
          widget.gateway.openSystemGallery(savedTarget: savedTarget),
    );
  }

  Future<void> _pickAndUnpackLivePhoto() async {
    if (_isConverting) return;
    try {
      final unpacked = await widget.gateway.pickAndUnpackLivePhoto();
      if (unpacked == null || !mounted) return;
      await _loadVideoFile(
        unpacked.videoPath,
        initialCoverTimeMs: unpacked.coverTimeMs,
        customToast: '已拆解实况照片，可二次编辑或点右上角导出',
      );
    } on PlatformException catch (e) {
      if (e.code != 'CANCELLED') {
        _showMessage(e.message ?? '拆解实况失败（${e.code}）');
      }
    } catch (e) {
      _showMessage('拆解实况失败：$e');
    }
  }

  Future<void> _unpackAndLoadFile(String filePath) async {
    if (_isConverting) return;
    setState(() => _isLoadingVideo = true);
    try {
      final unpacked =
          await widget.gateway.unpackLivePhotoFile(filePath: filePath);
      if (!mounted) return;
      await _loadVideoFile(
        unpacked.videoPath,
        initialCoverTimeMs: unpacked.coverTimeMs,
        customToast: '已拆解实况照片，可二次编辑或点右上角导出',
      );
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => _isLoadingVideo = false);
        _showMessage(e.message ?? '该图片不包含实况视频轨道');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingVideo = false);
        _showMessage('拆解实况失败：$e');
      }
    }
  }

  Future<void> _openSourceSheet() async {
    if (_isConverting) return;
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ui.surface,
      barrierColor: const Color(0xA6000000),
      builder: (BuildContext sheetContext) {
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
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
                  key: const Key('sheet_pick_batch'),
                  label: '批量多选转换',
                  icon: LucideIcons.layers,
                  onTap: () => Navigator.of(sheetContext).pop('batch'),
                ),
                const SizedBox(height: Ui.s2 + 2),
                SecondaryButton(
                  key: const Key('sheet_pick_live_unpack'),
                  label: '导入实况照片（拆解 / 重编）',
                  icon: LucideIcons.sparkles,
                  onTap: () => Navigator.of(sheetContext).pop('unpack'),
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
    } else if (choice == 'batch') {
      await _pickBatchVideos();
    } else if (choice == 'unpack') {
      await _pickAndUnpackLivePhoto();
    } else if (choice == 'files') {
      await _pickFromFiles();
    }
  }

  Future<void> _openExportToolsSheet() async {
    if (_isConverting || _selectedVideoPath == null) return;
    final StandaloneExportMode? mode =
        await showModalBottomSheet<StandaloneExportMode>(
      context: context,
      isScrollControlled: true,
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
                  child: Text('导出独立素材', style: Ui.title),
                ),
                const SizedBox(height: Ui.s2),
                SecondaryButton(
                  key: const Key('sheet_export_video'),
                  label: '导出为普通视频（MP4）',
                  icon: LucideIcons.film,
                  onTap: () => Navigator.of(sheetContext)
                      .pop(StandaloneExportMode.video),
                ),
                const SizedBox(height: Ui.s2 + 2),
                SecondaryButton(
                  key: const Key('sheet_export_cover'),
                  label: '提取当前高清封面（JPG）',
                  icon: LucideIcons.image,
                  onTap: () => Navigator.of(sheetContext)
                      .pop(StandaloneExportMode.cover),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || mode == null) return;
    await _startStandaloneExport(mode);
  }

  Future<void> _startStandaloneExport(StandaloneExportMode mode) async {
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
    final speed = _playbackSpeed;
    final outputDuration = VideoSpeedMath.scaledDuration(
      effectiveDuration,
      speed.rate,
    );

    setState(() {
      _isConverting = true;
      _isLiveHolding = false;
      _progress = ConversionProgress(
        stage: mode == StandaloneExportMode.cover ? 'cover' : 'video',
        progress: 0.08,
        message: mode == StandaloneExportMode.cover
            ? '正在提取高清封面...'
            : '正在准备导出视频...',
      );
    });

    try {
      final result = await widget.gateway.exportStandaloneMedia(
        mode: mode,
        videoPath: path,
        coverTimeMs: _coverTimeMs,
        quality: _quality,
        keepAudio: _keepAudio,
        customCoverPath: _customCoverPath,
        trimStartMs: isTrimmed ? _trimStartMs : null,
        trimEndMs: isTrimmed ? _trimEndMs : null,
        preserveMetadata: _preserveMetadata,
        playbackSpeed: speed.rate,
      );

      if (!mounted) return;
      playHaptic(Haptic.medium);
      setState(() {
        _isConverting = false;
        _progress = null;
      });

      final isCover = mode == StandaloneExportMode.cover;
      await showConversionResultSheet(
        context: context,
        duration: outputDuration,
        result: result,
        playbackSpeed: isCover ? PlaybackSpeedPreset.normal : speed,
        showPickNext: false,
        showDurationMetric: !isCover,
        title: isCover ? '封面已存入相册' : '视频已存入相册',
        metricSizeLabel: isCover ? '图片体积' : '视频体积',
        hintText: isCover
            ? '已将当前高清静态封面保存至系统相册。'
            : '已按当前裁剪与倍速参数导出普通视频至系统相册。',
        onOpenGallery: () =>
            widget.gateway.openSystemGallery(savedTarget: result.savedTarget),
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _progress = null;
      });
      if (e.code == 'CANCELLED') {
        _showMessage('已取消导出', isError: false);
      } else {
        _showMessage(e.message ?? '导出失败（${e.code}）');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _progress = null;
      });
      _showMessage('导出出错：$e');
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

  Future<void> _loadHistory() async {
    final entries = await _historyStore.load();
    if (mounted) {
      setState(() => _historyEntries = entries);
    }
  }

  Future<bool> _checkFileExists(String path) async {
    if (path.isEmpty) return false;
    final checker = widget.fileExistsChecker;
    if (checker != null) {
      return checker(path);
    }
    return File(path).exists();
  }

  Future<int> _readFileSizeSafe(String path) async {
    final reader = widget.fileSizeReader;
    if (reader != null) {
      return reader(path);
    }
    try {
      final f = File(path);
      if (await f.exists()) {
        return await f.length();
      }
    } catch (_) {
      // Ignore missing or mock paths.
    }
    return 0;
  }

  String _fileBasename(String path, {required int fallbackIndex}) {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    final base = idx >= 0 ? normalized.substring(idx + 1) : normalized;
    return base.isEmpty ? '视频 $fallbackIndex' : base;
  }

  Future<void> _applyPlaybackSpeed(double rate) async {
    final ctrl = _videoController;
    if (ctrl == null) return;
    try {
      await ctrl.setPlaybackSpeed(rate);
    } catch (_) {
      // Ignore if controller implementation rejects playback speed updates.
    }
  }

  void _setPlaybackSpeed(PlaybackSpeedPreset preset) {
    if (_isConverting || preset == _playbackSpeed) return;
    setState(() => _playbackSpeed = preset);
    unawaited(_applyPlaybackSpeed(preset.rate));
  }

  Future<void> _openHistoryDrawer() async {
    if (_isConverting) return;
    await showHistoryDrawerSheet(
      context: context,
      initialEntries: _historyEntries,
      onDeleteEntry: (String id) async {
        final next = await _historyStore.removeById(id);
        if (mounted) {
          setState(() => _historyEntries = next);
        }
        return next;
      },
      onClearAll: () async {
        await _historyStore.clear();
        if (mounted) {
          setState(() => _historyEntries = const <ConversionHistoryEntry>[]);
        }
      },
      onSelectEntry: (ConversionHistoryEntry entry) {
        unawaited(_restoreFromHistoryEntry(entry));
      },
    );
  }

  Future<String?> _resolveSurvivingCustomCover(
    ConversionHistoryEntry entry,
  ) async {
    if (!entry.usedCustomCover) return null;
    for (final candidate in <String?>[
      entry.customCoverPath,
      entry.thumbnailPath,
    ]) {
      if (candidate != null &&
          candidate.isNotEmpty &&
          await _checkFileExists(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  Future<void> _restoreFromHistoryEntry(ConversionHistoryEntry entry) async {
    if (_isConverting) return;
    final videoExists = await _checkFileExists(entry.sourceVideoPath);
    if (!mounted) return;
    if (!videoExists) {
      final activeCtrl = _videoController;
      if (activeCtrl != null && activeCtrl.value.isInitialized) {
        final restoredSpeed = entry.speedPreset;
        final restoredAudio = entry.keepAudio;
        final survivingCover = await _resolveSurvivingCustomCover(entry);
        final restoredCustomCover = survivingCover ?? _customCoverPath;
        if (!mounted) return;
        await activeCtrl.setVolume(restoredAudio ? 1.0 : 0.0);
        await _applyPlaybackSpeed(restoredSpeed.rate);
        if (!mounted) return;
        setState(() {
          _quality = entry.quality;
          _playbackSpeed = restoredSpeed;
          _keepAudio = restoredAudio;
          _preserveMetadata = entry.preserveMetadata;
          _customCoverPath = restoredCustomCover;
        });
        _showMessage('原视频已移除，已将参数套用到当前视频', isError: false);
        return;
      }
      _showMessage('原视频文件已移除，无法重新载入');
      return;
    }

    if (_selectedVideoPath == entry.sourceVideoPath &&
        _videoController != null &&
        _videoController!.value.isInitialized) {
      final ctrl = _videoController!;
      final totalMs = _videoDuration.inMilliseconds;
      final restoredRange = entry.wasTrimmed
          ? VideoTrimMath.clampTrimRange(
              startMs: entry.trimStartMs ?? 0,
              endMs: entry.trimEndMs ?? totalMs,
              totalMs: totalMs,
            )
          : (startMs: 0, endMs: totalMs);
      final restoredCoverMs = VideoTrimMath.clampCoverToTrim(
        coverMs: entry.coverTimeMs,
        startMs: restoredRange.startMs,
        endMs: restoredRange.endMs,
      );
      final restoredCustomCover = await _resolveSurvivingCustomCover(entry);
      if (!mounted) return;

      final restoredSpeed = entry.speedPreset;
      final restoredAudio = entry.keepAudio;
      if (ctrl.value.isPlaying) {
        await ctrl.pause();
      }
      await ctrl.setVolume(restoredAudio ? 1.0 : 0.0);
      await ctrl.seekTo(Duration(milliseconds: restoredCoverMs));
      await _applyPlaybackSpeed(restoredSpeed.rate);
      if (!mounted) return;

      setState(() {
        _quality = entry.quality;
        _playbackSpeed = restoredSpeed;
        _keepAudio = restoredAudio;
        _preserveMetadata = entry.preserveMetadata;
        _trimStartMs = restoredRange.startMs;
        _trimEndMs = restoredRange.endMs;
        _coverTimeMs = restoredCoverMs;
        _currentPosition = Duration(milliseconds: restoredCoverMs);
        _customCoverPath = restoredCustomCover;
      });
      _showMessage('已恢复上次合成参数', isError: false);
      return;
    }

    await _loadVideoFile(entry.sourceVideoPath, restoredEntry: entry);
  }

  Future<void> _loadVideoFile(
    String path, {
    ConversionHistoryEntry? restoredEntry,
    int? initialCoverTimeMs,
    String? customToast,
  }) async {
    setState(() {
      _isLoadingVideo = true;
      _thumbnails = const <Uint8List>[];
    });

    final oldController = _videoController;
    final oldOwned = _ownsController;
    oldController?.removeListener(_onVideoTick);

    try {
      final size = await _readFileSizeSafe(path);
      final customBuilder = widget.controllerBuilder;
      final bool ownsNewController = customBuilder == null;
      final ctrl = customBuilder != null
          ? customBuilder(path)
          : VideoPlayerController.file(File(path));
      if (!ctrl.value.isInitialized) {
        await ctrl.initialize();
      }

      final totalMs = ctrl.value.duration.inMilliseconds;
      final restoredSpeed =
          restoredEntry?.speedPreset ?? PlaybackSpeedPreset.normal;
      final restoredAudio = restoredEntry?.keepAudio ?? _keepAudio;
      final restoredQuality = restoredEntry?.quality ?? _quality;
      final restoredMetadata =
          restoredEntry?.preserveMetadata ?? _preserveMetadata;

      final trimRange = (restoredEntry != null && restoredEntry.wasTrimmed)
          ? VideoTrimMath.clampTrimRange(
              startMs: restoredEntry.trimStartMs ?? 0,
              endMs: restoredEntry.trimEndMs ?? totalMs,
              totalMs: totalMs,
            )
          : (startMs: 0, endMs: totalMs);

      final defaultCoverMs = totalMs > 600 ? 500 : 0;
      final targetCoverMs = restoredEntry != null
          ? VideoTrimMath.clampCoverToTrim(
              coverMs: restoredEntry.coverTimeMs,
              startMs: trimRange.startMs,
              endMs: trimRange.endMs,
            )
          : (initialCoverTimeMs != null
              ? VideoTrimMath.clampCoverToTrim(
                  coverMs: initialCoverTimeMs,
                  startMs: trimRange.startMs,
                  endMs: trimRange.endMs,
                )
              : defaultCoverMs);

      final restoredCustomCover = restoredEntry != null
          ? await _resolveSurvivingCustomCover(restoredEntry)
          : null;

      await ctrl.setVolume(restoredAudio ? 1.0 : 0.0);
      try {
        await ctrl.setPlaybackSpeed(restoredSpeed.rate);
      } catch (_) {
        // Ignore if platform player rejects playback speed on init.
      }
      if (targetCoverMs > 0) {
        await ctrl.seekTo(Duration(milliseconds: targetCoverMs));
      }

      if (!mounted) {
        if (ownsNewController) {
          await ctrl.dispose();
        }
        return;
      }

      ctrl.addListener(_onVideoTick);
      setState(() {
        _videoController = ctrl;
        _ownsController = ownsNewController;
        _selectedVideoPath = path;
        _customCoverPath = restoredCustomCover;
        _sourceSizeBytes = size;
        _videoDuration = ctrl.value.duration;
        _currentPosition = Duration(milliseconds: targetCoverMs);
        _trimStartMs = trimRange.startMs;
        _trimEndMs = trimRange.endMs;
        _coverTimeMs = targetCoverMs;
        _quality = restoredQuality;
        _playbackSpeed = restoredSpeed;
        _keepAudio = restoredAudio;
        _preserveMetadata = restoredMetadata;
        _isLiveHolding = false;
        _isLoadingVideo = false;
      });

      if (customToast != null) {
        _showMessage(customToast, isError: false);
      } else if (restoredEntry != null) {
        _showMessage('已载入历史素材与参数', isError: false);
      }

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
    await _applyPlaybackSpeed(_playbackSpeed.rate);
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

  Uint8List? _pickThumbnailBytesForCover(int coverMs, int totalMs) {
    if (_thumbnails.isEmpty) return null;
    if (_thumbnails.length == 1 || totalMs <= 0) return _thumbnails.first;
    final ratio = (coverMs / totalMs).clamp(0.0, 1.0);
    final idx = (ratio * (_thumbnails.length - 1))
        .round()
        .clamp(0, _thumbnails.length - 1);
    return _thumbnails[idx];
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
    final speed = _playbackSpeed;
    final outputDuration = VideoSpeedMath.scaledDuration(
      effectiveDuration,
      speed.rate,
    );

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
        playbackSpeed: speed.rate,
      );

      if (!mounted) return;
      playHaptic(Haptic.medium);
      setState(() {
        _isConverting = false;
        _progress = null;
      });

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      _historySeq++;
      final entry = ConversionHistoryEntry(
        id: '${nowMs}_$_historySeq',
        createdAtMs: nowMs,
        sourceVideoPath: path,
        savedTarget: result.savedTarget,
        platformFormat: result.platformFormat,
        sourceDurationMs: effectiveDuration.inMilliseconds,
        outputDurationMs: outputDuration.inMilliseconds,
        outputSizeBytes: result.outputSizeBytes,
        elapsedMs: result.elapsedMs,
        qualityWireValue: _quality.wireValue,
        playbackSpeed: speed.rate,
        keepAudio: _keepAudio,
        preserveMetadata: _preserveMetadata,
        wasTrimmed: isTrimmed,
        trimStartMs: isTrimmed ? _trimStartMs : null,
        trimEndMs: isTrimmed ? _trimEndMs : null,
        coverTimeMs: _coverTimeMs,
        customCoverPath: _customCoverPath,
      );
      final thumbBytes = _customCoverPath == null
          ? _pickThumbnailBytesForCover(_coverTimeMs, totalMs)
          : null;
      try {
        final updated = await _historyStore.add(
          entry,
          thumbnailBytes: thumbBytes,
          customCoverSourcePath: _customCoverPath,
        );
        if (mounted) {
          setState(() => _historyEntries = updated);
        }
      } catch (_) {
        // Never block result feedback if local history persistence fails.
      }

      if (!mounted) return;
      final action = await showConversionResultSheet(
        context: context,
        duration: outputDuration,
        result: result,
        playbackSpeed: speed,
        showPickNext: true,
        onOpenGallery: () =>
            widget.gateway.openSystemGallery(savedTarget: result.savedTarget),
      );
      if (mounted && action == ResultSheetAction.pickNext) {
        unawaited(_pickFromGallery());
      }
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
                        Expanded(
                          child: Row(
                            children: <Widget>[
                              const Flexible(
                                child: Text(
                                  AppBranding.appName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Ui.wordmark,
                                ),
                              ),
                              if (!hasVideo && scaledPx <= 16.0) ...<Widget>[
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
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: Ui.s2),
                        if (hasVideo && scaledPx > 15.5) ...<Widget>[
                          IconAction(
                            key: const Key('history_drawer_button'),
                            icon: LucideIcons.history,
                            filled: true,
                            size: 17,
                            semanticLabel: '打开合成历史记录抽屉',
                            enabled: !_isConverting,
                            onTap: _openHistoryDrawer,
                          ),
                          const SizedBox(width: 4),
                          IconAction(
                            key: const Key('export_tools_button'),
                            icon: LucideIcons.share,
                            filled: true,
                            size: 17,
                            semanticLabel: '导出纯视频或高清封面',
                            enabled: !_isConverting,
                            onTap: _openExportToolsSheet,
                          ),
                          const SizedBox(width: 4),
                          IconAction(
                            key: const Key('replace_video_button'),
                            icon: LucideIcons.arrowLeftRight,
                            filled: true,
                            size: 17,
                            semanticLabel: '更换视频素材',
                            enabled: !_isConverting,
                            onTap: _openSourceSheet,
                          ),
                        ] else ...<Widget>[
                          PillAction(
                            key: const Key('history_drawer_button'),
                            label: _historyEntries.isEmpty
                                ? '记录'
                                : '记录 ${_historyEntries.length}',
                            semanticLabel: '打开合成历史记录抽屉',
                            icon: LucideIcons.history,
                            emphasized: _historyEntries.isNotEmpty,
                            enabled: !_isConverting,
                            onTap: _openHistoryDrawer,
                          ),
                          if (hasVideo) ...<Widget>[
                            const SizedBox(width: 4),
                            IconAction(
                              key: const Key('export_tools_button'),
                              icon: LucideIcons.share,
                              filled: true,
                              size: 17,
                              semanticLabel: '导出纯视频或高清封面',
                              enabled: !_isConverting,
                              onTap: _openExportToolsSheet,
                            ),
                            const SizedBox(width: 4),
                            PillAction(
                              key: const Key('replace_video_button'),
                              label: '更换',
                              semanticLabel: '更换视频素材',
                              icon: LucideIcons.arrowLeftRight,
                              enabled: !_isConverting,
                              onTap: _openSourceSheet,
                            ),
                          ],
                        ],
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
                          constraints.maxHeight < 560 || scaledPx > 18.0;

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
          onPickBatch: _pickBatchVideos,
          onPickLiveUnpack: _pickAndUnpackLivePhoto,
        ),
      );
    }

    final totalMs = _videoDuration.inMilliseconds;
    final trimmedSpanMs = (_trimEndMs - _trimStartMs).clamp(0, totalMs);
    final effectiveDuration = trimmedSpanMs > 0
        ? Duration(milliseconds: trimmedSpanMs)
        : _videoDuration;

    final outputDuration = VideoSpeedMath.scaledDuration(
      effectiveDuration,
      _playbackSpeed.rate,
    );
    final estimatedBytes = _quality.estimateOutputBytes(
      sourceSizeBytes: _sourceSizeBytes,
      duration: effectiveDuration,
      totalDuration: _videoDuration,
      keepAudio: _keepAudio,
      playbackSpeed: _playbackSpeed.rate,
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
      playbackSpeed: _playbackSpeed.rate,
      isLivePreviewing: _isLiveHolding,
      onTogglePlay: _togglePlay,
      onToggleAudio: _toggleAudio,
      onPickCustomCover: _handleCustomCoverButton,
      onLiveHoldStart: _onLiveHoldStart,
      onLiveHoldEnd: _onLiveHoldEnd,
    );

    final String subtitleText;
    if (_playbackSpeed.isModified) {
      final durationTag =
          '${_playbackSpeed.shortTag} ${formatPreciseDuration(outputDuration)}';
      final prefix = _quality == QualityPreset.passthrough
          ? '原画重编码（$durationTag）'
          : '${_quality.segmentLabel} · $durationTag';
      subtitleText = estimatedBytes > 0
          ? '$prefix · 约 ${formatFileSize(estimatedBytes)}'
          : prefix;
    } else {
      subtitleText = estimatedBytes > 0
          ? '${_quality.subtitle} · 约 ${formatFileSize(estimatedBytes)}'
          : _quality.subtitle;
    }

    final speedRoleLabel = _playbackSpeed.rate > 2.5
        ? '延时'
        : (_playbackSpeed.rate < 0.99 ? '慢放' : '倍速');

    return Column(
      key: const ValueKey<String>('state_editor'),
      mainAxisSize: useFlexibleStage ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (useFlexibleStage)
          Expanded(child: stage)
        else
          SizedBox(height: 250, child: stage),
        const SizedBox(height: Ui.s2),

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
        const SizedBox(height: Ui.s2),

        // 2. Live Speed / Timelapse Strip (0.5x – 4x)
        Row(
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_playbackSpeed.isModified) ...<Widget>[
                  Container(
                    width: 5.5,
                    height: 5.5,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Ui.liveActive,
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                Text(
                  speedRoleLabel,
                  style: Ui.caption.copyWith(
                    color: _playbackSpeed.isModified
                        ? Ui.textPrimary
                        : Ui.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(width: Ui.s2),
            Expanded(
              child: SegmentedTabs<PlaybackSpeedPreset>(
                key: const Key('speed_segmented_tabs'),
                items: PlaybackSpeedPreset.values,
                selectedIndex: _playbackSpeed.index,
                height: 36,
                fontSize: 12.5,
                monospace: true,
                enabled: !_isConverting,
                labelBuilder: (PlaybackSpeedPreset p) => p.label,
                onChanged: (int index) {
                  _setPlaybackSpeed(PlaybackSpeedPreset.values[index]);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: Ui.s1 + 2),

        // 3. Minimalist Sliding Quality Tabs
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
