# AGENTS.md — Unclip Project Context & Engineering Rules

## 1. Local Toolchain & Disk Constraints (Windows 11)
- **C: drive has limited free space (~19 GB).** Keep all SDKs and caches on `E:\Tools`:
  - `Flutter 3.50.1` (Dart `3.14.0`): `E:\Tools\flutter\bin\flutter.bat`
  - `PUB_CACHE`: `E:\Tools\pub-cache`
  - `GRADLE_USER_HOME`: `E:\Tools\gradle-home`
  - `Git`: `E:\Tools\git\cmd\git.exe`
  - `GitHub CLI` (authenticated as `zdahzsb-lab`): `E:\Tools\gh\bin\gh.exe`
- Local built mobile packages live in `releases/` (gitignored), linked from the user's Desktop via `C:\Users\Administrator\Desktop\Unclip-手机安装包.lnk`.

## 2. Architecture Overview
- **App Name**: `Unclip` (`lib/constants/app_branding.dart`, `AndroidManifest.xml`, `ios/Runner/Info.plist`).
- **UI Layer**: Pure minimalist darkroom design system (`lib/theme/ui_tokens.dart`, `lib/ui/pressable.dart`, `lib/ui/buttons.dart`, `lib/ui/segmented_tabs.dart`, `lib/ui/result_sheet.dart`, `lib/ui/history_drawer_sheet.dart`) built on `lucide_icons_flutter` and `package:material_ui/material_ui.dart` (do **not** import deprecated `package:flutter/material.dart` or `package:flutter/cupertino.dart` on Flutter 3.50+).
  - Zero `BackdropFilter` / glass shader overhead: crisp Zinc monochrome palette (`#09090B` / `#121215` / `#FAFAFA`), `1px` translucent hairlines, and explicit `TextDecoration.none` across all typography.
  - Every interactive control builds on `Pressable` (`Listener.onPointerDown` 0ms trigger + continuous `SpringSimulation` physics + `>= 44×44pt` opaque hit boxes).
  - Local synthesis history (`lib/models/conversion_history.dart`, `lib/services/conversion_history_store.dart`) persists up to 30 JSON entries + cover thumbnails under `<appDocs>/unclip_history/` with atomic temp-rename writes and parameter restoration in `lib/main.dart`.
- **iOS Native Engine** (`ios/Runner/AppDelegate.swift`):
  - Uses `FlutterImplicitEngineDelegate` (`didInitializeImplicitFlutterEngine`) for `MethodChannel('com.longlive.long_live_photo/converter')` (`convertAndSave`, `cancelConversion`, `extractThumbnails`) and `EventChannel('com.longlive.long_live_photo/progress')`.
  - Generates paired `JPG` (`MakerApple` key `"17"`) + QuickTime `MOV` (`com.apple.quicktime.content.identifier` + `mdta/com.apple.quicktime.still-image-time` timed metadata track), preserving scaled rotation translation via `scaledTransform`, and saves via `PHAssetCreationRequest`.
  - Supports external static cover normalization (`CGImageSourceCreateThumbnailAtIndex` upright + `<= 4096px`), source `creationDate` + ISO 6709 `CLLocation` preservation, `AVAssetReader.timeRange` trimming with matched `writer.startSession(atSourceTime:)` (disabling raw passthrough when trimmed or speed-scaled), `AVMutableComposition.scaleTimeRange` + `AVAssetReaderAudioMixOutput` (`0.5x–4x` speed scaling with output FPS cap `<= 30/60fps` and scaled `still-image-time`), `isIdleTimerDisabled` + `UIBackgroundTaskIdentifier` keep-awake, and thread-safe cancellation.
- **Android Native Engine** (`android/app/src/main/kotlin/com/longlive/long_live_photo/`):
  - `MotionPhotoConverter.kt` + `MotionPhotoXmpInjector.kt`: Lossless `MediaMuxer` passthrough (untrimmed `1x` only) or `androidx.media3:media3-transformer:1.9.2` (`MediaItem.ClippingConfiguration` when trimmed), dual-standard XMP (`GCamera:MotionPhoto` + `GCamera:MicroVideoOffset`), 64KB streaming write into `MediaStore` (`DCIM/Camera/MVIMG_*.jpg` with `IS_PENDING`).
  - Speed scaling (`0.5x–4x`): uses `EditedMediaItem.Builder.setSpeed(SpeedProvider)` when audio is kept & present, or GL `SpeedChangeEffect` when muted/audio-absent (avoiding Media3 1.9.2 `SpeedChangingAudioProcessor` timestamp stall), plus `FrameDropEffect.createDefaultFrameDropEffect` (`<= 30/60fps`) and `playbackSpeed`-scaled XMP `presentationTimestampUs`.
  - Supports external cover decoding/EXIF orientation normalization (`<= 4096px`), original `METADATA_KEY_DATE` + `METADATA_KEY_LOCATION` preservation (**EXIF written via `androidx.exifinterface:exifinterface:1.4.2` BEFORE `MotionPhotoXmpInjector` & MP4 append**), `FLAG_KEEP_SCREEN_ON` keep-awake, and main-thread `Transformer.cancel()` + `CountDownLatch` release.

## 3. Verification & CI Rules
- Always run `flutter analyze --fatal-infos --fatal-warnings` and `flutter test` locally before pushing.
- `.github/workflows/build_mobile.yml` uses `java-version: '21'` on `ubuntu-latest` (required by Gradle 9.5 / AGP 9.3) and `macos-26-intel` for iOS (avoids `macOS arm64` runner queue bottlenecks).
