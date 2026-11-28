import 'dart:convert';
import 'dart:typed_data';

/// Result of unpacking an embedded video + still cover from an Android Motion Photo JPEG.
class ExtractedMotionPhoto {
  const ExtractedMotionPhoto({
    required this.jpegBytes,
    required this.mp4Bytes,
    required this.presentationTimestampUs,
  });

  final Uint8List jpegBytes;
  final Uint8List mp4Bytes;
  final int presentationTimestampUs;
}

/// Reference builder and unpacker for Android Motion Photo XMP (compatible with both
/// Android Motion Photo 1.0 Container:Directory and legacy GCamera:MicroVideo).
/// Kept in sync with Android's MotionPhotoXmpInjector.kt and verified by unit tests.
class MotionPhotoSpec {
  static const String xmpNamespaceHeader = 'http://ns.adobe.com/xap/1.0/\x00';
  static final List<int> _samsungMotionMarker =
      ascii.encode('MotionPhoto_Data');
  static final List<int> _ftypTag = ascii.encode('ftyp');

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

  /// Extracts the still cover JPEG (with Motion Photo XMP stripped) and embedded MP4
  /// video stream from an Android Motion Photo file, or returns `null` if [fileBytes]
  /// is a regular static image without an embedded MP4 trailer.
  static ExtractedMotionPhoto? extractMotionPhoto(Uint8List fileBytes) {
    if (fileBytes.length < 24 ||
        fileBytes[0] != 0xFF ||
        fileBytes[1] != 0xD8) {
      return null;
    }

    final xmpInfo = _parseMotionPhotoXmp(fileBytes);
    final presentationUs = xmpInfo?.presentationTimestampUs ?? 0;

    int? mp4Start;
    int? jpegEnd;

    if (xmpInfo != null && xmpInfo.videoLengthBytes > 0) {
      final candidate = fileBytes.length - xmpInfo.videoLengthBytes;
      final resolved = _resolveMp4AtCandidate(fileBytes, candidate);
      if (resolved != null) {
        mp4Start = resolved.mp4Start;
        jpegEnd = resolved.jpegEnd;
      }
    }

    if (mp4Start == null || jpegEnd == null) {
      final fallback = _scanMp4AfterJpegEoi(fileBytes);
      if (fallback != null) {
        mp4Start = fallback.mp4Start;
        jpegEnd = fallback.jpegEnd;
      }
    }

    if (mp4Start == null ||
        jpegEnd == null ||
        jpegEnd < 4 ||
        mp4Start < jpegEnd ||
        mp4Start >= fileBytes.length) {
      return null;
    }

    final rawJpeg = Uint8List.sublistView(fileBytes, 0, jpegEnd);
    final cleanJpeg = _stripExistingXmpAndFindInsertOffset(rawJpeg).bytes;
    final mp4Bytes = Uint8List.fromList(
      Uint8List.sublistView(fileBytes, mp4Start),
    );
    if (mp4Bytes.length < 16) {
      return null;
    }

    return ExtractedMotionPhoto(
      jpegBytes: cleanJpeg,
      mp4Bytes: mp4Bytes,
      presentationTimestampUs: presentationUs,
    );
  }

  static ({int mp4Start, int jpegEnd})? _resolveMp4AtCandidate(
    Uint8List bytes,
    int candidate,
  ) {
    if (candidate < 4 || candidate + 8 > bytes.length) return null;

    if (_hasValidFtypHeader(bytes, candidate)) {
      final jpegEnd = _findPrecedingJpegEnd(bytes, candidate);
      if (jpegEnd != null) {
        return (mp4Start: candidate, jpegEnd: jpegEnd);
      }
    }

    if (candidate + _samsungMotionMarker.length + 8 <= bytes.length &&
        _matchesBytesAt(bytes, candidate, _samsungMotionMarker)) {
      final afterMarker = candidate + _samsungMotionMarker.length;
      if (_hasValidFtypHeader(bytes, afterMarker)) {
        final jpegEnd = _findPrecedingJpegEnd(bytes, candidate);
        if (jpegEnd != null) {
          return (mp4Start: afterMarker, jpegEnd: jpegEnd);
        }
      }
    }

    return null;
  }

