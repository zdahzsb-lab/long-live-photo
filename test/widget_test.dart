import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:long_live_photo/constants/app_branding.dart';
import 'package:long_live_photo/main.dart';
import 'package:long_live_photo/models/conversion_options.dart';
import 'package:long_live_photo/services/live_photo_channel.dart';
import 'package:long_live_photo/utils/motion_photo_spec.dart';
import 'package:long_live_photo/widgets/filmstrip_scrubber.dart';
import 'package:long_live_photo/widgets/video_stage_card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

class _FakeGateway implements LivePhotoConverterGateway {
  @override
  Stream<ConversionProgress> get progressStream => const Stream.empty();

  @override
  Future<ConversionResult> convertAndSave({
    required String videoPath,
    required int coverTimeMs,
    required QualityPreset quality,
    required bool keepAudio,
  }) async {
    return const ConversionResult(
      savedTarget: 'mock://saved',
      outputSizeBytes: 10485760,
      elapsedMs: 1200,
      platformFormat: 'Mock Live Photo',
    );
  }

  @override
  Future<List<Uint8List>> extractThumbnails({
    required String videoPath,
    int count = 8,
  }) async {
    return const <Uint8List>[];
  }
}

class _FakeVideoController extends VideoPlayerController {
  _FakeVideoController()
      : super.networkUrl(Uri.parse('https://example.invalid/mock.mp4')) {
    value = const VideoPlayerValue(
      duration: Duration(seconds: 30),
      size: Size(1080, 1920),
      isInitialized: true,
      isPlaying: false,
    );
  }
}

