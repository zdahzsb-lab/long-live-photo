package com.longlive.long_live_photo

import java.io.ByteArrayOutputStream

object MotionPhotoXmpInjector {
    private const val XMP_NAMESPACE_HEADER = "http://ns.adobe.com/xap/1.0/\u0000"

    fun buildDualStandardXmpXml(
        videoLengthBytes: Long,
        presentationTimestampUs: Long,
    ): String {
        require(videoLengthBytes > 0L) { "videoLengthBytes must be positive" }
        val safeTs = if (presentationTimestampUs < 0L) 0L else presentationTimestampUs
        return buildString(1024) {
            append("""<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.0-jc003">""")
            append("""<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">""")
            append("""<rdf:Description rdf:about="" """)
            append("""xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" """)
            append("""xmlns:Container="http://ns.google.com/photos/1.0/container/" """)
            append("""xmlns:Item="http://ns.google.com/photos/1.0/container/item/" """)
            append("""GCamera:MotionPhoto="1" """)
            append("""GCamera:MotionPhotoVersion="1" """)
            append("""GCamera:MotionPhotoPresentationTimestampUs="$safeTs" """)
            append("""GCamera:MicroVideo="1" """)
            append("""GCamera:MicroVideoVersion="1" """)
            append("""GCamera:MicroVideoOffset="$videoLengthBytes" """)
            append("""GCamera:MicroVideoPresentationTimestampUs="$safeTs">""")
            append("""<Container:Directory><rdf:Seq>""")
            append("""<rdf:li rdf:parseType="Resource">""")
            append("""<Item:Mime>image/jpeg</Item:Mime>""")
            append("""<Item:Semantic>Primary</Item:Semantic>""")
            append("""<Item:Length>0</Item:Length>""")
            append("""<Item:Padding>0</Item:Padding>""")
            append("""</rdf:li>""")
            append("""<rdf:li rdf:parseType="Resource">""")
            append("""<Item:Mime>video/mp4</Item:Mime>""")
            append("""<Item:Semantic>MotionPhoto</Item:Semantic>""")
            append("""<Item:Length>$videoLengthBytes</Item:Length>""")
            append("""<Item:Padding>0</Item:Padding>""")
            append("""</rdf:li>""")
            append("""</rdf:Seq></Container:Directory>""")
            append("""</rdf:Description></rdf:RDF></x:xmpmeta>""")
        }
    }

    /**
     * Injects a Motion Photo XMP APP1 marker into [jpegBytes] (without appending the video yet,
     * so callers can stream multi-hundred-MB MP4 files directly to disk/MediaStore without OOM).
     */
    fun injectXmpIntoJpeg(
        jpegBytes: ByteArray,
        videoLengthBytes: Long,
        presentationTimestampUs: Long,
    ): ByteArray {
        if (jpegBytes.size < 4 ||
            (jpegBytes[0].toInt() and 0xFF) != 0xFF ||
            (jpegBytes[1].toInt() and 0xFF) != 0xD8
        ) {
            throw IllegalArgumentException("Invalid JPEG byte array (missing SOI FF D8)")
        }

        val headerBytes = XMP_NAMESPACE_HEADER.toByteArray(Charsets.US_ASCII)
        val xmlBytes = buildDualStandardXmpXml(
            videoLengthBytes = videoLengthBytes,
            presentationTimestampUs = presentationTimestampUs,
        ).toByteArray(Charsets.UTF_8)

        val segmentPayloadLen = headerBytes.size + xmlBytes.size + 2
        if (segmentPayloadLen > 0xFFFF) {
            throw IllegalStateException("XMP APP1 payload exceeds 64KB JPEG limit")
        }

        val (cleanJpeg, insertOffset) = stripExistingXmp(jpegBytes, headerBytes)
        val out = ByteArrayOutputStream(cleanJpeg.size + segmentPayloadLen + 4)
        out.write(cleanJpeg, 0, insertOffset)
        out.write(0xFF)
        out.write(0xE1)
        out.write((segmentPayloadLen shr 8) and 0xFF)
        out.write(segmentPayloadLen and 0xFF)
        out.write(headerBytes)
        out.write(xmlBytes)
        out.write(cleanJpeg, insertOffset, cleanJpeg.size - insertOffset)
        return out.toByteArray()
    }

    private fun stripExistingXmp(
        jpeg: ByteArray,
        xmpHeader: ByteArray,
    ): Pair<ByteArray, Int> {
        val kept = ByteArrayOutputStream(jpeg.size)
        kept.write(0xFF)
        kept.write(0xD8)

        var pos = 2
        var insertOffset = 2

        while (pos + 4 <= jpeg.size) {
            if ((jpeg[pos].toInt() and 0xFF) != 0xFF) break
            val marker = jpeg[pos + 1].toInt() and 0xFF
            if (marker == 0xDA || marker == 0xD9) {
                break
            }
            if (marker == 0xFF) {
                pos++
                continue
            }
            val segLen = ((jpeg[pos + 2].toInt() and 0xFF) shl 8) or (jpeg[pos + 3].toInt() and 0xFF)
            if (segLen < 2 || pos + 2 + segLen > jpeg.size) {
                break
            }
            val segEnd = pos + 2 + segLen

            var isXmp = false
            if (marker == 0xE1 && segLen >= 2 + xmpHeader.size) {
                isXmp = true
                for (i in xmpHeader.indices) {
                    if (jpeg[pos + 4 + i] != xmpHeader[i]) {
                        isXmp = false
                        break
                    }
                }
            }

            if (!isXmp) {
                kept.write(jpeg, pos, segEnd - pos)
                if (marker == 0xE0 || marker == 0xE1) {
                    insertOffset = kept.size()
                }
            }
            pos = segEnd
        }

        if (pos < jpeg.size) {
            kept.write(jpeg, pos, jpeg.size - pos)
        }
        return Pair(kept.toByteArray(), insertOffset)
    }
}
