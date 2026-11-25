package com.longlive.long_live_photo

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
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
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
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

    fun convertAndSaveAsync(
        videoPath: String,
        coverTimeMs: Long,
        quality: String,
        keepAudio: Boolean,
        onSuccess: (NativeConversionOutcome) -> Unit,
        onError: (code: String, message: String) -> Unit,
    ) {
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
                emitProgress("cover", 0.06, "正在抽取高清封面帧...")
                val videoMeta = inspectVideoAndExtractCover(inputFile, coverTimeMs)
                val coverJpegBytes = videoMeta.coverJpegBytes

                emitProgress("video", 0.12, "正在准备动态视频轨道...")
                val preparedMp4 = prepareMp4Trailer(
                    inputFile = inputFile,
                    tempMp4File = tempMp4File,
                    srcWidth = videoMeta.width,
                    srcHeight = videoMeta.height,
                    quality = quality,
                    keepAudio = keepAudio,
                )

                val mp4Length = preparedMp4.length()
                if (mp4Length <= 0L) {
                    throw IllegalStateException("生成的动态视频轨道为空")
                }

                emitProgress("packaging", 0.94, "正在注入双标准实况 XMP 元数据并写入相册...")
                val coverTimestampUs = (coverTimeMs.coerceAtLeast(0L)) * 1000L
                val xmpJpegBytes = MotionPhotoXmpInjector.injectXmpIntoJpeg(
                    jpegBytes = coverJpegBytes,
                    videoLengthBytes = mp4Length,
                    presentationTimestampUs = coverTimestampUs,
                )

                val savedUri = writeMotionPhotoToMediaStore(
                    xmpJpegBytes = xmpJpegBytes,
                    mp4File = preparedMp4,
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
            } catch (e: Exception) {
                mainHandler.post {
                    onError("CONVERT_FAILED", e.message ?: "实况合成失败")
                }
            } finally {
                tempDir.deleteRecursively()
            }
        }
    }

    private fun emitProgress(stage: String, progress: Double, message: String) {
        mainHandler.post {
            onProgress(stage, progress.coerceIn(0.0, 1.0), message)
        }
    }

    private data class VideoCoverInfo(
        val coverJpegBytes: ByteArray,
        val width: Int,
        val height: Int,
        val durationMs: Long,
    )

    private fun inspectVideoAndExtractCover(
        inputFile: File,
        coverTimeMs: Long,
    ): VideoCoverInfo {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(inputFile.absolutePath)
            val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 1080
            val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 1920
            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 1000L

            val safeTimeUs = coverTimeMs.coerceIn(0L, durationMs.coerceAtLeast(0L)) * 1000L
            val bitmap: Bitmap = retriever.getFrameAtTime(
                safeTimeUs,
                MediaMetadataRetriever.OPTION_CLOSEST
            ) ?: retriever.getFrameAtTime(
                safeTimeUs,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: retriever.getFrameAtTime(0L)
                ?: throw IllegalStateException("无法从视频抽取静态封面画面")

            val baos = ByteArrayOutputStream(256 * 1024)
            try {
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 92, baos)) {
                    throw IllegalStateException("JPEG 封面编码失败")
                }
            } finally {
                bitmap.recycle()
            }

            return VideoCoverInfo(
                coverJpegBytes = baos.toByteArray(),
                width = width,
                height = height,
                durationMs = durationMs,
            )
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun prepareMp4Trailer(
        inputFile: File,
        tempMp4File: File,
        srcWidth: Int,
        srcHeight: Int,
        quality: String,
        keepAudio: Boolean,
    ): File {
        if (quality == "passthrough") {
            val remuxOk = tryLosslessRemuxToMp4(inputFile, tempMp4File, keepAudio)
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
        quality: String,
        keepAudio: Boolean,
    ) {
        val latch = CountDownLatch(1)
        val errorRef = AtomicReference<Exception?>(null)

        val (targetShortSide, targetBitrate) = when (quality) {
            "720p" -> Pair(720, 2_800_000)
            "passthrough" -> Pair(Int.MAX_VALUE, 8_000_000)
            else -> Pair(1080, 6_000_000)
        }

        mainHandler.post {
            try {
                val videoEffects = mutableListOf<Effect>()
                val srcShortSide = min(srcWidth, srcHeight)
                if (srcShortSide > targetShortSide) {
                    videoEffects.add(Presentation.createForShortSide(targetShortSide))
                }

                val editedItem = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(inputFile)))
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
                        if (finished) return
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
                            latch.countDown()
                        }

                        override fun onError(
                            composition: Composition,
                            exportResult: ExportResult,
                            exportException: ExportException,
                        ) {
                            finished = true
                            mainHandler.removeCallbacks(pollRunnable)
                            errorRef.set(exportException)
                            latch.countDown()
                        }
                    })
                    .build()

                transformer.start(editedItem, outputFile.absolutePath)
                mainHandler.postDelayed(pollRunnable, 200L)
            } catch (e: Exception) {
                errorRef.set(e)
                latch.countDown()
            }
        }

        latch.await()
        errorRef.get()?.let { throw it }
    }

    private fun writeMotionPhotoToMediaStore(
        xmpJpegBytes: ByteArray,
        mp4File: File,
    ): Uri {
        val resolver = context.contentResolver
        val timestampStr = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val displayName = "MVIMG_$timestampStr.jpg"

        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            val nowSec = System.currentTimeMillis() / 1000L
            put(MediaStore.Images.Media.DATE_ADDED, nowSec)
            put(MediaStore.Images.Media.DATE_MODIFIED, nowSec)
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
                    mp4In.copyTo(out, bufferSize = 64 * 1024)
                }
                out.flush()
            } ?: throw IllegalStateException("无法打开系统相册输出流")

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
}