  static ({int mp4Start, int jpegEnd})? _scanMp4AfterJpegEoi(Uint8List bytes) {
    final eoiEnd = _findPrimaryJpegEoiEnd(bytes);
    if (eoiEnd == null || eoiEnd >= bytes.length - 12) return null;

    // 1. Direct MP4 right after JPEG EOI
    if (_hasValidFtypHeader(bytes, eoiEnd)) {
      return (mp4Start: eoiEnd, jpegEnd: eoiEnd);
    }

    // 2. Samsung "MotionPhoto_Data" prefix right after EOI (or within small gap)
    final scanLimit = (eoiEnd + 64).clamp(eoiEnd, bytes.length);
    for (int i = eoiEnd; i <= scanLimit - _samsungMotionMarker.length - 8; i++) {
      if (_matchesBytesAt(bytes, i, _samsungMotionMarker)) {
        final afterMarker = i + _samsungMotionMarker.length;
        if (_hasValidFtypHeader(bytes, afterMarker)) {
          return (mp4Start: afterMarker, jpegEnd: eoiEnd);
        }
      }
    }

    // 3. Fallback scan after EOI for valid [boxSize][ftyp] box
    for (int i = eoiEnd; i <= bytes.length - 12; i++) {
      if (_hasValidFtypHeader(bytes, i)) {
        return (mp4Start: i, jpegEnd: eoiEnd);
      }
    }
    return null;
  }

  static int? _findPrecedingJpegEnd(Uint8List bytes, int limitOffset) {
    if (limitOffset >= 4 &&
        bytes[limitOffset - 2] == 0xFF &&
        bytes[limitOffset - 1] == 0xD9) {
      return limitOffset;
    }
    final eoiEnd = _findPrimaryJpegEoiEnd(bytes);
    if (eoiEnd != null && eoiEnd <= limitOffset) {
      return eoiEnd;
    }
    return limitOffset >= 4 ? limitOffset : null;
  }

