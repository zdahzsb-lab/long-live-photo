import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:long_live_photo/constants/app_branding.dart';
import 'package:long_live_photo/main.dart';
import 'package:long_live_photo/models/conversion_options.dart';
import 'package:long_live_photo/services/live_photo_channel.dart';
import 'package:long_live_photo/ui/buttons.dart';
import 'package:long_live_photo/utils/motion_photo_spec.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

class _ControllableGateway implements LivePhotoConverterGateway {
  final StreamController<ConversionProgress> progressController =
      StreamController<ConversionProgress>.broadcast();

  Completer<ConversionResult>? pendingConversion;
  String? lastVideoPath;
  int? lastCoverTimeMs;
  QualityPreset? lastQuality;
  bool? lastKeepAudio;

  @override
  Stream<ConversionProgress> get progressStream => progressController.stream;

  @override
  Future<ConversionResult> convertAndSave({
    required String videoPath,
    required int coverTimeMs,
    required QualityPreset quality,
    required bool keepAudio,
  }) {
    lastVideoPath = videoPath;
    lastCoverTimeMs = coverTimeMs;
    lastQuality = quality;
    lastKeepAudio = keepAudio;
    final completer = Completer<ConversionResult>();
    pendingConversion = completer;
    return completer.future;
  }

  @override
  Future<List<Uint8List>> extractThumbnails({
    required String videoPath,
    int count = 8,
  }) async {
    return const <Uint8List>[];
  }

  void dispose() {
    progressController.close();
  }
}

class _FakeVideoController extends VideoPlayerController {
  _FakeVideoController()
      : super.networkUrl(Uri.parse('https://example.invalid/mock.mp4')) {
    value = const VideoPlayerValue(
      duration: Duration(seconds: 25),
      position: Duration(milliseconds: 500),
      size: Size(1080, 1920),
      isInitialized: true,
      isPlaying: false,
    );
  }

  double lastVolume = 1.0;
  Duration lastSeek = const Duration(milliseconds: 500);

