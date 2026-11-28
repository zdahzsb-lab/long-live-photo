package com.longlive.long_live_photo

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.annotation.OptIn
import androidx.exifinterface.media.ExifInterface
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.SpeedChangeEffect
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

data class NativeConversionOutcome(
    val savedUri: String,
    val outputSizeBytes: Long,
    val elapsedMs: Long,
)

data class NativeUnpackedLivePhoto(
    val videoPath: String,
    val coverImagePath: String?,
    val coverTimeMs: Long,
)

@OptIn(UnstableApi::class)
class MotionPhotoConverter(
    private val context: Context,
    private val onProgress: (stage: String, progress: Double, message: String) -> Unit,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val workerExecutor = Executors.newSingleThreadExecutor()

    private val cancelled = AtomicBoolean(false)

    @Volatile
    private var activeTransformer: Transformer? = null

    @Volatile
    private var activeLatch: CountDownLatch? = null

    fun cancelCurrent() {
        cancelled.set(true)
        mainHandler.post {
            try {
                activeTransformer?.cancel()
            } catch (_: Exception) {
            } finally {
                activeTransformer = null
                activeLatch?.countDown()
            }
        }
    }

    fun convertAndSaveAsync(
        videoPath: String,
        coverTimeMs: Long,
        quality: String,
        keepAudio: Boolean,
        customCoverPath: String? = null,
        trimStartMs: Long? = null,
        trimEndMs: Long? = null,
        preserveMetadata: Boolean = true,
        playbackSpeed: Double = 1.0,
        onSuccess: (NativeConversionOutcome) -> Unit,
        onError: (code: String, message: String) -> Unit,
    ) {
        cancelled.set(false)
        val safeSpeed = playbackSpeed.coerceIn(0.5, 4.0)
        workerExecutor.execute {
            val startTime = System.currentTimeMillis()
            val inputFile = File(videoPath)
            if (!inputFile.exists()) {
                mainHandler.post { onError("FILE_NOT_FOUND", "找不到所选视频文件") }
                return@execute
            }

            val workId = UUID.randomUUID().toString()
            val tempDir = File(context.cacheDir, "motion_work_$workId").apply { mkdirs() }
            val tempMp4File = File(tempDir, "trailer.mp4")

            try {
                ensureNotCancelled()
                emitProgress(
                    "cover",
                    0.06,
                    if (!customCoverPath.isNullOrBlank()) "正在处理自定义高清封面..." else "正在抽取高清封面帧...",
                )

                val inspection = inspectSourceVideo(
                    inputFile = inputFile,
                    coverTimeMs = coverTimeMs,
                    customCoverPath = customCoverPath,
                    trimStartMs = trimStartMs,
                    trimEndMs = trimEndMs,
                    preserveMetadata = preserveMetadata,
                )

                ensureNotCancelled()
                val preparedJpeg = if (preserveMetadata &&
                    (inspection.captureTimeMs != null || inspection.location != null)
                ) {
                    applyExifMetadataToJpeg(
                        jpegBytes = inspection.rawCoverJpegBytes,
                        tempDir = tempDir,
                        captureTimeMs = inspection.captureTimeMs,
                        location = inspection.location,
                    )
                } else {
                    inspection.rawCoverJpegBytes
                }

                ensureNotCancelled()
                emitProgress("video", 0.12, "正在准备动态视频轨道...")
                val preparedMp4 = prepareMp4Trailer(
                    inputFile = inputFile,
                    tempMp4File = tempMp4File,
                    srcWidth = inspection.width,
                    srcHeight = inspection.height,
                    durationMs = inspection.durationMs,
                    trimStartMs = inspection.safeTrimStartMs,
                    trimEndMs = inspection.safeTrimEndMs,
                    isTrimmed = inspection.isTrimmed,
                    hasAudioTrack = inspection.hasAudioTrack,
                    isHdr = inspection.isHdr,
                    quality = quality,
                    keepAudio = keepAudio,
                    playbackSpeed = safeSpeed,
                )

                ensureNotCancelled()
                val mp4Length = preparedMp4.length()
                if (mp4Length <= 0L) {
                    throw IllegalStateException("生成的动态视频轨道为空")
                }

                emitProgress("packaging", 0.94, "正在注入双标准实况 XMP 元数据并写入相册...")
                val relativeCoverMs = ((inspection.clampedCoverMs - inspection.safeTrimStartMs)
                    .coerceAtLeast(0L).toDouble() / safeSpeed)
                    .roundToLong()
                    .coerceAtLeast(0L)
                val coverTimestampUs = relativeCoverMs * 1000L

                val xmpJpegBytes = MotionPhotoXmpInjector.injectXmpIntoJpeg(
                    jpegBytes = preparedJpeg,
                    videoLengthBytes = mp4Length,
                    presentationTimestampUs = coverTimestampUs,
                )

                ensureNotCancelled()
                val savedUri = writeMotionPhotoToMediaStore(
                    xmpJpegBytes = xmpJpegBytes,
                    mp4File = preparedMp4,
                    captureTimeMs = if (preserveMetadata) inspection.captureTimeMs else null,
                )

                val totalSize = xmpJpegBytes.size.toLong() + mp4Length
                val elapsed = System.currentTimeMillis() - startTime
                mainHandler.post {
                    onSuccess(
                        NativeConversionOutcome(
                            savedUri = savedUri.toString(),
                            outputSizeBytes = totalSize,
                            elapsedMs = elapsed,
                        )
                    )
                }
            } catch (_: CancellationException) {
                mainHandler.post {
                    onError("CANCELLED", "已取消实况合成")
                }
            } catch (e: Exception) {
                if (cancelled.get()) {
                    mainHandler.post {
                        onError("CANCELLED", "已取消实况合成")
                    }
                } else {
                    mainHandler.post {
                        onError("CONVERT_FAILED", e.message ?: "实况合成失败")
                    }
                }
            } finally {
                tempDir.deleteRecursively()
            }
        }
    }

    private fun ensureNotCancelled() {
        if (cancelled.get()) {
            throw CancellationException("Cancelled by user")
        }
    }

    private fun emitProgress(stage: String, progress: Double, message: String) {
        if (cancelled.get()) return
        mainHandler.post {
            onProgress(stage, progress.coerceIn(0.0, 1.0), message)
        }
    }

    private data class SourceInspection(
        val rawCoverJpegBytes: ByteArray,
        val width: Int,
        val height: Int,
        val durationMs: Long,
        val safeTrimStartMs: Long,
        val safeTrimEndMs: Long,
        val isTrimmed: Boolean,
        val hasAudioTrack: Boolean,
        val isHdr: Boolean,
        val clampedCoverMs: Long,
        val captureTimeMs: Long?,
        val location: Pair<Double, Double>?,
    )

    private fun detectIsHdrVideo(
        inputFile: File,
        retriever: MediaMetadataRetriever,
    ): Boolean {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(inputFile.absolutePath)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/")) continue
                if (mime == MimeTypes.VIDEO_DOLBY_VISION) return true
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                    format.containsKey(MediaFormat.KEY_COLOR_TRANSFER)
                ) {
                    val transfer = format.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
                    if (transfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
                        transfer == MediaFormat.COLOR_TRANSFER_HLG
                    ) {
                        return true
                    }
                }
            }
        } catch (_: Exception) {
        } finally {
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val transferMeta = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_COLOR_TRANSFER)
                ?.toIntOrNull()
            if (transferMeta == MediaFormat.COLOR_TRANSFER_ST2084 ||
                transferMeta == MediaFormat.COLOR_TRANSFER_HLG
            ) {
                return true
            }
        }
        return false
    }

    private fun detectHasAudioTrack(
        inputFile: File,
        retriever: MediaMetadataRetriever,
    ): Boolean {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(inputFile.absolutePath)
            var found = false
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                if (mime != null && mime.startsWith("audio/")) {
                    found = true
                    break
                }
            }
            found
        } catch (_: Exception) {
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
        } finally {
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun inspectSourceVideo(
        inputFile: File,
        coverTimeMs: Long,
        customCoverPath: String?,
        trimStartMs: Long?,
        trimEndMs: Long?,
        preserveMetadata: Boolean,
    ): SourceInspection {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(inputFile.absolutePath)
            val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 1080
            val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 1920
            val durationMs = (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 1000L).coerceAtLeast(100L)
            val hasAudioTrack = detectHasAudioTrack(inputFile, retriever)
            val isHdr = detectIsHdrVideo(inputFile, retriever)

            val rawStart = (trimStartMs ?: 0L).coerceIn(0L, max(0L, durationMs - 100L))
            var rawEnd = (trimEndMs ?: durationMs).coerceIn(100L, durationMs)
            if (rawEnd - rawStart < 200L) {
                rawEnd = min(durationMs, rawStart + 200L)
            }
            val safeTrimStartMs = min(rawStart, max(0L, rawEnd - 100L))
            val safeTrimEndMs = max(safeTrimStartMs + 100L, min(rawEnd, durationMs))
            val isTrimmed = safeTrimStartMs > 50L || safeTrimEndMs < durationMs - 50L
            val clampedCoverMs = coverTimeMs.coerceIn(safeTrimStartMs, safeTrimEndMs)

            val captureTimeMs = if (preserveMetadata) {
                parseCaptureTimestampMs(
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE)
                )
            } else {
                null
            }
            val location = if (preserveMetadata) {
                parseIso6709Location(
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)
                )
            } else {
                null
            }

            val coverBytes = if (!customCoverPath.isNullOrBlank() && File(customCoverPath).exists()) {
                loadCustomCoverJpeg(customCoverPath)
            } else {
                extractVideoFrameJpeg(retriever, clampedCoverMs, safeTrimStartMs)
            }

            return SourceInspection(
                rawCoverJpegBytes = coverBytes,
                width = width,
                height = height,
                durationMs = durationMs,
                safeTrimStartMs = safeTrimStartMs,
                safeTrimEndMs = safeTrimEndMs,
                isTrimmed = isTrimmed,
                hasAudioTrack = hasAudioTrack,
                isHdr = isHdr,
                clampedCoverMs = clampedCoverMs,
                captureTimeMs = captureTimeMs,
                location = location,
            )
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun extractVideoFrameJpeg(
        retriever: MediaMetadataRetriever,
        coverMs: Long,
        fallbackMs: Long,
    ): ByteArray {
        val safeTimeUs = coverMs.coerceAtLeast(0L) * 1000L
        val fallbackUs = fallbackMs.coerceAtLeast(0L) * 1000L
        val bitmap: Bitmap = retriever.getFrameAtTime(
            safeTimeUs,
            MediaMetadataRetriever.OPTION_CLOSEST
        ) ?: retriever.getFrameAtTime(
            safeTimeUs,
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC
        ) ?: retriever.getFrameAtTime(
            fallbackUs,
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC
        ) ?: retriever.getFrameAtTime(0L)
            ?: throw IllegalStateException("无法从视频抽取静态封面画面")

        val baos = ByteArrayOutputStream(256 * 1024)
        try {
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 92, baos)) {
                throw IllegalStateException("JPEG 封面编码失败")
            }
            return baos.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    private fun loadCustomCoverJpeg(path: String): ByteArray {
        val boundsOpts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, boundsOpts)
        if (boundsOpts.outWidth <= 0 || boundsOpts.outHeight <= 0) {
            throw IllegalStateException("无法解析自定义封面图片")
        }

        val maxSide = 4096
        var inSampleSize = 1
        while ((boundsOpts.outWidth / inSampleSize) > maxSide * 2 ||
            (boundsOpts.outHeight / inSampleSize) > maxSide * 2
        ) {
            inSampleSize *= 2
        }

        val decodeOpts = BitmapFactory.Options().apply { this.inSampleSize = inSampleSize }
        var bitmap = BitmapFactory.decodeFile(path, decodeOpts)
            ?: throw IllegalStateException("解码自定义封面图片失败")

        try {
            val matrix = Matrix()
            var needsTransform = false
            try {
                val exif = ExifInterface(path)
                when (exif.getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> {
                        matrix.postRotate(90f)
                        needsTransform = true
                    }
                    ExifInterface.ORIENTATION_ROTATE_180 -> {
                        matrix.postRotate(180f)
                        needsTransform = true
                    }
                    ExifInterface.ORIENTATION_ROTATE_270 -> {
                        matrix.postRotate(270f)
                        needsTransform = true
                    }
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> {
                        matrix.postScale(-1f, 1f)
                        needsTransform = true
                    }
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                        matrix.postScale(1f, -1f)
                        needsTransform = true
                    }
                    ExifInterface.ORIENTATION_TRANSPOSE -> {
                        matrix.postRotate(90f)
                        matrix.postScale(-1f, 1f)
                        needsTransform = true
                    }
                    ExifInterface.ORIENTATION_TRANSVERSE -> {
                        matrix.postRotate(270f)
                        matrix.postScale(-1f, 1f)
                        needsTransform = true
                    }
                }
            } catch (_: Exception) {
            }

            if (needsTransform) {
                val rotated = Bitmap.createBitmap(
                    bitmap,
                    0,
                    0,
                    bitmap.width,
                    bitmap.height,
                    matrix,
                    true,
                )
                if (rotated !== bitmap) {
                    bitmap.recycle()
                    bitmap = rotated
                }
            }

            val currentMax = max(bitmap.width, bitmap.height)
            if (currentMax > maxSide) {
                val ratio = maxSide.toDouble() / currentMax.toDouble()
                val dstW = (bitmap.width * ratio).toInt().coerceAtLeast(2)
                val dstH = (bitmap.height * ratio).toInt().coerceAtLeast(2)
                val scaled = Bitmap.createScaledBitmap(bitmap, dstW, dstH, true)
                if (scaled !== bitmap) {
                    bitmap.recycle()
                    bitmap = scaled
                }
            }

            val baos = ByteArrayOutputStream(384 * 1024)
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 92, baos)) {
                throw IllegalStateException("自定义封面编码失败")
            }
            return baos.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    private fun applyExifMetadataToJpeg(
        jpegBytes: ByteArray,
        tempDir: File,
        captureTimeMs: Long?,
        location: Pair<Double, Double>?,
    ): ByteArray {
        val tempCover = File(tempDir, "exif_cover.jpg")
        return try {
            tempCover.writeBytes(jpegBytes)
            val exif = ExifInterface(tempCover.absolutePath)
            if (captureTimeMs != null) {
                val exifFmt = SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US)
                val formatted = exifFmt.format(Date(captureTimeMs))
                exif.setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, formatted)
                exif.setAttribute(ExifInterface.TAG_DATETIME_DIGITIZED, formatted)
                exif.setAttribute(ExifInterface.TAG_DATETIME, formatted)

                val offsetMinutes = TimeZone.getDefault().getOffset(captureTimeMs) / 60000
                val sign = if (offsetMinutes >= 0) "+" else "-"
                val absMin = kotlin.math.abs(offsetMinutes)
                val offsetStr = String.format(
                    Locale.US,
                    "%s%02d:%02d",
                    sign,
                    absMin / 60,
                    absMin % 60,
                )
                exif.setAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL, offsetStr)
                exif.setAttribute(ExifInterface.TAG_OFFSET_TIME_DIGITIZED, offsetStr)
                exif.setAttribute(ExifInterface.TAG_OFFSET_TIME, offsetStr)
            }
            if (location != null) {
                exif.setLatLong(location.first, location.second)
            }
            exif.saveAttributes()
            tempCover.readBytes()
        } catch (_: Exception) {
            jpegBytes
        } finally {
            tempCover.delete()
        }
    }

    private fun parseCaptureTimestampMs(rawDate: String?): Long? {
        if (rawDate.isNullOrBlank()) return null
        val trimmed = rawDate.trim()
        val utcPatterns = listOf(
            "yyyyMMdd'T'HHmmss.SSS'Z'",
            "yyyyMMdd'T'HHmmss'Z'",
            "yyyyMMdd'T'HHmmss",
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd'T'HH:mm:ssXXX",
            "yyyy-MM-dd HH:mm:ss",
            "yyyyMMdd HHmmss",
        )
        for (pattern in utcPatterns) {
            try {
                val fmt = SimpleDateFormat(pattern, Locale.US).apply {
                    isLenient = false
                    if (!pattern.contains("XXX")) {
                        timeZone = TimeZone.getTimeZone("UTC")
                    }
                }
                val parsed = fmt.parse(trimmed)
                if (parsed != null && parsed.time > 315532800000L) {
                    return parsed.time
                }
            } catch (_: Exception) {
            }
        }
        return null
    }

    private fun parseIso6709Location(rawLoc: String?): Pair<Double, Double>? {
        if (rawLoc.isNullOrBlank()) return null
        val regex = Regex("""([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)""")
        val match = regex.find(rawLoc.trim()) ?: return null
        val lat = match.groupValues[1].toDoubleOrNull() ?: return null
        val lon = match.groupValues[2].toDoubleOrNull() ?: return null
        if (lat !in -90.0..90.0 || lon !in -180.0..180.0) return null
        if (lat == 0.0 && lon == 0.0) return null
        return Pair(lat, lon)
    }

    private fun formatSpeedTag(speed: Double): String {
        return when {
            abs(speed - 0.5) < 0.05 -> "0.5x 慢放"
            abs(speed - 1.5) < 0.05 -> "1.5x 倍速"
            abs(speed - 2.0) < 0.05 -> "2x 倍速"
            abs(speed - 4.0) < 0.05 -> "4x 延时"
            else -> String.format(Locale.US, "%.1fx 倍速", speed)
        }
    }

    private fun prepareMp4Trailer(
        inputFile: File,
        tempMp4File: File,
        srcWidth: Int,
        srcHeight: Int,
        durationMs: Long,
        trimStartMs: Long,
        trimEndMs: Long,
        isTrimmed: Boolean,
        hasAudioTrack: Boolean,
        isHdr: Boolean,
        quality: String,
        keepAudio: Boolean,
        playbackSpeed: Double,
    ): File {
        val safeSpeed = playbackSpeed.coerceIn(0.5, 4.0)
        val hasSpeedChange = abs(safeSpeed - 1.0) > 0.01

        if (!isTrimmed && !hasSpeedChange && quality == "passthrough") {
            val remuxOk = tryLosslessRemuxToMp4(inputFile, tempMp4File, keepAudio)
            ensureNotCancelled()
            if (remuxOk && tempMp4File.exists() && tempMp4File.length() > 0L) {
                return tempMp4File
            }
            if (tempMp4File.exists()) tempMp4File.delete()
        }

        transcodeWithMedia3(
            inputFile = inputFile,
            outputFile = tempMp4File,
            srcWidth = srcWidth,
            srcHeight = srcHeight,
            durationMs = durationMs,
            trimStartMs = trimStartMs,
            trimEndMs = trimEndMs,
            isTrimmed = isTrimmed,
            hasAudioTrack = hasAudioTrack,
            isHdr = isHdr,
            quality = quality,
            keepAudio = keepAudio,
            playbackSpeed = safeSpeed,
        )
        return tempMp4File
    }

    private fun tryLosslessRemuxToMp4(
        inputFile: File,
        outputFile: File,
        keepAudio: Boolean,
    ): Boolean {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(inputFile.absolutePath)
            val trackMap = mutableMapOf<Int, Int>()
            var durationUs = 0L
            var rotationDegrees = 0

            val tempMuxer = MediaMuxer(
                outputFile.absolutePath,
                MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            )
            muxer = tempMuxer

            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    if (mime != MimeTypes.VIDEO_H264 && mime != MimeTypes.VIDEO_H265) {
                        return false
                    }
                    if (format.containsKey(MediaFormat.KEY_DURATION)) {
                        durationUs = format.getLong(MediaFormat.KEY_DURATION)
                    }
                    if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                        rotationDegrees = format.getInteger(MediaFormat.KEY_ROTATION)
                    }
                    val dstIndex = tempMuxer.addTrack(format)
                    extractor.selectTrack(i)
                    trackMap[i] = dstIndex
                } else if (keepAudio && mime.startsWith("audio/")) {
                    if (mime != MimeTypes.AUDIO_AAC) {
                        return false
                    }
                    val dstIndex = tempMuxer.addTrack(format)
                    extractor.selectTrack(i)
                    trackMap[i] = dstIndex
                }
            }

            if (trackMap.isEmpty()) return false
            if (rotationDegrees != 0) {
                tempMuxer.setOrientationHint(rotationDegrees)
            }

            tempMuxer.start()
            val buffer = ByteBuffer.allocateDirect(2 * 1024 * 1024)
            val bufferInfo = MediaCodec.BufferInfo()
            var lastPct = -1

            while (true) {
                if (cancelled.get()) return false
                val trackIndex = extractor.sampleTrackIndex
                if (trackIndex < 0) break
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break

                val sampleTimeUs = extractor.sampleTime
                val sampleFlags = extractor.sampleFlags
                var codecFlags = 0
                if ((sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) {
                    codecFlags = codecFlags or MediaCodec.BUFFER_FLAG_KEY_FRAME
                }
                if ((sampleFlags and MediaExtractor.SAMPLE_FLAG_PARTIAL_FRAME) != 0 &&
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ) {
                    codecFlags = codecFlags or MediaCodec.BUFFER_FLAG_PARTIAL_FRAME
                }

                bufferInfo.set(0, size, sampleTimeUs.coerceAtLeast(0L), codecFlags)
                val dstTrack = trackMap[trackIndex]
                if (dstTrack != null) {
                    tempMuxer.writeSampleData(dstTrack, buffer, bufferInfo)
                }

                if (durationUs > 0L && sampleTimeUs >= 0L) {
                    val ratio = (sampleTimeUs.toDouble() / durationUs.toDouble()).coerceIn(0.0, 1.0)
                    val pct = (ratio * 100.0).toInt()
                    if (pct >= lastPct + 5) {
                        lastPct = pct
                        emitProgress("video", 0.12 + ratio * 0.80, "原画直通封装中（$pct%）...")
                    }
                }
                extractor.advance()
            }

            tempMuxer.stop()
            return true
        } catch (_: Exception) {
            return false
        } finally {
            try {
                muxer?.release()
            } catch (_: Exception) {
            }
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun transcodeWithMedia3(
        inputFile: File,
        outputFile: File,
        srcWidth: Int,
        srcHeight: Int,
        durationMs: Long,
        trimStartMs: Long,
        trimEndMs: Long,
        isTrimmed: Boolean,
        hasAudioTrack: Boolean,
        isHdr: Boolean,
        quality: String,
        keepAudio: Boolean,
        playbackSpeed: Double,
    ) {
        val latch = CountDownLatch(1)
        activeLatch = latch
        val errorRef = AtomicReference<Exception?>(null)

        val safeSpeed = playbackSpeed.coerceIn(0.5, 4.0)
        val hasSpeedChange = abs(safeSpeed - 1.0) > 0.01
        val keepActualAudio = keepAudio && hasAudioTrack

        val (targetShortSide, targetBitrate) = when (quality) {
            "720p" -> Pair(720, 2_800_000)
            "passthrough" -> Pair(Int.MAX_VALUE, 14_000_000)
            else -> Pair(1080, 6_000_000)
        }

        mainHandler.post {
            if (cancelled.get()) {
                latch.countDown()
                return@post
            }
            try {
                val videoEffects = mutableListOf<Effect>()
                if (hasSpeedChange && !keepActualAudio) {
                    // Pure GL speed scaling avoids SpeedChangingAudioProcessor waiting on absent audio frames.
                    videoEffects.add(SpeedChangeEffect(safeSpeed.toFloat()))
                }
                if (hasSpeedChange && safeSpeed > 1.01) {
                    val targetFps = if (safeSpeed >= 3.0) 30f else 60f
                    videoEffects.add(FrameDropEffect.createDefaultFrameDropEffect(targetFps))
                }
                val srcShortSide = min(srcWidth, srcHeight)
                if (srcShortSide > targetShortSide) {
                    videoEffects.add(Presentation.createForShortSide(targetShortSide))
                }

                val mediaItemBuilder = MediaItem.Builder()
                    .setUri(Uri.fromFile(inputFile))
                if (isTrimmed) {
                    val clipEnd = trimEndMs.coerceIn(trimStartMs + 100L, durationMs)
                    mediaItemBuilder.setClippingConfiguration(
                        MediaItem.ClippingConfiguration.Builder()
                            .setStartPositionMs(trimStartMs)
                            .setEndPositionMs(clipEnd)
                            .build()
                    )
                }

                val editedItemBuilder = EditedMediaItem.Builder(mediaItemBuilder.build())
                    .setRemoveAudio(!keepActualAudio)
                    .setEffects(Effects(emptyList(), videoEffects))

                if (hasSpeedChange && keepActualAudio) {
                    val speedFloat = safeSpeed.toFloat()
                    editedItemBuilder.setSpeed(object : SpeedProvider {
                        override fun getSpeed(timeUs: Long): Float = speedFloat
                        override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
                    })
                }

                val editedItem = editedItemBuilder.build()

                val videoEncoderSettings = VideoEncoderSettings.Builder()
                    .setBitrate(targetBitrate)
                    .build()

                val encoderFactory = DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(videoEncoderSettings)
                    .build()

                lateinit var transformer: Transformer
                val progressHolder = ProgressHolder()
                var finished = false
                val progressPrefix = if (hasSpeedChange) {
                    "${formatSpeedTag(safeSpeed)}压制中"
                } else {
                    "硬件编码压制中"
                }

                val pollRunnable = object : Runnable {
                    override fun run() {
                        if (finished || cancelled.get()) return
                        val state = transformer.getProgress(progressHolder)
                        if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
                            val pct = progressHolder.progress.coerceIn(0, 100)
                            val uiProg = 0.12 + (pct / 100.0) * 0.80
                            onProgress("video", uiProg, "$progressPrefix（$pct%）...")
                        }
                        mainHandler.postDelayed(this, 200L)
                    }
                }

                transformer = Transformer.Builder(context)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .setEncoderFactory(encoderFactory)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            finished = true
                            mainHandler.removeCallbacks(pollRunnable)
                            if (activeTransformer === transformer) {
                                activeTransformer = null
                            }
                            latch.countDown()
                        }

                        override fun onError(
                            composition: Composition,
                            exportResult: ExportResult,
                            exportException: ExportException,
                        ) {
                            finished = true
                            mainHandler.removeCallbacks(pollRunnable)
                            if (activeTransformer === transformer) {
                                activeTransformer = null
                            }
                            errorRef.set(exportException)
                            latch.countDown()
                        }
                    })
                    .build()

                val sequence = if (keepActualAudio) {
                    EditedMediaItemSequence.withAudioAndVideoFrom(listOf(editedItem))
                } else {
                    EditedMediaItemSequence.withVideoFrom(listOf(editedItem))
                }
                val compositionBuilder = Composition.Builder(listOf(sequence))
                if (isHdr && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    compositionBuilder.setHdrMode(
                        Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
                    )
                }

                activeTransformer = transformer
                transformer.start(compositionBuilder.build(), outputFile.absolutePath)
                mainHandler.postDelayed(pollRunnable, 200L)
            } catch (e: Exception) {
                activeTransformer = null
                errorRef.set(e)
                latch.countDown()
            }
        }

        latch.await()
        activeTransformer = null
        activeLatch = null
        ensureNotCancelled()
        errorRef.get()?.let { throw it }
    }

    private fun writeMotionPhotoToMediaStore(
        xmpJpegBytes: ByteArray,
        mp4File: File,
        captureTimeMs: Long?,
    ): Uri {
        val fileDateMs = captureTimeMs ?: System.currentTimeMillis()
        val timestampStr = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date(fileDateMs))
        return writeMediaToMediaStore(
            contentUri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            displayName = "MVIMG_$timestampStr.jpg",
            mimeType = "image/jpeg",
            dateTakenKey = MediaStore.Images.Media.DATE_TAKEN,
            captureTimeMs = captureTimeMs,
            prefixBytes = xmpJpegBytes,
            bodyFile = mp4File,
        )
    }

    private fun writeMediaToMediaStore(
        contentUri: Uri,
        displayName: String,
        mimeType: String,
        dateTakenKey: String,
        captureTimeMs: Long?,
        prefixBytes: ByteArray?,
        bodyFile: File?,
    ): Uri {
        val resolver = context.contentResolver
        val fileDateMs = captureTimeMs ?: System.currentTimeMillis()
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            val timeSec = fileDateMs / 1000L
            put(MediaStore.MediaColumns.DATE_ADDED, timeSec)
            put(MediaStore.MediaColumns.DATE_MODIFIED, timeSec)
            if (captureTimeMs != null) {
                put(dateTakenKey, captureTimeMs)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DCIM + "/Camera")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val itemUri = resolver.insert(contentUri, values)
            ?: throw IllegalStateException("无法在系统相册中创建文件条目")

        try {
            resolver.openOutputStream(itemUri)?.use { out ->
                if (prefixBytes != null && prefixBytes.isNotEmpty()) {
                    out.write(prefixBytes)
                }
                if (bodyFile != null) {
                    FileInputStream(bodyFile).use { bodyIn ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            ensureNotCancelled()
                            val read = bodyIn.read(buffer)
                            if (read < 0) break
                            out.write(buffer, 0, read)
                        }
                    }
                }
                out.flush()
            } ?: throw IllegalStateException("无法打开系统相册输出流")

            ensureNotCancelled()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val completeValues = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                resolver.update(itemUri, completeValues, null, null)
            }
            return itemUri
        } catch (e: Exception) {
            try {
                resolver.delete(itemUri, null, null)
            } catch (_: Exception) {
            }
            throw e
        }
    }

    fun exportStandaloneAsync(
        mode: String,
        videoPath: String,
        coverTimeMs: Long,
        quality: String,
        keepAudio: Boolean,
        customCoverPath: String? = null,
        trimStartMs: Long? = null,
        trimEndMs: Long? = null,
        preserveMetadata: Boolean = true,
        playbackSpeed: Double = 1.0,
        onSuccess: (NativeConversionOutcome) -> Unit,
        onError: (code: String, message: String) -> Unit,
    ) {
        cancelled.set(false)
        val safeSpeed = playbackSpeed.coerceIn(0.5, 4.0)
        workerExecutor.execute {
            val startTime = System.currentTimeMillis()
            val inputFile = File(videoPath)
            if (!inputFile.exists()) {
                mainHandler.post { onError("FILE_NOT_FOUND", "找不到所选视频文件") }
                return@execute
            }

            val workId = UUID.randomUUID().toString()
            val tempDir = File(context.cacheDir, "export_work_$workId").apply { mkdirs() }
            val tempMp4File = File(tempDir, "standalone.mp4")

            try {
                ensureNotCancelled()
                val inspection = inspectSourceVideo(
                    inputFile = inputFile,
                    coverTimeMs = coverTimeMs,
                    customCoverPath = customCoverPath,
                    trimStartMs = trimStartMs,
                    trimEndMs = trimEndMs,
                    preserveMetadata = preserveMetadata,
                )
                val captureTimeMs = if (preserveMetadata) inspection.captureTimeMs else null
                val timestampStr = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)
                    .format(Date(captureTimeMs ?: System.currentTimeMillis()))

                if (mode == "cover") {
                    emitProgress(
                        "cover",
                        0.45,
                        if (!customCoverPath.isNullOrBlank()) "正在导出自定义高清封面..." else "正在导出当前高清封面...",
                    )
                    val preparedJpeg = if (preserveMetadata &&
                        (inspection.captureTimeMs != null || inspection.location != null)
                    ) {
                        applyExifMetadataToJpeg(
                            jpegBytes = inspection.rawCoverJpegBytes,
                            tempDir = tempDir,
                            captureTimeMs = inspection.captureTimeMs,
                            location = inspection.location,
                        )
                    } else {
                        inspection.rawCoverJpegBytes
                    }
                    ensureNotCancelled()
                    emitProgress("packaging", 0.92, "正在写入系统相册...")
                    val savedUri = writeMediaToMediaStore(
                        contentUri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        displayName = "IMG_Unclip_$timestampStr.jpg",
                        mimeType = "image/jpeg",
                        dateTakenKey = MediaStore.Images.Media.DATE_TAKEN,
                        captureTimeMs = captureTimeMs,
                        prefixBytes = preparedJpeg,
                        bodyFile = null,
                    )
                    val elapsed = System.currentTimeMillis() - startTime
                    mainHandler.post {
                        onSuccess(
                            NativeConversionOutcome(
                                savedUri = savedUri.toString(),
                                outputSizeBytes = preparedJpeg.size.toLong(),
                                elapsedMs = elapsed,
                            )
                        )
                    }
                    return@execute
                }

                emitProgress("video", 0.12, "正在准备导出普通视频...")
                val preparedMp4 = prepareMp4Trailer(
                    inputFile = inputFile,
                    tempMp4File = tempMp4File,
                    srcWidth = inspection.width,
                    srcHeight = inspection.height,
                    durationMs = inspection.durationMs,
                    trimStartMs = inspection.safeTrimStartMs,
                    trimEndMs = inspection.safeTrimEndMs,
                    isTrimmed = inspection.isTrimmed,
                    hasAudioTrack = inspection.hasAudioTrack,
                    isHdr = inspection.isHdr,
                    quality = quality,
                    keepAudio = keepAudio,
                    playbackSpeed = safeSpeed,
                )
                ensureNotCancelled()
                val mp4Length = preparedMp4.length()
                if (mp4Length <= 0L) {
                    throw IllegalStateException("导出的视频文件为空")
                }

                emitProgress("packaging", 0.94, "正在保存视频至系统相册...")
                val savedUri = writeMediaToMediaStore(
                    contentUri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                    displayName = "VID_Unclip_$timestampStr.mp4",
                    mimeType = "video/mp4",
                    dateTakenKey = MediaStore.Video.Media.DATE_TAKEN,
                    captureTimeMs = captureTimeMs,
                    prefixBytes = null,
                    bodyFile = preparedMp4,
                )
                val elapsed = System.currentTimeMillis() - startTime
                mainHandler.post {
                    onSuccess(
                        NativeConversionOutcome(
                            savedUri = savedUri.toString(),
                            outputSizeBytes = mp4Length,
                            elapsedMs = elapsed,
                        )
                    )
                }
            } catch (_: CancellationException) {
                mainHandler.post {
                    onError("CANCELLED", "已取消导出")
                }
            } catch (e: Exception) {
                if (cancelled.get()) {
                    mainHandler.post {
                        onError("CANCELLED", "已取消导出")
                    }
                } else {
                    mainHandler.post {
                        onError("EXPORT_FAILED", e.message ?: "导出失败")
                    }
                }
            } finally {
                tempDir.deleteRecursively()
            }
        }
    }

    fun unpackMotionPhotoAsync(
        filePath: String,
        onSuccess: (NativeUnpackedLivePhoto) -> Unit,
        onError: (code: String, message: String) -> Unit,
    ) {
        workerExecutor.execute {
            val inputFile = File(filePath)
            if (!inputFile.exists() || inputFile.length() < 24L) {
                mainHandler.post {
                    onError("FILE_NOT_FOUND", "找不到所选动态照片文件")
                }
                return@execute
            }

            try {
                val unpackedDir = File(context.cacheDir, "unpacked_live").apply { mkdirs() }
                pruneOldCacheFiles(unpackedDir, maxAgeMs = 24L * 3600L * 1000L)

                val located = locateEmbeddedMp4InMotionPhoto(inputFile)
                if (located == null) {
                    mainHandler.post {
                        onError("NOT_LIVE_PHOTO", "所选图片不包含实况视频轨道，请选择动态照片")
                    }
                    return@execute
                }

                val stamp = "${System.currentTimeMillis()}_${UUID.randomUUID().toString().take(8)}"
                val outVideo = File(unpackedDir, "unpacked_$stamp.mp4")
                val outCover = File(unpackedDir, "unpacked_cover_$stamp.jpg")

                RandomAccessFile(inputFile, "r").use { raf ->
                    // 1. Stream clean JPEG cover (stripping Motion Photo XMP segment if present)
                    streamRangeSkippingSpan(
                        raf = raf,
                        start = 0L,
                        end = located.jpegEnd,
                        skipStart = located.xmpSegmentStart,
                        skipEnd = located.xmpSegmentEnd,
                        outFile = outCover,
                    )
                    // 2. Stream embedded MP4 trailer
                    streamRangeSkippingSpan(
                        raf = raf,
                        start = located.mp4Start,
                        end = inputFile.length(),
                        skipStart = -1L,
                        skipEnd = -1L,
                        outFile = outVideo,
                    )
                }

                if (!outVideo.exists() || outVideo.length() < 16L) {
                    outVideo.delete()
                    outCover.delete()
                    mainHandler.post {
                        onError("NOT_LIVE_PHOTO", "未能提取有效实况视频轨道")
                    }
                    return@execute
                }

                val coverPath = if (outCover.exists() && outCover.length() >= 4L) {
                    outCover.absolutePath
                } else {
                    null
                }
                val coverMs = (located.presentationTimestampUs / 1000L).coerceAtLeast(0L)
                mainHandler.post {
                    onSuccess(
                        NativeUnpackedLivePhoto(
                            videoPath = outVideo.absolutePath,
                            coverImagePath = coverPath,
                            coverTimeMs = coverMs,
                        )
                    )
                }
            } catch (e: Exception) {
                mainHandler.post {
                    onError("UNPACK_FAILED", e.message ?: "拆解动态照片失败")
                }
            }
        }
    }

    private data class LocatedMotionPhoto(
        val jpegEnd: Long,
        val mp4Start: Long,
        val presentationTimestampUs: Long,
        val xmpSegmentStart: Long,
        val xmpSegmentEnd: Long,
    )

    private fun pruneOldCacheFiles(dir: File, maxAgeMs: Long) {
        val cutoff = System.currentTimeMillis() - maxAgeMs
        dir.listFiles()?.forEach { child ->
            if (child.lastModified() < cutoff) {
                try {
                    child.deleteRecursively()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun streamRangeSkippingSpan(
        raf: RandomAccessFile,
        start: Long,
        end: Long,
        skipStart: Long,
        skipEnd: Long,
        outFile: File,
    ) {
        if (end <= start) return
        FileOutputStream(outFile).use { out ->
            val buf = ByteArray(64 * 1024)
            var pos = start
            raf.seek(pos)
            while (pos < end) {
                if (skipStart in pos until skipEnd && skipStart == pos) {
                    pos = skipEnd.coerceAtMost(end)
                    raf.seek(pos)
                    continue
                }
                val nextStop = if (skipStart in pos until end) skipStart else end
                val toRead = min(buf.size.toLong(), nextStop - pos).toInt()
                if (toRead <= 0) break
                val read = raf.read(buf, 0, toRead)
                if (read <= 0) break
                out.write(buf, 0, read)
                pos += read
            }
            out.flush()
        }
    }

    private fun locateEmbeddedMp4InMotionPhoto(file: File): LocatedMotionPhoto? {
        val fileLen = file.length()
        if (fileLen < 24L) return null

        RandomAccessFile(file, "r").use { raf ->
            val headSize = min(fileLen, 256L * 1024L).toInt()
            val head = ByteArray(headSize)
            raf.seek(0L)
            raf.readFully(head)

            if ((head[0].toInt() and 0xFF) != 0xFF || (head[1].toInt() and 0xFF) != 0xD8) {
                return null
            }

            val xmpHeader = "http://ns.adobe.com/xap/1.0/\u0000".toByteArray(StandardCharsets.US_ASCII)
            var pos = 2
            var videoLength = 0L
            var presentationUs = 0L
            var xmpSegStart = -1L
            var xmpSegEnd = -1L

            while (pos + 4 <= head.size) {
                if ((head[pos].toInt() and 0xFF) != 0xFF) break
                val marker = head[pos + 1].toInt() and 0xFF
                if (marker == 0xDA || marker == 0xD9) break
                if (marker == 0xFF || marker == 0x00) {
                    pos++
                    continue
                }
                val segLen = ((head[pos + 2].toInt() and 0xFF) shl 8) or (head[pos + 3].toInt() and 0xFF)
                if (segLen < 2 || pos + 2 + segLen > head.size) break
                val segEnd = pos + 2 + segLen

                if (marker == 0xE1 && segLen >= 2 + xmpHeader.size &&
                    matchesBytes(head, pos + 4, xmpHeader)
                ) {
                    val xml = String(head, pos + 4 + xmpHeader.size, segEnd - (pos + 4 + xmpHeader.size), StandardCharsets.UTF_8)
                    val parsed = parseMotionPhotoXmp(xml)
                    if (parsed != null) {
                        videoLength = parsed.first
                        presentationUs = parsed.second
                        xmpSegStart = pos.toLong()
                        xmpSegEnd = segEnd.toLong()
                        break
                    }
                }
                pos = segEnd
            }

            if (videoLength > 0L && videoLength < fileLen - 24L) {
                val candidate = fileLen - videoLength
                val resolved = resolveMp4AtOffset(raf, fileLen, candidate)
                if (resolved != null) {
                    return LocatedMotionPhoto(
                        jpegEnd = resolved.first,
                        mp4Start = resolved.second,
                        presentationTimestampUs = presentationUs,
                        xmpSegmentStart = xmpSegStart,
                        xmpSegmentEnd = xmpSegEnd,
                    )
                }
            }

            // Fallback: find primary JPEG EOI (FF D9) via marker + entropy scan, then look for MP4 box
            val eoiEnd = findPrimaryJpegEoiEnd(raf, fileLen)
            if (eoiEnd != null && eoiEnd < fileLen - 16L) {
                val resolvedDirect = resolveMp4AtOffset(raf, fileLen, eoiEnd)
                if (resolvedDirect != null) {
                    return LocatedMotionPhoto(
                        jpegEnd = eoiEnd,
                        mp4Start = resolvedDirect.second,
                        presentationTimestampUs = presentationUs,
                        xmpSegmentStart = xmpSegStart,
                        xmpSegmentEnd = xmpSegEnd,
                    )
                }
                val scannedMp4 = scanMp4AfterOffset(raf, fileLen, eoiEnd)
                if (scannedMp4 != null) {
                    return LocatedMotionPhoto(
                        jpegEnd = eoiEnd,
                        mp4Start = scannedMp4,
                        presentationTimestampUs = presentationUs,
                        xmpSegmentStart = xmpSegStart,
                        xmpSegmentEnd = xmpSegEnd,
                    )
                }
            }
        }
        return null
    }

    private fun parseMotionPhotoXmp(xml: String): Pair<Long, Long>? {
        var videoLen = 0L
        var tsUs = 0L

        val tsMatch = Regex(
            """(?:MotionPhotoPresentationTimestampUs|MicroVideoPresentationTimestampUs)(?:\s*=\s*"(\d+)"|>\s*(\d+)\s*<)"""
        ).find(xml)
        if (tsMatch != null) {
            val raw = tsMatch.groupValues[1].ifEmpty { tsMatch.groupValues[2] }
            tsUs = raw.toLongOrNull() ?: 0L
        }

        val liMatches = Regex("""<rdf:li\b[\s\S]*?(?:/>|</rdf:li>)""").findAll(xml)
        for (m in liMatches) {
            val block = m.value
            if (!block.contains("MotionPhoto")) continue
            val lenMatch = Regex("""Item:Length(?:\s*=\s*"(\d+)"|>\s*(\d+)\s*<)""").find(block)
            val rawLen = lenMatch?.let { it.groupValues[1].ifEmpty { it.groupValues[2] } }
            val parsedLen = rawLen?.toLongOrNull() ?: 0L
            if (parsedLen > 0L) {
                val padMatch = Regex("""Item:Padding(?:\s*=\s*"(\d+)"|>\s*(\d+)\s*<)""").find(block)
                val rawPad = padMatch?.let { it.groupValues[1].ifEmpty { it.groupValues[2] } }
                val padding = rawPad?.toLongOrNull() ?: 0L
                videoLen = parsedLen + padding
                break
            }
        }

        if (videoLen <= 0L) {
            val microMatch = Regex("""GCamera:MicroVideoOffset(?:\s*=\s*"(\d+)"|>\s*(\d+)\s*<)""").find(xml)
            val rawMicro = microMatch?.let { it.groupValues[1].ifEmpty { it.groupValues[2] } }
            videoLen = rawMicro?.toLongOrNull() ?: 0L
        }

        if (videoLen <= 0L && tsUs <= 0L) return null
        return Pair(videoLen, tsUs)
    }

    private fun resolveMp4AtOffset(
        raf: RandomAccessFile,
        fileLen: Long,
        candidate: Long,
    ): Pair<Long, Long>? {
        if (candidate < 4L || candidate + 16L > fileLen) return null
        val probe = ByteArray(min(40L, fileLen - candidate).toInt())
        raf.seek(candidate)
        raf.readFully(probe)

        if (hasValidFtypHeader(probe, 0, fileLen - candidate)) {
            val jpegEnd = resolveJpegEndBefore(raf, fileLen, candidate) ?: return null
            return Pair(jpegEnd, candidate)
        }

        val samsungMarker = "MotionPhoto_Data".toByteArray(StandardCharsets.US_ASCII)
        if (probe.size >= samsungMarker.size + 12 &&
            matchesBytes(probe, 0, samsungMarker) &&
            hasValidFtypHeader(probe, samsungMarker.size, fileLen - (candidate + samsungMarker.size))
        ) {
            val jpegEnd = resolveJpegEndBefore(raf, fileLen, candidate) ?: return null
            return Pair(jpegEnd, candidate + samsungMarker.size)
        }
        return null
    }

    private fun resolveJpegEndBefore(
        raf: RandomAccessFile,
        fileLen: Long,
        limitOffset: Long,
    ): Long? {
        if (limitOffset >= 4L) {
            val tail = ByteArray(2)
            raf.seek(limitOffset - 2L)
            raf.readFully(tail)
            if ((tail[0].toInt() and 0xFF) == 0xFF && (tail[1].toInt() and 0xFF) == 0xD9) {
                return limitOffset
            }
        }
        val eoi = findPrimaryJpegEoiEnd(raf, limitOffset.coerceAtMost(fileLen))
        if (eoi != null && eoi <= limitOffset) return eoi
        return if (limitOffset >= 4L) limitOffset else null
    }

    private fun findPrimaryJpegEoiEnd(raf: RandomAccessFile, limitLen: Long): Long? {
        var pos = 2L
        var inEntropy = false

        while (pos + 2L <= limitLen) {
            if (!inEntropy) {
                raf.seek(pos)
                val first = raf.read()
                if (first != 0xFF) return null
                val marker = raf.read()
                if (marker < 0) return null
                if (marker == 0xFF || marker == 0x00) {
                    pos++
                    continue
                }
                if (marker == 0xD9) {
                    return pos + 2L
                }
                if (marker == 0x01 || marker in 0xD0..0xD8) {
                    pos += 2L
                    continue
                }
                if (pos + 4L > limitLen) return null
                val b2 = raf.read()
                val b3 = raf.read()
                if (b2 < 0 || b3 < 0) return null
                val segLen = (b2 shl 8) or b3
                if (segLen < 2 || pos + 2L + segLen > limitLen) return null
                pos += 2L + segLen
                if (marker == 0xDA) {
                    inEntropy = true
                }
            } else {
                val buf = ByteArray(64 * 1024)
                raf.seek(pos)
                var prevWasFf = false
                while (pos < limitLen) {
                    val toRead = min(buf.size.toLong(), limitLen - pos).toInt()
                    val read = raf.read(buf, 0, toRead)
                    if (read <= 0) break
                    for (i in 0 until read) {
                        val b = buf[i].toInt() and 0xFF
                        val absPos = pos + i
                        if (prevWasFf) {
                            prevWasFf = false
                            if (b == 0x00 || b in 0xD0..0xD7) {
                                continue
                            }
                            if (b == 0xFF) {
                                prevWasFf = true
                                continue
                            }
                            if (b == 0xD9) {
                                return absPos + 1L
                            }
                        } else if (b == 0xFF) {
                            prevWasFf = true
                        }
                    }
                    pos += read
                }
                return null
            }
        }
        return null
    }

    private fun scanMp4AfterOffset(
        raf: RandomAccessFile,
        fileLen: Long,
        startOffset: Long,
    ): Long? {
        val samsungMarker = "MotionPhoto_Data".toByteArray(StandardCharsets.US_ASCII)
        val scanEnd = min(fileLen, startOffset + 512L * 1024L)
        val chunkSize = 64 * 1024
        val overlap = 32
        val buf = ByteArray(chunkSize + overlap)
        var pos = startOffset

        while (pos < scanEnd) {
            raf.seek(pos)
            val toRead = min((chunkSize + overlap).toLong(), scanEnd - pos).toInt()
            val read = raf.read(buf, 0, toRead)
            if (read < 12) break

            for (i in 0..(read - 12)) {
                if (i + samsungMarker.size + 12 <= read &&
                    matchesBytes(buf, i, samsungMarker) &&
                    hasValidFtypHeader(buf, i + samsungMarker.size, fileLen - (pos + i + samsungMarker.size))
                ) {
                    return pos + i + samsungMarker.size
                }
                if (hasValidFtypHeader(buf, i, fileLen - (pos + i))) {
                    return pos + i
                }
            }
            if (pos + read >= scanEnd) break
            pos += (read - overlap).coerceAtLeast(1)
        }
        return null
    }

    private fun hasValidFtypHeader(buf: ByteArray, offset: Int, remainingLen: Long): Boolean {
        if (offset < 0 || offset + 12 > buf.size) return false
        if (buf[offset + 4] != 'f'.code.toByte() ||
            buf[offset + 5] != 't'.code.toByte() ||
            buf[offset + 6] != 'y'.code.toByte() ||
            buf[offset + 7] != 'p'.code.toByte()
        ) {
            return false
        }
        val boxSize = ((buf[offset].toInt() and 0xFF) shl 24) or
            ((buf[offset + 1].toInt() and 0xFF) shl 16) or
            ((buf[offset + 2].toInt() and 0xFF) shl 8) or
            (buf[offset + 3].toInt() and 0xFF)
        if (boxSize < 12 || boxSize > 512 || boxSize.toLong() > remainingLen) return false
        for (i in 8 until 12) {
            val c = buf[offset + i].toInt() and 0xFF
            if (c < 0x20 || c > 0x7E) return false
        }
        return true
    }

    private fun matchesBytes(haystack: ByteArray, offset: Int, needle: ByteArray): Boolean {
        if (offset < 0 || offset + needle.size > haystack.size) return false
        for (i in needle.indices) {
            if (haystack[offset + i] != needle[i]) return false
        }
        return true
    }

    fun extractThumbnailsAsync(
        videoPath: String,
        count: Int,
        onResult: (List<ByteArray>) -> Unit,
    ) {
        workerExecutor.execute {
            val frames = ArrayList<ByteArray>(count)
            val file = File(videoPath)
            if (!file.exists()) {
                mainHandler.post { onResult(frames) }
                return@execute
            }
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(file.absolutePath)
                val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 1000L
                val rawW = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                    ?.toIntOrNull() ?: 1080
                val rawH = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                    ?.toIntOrNull() ?: 1920
                val maxDim = 180.0
                val scale = min(1.0, maxDim / maxOf(rawW, rawH).coerceAtLeast(1).toDouble())
                val dstW = (rawW * scale).toInt().coerceAtLeast(32)
                val dstH = (rawH * scale).toInt().coerceAtLeast(32)

                val safeCount = count.coerceIn(1, 16)
                for (i in 0 until safeCount) {
                    val ratio = if (safeCount == 1) 0.0 else i.toDouble() / (safeCount - 1).toDouble()
                    val tsUs = ((durationMs * ratio).toLong().coerceAtLeast(0L)) * 1000L
                    val bmp: Bitmap? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                        retriever.getScaledFrameAtTime(
                            tsUs,
                            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                            dstW,
                            dstH
                        )
                    } else {
                        retriever.getFrameAtTime(tsUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)?.let { raw ->
                            val scaled = Bitmap.createScaledBitmap(raw, dstW, dstH, true)
                            if (scaled !== raw) raw.recycle()
                            scaled
                        }
                    }

                    if (bmp != null) {
                        val out = ByteArrayOutputStream(16 * 1024)
                        bmp.compress(Bitmap.CompressFormat.JPEG, 72, out)
                        bmp.recycle()
                        frames.add(out.toByteArray())
                    }
                }
            } catch (_: Exception) {
            } finally {
                try {
                    retriever.release()
                } catch (_: Exception) {
                }
            }
            mainHandler.post { onResult(frames) }
        }
    }
}
