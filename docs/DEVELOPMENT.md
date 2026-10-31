# 构建与开发

[← 返回 DuoRec](../README.md)

## 环境要求

- macOS 26 或更高版本。
- 从源码构建需要完整安装 Xcode 26 或更高版本；仅安装 Command Line Tools 不够。
- 录音需要“屏幕与系统音频录制”和“麦克风”权限。
- 转写依赖设备支持的 macOS SpeechTranscriber 与普通话模型。首次使用可能需要联网下载模型；无法使用模型时仍可录音。

项目使用 Apple 系统框架，没有第三方包依赖。当前已在 Xcode 26.6 下验证构建。

## 从源码构建

克隆仓库或下载并解压源码，然后在项目根目录操作。

### 使用 Xcode

1. 打开 `screen.xcodeproj`。
2. 选择 `screen` Scheme，运行目标选择 `My Mac`。
3. 在 `screen` Target 的 `Signing & Capabilities` 中选择本机可用的签名方式，例如 `Sign to Run Locally`；也可使用自己的开发团队签名。
4. 按 ⌘R 构建并运行 DuoRec。

项目中的工程和 Scheme 名称为 `screen`，生成的应用名称为 `DuoRec.app`。

### 使用命令行

先启动一次 Xcode，完成首次运行所需的组件安装，并确认 `xcodebuild -version` 指向完整 Xcode。然后执行：

```sh
xcodebuild \
  -project screen.xcodeproj \
  -scheme screen \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  build

open .build/DerivedData/Build/Products/Release/DuoRec.app
```

此命令使用本机临时签名构建，无需 Apple 开发者账号。它不包含面向其他用户分发所需的 Developer ID 签名与公证。

如需日常使用，可将生成的 `DuoRec.app` 复制到“应用程序”文件夹，再从那里启动和授予权限。更新后也请从同一位置运行，避免切换多个副本造成权限状态混淆。

## 回归检查

应用源码位于 `screen/`，独立回归检查位于 `Tests/`。在项目根目录执行以下命令：

```sh
set -e
mkdir -p .build

xcrun swiftc -parse-as-library -module-cache-path .build/ModuleCache.noindex screen/ScreenRecordingAccess.swift Tests/PermissionChecks.swift -o .build/permission-checks
.build/permission-checks

xcrun swiftc -parse-as-library -module-cache-path .build/ModuleCache.noindex screen/RecordingTermination.swift Tests/TerminationChecks.swift -o .build/termination-checks
.build/termination-checks

xcrun swiftc -parse-as-library -module-cache-path .build/ModuleCache.noindex screen/TranscriptSelection.swift Tests/TranscriptSelectionChecks.swift -o .build/transcript-selection-checks
.build/transcript-selection-checks

xcrun swiftc -parse-as-library -module-cache-path .build/ModuleCache.noindex screen/AudioCapture.swift screen/TranscriptTimeline.swift Tests/TranscriptTimelineChecks.swift -o .build/transcript-timeline-checks
.build/transcript-timeline-checks

xcrun swiftc -parse-as-library -module-cache-path .build/ModuleCache.noindex screen/AudioCapture.swift screen/RecordingFinalizer.swift Tests/RecordingSafetyChecks.swift -o .build/recording-safety-checks
.build/recording-safety-checks "$PWD/.build"
```

这些检查不采集真实系统声音或麦克风。录音安全检查使用合成音频，并通过强制结束自己的测试子进程验证中断恢复；需在能够访问 macOS 音频编码服务的本机会话运行。若出现 `Cannot Encode`，请确认运行环境允许访问该服务。

当前公开版的检查覆盖权限结果分类、退出等待与保存失败、选区安全、来源时间线、音频解码与分轨提取、重复保存、空录音、单路声音和中断文件恢复。它们不替代实际设备上的录音、权限弹窗与语音转写测试。

欢迎通过 Issue 反馈问题或提交 Pull Request。报告问题时请附上 macOS 和 Xcode 版本、复现步骤及错误提示；无需附上私人录音。