  static int? _findPrimaryJpegEoiEnd(Uint8List bytes) {
    int pos = 2;
    bool inEntropy = false;

    while (pos + 1 < bytes.length) {
      if (!inEntropy) {
        if (bytes[pos] != 0xFF) return null;
        final marker = bytes[pos + 1];
        if (marker == 0xFF || marker == 0x00) {
          pos++;
          continue;
        }
        if (marker == 0xD9) {
          return pos + 2;
        }
        if (marker == 0xDA) {
          if (pos + 4 > bytes.length) return null;
          final sosLen = (bytes[pos + 2] << 8) | bytes[pos + 3];
          if (sosLen < 2 || pos + 2 + sosLen > bytes.length) return null;
          pos += 2 + sosLen;
          inEntropy = true;
          continue;
        }
        // Standalone markers (TEM / RST0..7 / SOI)
        if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
          pos += 2;
          continue;
        }
        if (pos + 4 > bytes.length) return null;
        final segLen = (bytes[pos + 2] << 8) | bytes[pos + 3];
        if (segLen < 2 || pos + 2 + segLen > bytes.length) return null;
        pos += 2 + segLen;
      } else {
        if (bytes[pos] != 0xFF) {
          pos++;
          continue;
        }
        final next = bytes[pos + 1];
        if (next == 0x00 || (next >= 0xD0 && next <= 0xD7)) {
          pos += 2;
          continue;
        }
        if (next == 0xFF) {
          pos++;
          continue;
        }
        if (next == 0xD9) {
          return pos + 2;
        }
        // Unexpected marker inside scan; skip 2 bytes
        pos += 2;
      }
    }
    return null;
  }

  static bool _hasValidFtypHeader(Uint8List bytes, int offset) {
    if (offset < 0 || offset + 12 > bytes.length) return false;
    if (!_matchesBytesAt(bytes, offset + 4, _ftypTag)) return false;
    final boxSize = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    if (boxSize < 12 || boxSize > 512 || offset + boxSize > bytes.length) {
      return false;
    }
    // Major brand at offset + 8..12 should be printable ASCII
    for (int i = 8; i < 12; i++) {
      final c = bytes[offset + i];
      if (c < 0x20 || c > 0x7E) return false;
    }
    return true;
  }

  static bool _matchesBytesAt(Uint8List bytes, int offset, List<int> pattern) {
    if (offset < 0 || offset + pattern.length > bytes.length) return false;
    for (int i = 0; i < pattern.length; i++) {
      if (bytes[offset + i] != pattern[i]) return false;
    }
    return true;
  }

  static ({int videoLengthBytes, int presentationTimestampUs})?
      _parseMotionPhotoXmp(Uint8List bytes) {
    final headerBytes = ascii.encode(xmpNamespaceHeader);
    int pos = 2;

    while (pos + 4 <= bytes.length) {
      if (bytes[pos] != 0xFF) break;
      final marker = bytes[pos + 1];
      if (marker == 0xDA || marker == 0xD9) break;
      if (marker == 0xFF) {
        pos++;
        continue;
      }
      final segLen = (bytes[pos + 2] << 8) | bytes[pos + 3];
      if (segLen < 2 || pos + 2 + segLen > bytes.length) break;
      final segEnd = pos + 2 + segLen;

      if (marker == 0xE1 &&
          segLen >= 2 + headerBytes.length &&
          _matchesBytesAt(bytes, pos + 4, headerBytes)) {
        final xmlStart = pos + 4 + headerBytes.length;
        final xml = utf8.decode(
          Uint8List.sublistView(bytes, xmlStart, segEnd),
          allowMalformed: true,
        );
        final parsed = _extractOffsetsFromXmpXml(xml);
        if (parsed != null) return parsed;
      }
      pos = segEnd;
    }
    return null;
  }

  static ({int videoLengthBytes, int presentationTimestampUs})?
      _extractOffsetsFromXmpXml(String xml) {
    int videoLength = 0;
    int timestampUs = 0;

    final tsMatch = RegExp(
      r'(?:MotionPhotoPresentationTimestampUs|MicroVideoPresentationTimestampUs)(?:\s*=\s*"(\d+)"|>\s*(\d+)\s*<)',
    ).firstMatch(xml);
    if (tsMatch != null) {
      final rawTs = tsMatch.group(1) ?? tsMatch.group(2);
      timestampUs = int.tryParse(rawTs ?? '') ?? 0;
    }

    // Look for Container:Directory item with Semantic == MotionPhoto
    final liBlocks = RegExp(r'<rdf:li\b[\s\S]*?(?:/>|</rdf:li>)').allMatches(xml);
    for (final m in liBlocks) {
      final block = m.group(0)!;
      if (!block.contains('MotionPhoto')) continue;
      final lenMatch = RegExp(
        r'Item:Length(?:\s*=\s*"(\d+)"|>\s*(\d+)\s*<)',
      ).firstMatch(block);
      final rawLen = lenMatch?.group(1) ?? lenMatch?.group(2);
      final parsedLen = int.tryParse(rawLen ?? '') ?? 0;
      if (parsedLen > 0) {
        final padMatch = RegExp(
          r'Item:Padding(?:\s*=\s*"(\d+)"|>\s*(\d+)\s*<)',
        ).firstMatch(block);
        final rawPad = padMatch?.group(1) ?? padMatch?.group(2);
        final padding = int.tryParse(rawPad ?? '') ?? 0;
        videoLength = parsedLen + padding;
        break;
      }
    }

    if (videoLength <= 0) {
      final microMatch = RegExp(
        r'GCamera:MicroVideoOffset(?:\s*=\s*"(\d+)"|>\s*(\d+)\s*<)',
      ).firstMatch(xml);
      final rawMicro = microMatch?.group(1) ?? microMatch?.group(2);
      videoLength = int.tryParse(rawMicro ?? '') ?? 0;
    }

    if (videoLength <= 0 && timestampUs <= 0) return null;
    return (
      videoLengthBytes: videoLength,
      presentationTimestampUs: timestampUs,
    );
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
