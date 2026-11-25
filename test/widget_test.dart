import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:long_live_photo/main.dart';
import 'package:long_live_photo/models/conversion_options.dart';
import 'package:long_live_photo/services/live_photo_channel.dart';
import 'package:long_live_photo/utils/motion_photo_spec.dart';

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
}

void main() {
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
      // Minimal synthetic JPEG: SOI + APP0 (JFIF) + SOS + scan byte + EOI
      final minimalJpeg = Uint8List.fromList(<int>[
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x06, 0x4A, 0x46, 0x49, 0x46, // APP0
        0xFF, 0xDA, 0x00, 0x04, 0x00, 0x01, // SOS
        0x7F, // compressed scan payload
        0xFF, 0xD9, // EOI
      ]);
      final fakeMp4 = Uint8List.fromList(
        ascii.encode('0000ftypisom_unlimited_duration_mp4_payload_stream'),
      );

      final motionFile = MotionPhotoSpec.assembleMotionPhoto(
        jpegBytes: minimalJpeg,
        mp4Bytes: fakeMp4,
        presentationTimestampUs: 1250000,
      );

      // Must start with JPEG SOI
      expect(motionFile[0], 0xFF);
      expect(motionFile[1], 0xD8);

      // Trailer offset math: FileSize - MicroVideoOffset == exact MP4 start
      final mp4Start = motionFile.length - fakeMp4.length;
      expect(motionFile[mp4Start - 2], 0xFF);
      expect(motionFile[mp4Start - 1], 0xD9);
      expect(
        motionFile.sublist(mp4Start),
        equals(fakeMp4),
      );

      // Verify embedded XMP metadata string
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

  testWidgets('ConverterHomePage renders controls and presets properly', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(LongLivePhotoApp(gateway: _FakeGateway()));

    expect(find.text('长实况 · 全时长视频转实况'), findsOneWidget);
    expect(find.text('从相册选视频'), findsOneWidget);
    expect(find.text('从文件选视频'), findsOneWidget);
    expect(find.text('原画直通（秒转 · 零重压）'), findsOneWidget);
    expect(find.text('1080p 高清均衡（推荐）'), findsOneWidget);
    expect(find.text('720p 省空间（超长视频专用）'), findsOneWidget);

    final saveBtn = tester.widget<FilledButton>(
      find.byKey(const Key('convert_save_button')),
    );
    expect(saveBtn.onPressed, isNull);
  });
}
