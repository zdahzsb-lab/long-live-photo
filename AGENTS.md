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
- **UI Layer**: Pure minimalist darkroom design system (`lib/theme/ui_tokens.dart`, `lib/ui/pressable.dart`, `lib/ui/buttons.dart`, `lib/ui/segmented_tabs.dart`, `lib/ui/minimal_bottom_nav.dart`, `lib/ui/minimal_switch.dart`, `lib/ui/result_sheet.dart`, `lib/ui/history_drawer_sheet.dart`, `lib/ui/batch_queue_sheet.dart`) built on `lucide_icons_flutter` and `package:material_ui/material_ui.dart` (do **not** import deprecated `package:flutter/material.dart` or `package:flutter/cupertino.dart` on Flutter 3.50+).
  - Zero `BackdropFilter` / glass shader overhead: crisp Zinc monochrome palette (`#09090B` / `#121215` / `#FAFAFA`), `1px` translucent hairlines, and explicit `TextDecoration.none` across all typography.
  - Every interactive control builds on `Pressable` (`Listener.onPointerDown` 0ms trigger + continuous `SpringSimulation` physics + `>= 44×44pt` opaque hit boxes).
  - Outer shell uses a minimalist 3-tab bottom bar (`MinimalBottomNav`: `首页` / `工具` / `设置`): `首页` (`EmptyStudioView`) focuses strictly on gallery/file picking; `工具` (`ToolsHistoryView`) hosts batch queue (`批量转实况`), Live Photo unpack (`实况拆解`), and recent history cards (`HistoryEntryTile`); `设置` (`SettingsView`) persists defaults via `AppPreferencesStore` (`<appDocs>/unclip_prefs/preferences.json`), shows cache size, and provides platform/share tips.
  - Selecting/importing/unpacking media enters the full-screen darkroom editor (hiding `MinimalBottomNav`), keeping `<-` back, top-right standalone export sheet (`导出为普通视频 MP4` / `提取当前高清封面 JPG`), source/history switcher (`更换`), and `result_sheet` (`打开相册` + `再选一段`).
  - Local synthesis history (`lib/models/conversion_history.dart`, `lib/services/conversion_history_store.dart`) persists up to 30 JSON entries + cover thumbnails (including copied custom covers) under `<appDocs>/unclip_history/` with atomic temp-rename writes and graceful parameter fallback in `lib/main.dart` if source video is missing while another video is active.
- **iOS Native Engine** (`ios/Runner/AppDelegate.swift`, `ios/Runner/SceneDelegate.swift`, `ios/Runner/Info.plist`):
  - Uses `FlutterImplicitEngineDelegate` (`didInitializeImplicitFlutterEngine`) for `MethodChannel('com.longlive.long_live_photo/converter')` (`convertAndSave`, `cancelConversion`, `extractThumbnails`, `consumeInitialSharedMedia`, `openSystemGallery`, `pickAndUnpackLivePhoto`, `unpackLivePhotoFile`, `exportStandaloneMedia`) plus `EventChannel`s `progress` and `shared_media`.
  - `SceneDelegate` forwards `willConnectTo` / `openURLContexts` to `SharedMediaBridge` (`CFBundleDocumentTypes` with `LSHandlerRank = Alternate`, no `.appex` extension so unsigned IPA sideloading keeps working cleanly).
  - Generates paired `JPG` (`MakerApple` key `"17"`) + QuickTime `MOV` (`com.apple.quicktime.content.identifier` + `mdta/com.apple.quicktime.still-image-time` timed metadata track), or standalone `.mp4`/`.jpg` (`assetIdentifier == nil`), with `AVMutableVideoComposition` Rec.709 HDR→SDR tone-mapping (`AVAssetReaderVideoCompositionOutput`) when re-encoding HDR/Dolby Vision/HLG/PQ inputs.
  - Unpacks iOS Live Photos via `PHPickerViewController` (`.livePhotos` + `PHLivePhoto` `.pairedVideo` + `still-image-time`) and Android Motion Photo JPEGs / `.pvt` bundles via `unpackLivePhotoFile`.
- **Android Native Engine** (`android/app/src/main/kotlin/com/longlive/long_live_photo/`):
  - `MainActivity.kt` handles `ACTION_SEND` / `ACTION_SEND_MULTIPLE` (`video/*`, `image/*`) share-sheet intents (`EXTRA_CONSUMED` guard + background URI copy to `cacheDir/shared_imports`), `ACTION_OPEN_DOCUMENT` Live Photo picker, and `openSystemGallery`.
  - `MotionPhotoConverter.kt` + `MotionPhotoXmpInjector.kt`: Lossless `MediaMuxer` passthrough (untrimmed `1x` only) or `androidx.media3:media3-transformer:1.9.2` `Composition.Builder(listOf(EditedMediaItemSequence...))` with `HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL` (API 29+ for HLG/PQ/Dolby Vision), dual-standard XMP (`GCamera:MotionPhoto` + `GCamera:MicroVideoOffset`), streaming Motion Photo unpacker (`unpackMotionPhotoAsync` handling XMP offsets + Samsung `MotionPhoto_Data` + `FF D9` fallback), and standalone MP4/JPEG MediaStore export.

## 3. Verification & CI Rules
- Always run `flutter analyze --fatal-infos --fatal-warnings` and `flutter test` locally before pushing.
- `.github/workflows/build_mobile.yml` uses `java-version: '21'` on `ubuntu-latest` (required by Gradle 9.5 / AGP 9.3) and `macos-26-intel` for iOS (avoids `macOS arm64` runner queue bottlenecks).
