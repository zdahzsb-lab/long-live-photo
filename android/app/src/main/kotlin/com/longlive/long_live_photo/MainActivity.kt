package com.longlive.long_live_photo

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var eventSink: EventChannel.EventSink? = null
    private var converter: MotionPhotoConverter? = null

    private fun setKeepScreenOn(keepOn: Boolean) {
        runOnUiThread {
            if (keepOn) {
                window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
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
    }

    override fun onDestroy() {
        converter?.cancelCurrent()
        setKeepScreenOn(false)
        super.onDestroy()
    }
}