  @override
  Future<void> play() async {
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> setVolume(double volume) async {
    lastVolume = volume;
    value = value.copyWith(volume: volume);
  }

  @override
  Future<void> seekTo(Duration position) async {
    lastSeek = position;
    value = value.copyWith(position: position);
  }
}

void main() {
  group('Formatting, estimation & XMP binary spec', () {
    test('formatPreciseDuration & formatFileSize format values accurately', () {
      expect(
        formatPreciseDuration(const Duration(seconds: 84, milliseconds: 350)),
        '01:24.3',
      );
      expect(
        formatPreciseDuration(
          const Duration(hours: 1, minutes: 5, seconds: 9, milliseconds: 800),
        ),
        '01:05:09.8',
      );
      expect(formatFileSize(512), '512 B');
      expect(formatFileSize(2048), '2.0 KB');
      expect(formatFileSize(5 * 1024 * 1024), '5.0 MB');
      expect(formatFileSize(2 * 1024 * 1024 * 1024), '2.00 GB');
    });

    test('QualityPreset.estimateOutputBytes reacts to bitrate and audio', () {
      final p1080Audio = QualityPreset.p1080.estimateOutputBytes(
        sourceSizeBytes: 80 * 1024 * 1024,
        duration: const Duration(seconds: 20),
        keepAudio: true,
      );
      final p1080Muted = QualityPreset.p1080.estimateOutputBytes(
        sourceSizeBytes: 80 * 1024 * 1024,
        duration: const Duration(seconds: 20),
        keepAudio: false,
      );
      final p720Audio = QualityPreset.p720.estimateOutputBytes(
        sourceSizeBytes: 80 * 1024 * 1024,
        duration: const Duration(seconds: 20),
        keepAudio: true,
      );

      expect(p1080Audio, greaterThan(p1080Muted));
      expect(p1080Audio, greaterThan(p720Audio));
    });

    test('MotionPhotoSpec injects dual-standard XMP APP1 and MP4 trailer', () {
      final minimalJpeg = Uint8List.fromList(<int>[
        0xFF, 0xD8,
        0xFF, 0xE0, 0x00, 0x06, 0x4A, 0x46, 0x49, 0x46,
        0xFF, 0xDA, 0x00, 0x04, 0x00, 0x01,
        0x7F,
        0xFF, 0xD9,
      ]);
      final fakeMp4 = Uint8List.fromList(
        ascii.encode('0000ftypisom_unlimited_duration_mp4_payload_stream'),
      );

      final motionFile = MotionPhotoSpec.assembleMotionPhoto(
        jpegBytes: minimalJpeg,
        mp4Bytes: fakeMp4,
        presentationTimestampUs: 1250000,
      );

      final mp4Start = motionFile.length - fakeMp4.length;
      expect(motionFile[0], 0xFF);
      expect(motionFile[1], 0xD8);
      expect(motionFile[mp4Start - 2], 0xFF);
      expect(motionFile[mp4Start - 1], 0xD9);
      expect(motionFile.sublist(mp4Start), equals(fakeMp4));

      final fullLatin1 = latin1.decode(motionFile);
      expect(fullLatin1, contains('GCamera:MotionPhoto="1"'));
      expect(
        fullLatin1,
        contains('GCamera:MicroVideoOffset="${fakeMp4.length}"'),
      );
      expect(
        fullLatin1,
        contains('GCamera:MotionPhotoPresentationTimestampUs="1250000"'),
      );
    });
  });

  testWidgets(
    'Welcome screen renders cleanly across small phone, landscape, and 1.4x Dynamic Type with zero underlines',
    (WidgetTester tester) async {
      final gateway = _ControllableGateway();
      addTearDown(() {
        gateway.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      tester.view.physicalSize = const Size(375 * 3, 667 * 3);
      tester.view.devicePixelRatio = 3.0;

      await tester.pumpWidget(LongLivePhotoApp(gateway: gateway));
      await tester.pumpAndSettle();

      expect(find.text(AppBranding.appName), findsOneWidget);
      expect(find.text('长视频转实况照片'), findsOneWidget);
      expect(find.text('从相册选视频'), findsOneWidget);
      expect(find.text('从文件导入'), findsOneWidget);

      final galleryRect = tester.getRect(
        find.byKey(const Key('pick_gallery_button')),
      );
      expect(galleryRect.height, greaterThanOrEqualTo(52));

      for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
        expect(rt.text.style?.decoration, isNot(equals(TextDecoration.underline)));
      }

      // Landscape + 1.4x font scaling
      tester.view.physicalSize = const Size(844 * 3, 390 * 3);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: LongLivePhotoApp(gateway: gateway),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Pressable spring responds within a single 16ms frame on pointer-down and settles cleanly',
    (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                child: PrimaryButton(
                  key: const Key('spring_btn'),
                  label: '丝滑测试',
                  onTap: () => taps++,
                ),
              ),
            ),
          ),
        ),
      );

      double readScale() {
        final transform = tester.widget<Transform>(
          find.descendant(
            of: find.byKey(const Key('spring_btn')),
            matching: find.byType(Transform),
          ),
        );
        return transform.transform.storage[0];
      }

      expect(readScale(), closeTo(1.0, 0.0001));