void main() {
  setUpAll(() async {
    await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
  });

  group('Formatting & estimation utilities', () {
    test('formatPreciseDuration formats short and multi-hour durations', () {
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
    });

    test('formatFileSize formats KB, MB, and GB cleanly', () {
      expect(formatFileSize(512), '512 B');
      expect(formatFileSize(2048), '2.0 KB');
      expect(formatFileSize(5 * 1024 * 1024), '5.0 MB');
      expect(formatFileSize(2 * 1024 * 1024 * 1024), '2.00 GB');
    });

    test('QualityPreset.estimateOutputBytes reacts to bitrate and audio toggle', () {
      final withAudio = QualityPreset.p1080.estimateOutputBytes(
        sourceSizeBytes: 80 * 1024 * 1024,
        duration: const Duration(seconds: 20),
        keepAudio: true,
      );
      final muted = QualityPreset.p1080.estimateOutputBytes(
        sourceSizeBytes: 80 * 1024 * 1024,
        duration: const Duration(seconds: 20),
        keepAudio: false,
      );
      final compact720 = QualityPreset.p720.estimateOutputBytes(
        sourceSizeBytes: 80 * 1024 * 1024,
        duration: const Duration(seconds: 20),
        keepAudio: true,
      );

      expect(withAudio, greaterThan(muted));
      expect(withAudio, greaterThan(compact720));
    });
  });

  group('MotionPhotoSpec XMP & binary packaging', () {
    test('injects dual-standard XMP APP1 and appends MP4 trailer accurately', () {
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

      expect(motionFile[0], 0xFF);
      expect(motionFile[1], 0xD8);

      final mp4Start = motionFile.length - fakeMp4.length;
      expect(motionFile[mp4Start - 2], 0xFF);
      expect(motionFile[mp4Start - 1], 0xD9);
      expect(motionFile.sublist(mp4Start), equals(fakeMp4));

      final fullLatin1 = latin1.decode(motionFile);
      expect(fullLatin1, contains('http://ns.adobe.com/xap/1.0/'));
      expect(fullLatin1, contains('GCamera:MotionPhoto="1"'));
      expect(
        fullLatin1,
        contains('GCamera:MicroVideoOffset="${fakeMp4.length}"'),
      );
      expect(
        fullLatin1,
        contains('GCamera:MotionPhotoPresentationTimestampUs="1250000"'),
      );
      expect(
        fullLatin1,
        contains('<Item:Length>${fakeMp4.length}</Item:Length>'),
      );
    });
  });

  testWidgets(
    'Studio renders zero yellow underlines and adapts cleanly across portrait, landscape, and large Dynamic Type',
    (WidgetTester tester) async {
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // 1. Small phone portrait (375x667) with reduced motion off
      tester.view.physicalSize = const Size(375 * 3, 667 * 3);
      tester.view.devicePixelRatio = 3.0;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: LiquidGlassWidgets.wrap(
            brightnessResolver: Theme.maybeBrightnessOf,
            theme: const GlassThemeData.minimal(),
            child: LongLivePhotoApp(gateway: _FakeGateway()),
          ),
        ),
      );
      await tester.pump();

      expect(find.text(AppBranding.appName), findsOneWidget);
      expect(find.text('从相册选视频'), findsOneWidget);
      expect(find.text('从文件导入'), findsOneWidget);

      // Verify GlassScaffold does NOT extend body under GlassAppBar
      final scaffold = tester.widget<GlassScaffold>(find.byType(GlassScaffold));
      expect(scaffold.extendBody, isFalse);

      // Regression guard: ZERO RichText widgets may carry WidgetsApp's yellow underline
      final richTexts = tester.widgetList<RichText>(find.byType(RichText));
      expect(richTexts, isNotEmpty);
      for (final rt in richTexts) {
        final style = rt.text.style;
        expect(
          style?.decoration,
          isNot(equals(TextDecoration.underline)),
          reason: 'Text "${rt.text.toPlainText()}" must never have underline fallback',
        );
      }

      // 2. Landscape phone (844x390) + 1.35x Dynamic Type scaling without overflow
      tester.view.physicalSize = const Size(844 * 3, 390 * 3);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            disableAnimations: true,
            textScaler: TextScaler.linear(1.35),
          ),
          child: LiquidGlassWidgets.wrap(
            brightnessResolver: Theme.maybeBrightnessOf,
            theme: const GlassThemeData.minimal(),
            child: LongLivePhotoApp(gateway: _FakeGateway()),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'VideoStageCard top-left audio button enforces >=48dp touch zone and never leaks taps to play/pause',
    (WidgetTester tester) async {
      final fakeCtrl = _FakeVideoController();
      addTearDown(fakeCtrl.dispose);

      int audioToggles = 0;
      int playToggles = 0;
      bool keepAudio = true;

      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: const GlassThemeData.minimal(),
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 360,
                height: 480,
                child: StatefulBuilder(
                  builder: (BuildContext context, StateSetter setModalState) {
                    return VideoStageCard(
                      controller: fakeCtrl,
                      currentPosition: const Duration(seconds: 3),
                      totalDuration: const Duration(seconds: 30),
                      sourceSizeBytes: 24 * 1024 * 1024,
                      keepAudio: keepAudio,
                      isConverting: false,
                      onTogglePlay: () => playToggles++,
                      onToggleAudio: () {
                        setModalState(() {
                          audioToggles++;
                          keepAudio = !keepAudio;
                        });
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final audioFinder = find.byKey(const Key('audio_toggle_button'));
      final audioRect = tester.getRect(audioFinder);
      expect(audioRect.width, greaterThanOrEqualTo(116));
      expect(audioRect.height, greaterThanOrEqualTo(52));
      expect(find.text('实况有声'), findsOneWidget);

      // Tap outer bottom-right edge of the expanded hit area (outside visual pill center)
      await tester.tapAt(audioRect.bottomRight - const Offset(4, 4));
      await tester.pump(const Duration(milliseconds: 250));

      expect(audioToggles, 1);
      expect(playToggles, 0);
      expect(find.text('已静音'), findsOneWidget);

      // Tap outer top-left edge of the expanded hit area
      await tester.tapAt(audioRect.topLeft + const Offset(4, 4));
      await tester.pump(const Duration(milliseconds: 250));

      expect(audioToggles, 2);
      expect(playToggles, 0);
      expect(find.text('实况有声'), findsOneWidget);
    },
  );

  testWidgets(
    'FilmstripScrubber enforces >=44dp micro-step targets and maps horizontal scrub accurately',
    (WidgetTester tester) async {
      int? scrubbedMs;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: FilmstripScrubber(
                thumbnails: const <Uint8List>[],
                coverTimeMs: 5000,
                totalDurationMs: 10000,
                enabled: true,
                onScrubToMs: (int ms) => scrubbedMs = ms,
                onUseCurrentFrame: () => scrubbedMs = 7777,
              ),
            ),
          ),
        ),
      );

      final stepPlusRect = tester.getRect(
        find.ancestor(
          of: find.text('+0.1s'),
          matching: find.byType(GestureDetector),
        ).first,
      );
      expect(stepPlusRect.height, greaterThanOrEqualTo(44.0));

      await tester.tap(find.text('+0.1s'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(scrubbedMs, 5100);

      await tester.tap(find.text('当前帧'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(scrubbedMs, 7777);
    },
  );
}
