import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
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
  String? lastCustomCoverPath;
  int? lastTrimStartMs;
  int? lastTrimEndMs;
  bool? lastPreserveMetadata;
  int cancelCalls = 0;

  @override
  Stream<ConversionProgress> get progressStream => progressController.stream;

  @override
  Future<ConversionResult> convertAndSave({
    required String videoPath,
    required int coverTimeMs,
    required QualityPreset quality,
    required bool keepAudio,
    String? customCoverPath,
    int? trimStartMs,
    int? trimEndMs,
    bool preserveMetadata = true,
  }) {
    lastVideoPath = videoPath;
    lastCoverTimeMs = coverTimeMs;
    lastQuality = quality;
    lastKeepAudio = keepAudio;
    lastCustomCoverPath = customCoverPath;
    lastTrimStartMs = trimStartMs;
    lastTrimEndMs = trimEndMs;
    lastPreserveMetadata = preserveMetadata;
    final completer = Completer<ConversionResult>();
    pendingConversion = completer;
    return completer.future;
  }

  @override
  Future<void> cancelConversion() async {
    cancelCalls++;
    final pending = pendingConversion;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        PlatformException(code: 'CANCELLED', message: '已取消实况合成'),
      );
    }
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
  _FakeVideoController({
    Duration duration = const Duration(seconds: 25),
    Duration position = const Duration(milliseconds: 500),
  }) : super.networkUrl(Uri.parse('https://example.invalid/mock.mp4')) {
    value = VideoPlayerValue(
      duration: duration,
      position: position,
      size: const Size(1080, 1920),
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
  group('Formatting, trim math, estimation & XMP binary spec', () {
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

    test('VideoTrimMath clamps trim bounds, minimum 500ms span, and cover time', () {
      // Normal clamp
      final r1 = VideoTrimMath.clampTrimRange(
        startMs: -200,
        endMs: 12000,
        totalMs: 10000,
      );
      expect(r1.startMs, 0);
      expect(r1.endMs, 10000);

      // Enforces minimum 500ms span
      final r2 = VideoTrimMath.clampTrimRange(
        startMs: 5000,
        endMs: 5100,
        totalMs: 10000,
      );
      expect(r2.endMs - r2.startMs, greaterThanOrEqualTo(500));

      // Ultra-short video shorter than 500ms
      final r3 = VideoTrimMath.clampTrimRange(
        startMs: 100,
        endMs: 200,
        totalMs: 320,
      );
      expect(r3.startMs, 0);
      expect(r3.endMs, 320);

      expect(
        VideoTrimMath.clampCoverToTrim(coverMs: 200, startMs: 1000, endMs: 8000),
        1000,
      );
      expect(
        VideoTrimMath.clampCoverToTrim(coverMs: 9000, startMs: 1000, endMs: 8000),
        8000,
      );
      expect(
        VideoTrimMath.isEffectivelyTrimmed(
          startMs: 20,
          endMs: 9970,
          totalMs: 10000,
        ),
        isFalse,
      );
      expect(
        VideoTrimMath.isEffectivelyTrimmed(
          startMs: 500,
          endMs: 10000,
          totalMs: 10000,
        ),
        isTrue,
      );
    });

    test('QualityPreset.estimateOutputBytes scales with trim duration and audio', () {
      final full1080 = QualityPreset.p1080.estimateOutputBytes(
        sourceSizeBytes: 80 * 1024 * 1024,
        duration: const Duration(seconds: 20),
        totalDuration: const Duration(seconds: 20),
        keepAudio: true,
      );
      final trimmed1080 = QualityPreset.p1080.estimateOutputBytes(
        sourceSizeBytes: 80 * 1024 * 1024,
        duration: const Duration(seconds: 10),
        totalDuration: const Duration(seconds: 20),
        keepAudio: true,
      );
      final fullPassthrough = QualityPreset.passthrough.estimateOutputBytes(
        sourceSizeBytes: 80 * 1024 * 1024,
        duration: const Duration(seconds: 20),
        totalDuration: const Duration(seconds: 20),
        keepAudio: true,
      );
      final trimmedPassthrough = QualityPreset.passthrough.estimateOutputBytes(
        sourceSizeBytes: 80 * 1024 * 1024,
        duration: const Duration(seconds: 10),
        totalDuration: const Duration(seconds: 20),
        keepAudio: true,
      );

      expect(full1080, greaterThan(trimmed1080));
      expect(fullPassthrough, greaterThan(trimmedPassthrough));
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
    'Welcome & Editor screens render without overflow across 375x667, landscape, and 1.4x Dynamic Type',
    (WidgetTester tester) async {
      final gateway = _ControllableGateway();
      final fakeCtrl = _FakeVideoController();
      addTearDown(() {
        gateway.dispose();
        fakeCtrl.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // 1. Small phone portrait welcome screen (375x667)
      tester.view.physicalSize = const Size(375 * 3, 667 * 3);
      tester.view.devicePixelRatio = 3.0;

      await tester.pumpWidget(LongLivePhotoApp(gateway: gateway));
      await tester.pumpAndSettle();

      expect(find.text(AppBranding.appName), findsOneWidget);
      expect(find.text('长视频转实况照片'), findsOneWidget);
      expect(find.text('从相册选视频'), findsOneWidget);

      for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
        expect(rt.text.style?.decoration, isNot(equals(TextDecoration.underline)));
      }

      // 2. Small phone portrait editor screen (375x667) + 1.4x Dynamic Type
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: LongLivePhotoApp(
            gateway: gateway,
            debugInitialController: fakeCtrl,
            debugInitialVideoPath: 'mock://clip.mp4',
            debugInitialSizeBytes: 32 * 1024 * 1024,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('custom_cover_button')), findsOneWidget);
      expect(find.byKey(const Key('preserve_metadata_toggle')), findsOneWidget);

      // 3. Landscape phone (844x390) + 1.4x Dynamic Type
      tester.view.physicalSize = const Size(844 * 3, 390 * 3);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: LongLivePhotoApp(
            gateway: gateway,
            debugInitialController: fakeCtrl,
            debugInitialVideoPath: 'mock://clip.mp4',
            debugInitialSizeBytes: 32 * 1024 * 1024,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Pressable spring responds within 16ms on pointer-down and settles cleanly',
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
    'Editor workflow: trim handles, reset trim, custom cover badge, metadata toggle, hold-to-preview, and cancel conversion',
    (WidgetTester tester) async {
      final gateway = _ControllableGateway();
      final fakeCtrl = _FakeVideoController(
        duration: const Duration(seconds: 25),
        position: const Duration(milliseconds: 500),
      );
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
          debugInitialCustomCoverPath: 'mock://custom_cover.jpg',
        ),
      );
      await tester.pumpAndSettle();

      // 1. Custom cover button reflects active external cover & can restore video frame
      expect(find.text('已换封面'), findsOneWidget);
      await tester.tap(find.byKey(const Key('custom_cover_button')));
      await tester.pumpAndSettle();
      expect(find.text('自定义静态封面'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sheet_restore_frame_cover')));
      await tester.pumpAndSettle();
      expect(find.text('自选封面'), findsOneWidget);

      // 2. Drag left & right trim handles -> verify trim summary + cover clamp + reset
      await tester.drag(
        find.byKey(const Key('trim_start_handle')),
        const Offset(80, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reset_trim_button')), findsOneWidget);
      expect(find.textContaining('截取'), findsOneWidget);

      await tester.drag(
        find.byKey(const Key('trim_end_handle')),
        const Offset(-60, 0),
      );
      await tester.pumpAndSettle();

      // Reset trim restores full length
      await tester.tap(find.byKey(const Key('reset_trim_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reset_trim_button')), findsNothing);

      // Re-apply a start trim so conversion payload sends trimStartMs/trimEndMs
      await tester.drag(
        find.byKey(const Key('trim_start_handle')),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();

      // 3. Toggle metadata preservation off
      expect(find.text('原拍摄时间'), findsOneWidget);
      await tester.tap(find.byKey(const Key('preserve_metadata_toggle')));
      await tester.pumpAndSettle();
      expect(find.text('当前时间'), findsOneWidget);

      // 4. Start conversion -> cancel mid-flight -> verify CANCELLED state & restoration
      await tester.tap(find.byKey(const Key('convert_save_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      expect(find.byKey(const Key('cancel_convert_button')), findsOneWidget);
      expect(gateway.lastTrimStartMs, greaterThan(0));
      expect(gateway.lastTrimEndMs, 25000);
      expect(gateway.lastPreserveMetadata, isFalse);

      await tester.tap(find.byKey(const Key('cancel_convert_button')));
      await tester.pumpAndSettle();

      expect(gateway.cancelCalls, 1);
      expect(find.text('已取消合成'), findsOneWidget);
      expect(find.byKey(const Key('cancel_convert_button')), findsNothing);
      expect(find.text('生成实况并存入相册'), findsOneWidget);
    },
  );

  testWidgets(
    'Full conversion flow: audio toggle, custom cover pass-through, metadata ON, progress sweep, and result sheet',
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
          debugInitialCustomCoverPath: 'mock://portrait_cover.jpg',
        ),
      );
      await tester.pumpAndSettle();

      // Top-left audio switch (>=112x48dp, zero leak to play/pause)
      final audioFinder = find.byKey(const Key('audio_toggle_button'));
      final audioRect = tester.getRect(audioFinder);
      expect(audioRect.width, greaterThanOrEqualTo(112));
      expect(audioRect.height, greaterThanOrEqualTo(48));
      await tester.tapAt(audioRect.bottomRight - const Offset(3, 3));
      await tester.pumpAndSettle();
      expect(find.text('已静音'), findsOneWidget);
      expect(fakeCtrl.lastVolume, 0.0);
      expect(fakeCtrl.value.isPlaying, isFalse);

      // Hold-to-preview-Live gesture on stage
      final holdGesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('video_viewport_tap'))),
      );
      await tester.pump(const Duration(milliseconds: 650));
      expect(fakeCtrl.value.isPlaying, isTrue);
      expect(find.text('实况预览'), findsOneWidget);
      await holdGesture.up();
      await tester.pumpAndSettle();
      expect(fakeCtrl.value.isPlaying, isFalse);

      // Quality glide & conversion
      await tester.tap(find.text('720p 省流'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('convert_save_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      gateway.progressController.add(
        const ConversionProgress(
          stage: 'encoding',
          progress: 0.64,
          message: '正在封装实况轨道...',
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('64%'), findsOneWidget);

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
      expect(gateway.lastCustomCoverPath, 'mock://portrait_cover.jpg');
      expect(gateway.lastTrimStartMs, isNull);
      expect(gateway.lastTrimEndMs, isNull);
      expect(gateway.lastPreserveMetadata, isTrue);
      expect(gateway.lastQuality, QualityPreset.p720);
      expect(gateway.lastKeepAudio, isFalse);

      expect(find.text('已存入系统相册'), findsOneWidget);
      expect(find.text('9.0 MB'), findsOneWidget);
      expect(find.text('1.8s'), findsOneWidget);

      await tester.tap(find.byKey(const Key('result_done_button')));
      await tester.pumpAndSettle();
      expect(find.text('已存入系统相册'), findsNothing);
    },
  );
}