      // Pointer touches down — Ticker stamps t0 on frame 0 and compresses by 16ms (no 100ms arena lag!)
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('spring_btn'))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(readScale(), lessThan(0.999));
      await tester.pump(const Duration(milliseconds: 32));
      expect(readScale(), lessThan(0.988));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(readScale(), closeTo(1.0, 0.001));
    },
  );

  testWidgets(
    'Full Studio Editor workflow: audio switch, play/pause, filmstrip scrub, quality glide, replace sheet, and conversion progress to result sheet',
    (WidgetTester tester) async {
      final gateway = _ControllableGateway();
      final fakeCtrl = _FakeVideoController();
      addTearDown(() {
        gateway.dispose();
        fakeCtrl.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3.0;

      await tester.pumpWidget(
        LongLivePhotoApp(
          gateway: gateway,
          debugInitialController: fakeCtrl,
          debugInitialVideoPath: 'mock://clip.mp4',
          debugInitialSizeBytes: 32 * 1024 * 1024,
        ),
      );
      await tester.pumpAndSettle();

      // 1. Top-left audio switch (>=112x48dp, zero leak to play/pause)
      final audioFinder = find.byKey(const Key('audio_toggle_button'));
      final audioRect = tester.getRect(audioFinder);
      expect(audioRect.width, greaterThanOrEqualTo(112));
      expect(audioRect.height, greaterThanOrEqualTo(48));
      expect(find.text('实况有声'), findsOneWidget);

      await tester.tapAt(audioRect.bottomRight - const Offset(3, 3));
      await tester.pumpAndSettle();
      expect(find.text('已静音'), findsOneWidget);
      expect(fakeCtrl.lastVolume, 0.0);
      expect(fakeCtrl.value.isPlaying, isFalse);

      // 2. Play / Pause toggle on viewport
      await tester.tap(find.bySemanticsLabel('播放视频预览'));
      await tester.pumpAndSettle();
      expect(fakeCtrl.value.isPlaying, isTrue);

      await tester.tapAt(tester.getCenter(find.byKey(const Key('video_viewport_tap'))));
      await tester.pumpAndSettle();
      expect(fakeCtrl.value.isPlaying, isFalse);

      // 3. Filmstrip micro-steppers (+0.1s, -0.1s, 当前帧) & drag scrub
      await tester.tap(find.text('+0.1s'));
      await tester.pumpAndSettle();
      expect(fakeCtrl.lastSeek.inMilliseconds, 600);

      await tester.drag(
        find.bySemanticsLabel('拖动胶片轨道选择实况封面帧'),
        const Offset(100, 0),
      );
      await tester.pumpAndSettle();
      expect(fakeCtrl.lastSeek.inMilliseconds, greaterThan(600));

      // 4. Sliding quality segmented tabs
      await tester.tap(find.text('720p 省流'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2.8 Mbps'), findsOneWidget);

      // 5. Replace video bottom sheet opens and dismisses cleanly
      await tester.tap(find.byKey(const Key('replace_video_button')));
      await tester.pumpAndSettle();
      expect(find.text('更换视频素材'), findsOneWidget);
      expect(find.text('从系统相册选择'), findsOneWidget);
      await tester.tapAt(const Offset(20, 40)); // tap barrier to dismiss
      await tester.pumpAndSettle();
      expect(find.text('更换视频素材'), findsNothing);

      // 6. Full conversion pipeline -> live sweep progress -> result sheet -> dismiss
      await tester.tap(find.byKey(const Key('convert_save_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('正在准备实况合成'), findsOneWidget);

      gateway.progressController.add(
        const ConversionProgress(
          stage: 'encoding',
          progress: 0.56,
          message: '正在封装实况轨道...',
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('56%'), findsOneWidget);

      gateway.pendingConversion!.complete(
        const ConversionResult(
          savedTarget: 'mock://dcim/MVIMG_001.jpg',
          outputSizeBytes: 9 * 1024 * 1024,
          elapsedMs: 1800,
          platformFormat: 'Motion Photo',
        ),
      );
      await tester.pumpAndSettle();

      expect(gateway.lastVideoPath, 'mock://clip.mp4');
      expect(gateway.lastQuality, QualityPreset.p720);
      expect(gateway.lastKeepAudio, isFalse);

      // Result bottom sheet verified
      expect(find.text('已存入系统相册'), findsOneWidget);
      expect(find.text('9.0 MB'), findsOneWidget);
      expect(find.text('1.8s'), findsOneWidget);

      await tester.tap(find.byKey(const Key('result_done_button')));
      await tester.pumpAndSettle();
      expect(find.text('已存入系统相册'), findsNothing);
    },
  );
}
