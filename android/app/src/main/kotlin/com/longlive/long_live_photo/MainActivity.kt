package com.longlive.long_live_photo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.WindowManager
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val REQ_PICK_MOTION_PHOTO = 9301
        private const val EXTRA_CONSUMED = "com.longlive.CONSUMED"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val sharedImportExecutor = Executors.newSingleThreadExecutor()

    private var eventSink: EventChannel.EventSink? = null
    private var sharedEventSink: EventChannel.EventSink? = null
    private val pendingSharedLock = Any()
    private val pendingSharedQueue = mutableListOf<Map<String, String>>()

    private var converter: MotionPhotoConverter? = null
    private var pendingPickLivePhotoResult: MethodChannel.Result? = null

    private fun setKeepScreenOn(keepOn: Boolean) {
        runOnUiThread {
            if (keepOn) {
                window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        converter = MotionPhotoConverter(applicationContext) { stage, progress, message ->
            eventSink?.success(
                mapOf(
                    "stage" to stage,
                    "progress" to progress,
                    "message" to message,
                )
            )
        }

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "com.longlive.long_live_photo/converter")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "convertAndSave" -> {
                        val videoPath = call.argument<String>("videoPath")
                        if (videoPath.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "缺少视频路径参数", null)
                            return@setMethodCallHandler
                        }
                        val coverTimeMs = call.argument<Number>("coverTimeMs")?.toLong() ?: 0L
                        val quality = call.argument<String>("quality") ?: "1080p"
                        val keepAudio = call.argument<Boolean>("keepAudio") ?: true
                        val customCoverPath = call.argument<String>("customCoverPath")
                        val trimStartMs = call.argument<Number>("trimStartMs")?.toLong()
                        val trimEndMs = call.argument<Number>("trimEndMs")?.toLong()
                        val preserveMetadata = call.argument<Boolean>("preserveMetadata") ?: true
                        val playbackSpeed = (call.argument<Number>("playbackSpeed")?.toDouble() ?: 1.0)
                            .coerceIn(0.5, 4.0)

                        setKeepScreenOn(true)

                        converter?.convertAndSaveAsync(
                            videoPath = videoPath,
                            coverTimeMs = coverTimeMs,
                            quality = quality,
                            keepAudio = keepAudio,
                            customCoverPath = customCoverPath,
                            trimStartMs = trimStartMs,
                            trimEndMs = trimEndMs,
                            preserveMetadata = preserveMetadata,
                            playbackSpeed = playbackSpeed,
                            onSuccess = { outcome ->
                                setKeepScreenOn(false)
                                result.success(
                                    mapOf(
                                        "savedTarget" to outcome.savedUri,
                                        "outputSizeBytes" to outcome.outputSizeBytes,
                                        "elapsedMs" to outcome.elapsedMs,
                                        "platformFormat" to "Android Motion Photo (MVIMG JPG+MP4)",
                                    )
                                )
                            },
                            onError = { code, msg ->
                                setKeepScreenOn(false)
                                result.error(code, msg, null)
                            },
                        )
                    }

                    "cancelConversion" -> {
                        converter?.cancelCurrent()
                        setKeepScreenOn(false)
                        result.success(null)
                    }

                    "extractThumbnails" -> {
                        val videoPath = call.argument<String>("videoPath")
                        if (videoPath.isNullOrBlank()) {
                            result.success(emptyList<ByteArray>())
                            return@setMethodCallHandler
                        }
                        val count = call.argument<Number>("count")?.toInt() ?: 8
                        converter?.extractThumbnailsAsync(videoPath, count) { frames ->
                            result.success(frames)
                        }
                    }

                    "consumeInitialSharedMedia" -> {
                        val items = synchronized(pendingSharedLock) {
                            val copy = pendingSharedQueue.toList()
                            pendingSharedQueue.clear()
                            copy
                        }
                        result.success(items)
                    }

                    "openSystemGallery" -> {
                        val savedTarget = call.argument<String>("savedTarget")
                        result.success(openSystemGallery(savedTarget))
                    }

                    "pickAndUnpackLivePhoto" -> {
                        if (pendingPickLivePhotoResult != null) {
                            result.error("BUSY", "正在选择动态照片，请稍候", null)
                            return@setMethodCallHandler
                        }
                        pendingPickLivePhotoResult = result
                        try {
                            val pickIntent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "image/*"
                            }
                            @Suppress("DEPRECATION")
                            startActivityForResult(pickIntent, REQ_PICK_MOTION_PHOTO)
                        } catch (e: Exception) {
                            pendingPickLivePhotoResult = null
                            result.error("PICKER_UNAVAILABLE", e.message ?: "无法打开文件选择器", null)
                        }
                    }

                    "unpackLivePhotoFile" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "缺少文件路径参数", null)
                            return@setMethodCallHandler
                        }
                        converter?.unpackMotionPhotoAsync(
                            filePath = filePath,
                            onSuccess = { unpacked ->
                                result.success(
                                    mapOf(
                                        "videoPath" to unpacked.videoPath,
                                        "coverImagePath" to unpacked.coverImagePath,
                                        "coverTimeMs" to unpacked.coverTimeMs,
                                    )
                                )
                            },
                            onError = { code, msg ->
                                result.error(code, msg, null)
                            },
                        )
                    }

                    "exportStandaloneMedia" -> {
                        val mode = call.argument<String>("mode") ?: "video"
                        val videoPath = call.argument<String>("videoPath")
                        if (videoPath.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "缺少视频路径参数", null)
                            return@setMethodCallHandler
                        }
                        val coverTimeMs = call.argument<Number>("coverTimeMs")?.toLong() ?: 0L
                        val quality = call.argument<String>("quality") ?: "passthrough"
                        val keepAudio = call.argument<Boolean>("keepAudio") ?: true
                        val customCoverPath = call.argument<String>("customCoverPath")
                        val trimStartMs = call.argument<Number>("trimStartMs")?.toLong()
                        val trimEndMs = call.argument<Number>("trimEndMs")?.toLong()
                        val preserveMetadata = call.argument<Boolean>("preserveMetadata") ?: true
                        val playbackSpeed = (call.argument<Number>("playbackSpeed")?.toDouble() ?: 1.0)
                            .coerceIn(0.5, 4.0)

                        setKeepScreenOn(true)
                        converter?.exportStandaloneAsync(
                            mode = mode,
                            videoPath = videoPath,
                            coverTimeMs = coverTimeMs,
                            quality = quality,
                            keepAudio = keepAudio,
                            customCoverPath = customCoverPath,
                            trimStartMs = trimStartMs,
                            trimEndMs = trimEndMs,
                            preserveMetadata = preserveMetadata,
                            playbackSpeed = playbackSpeed,
                            onSuccess = { outcome ->
                                setKeepScreenOn(false)
                                result.success(
                                    mapOf(
                                        "savedTarget" to outcome.savedUri,
                                        "outputSizeBytes" to outcome.outputSizeBytes,
                                        "elapsedMs" to outcome.elapsedMs,
                                        "platformFormat" to if (mode == "cover") "JPEG 高清封面" else "MP4 普通视频",
                                    )
                                )
                            },
                            onError = { code, msg ->
                                setKeepScreenOn(false)
                                result.error(code, msg, null)
                            },
                        )
                    }

                    else -> result.notImplemented()
                }
            }

        EventChannel(messenger, "com.longlive.long_live_photo/progress")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        EventChannel(messenger, "com.longlive.long_live_photo/shared_media")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sharedEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    sharedEventSink = null
                }
            })
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_PICK_MOTION_PHOTO) {
            val pending = pendingPickLivePhotoResult
            pendingPickLivePhotoResult = null
            if (pending == null) return
            val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
            if (uri == null) {
                pending.success(null)
                return
            }
            sharedImportExecutor.execute {
                val copied = copySharedUriToCache(uri)
                if (copied == null) {
                    mainHandler.post {
                        pending.error("READ_FAILED", "无法读取所选照片文件", null)
                    }
                    return@execute
                }
                converter?.unpackMotionPhotoAsync(
                    filePath = copied.first.absolutePath,
                    onSuccess = { unpacked ->
                        pending.success(
                            mapOf(
                                "videoPath" to unpacked.videoPath,
                                "coverImagePath" to unpacked.coverImagePath,
                                "coverTimeMs" to unpacked.coverTimeMs,
                            )
                        )
                    },
                    onError = { code, msg ->
                        pending.error(code, msg, null)
                    },
                )
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun openSystemGallery(savedTarget: String?): Boolean {
        if (!savedTarget.isNullOrBlank() && savedTarget.startsWith("content://")) {
            try {
                val uri = Uri.parse(savedTarget)
                val mime = if (savedTarget.contains("/video")) "video/*" else "image/*"
                val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mime)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(viewIntent)
                return true
            } catch (_: ActivityNotFoundException) {
            } catch (_: Exception) {
            }
        }

        try {
            val galleryUriIntent = Intent(Intent.ACTION_VIEW, MediaStore.Images.Media.EXTERNAL_CONTENT_URI).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(galleryUriIntent)
            return true
        } catch (_: Exception) {
        }

        return try {
            val appGalleryIntent = Intent.makeMainSelectorActivity(
                Intent.ACTION_MAIN,
                Intent.CATEGORY_APP_GALLERY
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(appGalleryIntent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent == null || intent.getBooleanExtra(EXTRA_CONSUMED, false)) return
        val action = intent.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return

        val uris = extractSharedUris(intent)
        if (uris.isEmpty()) return
        intent.putExtra(EXTRA_CONSUMED, true)

        sharedImportExecutor.execute {
            val imported = mutableListOf<Map<String, String>>()
            for (uri in uris) {
                val copied = copySharedUriToCache(uri) ?: continue
                imported.add(
                    mapOf(
                        "path" to copied.first.absolutePath,
                        "kind" to copied.second,
                    )
                )
            }
            if (imported.isEmpty()) return@execute

            mainHandler.post {
                val sink = sharedEventSink
                if (sink != null) {
                    sink.success(imported)
                } else {
                    synchronized(pendingSharedLock) {
                        pendingSharedQueue.addAll(imported)
                    }
                }
            }
        }
    }

    private fun extractSharedUris(intent: Intent): List<Uri> {
        return when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                if (uri != null) listOf(uri) else emptyList()
            }

            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                }
                uris?.filterNotNull().orEmpty()
            }

            else -> emptyList()
        }
    }

    private fun copySharedUriToCache(uri: Uri): Pair<File, String>? {
        return try {
            val importDir = File(cacheDir, "shared_imports").apply { mkdirs() }
            val cutoff = System.currentTimeMillis() - 24L * 3600L * 1000L
            importDir.listFiles()?.forEach { old ->
                if (old.lastModified() < cutoff) {
                    try {
                        old.deleteRecursively()
                    } catch (_: Exception) {
                    }
                }
            }

            val mime = contentResolver.getType(uri)?.lowercase(Locale.US) ?: ""
            val mimeExt = if (mime.isNotEmpty()) {
                MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
            } else {
                null
            }
            val uriExt = MimeTypeMap.getFileExtensionFromUrl(uri.toString())
                ?.lowercase(Locale.US)
                ?.takeIf { it.isNotEmpty() && it.length <= 6 }

            val isImage = mime.startsWith("image/") ||
                uriExt in setOf("jpg", "jpeg", "png", "heic", "heif", "webp")
            val ext = (mimeExt ?: uriExt ?: if (isImage) "jpg" else "mp4")
                .lowercase(Locale.US)
            val kind = if (isImage) "image" else "video"

            val outFile = File(
                importDir,
                "share_${System.currentTimeMillis()}_${UUID.randomUUID().toString().take(8)}.$ext"
            )
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buf)
                        if (read < 0) break
                        output.write(buf, 0, read)
                    }
                    output.flush()
                }
            } ?: return null

            if (!outFile.exists() || outFile.length() == 0L) {
                outFile.delete()
                return null
            }
            Pair(outFile, kind)
        } catch (_: Exception) {
            null
        }
    }

    override fun onDestroy() {
        converter?.cancelCurrent()
        setKeepScreenOn(false)
        sharedImportExecutor.shutdown()
        super.onDestroy()
    }
}
