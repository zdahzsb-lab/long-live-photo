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
import 'package:material_ui/material_ui.dart';

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

void main() {
  setUpAll(() async {
    await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
  });

  group('Formatting utilities', () {
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
      expect(fullLatin1, contains('GCamera:MicroVideoOffset="${fakeMp4.length}"'));
      expect(
        fullLatin1,
        contains('GCamera:MotionPhotoPresentationTimestampUs="1250000"'),
      );
      expect(fullLatin1, contains('<Item:Length>${fakeMp4.length}</Item:Length>'));
    });
  });

  testWidgets('Liquid Glass Studio renders one-screen canvas without overflow', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: const GlassThemeData.minimal(),
        child: LongLivePhotoApp(gateway: _FakeGateway()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text(AppBranding.appName), findsOneWidget);
    expect(find.text('从相册选视频'), findsOneWidget);
    expect(find.text('从文件导入'), findsOneWidget);
    expect(find.text('原画秒转'), findsOneWidget);
    expect(find.text('1080p 均衡'), findsOneWidget);
    expect(find.text('720p 省流'), findsOneWidget);

    final saveBtn = tester.widget<GlassButton>(
      find.byKey(const Key('convert_save_button')),
    );
    expect(saveBtn.enabled, isFalse);
  });

  testWidgets('FilmstripScrubber maps horizontal tap and micro-steps accurately', (
    WidgetTester tester,
  ) async {
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

    await tester.tap(find.text('+0.1s'));
    await tester.pump();
    expect(scrubbedMs, 5100);

    await tester.tap(find.text('当前帧'));
    await tester.pump();
    expect(scrubbedMs, 7777);
  });
}
