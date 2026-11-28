import Flutter
import UIKit
import AVFoundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import CoreMedia
import CoreLocation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler, FlutterImplicitEngineDelegate {
  private var eventSink: FlutterEventSink?

  private let stateLock = NSLock()
  private var isCancelled = false
  private var activeReader: AVAssetReader?
  private var activeWriter: AVAssetWriter?
  private var activeBackgroundTask: UIBackgroundTaskIdentifier = .invalid

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
      switch call.method {
      case "convertAndSave":
        guard let args = call.arguments as? [String: Any],
              let videoPath = args["videoPath"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "缺少视频文件路径参数", details: nil))
          return
        }
        let coverTimeMs = (args["coverTimeMs"] as? NSNumber)?.int64Value ?? 0
        let quality = (args["quality"] as? String) ?? "1080p"
        let keepAudio = (args["keepAudio"] as? Bool) ?? true
        let customCoverPath = args["customCoverPath"] as? String
        let trimStartMs = (args["trimStartMs"] as? NSNumber)?.int64Value
        let trimEndMs = (args["trimEndMs"] as? NSNumber)?.int64Value
        let preserveMetadata = (args["preserveMetadata"] as? Bool) ?? true
        let rawSpeed = (args["playbackSpeed"] as? NSNumber)?.doubleValue ?? 1.0
        let playbackSpeed = min(max(rawSpeed, 0.5), 4.0)

        self?.handleConvertAndSave(
          videoPath: videoPath,
          coverTimeMs: coverTimeMs,
          quality: quality,
          keepAudio: keepAudio,
          customCoverPath: customCoverPath,
          trimStartMs: trimStartMs,
          trimEndMs: trimEndMs,
          preserveMetadata: preserveMetadata,
          playbackSpeed: playbackSpeed,
          result: result
        )

      case "cancelConversion":
        self?.cancelActiveConversion()
        result(nil)

      case "extractThumbnails":
        guard let args = call.arguments as? [String: Any],
              let videoPath = args["videoPath"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "缺少视频文件路径参数", details: nil))
          return
        }
        let count = max(1, min((args["count"] as? NSNumber)?.intValue ?? 8, 16))
        self?.handleExtractThumbnails(videoPath: videoPath, count: count, result: result)

      default:
        result(FlutterMethodNotImplemented)
      }
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

  private func checkCancelled() -> Bool {
    stateLock.lock()
    let cancelled = isCancelled
    stateLock.unlock()
    return cancelled
  }

  private func resetCancellationAndSetPipeline(reader: AVAssetReader?, writer: AVAssetWriter?) {
    stateLock.lock()
    activeReader = reader
    activeWriter = writer
    stateLock.unlock()
  }

  private func prepareNewConversionState() {
    stateLock.lock()
    isCancelled = false
    activeReader = nil
    activeWriter = nil
    stateLock.unlock()
  }

  private func cancelActiveConversion() {
    stateLock.lock()
    isCancelled = true
    let reader = activeReader
    let writer = activeWriter
    stateLock.unlock()

    reader?.cancelReading()
    if let w = writer, w.status == .writing {
      w.cancelWriting()
    }
  }

  private func beginKeepAwakeAndBackgroundTask() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      UIApplication.shared.isIdleTimerDisabled = true
      if self.activeBackgroundTask == .invalid {
        self.activeBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "UnclipLivePhoto") { [weak self] in
          self?.cancelActiveConversion()
          self?.endKeepAwakeAndBackgroundTask()
        }
      }
    }
  }

  private func endKeepAwakeAndBackgroundTask() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      UIApplication.shared.isIdleTimerDisabled = false
      if self.activeBackgroundTask != .invalid {
        UIApplication.shared.endBackgroundTask(self.activeBackgroundTask)
        self.activeBackgroundTask = .invalid
      }
    }
  }

  private func handleConvertAndSave(
    videoPath: String,
    coverTimeMs: Int64,
    quality: String,
    keepAudio: Bool,
    customCoverPath: String?,
    trimStartMs: Int64?,
    trimEndMs: Int64?,
    preserveMetadata: Bool,
    playbackSpeed: Double,
    result: @escaping FlutterResult
  ) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
      guard let self = self else { return }
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "PHOTO_PERMISSION_DENIED",
            message: "请在系统“设置 → 隐私与安全性 → 照片”中允许 Unclip 添加照片",
            details: nil
          ))
        }
        return
      }

      self.prepareNewConversionState()
      self.beginKeepAwakeAndBackgroundTask()

      DispatchQueue.global(qos: .userInitiated).async {
        self.executePipeline(
          videoPath: videoPath,
          coverTimeMs: coverTimeMs,
          quality: quality,
          keepAudio: keepAudio,
          customCoverPath: customCoverPath,
          trimStartMs: trimStartMs,
          trimEndMs: trimEndMs,
          preserveMetadata: preserveMetadata,
          playbackSpeed: playbackSpeed,
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
    customCoverPath: String?,
    trimStartMs: Int64?,
    trimEndMs: Int64?,
    preserveMetadata: Bool,
    playbackSpeed: Double,
    result: @escaping FlutterResult
  ) {
    let startTime = CFAbsoluteTimeGetCurrent()
    let inputURL = URL(fileURLWithPath: videoPath)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
      endKeepAwakeAndBackgroundTask()
      DispatchQueue.main.async {
        result(FlutterError(code: "FILE_NOT_FOUND", message: "找不到所选视频文件", details: nil))
      }
      return
    }

    let asset = AVURLAsset(url: inputURL)
    let durationSeconds = max(CMTimeGetSeconds(asset.duration), 0.1)

    let requestedStartSec = trimStartMs.map { max(0.0, Double($0) / 1000.0) } ?? 0.0
    var requestedEndSec = trimEndMs.map { min(durationSeconds, Double($0) / 1000.0) } ?? durationSeconds
    if requestedEndSec - requestedStartSec < 0.2 {
      requestedEndSec = min(durationSeconds, requestedStartSec + 0.2)
    }
    let trimStartSec = min(requestedStartSec, max(0.0, requestedEndSec - 0.1))
    let trimEndSec = max(trimStartSec + 0.1, min(requestedEndSec, durationSeconds))
    let trimDurationSec = max(trimEndSec - trimStartSec, 0.1)
    let isTrimmed = (trimStartSec > 0.05) || (trimEndSec < durationSeconds - 0.05)

    let requestedCoverSec = Double(max(coverTimeMs, 0)) / 1000.0
    let maxCoverSec = max(trimStartSec, trimEndSec - 0.05)
    let clampedCoverSec = min(max(requestedCoverSec, trimStartSec), maxCoverSec)
    let coverCMTime = CMTime(seconds: clampedCoverSec, preferredTimescale: 600)

    let (sourceDate, sourceLocation) = preserveMetadata
      ? extractSourceMetadata(asset: asset)
      : (nil, nil)

    let assetId = UUID().uuidString
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("long_live_\(assetId)", isDirectory: true)

    do {
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    } catch {
      endKeepAwakeAndBackgroundTask()
      DispatchQueue.main.async {
        result(FlutterError(code: "TEMP_DIR_ERROR", message: "无法创建临时工作目录：\(error.localizedDescription)", details: nil))
      }
      return
    }

    let photoURL = tempDir.appendingPathComponent("IMG_\(assetId).JPG")
    let pairedVideoURL = tempDir.appendingPathComponent("IMG_\(assetId).MOV")

    let cleanup = { [weak self] in
      self?.resetCancellationAndSetPipeline(reader: nil, writer: nil)
      try? FileManager.default.removeItem(at: tempDir)
    }

    if checkCancelled() {
      cleanup()
      endKeepAwakeAndBackgroundTask()
      DispatchQueue.main.async {
        result(FlutterError(code: "CANCELLED", message: "已取消实况合成", details: nil))
      }
      return
    }

    // Step 1: Extract or normalize custom still frame with MakerApple ContentIdentifier (key "17")
    emitProgress(stage: "cover", progress: 0.06, message: customCoverPath != nil ? "正在处理自定义高清封面..." : "正在抽取高清封面帧并注入实况标识...")
    do {
      try writeStillImageWithIdentifier(
        asset: asset,
        at: coverCMTime,
        trimStartTime: CMTime(seconds: trimStartSec, preferredTimescale: 600),
        customCoverPath: customCoverPath,
        assetIdentifier: assetId,
        captureDate: sourceDate,
        location: sourceLocation,
        preserveMetadata: preserveMetadata,
        outputURL: photoURL
      )
    } catch {
      cleanup()
      endKeepAwakeAndBackgroundTask()
      DispatchQueue.main.async {
        result(FlutterError(code: "COVER_EXTRACT_FAILED", message: "生成封面帧失败：\(error.localizedDescription)", details: nil))
      }
      return
    }

    if checkCancelled() {
      cleanup()
      endKeepAwakeAndBackgroundTask()
      DispatchQueue.main.async {
        result(FlutterError(code: "CANCELLED", message: "已取消实况合成", details: nil))
      }
      return
    }

    // Step 2: Build paired QuickTime MOV with matching ContentIdentifier & still-image-time track
    emitProgress(stage: "video", progress: 0.12, message: "正在准备实况视频流...")
    let trimRange = CMTimeRange(
      start: CMTime(seconds: trimStartSec, preferredTimescale: 600),
      duration: CMTime(seconds: trimDurationSec, preferredTimescale: 600)
    )
    let hasSpeedChange = abs(playbackSpeed - 1.0) > 0.01
    let outputStillTime: CMTime
    if hasSpeedChange {
      let scaledTotalSec = max(trimDurationSec / playbackSpeed, 0.1)
      let relativeCoverSec = max(0.0, clampedCoverSec - trimStartSec)
      let scaledStillSec = min(max(relativeCoverSec / playbackSpeed, 0.0), max(scaledTotalSec - 0.03, 0.0))
      outputStillTime = CMTime(seconds: scaledStillSec, preferredTimescale: 600)
    } else {
      outputStillTime = coverCMTime
    }

    buildPairedLiveVideo(
      asset: asset,
      trimRange: trimRange,
      isTrimmed: isTrimmed,
      trimStartSec: trimStartSec,
      trimDurationSec: trimDurationSec,
      stillImageTime: outputStillTime,
      assetIdentifier: assetId,
      quality: quality,
      keepAudio: keepAudio,
      playbackSpeed: playbackSpeed,
      outputURL: pairedVideoURL
    ) { [weak self] videoError, wasCancelled in
      guard let self = self else {
        try? FileManager.default.removeItem(at: tempDir)
        return
      }

      if wasCancelled || self.checkCancelled() {
        cleanup()
        self.endKeepAwakeAndBackgroundTask()
        DispatchQueue.main.async {
          result(FlutterError(code: "CANCELLED", message: "已取消实况合成", details: nil))
        }
        return
      }

      if let videoError = videoError {
        cleanup()
        self.endKeepAwakeAndBackgroundTask()
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

        if preserveMetadata {
          if let capturedAt = sourceDate {
            creationRequest.creationDate = capturedAt
          }
          if let capturedLoc = sourceLocation {
            creationRequest.location = capturedLoc
          }
        }

        if let placeholder = creationRequest.placeholderForCreatedAsset {
          placeholderLocalId = placeholder.localIdentifier
        }
      }, completionHandler: { success, saveError in
        cleanup()
        self.endKeepAwakeAndBackgroundTask()
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000.0)
        DispatchQueue.main.async {
          if success {
            result([
              "savedTarget": placeholderLocalId,
              "outputSizeBytes": totalBytes,
              "elapsedMs": elapsedMs,
              "platformFormat": "Apple Live Photo (JPG + MOV)"
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

  private func extractSourceMetadata(asset: AVAsset) -> (Date?, CLLocation?) {
    var captureDate = asset.creationDate?.dateValue
    if captureDate == nil {
      let commonDateItem = AVMetadataItem.metadataItems(
        from: asset.commonMetadata,
        withKey: AVMetadataKey.commonKeyCreationDate,
        keySpace: .common
      ).first
      captureDate = commonDateItem?.dateValue
    }

    var isoString: String?
    if let commonLoc = AVMetadataItem.metadataItems(
      from: asset.commonMetadata,
      withKey: AVMetadataKey.commonKeyLocation,
      keySpace: .common
    ).first?.stringValue {
      isoString = commonLoc
    } else if let qtLoc = AVMetadataItem.metadataItems(
      from: asset.metadata(forFormat: .quickTimeMetadata),
      withKey: AVMetadataKey.quickTimeMetadataKeyLocationISO6709,
      keySpace: .quickTimeMetadata
    ).first?.stringValue {
      isoString = qtLoc
    } else if let udLoc = AVMetadataItem.metadataItems(
      from: asset.metadata(forFormat: .quickTimeUserData),
      withKey: AVMetadataKey.quickTimeUserDataKeyLocationISO6709,
      keySpace: .quickTimeUserData
    ).first?.stringValue {
      isoString = udLoc
    }

    let location = isoString.flatMap { parseISO6709($0) }
    return (captureDate, location)
  }

  private func parseISO6709(_ isoString: String) -> CLLocation? {
    let pattern = "([+-][0-9.]+)([+-][0-9.]+)([+-][0-9.]+)?"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: isoString, range: NSRange(isoString.startIndex..., in: isoString)),
          let latRange = Range(match.range(at: 1), in: isoString),
          let lonRange = Range(match.range(at: 2), in: isoString),
          let lat = Double(isoString[latRange]),
          let lon = Double(isoString[lonRange]) else {
      return nil
    }

    var alt: CLLocationDistance = 0
    if match.range(at: 3).location != NSNotFound,
       let altRange = Range(match.range(at: 3), in: isoString),
       let parsedAlt = Double(isoString[altRange]) {
      alt = parsedAlt
    }

    return CLLocation(
      coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
      altitude: alt,
      horizontalAccuracy: 5.0,
      verticalAccuracy: 5.0,
      timestamp: Date()
    )
  }

  private func writeStillImageWithIdentifier(
    asset: AVAsset,
    at time: CMTime,
    trimStartTime: CMTime,
    customCoverPath: String?,
    assetIdentifier: String,
    captureDate: Date?,
    location: CLLocation?,
    preserveMetadata: Bool,
    outputURL: URL
  ) throws {
    let cgImage: CGImage

    if let customPath = customCoverPath,
       !customPath.isEmpty,
       FileManager.default.fileExists(atPath: customPath),
       let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: customPath) as CFURL, nil) {
      let thumbOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 4096,
        kCGImageSourceShouldCacheImmediately: true
      ]
      if let normalized = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions as CFDictionary) {
        cgImage = normalized
      } else if let fullImg = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
        cgImage = fullImg
      } else {
        throw NSError(domain: "LongLivePhoto", code: -12, userInfo: [NSLocalizedDescriptionKey: "无法读取自定义封面图片"])
      }
    } else {
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
      generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

      do {
        cgImage = try generator.copyCGImage(at: time, actualTime: nil)
      } catch {
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        if let fallback = try? generator.copyCGImage(at: trimStartTime, actualTime: nil) {
          cgImage = fallback
        } else {
          cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
        }
      }
    }

    guard let dest = CGImageDestinationCreateWithURL(
      outputURL as CFURL,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else {
      throw NSError(domain: "LongLivePhoto", code: -10, userInfo: [NSLocalizedDescriptionKey: "无法创建 JPEG 编码目标"])
    }

    var properties: [String: Any] = [
      kCGImageDestinationLossyCompressionQuality as String: 0.92,
      kCGImagePropertyMakerAppleDictionary as String: [
        "17": assetIdentifier
      ]
    ]

    if preserveMetadata {
      if let date = captureDate {
        let exifFormatter = DateFormatter()
        exifFormatter.locale = Locale(identifier: "en_US_POSIX")
        exifFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let formattedDate = exifFormatter.string(from: date)
        properties[kCGImagePropertyExifDictionary as String] = [
          kCGImagePropertyExifDateTimeOriginal as String: formattedDate,
          kCGImagePropertyExifDateTimeDigitized as String: formattedDate
        ]
        properties[kCGImagePropertyTIFFDictionary as String] = [
          kCGImagePropertyTIFFDateTime as String: formattedDate
        ]
      }
      if let loc = location {
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        properties[kCGImagePropertyGPSDictionary as String] = [
          kCGImagePropertyGPSLatitude as String: abs(lat),
          kCGImagePropertyGPSLatitudeRef as String: lat >= 0 ? "N" : "S",
          kCGImagePropertyGPSLongitude as String: abs(lon),
          kCGImagePropertyGPSLongitudeRef as String: lon >= 0 ? "E" : "W",
          kCGImagePropertyGPSAltitude as String: abs(loc.altitude),
          kCGImagePropertyGPSAltitudeRef as String: loc.altitude >= 0 ? 0 : 1
        ]
      }
    }

    CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
      throw NSError(domain: "LongLivePhoto", code: -11, userInfo: [NSLocalizedDescriptionKey: "写入实况封面元数据失败"])
    }
  }

  private func formatSpeedTag(_ speed: Double) -> String {
    if abs(speed - 0.5) < 0.05 { return "0.5x 慢放" }
    if abs(speed - 1.5) < 0.05 { return "1.5x 倍速" }
    if abs(speed - 2.0) < 0.05 { return "2x 倍速" }
    if abs(speed - 4.0) < 0.05 { return "4x 延时" }
    return String(format: "%.1fx 倍速", speed)
  }

  private func buildPairedLiveVideo(
    asset: AVAsset,
    trimRange: CMTimeRange,
    isTrimmed: Bool,
    trimStartSec: Double,
    trimDurationSec: Double,
    stillImageTime: CMTime,
    assetIdentifier: String,
    quality: String,
    keepAudio: Bool,
    playbackSpeed: Double,
    outputURL: URL,
    completion: @escaping (Error?, Bool) -> Void
  ) {
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      completion(NSError(domain: "LongLivePhoto", code: -20, userInfo: [NSLocalizedDescriptionKey: "所选文件不包含有效视频轨道"]), false)
      return
    }

    do {
      let safeSpeed = min(max(playbackSpeed, 0.5), 4.0)
      let hasSpeedChange = abs(safeSpeed - 1.0) > 0.01

      let readerAsset: AVAsset
      let readerVideoTrack: AVAssetTrack
      var compositionAudioTrack: AVMutableCompositionTrack?
      var outputSpanSec = trimDurationSec

      if hasSpeedChange {
        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(
          withMediaType: .video,
          preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
          completion(NSError(domain: "LongLivePhoto", code: -25, userInfo: [NSLocalizedDescriptionKey: "无法创建倍速视频合成轨道"]), false)
          return
        }

        let intersectedVideo = trimRange.intersection(videoTrack.timeRange)
        let sourceInsertRange = (!intersectedVideo.isEmpty && CMTimeGetSeconds(intersectedVideo.duration) > 0.05)
          ? intersectedVideo
          : trimRange
        try compVideoTrack.insertTimeRange(sourceInsertRange, of: videoTrack, at: .zero)
        compVideoTrack.preferredTransform = videoTrack.preferredTransform

        if keepAudio,
           let srcAudio = asset.tracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(
             withMediaType: .audio,
             preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
          let audioRange = sourceInsertRange.intersection(srcAudio.timeRange)
          if !audioRange.isEmpty && CMTimeGetSeconds(audioRange.duration) > 0.05 {
            let rawOffset = CMTimeSubtract(audioRange.start, sourceInsertRange.start)
            let insertAt = CMTimeCompare(rawOffset, .zero) > 0 ? rawOffset : .zero
            try compAudio.insertTimeRange(audioRange, of: srcAudio, at: insertAt)
            compositionAudioTrack = compAudio
          } else {
            composition.removeTrack(compAudio)
          }
        }

        let insertedDuration = CMTimeGetSeconds(compVideoTrack.timeRange.duration) > 0.05
          ? compVideoTrack.timeRange.duration
          : sourceInsertRange.duration
        outputSpanSec = max(CMTimeGetSeconds(insertedDuration) / safeSpeed, 0.1)
        let scaledDuration = CMTime(seconds: outputSpanSec, preferredTimescale: 600)
        composition.scaleTimeRange(
          CMTimeRange(start: .zero, duration: insertedDuration),
          toDuration: scaledDuration
        )

        readerAsset = composition
        readerVideoTrack = compVideoTrack
      } else {
        readerAsset = asset
        readerVideoTrack = videoTrack
      }

      let reader = try AVAssetReader(asset: readerAsset)
      if !hasSpeedChange && isTrimmed {
        reader.timeRange = trimRange
      }

      let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
      resetCancellationAndSetPipeline(reader: reader, writer: writer)

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
      // Raw compressed passthrough is reserved for untrimmed 1x clips so trimmed/speed-scaled cuts re-encode cleanly.
      let usePassthrough = !isTrimmed && !hasSpeedChange && (quality == "passthrough" && canPassthroughCodec)

      let readerVideoOutput: AVAssetReaderTrackOutput
      let writerVideoInput: AVAssetWriterInput

      if usePassthrough {
        readerVideoOutput = AVAssetReaderTrackOutput(track: readerVideoTrack, outputSettings: nil)
        writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: sourceFormatDesc)
        writerVideoInput.transform = videoTrack.preferredTransform
      } else {
        readerVideoOutput = AVAssetReaderTrackOutput(
          track: readerVideoTrack,
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
        completion(NSError(domain: "LongLivePhoto", code: -21, userInfo: [NSLocalizedDescriptionKey: "无法初始化视频读写管线"]), false)
        return
      }
      reader.add(readerVideoOutput)
      writer.add(writerVideoInput)

      // 4. Optional audio track (uses AVAssetReaderAudioMixOutput for pitch-preserving speed scaling)
      var readerAudioOutput: AVAssetReaderOutput?
      var writerAudioInput: AVAssetWriterInput?
      if keepAudio {
        let audioInSettings: [String: Any] = [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVNumberOfChannelsKey: 2,
          AVSampleRateKey: 44100,
          AVEncoderBitRateKey: 128000
        ]
        let pcmOutSettings: [String: Any] = [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: 44100,
          AVNumberOfChannelsKey: 2,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsNonInterleaved: false
        ]

        let createdAudioOutput: AVAssetReaderOutput?
        if hasSpeedChange {
          if let compAudioTrack = compositionAudioTrack {
            let mixOut = AVAssetReaderAudioMixOutput(
              audioTracks: [compAudioTrack],
              audioSettings: pcmOutSettings
            )
            mixOut.audioTimePitchAlgorithm = (safeSpeed > 2.0 || safeSpeed < 0.5) ? .spectral : .timeDomain
            mixOut.alwaysCopiesSampleData = false
            createdAudioOutput = mixOut
          } else {
            createdAudioOutput = nil
          }
        } else if let audioTrack = asset.tracks(withMediaType: .audio).first {
          let trackOut = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: pcmOutSettings
          )
          trackOut.alwaysCopiesSampleData = false
          createdAudioOutput = trackOut
        } else {
          createdAudioOutput = nil
        }

        if let audioOut = createdAudioOutput {
          let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioInSettings)
          audioIn.expectsMediaDataInRealTime = false
          if reader.canAdd(audioOut) && writer.canAdd(audioIn) {
            reader.add(audioOut)
            writer.add(audioIn)
            readerAudioOutput = audioOut
            writerAudioInput = audioIn
          }
        }
      }

      guard writer.startWriting() else {
        completion(writer.error ?? NSError(domain: "LongLivePhoto", code: -22, userInfo: [NSLocalizedDescriptionKey: "启动 MOV 写入器失败"]), checkCancelled())
        return
      }
      guard reader.startReading() else {
        if writer.status == .writing {
          writer.cancelWriting()
        }
        completion(reader.error ?? NSError(domain: "LongLivePhoto", code: -23, userInfo: [NSLocalizedDescriptionKey: "读取源视频流失败"]), checkCancelled())
        return
      }

      // CRITICAL: Match startSession to trimRange.start on 1x trimmed runs; scaled compositions always start at 0s.
      let sessionStartTime = (!hasSpeedChange && isTrimmed) ? trimRange.start : CMTime.zero
      writer.startSession(atSourceTime: sessionStartTime)

      // Write still-image-time marker in the same timeline
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
      var lastAppendedVideoPts: CMTime = .invalid
      let maxOutputFps: Double = safeSpeed >= 3.0 ? 30.0 : 60.0
      let minFrameDeltaSec: Double = (safeSpeed > 1.01) ? (1.0 / maxOutputFps) * 0.92 : 0.0
      let progressOriginSec = hasSpeedChange ? 0.0 : trimStartSec
      let progressSpanSec = max(outputSpanSec, 0.1)

      pumpGroup.enter()
      writerVideoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
        while writerVideoInput.isReadyForMoreMediaData {
          if self?.checkCancelled() == true {
            writerVideoInput.markAsFinished()
            pumpGroup.leave()
            return
          }
          if let sample = readerVideoOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if lastAppendedVideoPts.isValid {
              if CMTimeCompare(pts, lastAppendedVideoPts) <= 0 {
                continue
              }
              if minFrameDeltaSec > 0.0 {
                let deltaSec = CMTimeGetSeconds(CMTimeSubtract(pts, lastAppendedVideoPts))
                if deltaSec.isFinite && deltaSec < minFrameDeltaSec {
                  continue
                }
              }
            }

            let sec = CMTimeGetSeconds(pts)
            if sec.isFinite {
              let ratio = min(max((sec - progressOriginSec) / progressSpanSec, 0.0), 1.0)
              let uiProg = 0.12 + ratio * 0.82
              let pct = Int(ratio * 100.0)
              if pct >= lastReportedPercent + 2 {
                lastReportedPercent = pct
                let modeLabel: String
                if hasSpeedChange {
                  modeLabel = "\(self?.formatSpeedTag(safeSpeed) ?? "倍速")压制中"
                } else {
                  modeLabel = usePassthrough ? "原画直通封装中" : "硬件编码压制中"
                }
                self?.emitProgress(stage: "video", progress: uiProg, message: "\(modeLabel)（\(pct)%）...")
              }
            }

            lastAppendedVideoPts = pts
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
        aIn.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
          while aIn.isReadyForMoreMediaData {
            if self?.checkCancelled() == true {
              aIn.markAsFinished()
              pumpGroup.leave()
              return
            }
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

      pumpGroup.notify(queue: DispatchQueue.global(qos: .userInitiated)) { [weak self] in
        let cancelledNow = (self?.checkCancelled() == true) || reader.status == .cancelled || writer.status == .cancelled
        if cancelledNow {
          if writer.status == .writing {
            writer.cancelWriting()
          }
          completion(nil, true)
          return
        }
        if reader.status == .failed {
          if writer.status == .writing {
            writer.cancelWriting()
          }
          completion(reader.error, false)
          return
        }
        writer.finishWriting {
          if self?.checkCancelled() == true || writer.status == .cancelled {
            completion(nil, true)
          } else if writer.status == .completed {
            completion(nil, false)
          } else {
            completion(writer.error ?? NSError(domain: "LongLivePhoto", code: -24, userInfo: [NSLocalizedDescriptionKey: "完成 MOV 封装时出错"]), false)
          }
        }
      }
    } catch {
      completion(error, checkCancelled())
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
    case "passthrough":
      targetShortLimit = CGFloat.greatestFiniteMagnitude
      bitrate = 14_000_000
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

  private func handleExtractThumbnails(
    videoPath: String,
    count: Int,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let inputURL = URL(fileURLWithPath: videoPath)
      guard FileManager.default.fileExists(atPath: inputURL.path) else {
        DispatchQueue.main.async { result([FlutterStandardTypedData]()) }
        return
      }
      let asset = AVURLAsset(url: inputURL)
      let totalSeconds = max(CMTimeGetSeconds(asset.duration), 0.1)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 200, height: 140)
      let tol = CMTime(seconds: min(0.4, totalSeconds / Double(max(count * 2, 2))), preferredTimescale: 600)
      generator.requestedTimeToleranceBefore = tol
      generator.requestedTimeToleranceAfter = tol

      var frames: [FlutterStandardTypedData] = []
      for i in 0..<count {
        let fraction = count == 1 ? 0.0 : Double(i) / Double(count - 1)
        let sec = min(max(totalSeconds * fraction, 0.0), max(totalSeconds - 0.05, 0.0))
        let cmTime = CMTime(seconds: sec, preferredTimescale: 600)
        if let cgImg = try? generator.copyCGImage(at: cmTime, actualTime: nil),
           let jpegData = UIImage(cgImage: cgImg).jpegData(compressionQuality: 0.72) {
          frames.append(FlutterStandardTypedData(bytes: jpegData))
        }
      }
      DispatchQueue.main.async {
        result(frames)
      }
    }
  }
}
