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
- **UI Layer**: `liquid_glass_widgets` (`^1.21.0`, iOS 27 preset), `lucide_icons_flutter`, `flutter_animate`, and `package:material_ui/material_ui.dart` (do **not** import deprecated `package:flutter/material.dart` or `package:flutter/cupertino.dart` on Flutter 3.50+).
  - Never nest refractive glass widgets (`GlassButton`, `GlassSegmentedControl`, `GlassIconButton`) inside a `glass`-mode `GlassContainer`.
  - `GlassButton` uses non-nullable `onTap` + `enabled` bool; `GlassIconButton` uses `onPressed`.
- **iOS Native Engine** (`ios/Runner/AppDelegate.swift`):
  - Uses `FlutterImplicitEngineDelegate` (`didInitializeImplicitFlutterEngine`) for `MethodChannel('com.longlive.long_live_photo/converter')` and `EventChannel('com.longlive.long_live_photo/progress')`.
  - Generates paired `JPG` (`MakerApple` key `"17"`) + QuickTime `MOV` (`com.apple.quicktime.content.identifier` + `mdta/com.apple.quicktime.still-image-time` timed metadata track), preserving scaled rotation translation via `scaledTransform`, and saves via `PHAssetCreationRequest`.
- **Android Native Engine** (`android/app/src/main/kotlin/com/longlive/long_live_photo/`):
  - `MotionPhotoConverter.kt` + `MotionPhotoXmpInjector.kt`: Lossless `MediaMuxer` passthrough or `androidx.media3:media3-transformer:1.9.2` (matched with `video_player_android`), dual-standard XMP (`GCamera:MotionPhoto` + `GCamera:MicroVideoOffset`), 64KB streaming write into `MediaStore` (`DCIM/Camera/MVIMG_*.jpg` with `IS_PENDING`).

## 3. Verification & CI Rules
- Always run `flutter analyze --fatal-infos --fatal-warnings` and `flutter test` locally before pushing.
- `.github/workflows/build_mobile.yml` uses `java-version: '21'` on `ubuntu-latest` (required by Gradle 9.5 / AGP 9.3) and `macos-26-intel` for iOS (avoids `macOS arm64` runner queue bottlenecks).
