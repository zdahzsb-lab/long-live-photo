import Flutter
import UIKit
import AVFoundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import CoreMedia

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler, FlutterImplicitEngineDelegate {
  private var eventSink: FlutterEventSink?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()
    let methodChannel = FlutterMethodChannel(
      name: "com.longlive.long_live_photo/converter",
      binaryMessenger: messenger
    )
    methodChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard call.method == "convertAndSave" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
            let videoPath = args["videoPath"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "缺少视频文件路径参数", details: nil))
        return
      }
      let coverTimeMs = (args["coverTimeMs"] as? NSNumber)?.int64Value ?? 0
      let quality = (args["quality"] as? String) ?? "1080p"
      let keepAudio = (args["keepAudio"] as? Bool) ?? true

      self?.handleConvertAndSave(
        videoPath: videoPath,
        coverTimeMs: coverTimeMs,
        quality: quality,
        keepAudio: keepAudio,
        result: result
      )
    }

    let progressChannel = FlutterEventChannel(
      name: "com.longlive.long_live_photo/progress",
      binaryMessenger: messenger
    )
    progressChannel.setStreamHandler(self)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  private func emitProgress(stage: String, progress: Double, message: String) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?([
        "stage": stage,
        "progress": min(max(progress, 0.0), 1.0),
        "message": message
      ])
    }
  }

  private func handleConvertAndSave(
    videoPath: String,
    coverTimeMs: Int64,
    quality: String,
    keepAudio: Bool,
    result: @escaping FlutterResult
  ) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
      guard let self = self else { return }
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "PHOTO_PERMISSION_DENIED",
            message: "请在系统“设置 → 隐私与安全性 → 照片”中允许“长实况”添加照片",
            details: nil
          ))
        }
        return
      }

      DispatchQueue.global(qos: .userInitiated).async {
        self.executePipeline(
          videoPath: videoPath,
          coverTimeMs: coverTimeMs,
          quality: quality,
          keepAudio: keepAudio,
          result: result
        )
      }
    }
  }

  private func executePipeline(
    videoPath: String,
    coverTimeMs: Int64,
    quality: String,
    keepAudio: Bool,
    result: @escaping FlutterResult
  ) {
    let startTime = CFAbsoluteTimeGetCurrent()
    let inputURL = URL(fileURLWithPath: videoPath)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
      DispatchQueue.main.async {
        result(FlutterError(code: "FILE_NOT_FOUND", message: "找不到所选视频文件", details: nil))
      }
      return
    }

    let asset = AVURLAsset(url: inputURL)
    let durationSeconds = max(CMTimeGetSeconds(asset.duration), 0.1)
    let requestedCoverSec = Double(max(coverTimeMs, 0)) / 1000.0
    let clampedCoverSec = min(requestedCoverSec, max(0.0, durationSeconds - 0.05))
    let coverCMTime = CMTime(seconds: clampedCoverSec, preferredTimescale: 600)

    let assetId = UUID().uuidString
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("long_live_\(assetId)", isDirectory: true)

    do {
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    } catch {
      DispatchQueue.main.async {
        result(FlutterError(code: "TEMP_DIR_ERROR", message: "无法创建临时工作目录：\(error.localizedDescription)", details: nil))
      }
      return
    }

    let photoURL = tempDir.appendingPathComponent("IMG_\(assetId).JPG")
    let pairedVideoURL = tempDir.appendingPathComponent("IMG_\(assetId).MOV")

    let cleanup = {
      try? FileManager.default.removeItem(at: tempDir)
    }

    // Step 1: Extract high-quality still frame with MakerApple ContentIdentifier (key "17")
    emitProgress(stage: "cover", progress: 0.06, message: "正在抽取高清封面帧并注入实况标识...")
    do {
      try writeStillImageWithIdentifier(
        asset: asset,
        at: coverCMTime,
        assetIdentifier: assetId,
        outputURL: photoURL
      )
    } catch {
      cleanup()
      DispatchQueue.main.async {
        result(FlutterError(code: "COVER_EXTRACT_FAILED", message: "抽取封面帧失败：\(error.localizedDescription)", details: nil))
      }
      return
    }

    // Step 2: Build paired QuickTime MOV with matching ContentIdentifier & still-image-time track
    emitProgress(stage: "video", progress: 0.12, message: "正在准备实况视频流...")
    buildPairedLiveVideo(
      asset: asset,
      durationSeconds: durationSeconds,
      stillImageTime: coverCMTime,
      assetIdentifier: assetId,
      quality: quality,
      keepAudio: keepAudio,
      outputURL: pairedVideoURL
    ) { [weak self] videoError in
      guard let self = self else {
        cleanup()
        return
      }

      if let videoError = videoError {
        cleanup()
        DispatchQueue.main.async {
          result(FlutterError(code: "VIDEO_ENCODE_FAILED", message: "封装实况视频失败：\(videoError.localizedDescription)", details: nil))
        }
        return
      }

      let photoBytes = (try? FileManager.default.attributesOfItem(atPath: photoURL.path)[.size] as? NSNumber)?.int64Value ?? 0
      let videoBytes = (try? FileManager.default.attributesOfItem(atPath: pairedVideoURL.path)[.size] as? NSNumber)?.int64Value ?? 0
      let totalBytes = photoBytes + videoBytes

      // Step 3: Save paired Live Photo into iOS Photos Library
      self.emitProgress(stage: "saving", progress: 0.96, message: "正在写入 iPhone 系统“照片”...")
      var placeholderLocalId: String = ""

      PHPhotoLibrary.shared().performChanges({
        let creationRequest = PHAssetCreationRequest.forAsset()
        let photoOptions = PHAssetResourceCreationOptions()
        creationRequest.addResource(with: .photo, fileURL: photoURL, options: photoOptions)

        let videoOptions = PHAssetResourceCreationOptions()
        videoOptions.shouldMoveFile = true
        creationRequest.addResource(with: .pairedVideo, fileURL: pairedVideoURL, options: videoOptions)

        if let placeholder = creationRequest.placeholderForCreatedAsset {
          placeholderLocalId = placeholder.localIdentifier
        }
      }, completionHandler: { success, saveError in
        cleanup()
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000.0)
        DispatchQueue.main.async {
          if success {
            result([
              "savedTarget": placeholderLocalId,
              "outputSizeBytes": totalBytes,
              "elapsedMs": elapsedMs,
              "platformFormat": "Apple Live Photo (HEIC/JPG + MOV)"
            ])
          } else {
            result(FlutterError(
              code: "PHOTOS_SAVE_FAILED",
              message: "写入系统相册失败：\(saveError?.localizedDescription ?? "未知错误")",
              details: nil
            ))
          }
        }
      })
    }
  }

  private func writeStillImageWithIdentifier(
    asset: AVAsset,
    at time: CMTime,
    assetIdentifier: String,
    outputURL: URL
  ) throws {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

    let cgImage: CGImage
    do {
      cgImage = try generator.copyCGImage(at: time, actualTime: nil)
    } catch {
      generator.requestedTimeToleranceBefore = .positiveInfinity
      generator.requestedTimeToleranceAfter = .positiveInfinity
      cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
    }

    guard let dest = CGImageDestinationCreateWithURL(
      outputURL as CFURL,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else {
      throw NSError(domain: "LongLivePhoto", code: -10, userInfo: [NSLocalizedDescriptionKey: "无法创建 JPEG 编码目标"])
    }

    let properties: [String: Any] = [
      kCGImagePropertyLossyCompressionQuality as String: 0.92,
      kCGImagePropertyMakerAppleDictionary as String: [
        "17": assetIdentifier
      ]
    ]
    CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
      throw NSError(domain: "LongLivePhoto", code: -11, userInfo: [NSLocalizedDescriptionKey: "写入实况封面元数据失败"])
    }
  }

  private func buildPairedLiveVideo(
    asset: AVAsset,
    durationSeconds: Double,
    stillImageTime: CMTime,
    assetIdentifier: String,
    quality: String,
    keepAudio: Bool,
    outputURL: URL,
    completion: @escaping (Error?) -> Void
  ) {
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      completion(NSError(domain: "LongLivePhoto", code: -20, userInfo: [NSLocalizedDescriptionKey: "所选文件不包含有效视频轨道"]))
      return
    }

    do {
      let reader = try AVAssetReader(asset: asset)
      let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

      // 1. Top-level QuickTime ContentIdentifier matching MakerApple "17"
      let idMetadata = AVMutableMetadataItem()
      idMetadata.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier as NSString
      idMetadata.keySpace = .quickTimeMetadata
      idMetadata.value = assetIdentifier as NSString
      idMetadata.dataType = kCMMetadataBaseDataType_UTF8 as String
      writer.metadata = [idMetadata]

      // 2. Timed metadata track for com.apple.quicktime.still-image-time
      let stillTimeSpec: NSDictionary = [
        kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: "mdta/com.apple.quicktime.still-image-time",
        kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: kCMMetadataBaseDataType_SInt8
      ]
      var metadataFormatDesc: CMFormatDescription?
      CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: [stillTimeSpec] as CFArray,
        formatDescriptionOut: &metadataFormatDesc
      )
      let metadataInput = AVAssetWriterInput(
        mediaType: .metadata,
        outputSettings: nil,
        sourceFormatHint: metadataFormatDesc
      )
      let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
      if writer.canAdd(metadataInput) {
        writer.add(metadataInput)
      }

      // 3. Configure video reader output & writer input (Passthrough vs Hardware H.264)
      let sourceFormatDesc: CMFormatDescription? = videoTrack.formatDescriptions.isEmpty
        ? nil
        : (videoTrack.formatDescriptions[0] as! CMFormatDescription)
      let codecSubType: FourCharCode = sourceFormatDesc.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
      let canPassthroughCodec = (codecSubType == kCMVideoCodecType_H264 || codecSubType == kCMVideoCodecType_HEVC)
      let usePassthrough = (quality == "passthrough" && canPassthroughCodec)

      let readerVideoOutput: AVAssetReaderTrackOutput
      let writerVideoInput: AVAssetWriterInput

      if usePassthrough {
        readerVideoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: sourceFormatDesc)
        writerVideoInput.transform = videoTrack.preferredTransform
      } else {
        readerVideoOutput = AVAssetReaderTrackOutput(
          track: videoTrack,
          outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
          ]
        )
        let (targetW, targetH, bitrate) = computeEncodingParams(
          naturalSize: videoTrack.naturalSize,
          quality: quality
        )
        let videoSettings: [String: Any] = [
          AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: targetW,
          AVVideoHeightKey: targetH,
          AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
          ]
        ]
        writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerVideoInput.transform = scaledTransform(
          original: videoTrack.preferredTransform,
          targetWidth: targetW,
          targetHeight: targetH
        )
      }
      readerVideoOutput.alwaysCopiesSampleData = false
      writerVideoInput.expectsMediaDataInRealTime = false

      guard reader.canAdd(readerVideoOutput), writer.canAdd(writerVideoInput) else {
        completion(NSError(domain: "LongLivePhoto", code: -21, userInfo: [NSLocalizedDescriptionKey: "无法初始化视频读写管线"]))
        return
      }
      reader.add(readerVideoOutput)
      writer.add(writerVideoInput)

      // 4. Optional audio track
      var readerAudioOutput: AVAssetReaderTrackOutput?
      var writerAudioInput: AVAssetWriterInput?
      if keepAudio, let audioTrack = asset.tracks(withMediaType: .audio).first {
        let audioOut = AVAssetReaderTrackOutput(
          track: audioTrack,
          outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
          ]
        )
        audioOut.alwaysCopiesSampleData = false
        let audioIn = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 128000
          ]
        )
        audioIn.expectsMediaDataInRealTime = false
        if reader.canAdd(audioOut) && writer.canAdd(audioIn) {
          reader.add(audioOut)
          writer.add(audioIn)
          readerAudioOutput = audioOut
          writerAudioInput = audioIn
        }
      }

      guard writer.startWriting() else {
        completion(writer.error ?? NSError(domain: "LongLivePhoto", code: -22, userInfo: [NSLocalizedDescriptionKey: "启动 MOV 写入器失败"]))
        return
      }
      guard reader.startReading() else {
        writer.cancelWriting()
        completion(reader.error ?? NSError(domain: "LongLivePhoto", code: -23, userInfo: [NSLocalizedDescriptionKey: "读取源视频流失败"]))
        return
      }

      writer.startSession(atSourceTime: .zero)

      // Write still-image-time marker
      let stillItem = AVMutableMetadataItem()
      stillItem.key = "com.apple.quicktime.still-image-time" as NSString
      stillItem.keySpace = .quickTimeMetadata
      stillItem.value = 0 as NSNumber
      stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
      let frameDur = CMTime(value: 1, timescale: 600)
      let group = AVTimedMetadataGroup(items: [stillItem], timeRange: CMTimeRange(start: stillImageTime, duration: frameDur))
      metadataAdaptor.append(group)
      metadataInput.markAsFinished()

      let pumpGroup = DispatchGroup()
      let videoQueue = DispatchQueue(label: "com.longlive.videoPump")
      var lastReportedPercent = -1

      pumpGroup.enter()
      writerVideoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
        while writerVideoInput.isReadyForMoreMediaData {
          if let sample = readerVideoOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let sec = CMTimeGetSeconds(pts)
            if sec.isFinite && durationSeconds > 0 {
              let ratio = min(max(sec / durationSeconds, 0.0), 1.0)
              let uiProg = 0.12 + ratio * 0.82
              let pct = Int(ratio * 100.0)
              if pct >= lastReportedPercent + 2 {
                lastReportedPercent = pct
                let modeLabel = usePassthrough ? "原画直通封装中" : "硬件编码压制中"
                self?.emitProgress(stage: "video", progress: uiProg, message: "\(modeLabel)（\(pct)%）...")
              }
            }
            if !writerVideoInput.append(sample) {
              writerVideoInput.markAsFinished()
              pumpGroup.leave()
              return
            }
          } else {
            writerVideoInput.markAsFinished()
            pumpGroup.leave()
            return
          }
        }
      }

      if let aOut = readerAudioOutput, let aIn = writerAudioInput {
        let audioQueue = DispatchQueue(label: "com.longlive.audioPump")
        pumpGroup.enter()
        aIn.requestMediaDataWhenReady(on: audioQueue) {
          while aIn.isReadyForMoreMediaData {
            if let sample = aOut.copyNextSampleBuffer() {
              if !aIn.append(sample) {
                aIn.markAsFinished()
                pumpGroup.leave()
                return
              }
            } else {
              aIn.markAsFinished()
              pumpGroup.leave()
              return
            }
          }
        }
      }

      pumpGroup.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
        if reader.status == .failed {
          writer.cancelWriting()
          completion(reader.error)
          return
        }
        writer.finishWriting {
          if writer.status == .completed {
            completion(nil)
          } else {
            completion(writer.error ?? NSError(domain: "LongLivePhoto", code: -24, userInfo: [NSLocalizedDescriptionKey: "完成 MOV 封装时出错"]))
          }
        }
      }
    } catch {
      completion(error)
    }
  }

  private func computeEncodingParams(naturalSize: CGSize, quality: String) -> (Int, Int, Int) {
    let rawW = max(abs(naturalSize.width), 2.0)
    let rawH = max(abs(naturalSize.height), 2.0)
    let shortSide = min(rawW, rawH)

    let targetShortLimit: CGFloat
    let bitrate: Int
    switch quality {
    case "720p":
      targetShortLimit = 720.0
      bitrate = 2_800_000
    default:
      targetShortLimit = 1080.0
      bitrate = 6_000_000
    }

    let scale = shortSide > targetShortLimit ? (targetShortLimit / shortSide) : 1.0
    var outW = Int((rawW * scale).rounded())
    var outH = Int((rawH * scale).rounded())
    if outW % 2 != 0 { outW -= 1 }
    if outH % 2 != 0 { outH -= 1 }
    outW = max(outW, 2)
    outH = max(outH, 2)
    return (outW, outH, bitrate)
  }

  private func scaledTransform(
    original t: CGAffineTransform,
    targetWidth: Int,
    targetHeight: Int
  ) -> CGAffineTransform {
    let linear = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0)
    if linear.isIdentity {
      return .identity
    }
    let rect = CGRect(x: 0, y: 0, width: CGFloat(targetWidth), height: CGFloat(targetHeight))
      .applying(linear)
    return CGAffineTransform(
      a: t.a,
      b: t.b,
      c: t.c,
      d: t.d,
      tx: -rect.origin.x,
      ty: -rect.origin.y
    )
  }
}
