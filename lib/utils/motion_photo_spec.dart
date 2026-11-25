import 'dart:convert';
import 'dart:typed_data';

/// Reference builder for Android Motion Photo XMP (compatible with both
/// Android Motion Photo 1.0 Container:Directory and legacy GCamera:MicroVideo).
/// Kept in sync with Android's MotionPhotoXmpInjector.kt and verified by unit tests.
class MotionPhotoSpec {
  static const String xmpNamespaceHeader = 'http://ns.adobe.com/xap/1.0/\x00';

  static String buildDualStandardXmpXml({
    required int videoLengthBytes,
    required int presentationTimestampUs,
  }) {
    if (videoLengthBytes <= 0) {
      throw ArgumentError.value(
        videoLengthBytes,
        'videoLengthBytes',
        'Embedded video byte length must be positive.',
      );
    }
    final safeTs = presentationTimestampUs < 0 ? 0 : presentationTimestampUs;
    return '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.0-jc003">'
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
        '<rdf:Description rdf:about="" '
        'xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" '
        'xmlns:Container="http://ns.google.com/photos/1.0/container/" '
        'xmlns:Item="http://ns.google.com/photos/1.0/container/item/" '
        'GCamera:MotionPhoto="1" '
        'GCamera:MotionPhotoVersion="1" '
        'GCamera:MotionPhotoPresentationTimestampUs="$safeTs" '
        'GCamera:MicroVideo="1" '
        'GCamera:MicroVideoVersion="1" '
        'GCamera:MicroVideoOffset="$videoLengthBytes" '
        'GCamera:MicroVideoPresentationTimestampUs="$safeTs">'
        '<Container:Directory>'
        '<rdf:Seq>'
        '<rdf:li rdf:parseType="Resource">'
        '<Item:Mime>image/jpeg</Item:Mime>'
        '<Item:Semantic>Primary</Item:Semantic>'
        '<Item:Length>0</Item:Length>'
        '<Item:Padding>0</Item:Padding>'
        '</rdf:li>'
        '<rdf:li rdf:parseType="Resource">'
        '<Item:Mime>video/mp4</Item:Mime>'
        '<Item:Semantic>MotionPhoto</Item:Semantic>'
        '<Item:Length>$videoLengthBytes</Item:Length>'
        '<Item:Padding>0</Item:Padding>'
        '</rdf:li>'
        '</rdf:Seq>'
        '</Container:Directory>'
        '</rdf:Description>'
        '</rdf:RDF>'
        '</x:xmpmeta>';
  }

  /// Injects an APP1 XMP segment into [jpegBytes] and appends [mp4Bytes] to form
  /// a single-file Android Motion Photo.
  static Uint8List assembleMotionPhoto({
    required Uint8List jpegBytes,
    required Uint8List mp4Bytes,
    required int presentationTimestampUs,
  }) {
    if (jpegBytes.length < 4 ||
        jpegBytes[0] != 0xFF ||
        jpegBytes[1] != 0xD8) {
      throw const FormatException('Invalid JPEG header (missing SOI FF D8).');
    }

    final xml = buildDualStandardXmpXml(
      videoLengthBytes: mp4Bytes.length,
      presentationTimestampUs: presentationTimestampUs,
    );
    final headerBytes = ascii.encode(xmpNamespaceHeader);
    final xmlBytes = utf8.encode(xml);
    final segmentPayloadLen = headerBytes.length + xmlBytes.length + 2;
    if (segmentPayloadLen > 0xFFFF) {
      throw StateError('XMP APP1 segment exceeds 64KB JPEG limit.');
    }

    // Locate insertion offset right after SOI (and after APP0/EXIF APP1 if present),
    // skipping any pre-existing XMP APP1 segment so we don't duplicate XMP.
    final strippedJpeg = _stripExistingXmpAndFindInsertOffset(jpegBytes);
    final cleanJpeg = strippedJpeg.bytes;
    final insertAt = strippedJpeg.insertOffset;

    final out = BytesBuilder(copy: false);
    out.add(Uint8List.sublistView(cleanJpeg, 0, insertAt));
    out.addByte(0xFF);
    out.addByte(0xE1);
    out.addByte((segmentPayloadLen >> 8) & 0xFF);
    out.addByte(segmentPayloadLen & 0xFF);
    out.add(headerBytes);
    out.add(xmlBytes);
    out.add(Uint8List.sublistView(cleanJpeg, insertAt));
    out.add(mp4Bytes);
    return out.toBytes();
  }

  static ({Uint8List bytes, int insertOffset})
      _stripExistingXmpAndFindInsertOffset(Uint8List jpeg) {
    final headerBytes = ascii.encode(xmpNamespaceHeader);
    final kept = BytesBuilder(copy: false);
    kept.addByte(0xFF);
    kept.addByte(0xD8);

    int pos = 2;
    int insertOffset = 2;
    bool passedMetadataPrefix = false;

    while (!passedMetadataPrefix && pos + 4 <= jpeg.length) {
      if (jpeg[pos] != 0xFF) break;
      final marker = jpeg[pos + 1];
      // SOS (FF DA) or EOI (FF D9) means image scan started
      if (marker == 0xDA || marker == 0xD9) {
        passedMetadataPrefix = true;
        break;
      }
      if (marker == 0xFF) {
        pos++;
        continue;
      }
      final segLen = (jpeg[pos + 2] << 8) | jpeg[pos + 3];
      if (segLen < 2 || pos + 2 + segLen > jpeg.length) {
        break;
      }
      final segEnd = pos + 2 + segLen;

      bool isXmp = false;
      if (marker == 0xE1 && segLen >= 2 + headerBytes.length) {
        isXmp = true;
        for (int i = 0; i < headerBytes.length; i++) {
          if (jpeg[pos + 4 + i] != headerBytes[i]) {
            isXmp = false;
            break;
          }
        }
      }

      if (!isXmp) {
        kept.add(Uint8List.sublistView(jpeg, pos, segEnd));
        if (marker == 0xE0 || marker == 0xE1) {
          insertOffset = kept.length;
        }
      }
      pos = segEnd;
    }

    if (pos < jpeg.length) {
      kept.add(Uint8List.sublistView(jpeg, pos));
    }
    return (bytes: kept.toBytes(), insertOffset: insertOffset);
  }
}
