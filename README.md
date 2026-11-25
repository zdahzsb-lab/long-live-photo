# 长实况（LongLivePhoto）— 不限时长视频转实况双端 App

专为个人相册收藏设计的 **iOS + Android 原生双端视频转实况工具**。去除市面上 3 秒 / 5 秒时长限制，支持将数秒至数十分钟的任意视频完整合成为单张实况照片，直接存入手机系统相册长按从头播放到尾。

## 核心特性

1. **零时长阉割**：完整保留整段视频内容，不截断。
2. **双端系统级原生合成（无第三方 FFmpeg 冗余依赖）**：
   - **iPhone (iOS)**：基于 `AVAssetReader` / `AVAssetWriter`、`ImageIO`（MakerApple `17` 标识）与 QuickTime `com.apple.quicktime.still-image-time` 定时元数据轨生成标准配对 `JPG + MOV`，通过 `PHAssetCreationRequest` 直接写入系统“照片”。
   - **Android**：基于 `MediaMuxer` / `AndroidX Media3 Transformer` 与双标准 XMP（同时写入 `GCamera:MotionPhoto` `Container:Directory` 与 `GCamera:MicroVideoOffset`），64KB 流式写入系统相册 `DCIM/Camera/MVIMG_*.jpg`，数十分钟大体积视频也不会内存溢出，兼容小米、OPPO、vivo、三星及 Google 相册。
3. **三档画质与体积策略**：
   - **原画直通（秒转）**：H.264 / HEVC 视频不重编码，仅封装实况容器与元数据，1～3 秒极速出图。
   - **1080p 高清均衡（默认）**：硬件编码控制在约 6 Mbps，长视频清晰且相册滑动不卡顿。
   - **720p 省空间（超长视频专用）**：硬件编码控制在约 2.8 Mbps，适合 5～30 分钟超长视频收藏。
4. **精准封面帧选择与原声开关**：支持滑动时间轴、`±0.1s` 微调及一键抓取当前播放帧作为静态封面，可自由保留或关闭视频原声。

## 云端自动打包（无需本地安装 Mac / Android Studio）

本项目已内置 `.github/workflows/build_mobile.yml` 云端流水线：

1. 登录 GitHub 新建一个空仓库（**建议选 Public 公开仓库以享受完全不限额的免费 macOS 打包时长**；Private 私有仓库每月也有免费额度）。
2. 在当前项目目录打开 PowerShell 运行：
   ```powershell
   .\push_to_github.ps1 https://github.com/<你的用户名>/<仓库名>.git
   ```
   （首次推送会弹出浏览器登录 GitHub 授权）。
3. 打开 GitHub 仓库顶部的 **Actions** 页面，等待约 5～8 分钟编译变绿，在页面底部 **Artifacts** 下载：
   - **`LongLivePhoto-Android-APK`**：解压后将 `LongLivePhoto-Android-arm64-v8a.apk` 发到安卓手机直接安装即可永久使用。
   - **`LongLivePhoto-iOS-IPA`**：解压得到 `LongLivePhoto-iOS-Unsigned.ipa`，在 Windows 电脑使用免费的 **Sideloadly** 或 **SideStore** 登录普通免费 Apple ID 签名装入 iPhone 即可。
