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
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
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
import kotlin.math.max
import kotlin.math.min

data class NativeConversionOutcome(
    val savedUri: String,
    val outputSizeBytes: Long,
    val elapsedMs: Long,
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
        onSuccess: (NativeConversionOutcome) -> Unit,
        onError: (code: String, message: String) -> Unit,
    ) {
        cancelled.set(false)
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
                    quality = quality,
                    keepAudio = keepAudio,
                )

                ensureNotCancelled()
                val mp4Length = preparedMp4.length()
                if (mp4Length <= 0L) {
                    throw IllegalStateException("生成的动态视频轨道为空")
                }

                emitProgress("packaging", 0.94, "正在注入双标准实况 XMP 元数据并写入相册...")
                val relativeCoverMs = (inspection.clampedCoverMs - inspection.safeTrimStartMs)
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
        val clampedCoverMs: Long,
        val captureTimeMs: Long?,
        val location: Pair<Double, Double>?,
    )

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

    private fun prepareMp4Trailer(
        inputFile: File,
        tempMp4File: File,
        srcWidth: Int,
        srcHeight: Int,
        durationMs: Long,
        trimStartMs: Long,
        trimEndMs: Long,
        isTrimmed: Boolean,
        quality: String,
        keepAudio: Boolean,
    ): File {
        if (!isTrimmed && quality == "passthrough") {
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
            quality = quality,
            keepAudio = keepAudio,
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
        quality: String,
        keepAudio: Boolean,
    ) {
        val latch = CountDownLatch(1)
        activeLatch = latch
        val errorRef = AtomicReference<Exception?>(null)

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

                val editedItem = EditedMediaItem.Builder(mediaItemBuilder.build())
                    .setRemoveAudio(!keepAudio)
                    .setEffects(Effects(emptyList(), videoEffects))
                    .build()

                val videoEncoderSettings = VideoEncoderSettings.Builder()
                    .setBitrate(targetBitrate)
                    .build()

                val encoderFactory = DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(videoEncoderSettings)
                    .build()

                lateinit var transformer: Transformer
                val progressHolder = ProgressHolder()
                var finished = false

                val pollRunnable = object : Runnable {
                    override fun run() {
                        if (finished || cancelled.get()) return
                        val state = transformer.getProgress(progressHolder)
                        if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
                            val pct = progressHolder.progress.coerceIn(0, 100)
                            val uiProg = 0.12 + (pct / 100.0) * 0.80
                            onProgress("video", uiProg, "硬件编码压制中（$pct%）...")
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

                activeTransformer = transformer
                transformer.start(editedItem, outputFile.absolutePath)
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
        val resolver = context.contentResolver
        val fileDateMs = captureTimeMs ?: System.currentTimeMillis()
        val timestampStr = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date(fileDateMs))
        val displayName = "MVIMG_$timestampStr.jpg"

        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            val timeSec = fileDateMs / 1000L
            put(MediaStore.Images.Media.DATE_ADDED, timeSec)
            put(MediaStore.Images.Media.DATE_MODIFIED, timeSec)
            if (captureTimeMs != null) {
                put(MediaStore.Images.Media.DATE_TAKEN, captureTimeMs)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_DCIM + "/Camera")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }

        val itemUri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("无法在系统相册中创建实况文件条目")

        try {
            resolver.openOutputStream(itemUri)?.use { out ->
                out.write(xmpJpegBytes)
                FileInputStream(mp4File).use { mp4In ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        ensureNotCancelled()
                        val read = mp4In.read(buffer)
                        if (read < 0) break
                        out.write(buffer, 0, read)
                    }
                }
                out.flush()
            } ?: throw IllegalStateException("无法打开系统相册输出流")

            ensureNotCancelled()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val completeValues = ContentValues().apply {
                    put(MediaStore.Images.Media.IS_PENDING, 0)
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
