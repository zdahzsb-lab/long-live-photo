package com.longlive.long_live_photo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var eventSink: EventChannel.EventSink? = null
    private var converter: MotionPhotoConverter? = null

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
                if (call.method != "convertAndSave") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val videoPath = call.argument<String>("videoPath")
                if (videoPath.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "缺少视频路径参数", null)
                    return@setMethodCallHandler
                }
                val coverTimeMs = call.argument<Number>("coverTimeMs")?.toLong() ?: 0L
                val quality = call.argument<String>("quality") ?: "1080p"
                val keepAudio = call.argument<Boolean>("keepAudio") ?: true

                converter?.convertAndSaveAsync(
                    videoPath = videoPath,
                    coverTimeMs = coverTimeMs,
                    quality = quality,
                    keepAudio = keepAudio,
                    onSuccess = { outcome ->
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
                        result.error(code, msg, null)
                    },
                )
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
}
