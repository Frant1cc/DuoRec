# DuoRec

DuoRec 是一个原生 macOS 双路录音工具，可同时录制系统声音和所选麦克风，保存为可直接播放的 M4A，并保留双轨源文件，便于按声音来源转写。

录音与语音转写在本机处理，无需 API Key。界面支持简体中文和英语。

## 功能

- 窗口与菜单栏录音控制、双路实时电平显示。
- 选择麦克风，支持关闭增强、+6 dB 或 +12 dB 增强。
- 系统声音使用 48 kHz / 128 kbps AAC，麦克风使用 48 kHz / 64 kbps AAC。
- 停止后输出混音 `.m4a` 和同名 `.tracks.mov` 双轨源文件。
- 自定义保存文件夹，并在下次启动时保留选择。
- 使用 macOS 本机普通话语音模型转写导入的录音；DuoRec 双轨录音可按时间线标明系统声音与麦克风，支持筛选和复制。
- 退出时等待录音保存，启动时尝试恢复意外中断的录音。

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

## 开始录音

1. 启动 DuoRec，点击“授予权限”，按系统提示允许屏幕与系统音频录制、麦克风访问。
2. 如果系统提示需要重新打开 App，请完全退出后从原位置重新打开。
3. 选择麦克风和保存位置。默认保存到当前用户的 `下载/DuoRec`。
4. 播放一段声音并对麦克风说话，点击“测试输入”确认两条电平条都会变化。测试期间不会保存声音。
5. 点击“开始录音”，结束后点击“停止并保存”。

建议佩戴耳机，避免扬声器声音再次进入麦克风而产生重音。

正常保存会生成一对文件：

```text
2026-10-31 14-30-00 DuoRec.m4a
2026-10-31 14-30-00 DuoRec.tracks.mov
```

M4A 用于直接播放，MOV 保留分开的系统声音与麦克风音轨。移动或重命名时，请保留同名配对关系，方便后续按来源转写。

## 录音转文字

在主窗口点击“导入录音转文字”，选择音频文件：

- 导入 DuoRec 的 M4A 时，应用会查找同一文件夹内的同名 `.tracks.mov` 双轨源文件。也可直接导入 `.tracks.mov`。
- 双轨转写按时间顺序显示每段话，并标明“系统声音”或“麦克风”。顶部可筛选全部内容或单一来源。
- 选中文字后按 ⌘C 或点击“复制选中”，也可复制当前筛选结果的全文。
- 普通单轨音频可转写和修改文字；没有双轨源文件时，无法准确区分系统声音与麦克风。

当前转写语言为普通话，界面切换英语不会改变识别语言。转写不会修改导入的录音，不生成文字文件，也不保留历史；需要保存的文字请在关闭转写窗口前复制。

## 隐私与权限

DuoRec 不上传录音，不包含分析统计或第三方在线转写服务。语音模型可能需要由 macOS 联网下载，转写过程在本机进行。

系统声音采集使用 ScreenCaptureKit，因此需要“屏幕与系统音频录制”权限；应用只接收音频，不保存屏幕画面。可在“系统设置 > 隐私与安全性”中管理或撤销权限。

录音与双轨源文件会保留在保存文件夹中；中断文件可能保留在应用的数据目录中等待恢复。关闭转写窗口会清空窗口中的文字，但不会删除录音文件或已经复制到剪贴板的内容。

## 录音保存与中断恢复

- 采集发生异常时自动停止计时，并尝试保存已经收到的声音。
- 录音中按 ⌘Q 退出，会等待保存完成。无法保存可播放的文件时会取消退出，并保留原始文件。
- 意外崩溃或强制结束后，下次启动会尝试将中断文件恢复到所选保存位置。无法恢复时可使用“打开待恢复文件夹”查看原文件。
- 混音失败时，应用会尝试保留可读取的原始音轨文件。

录制中的 MOV 会分段写入，首次约 1 秒，随后每 5 秒写入一个片段。强制结束可能丢失最后未写入的片段；首个片段完成前的短录音、磁盘故障，以及旧版未收尾的 M4A 不保证可恢复。重要录音建议先做短录测试，停止后确认文件可播放。

## 常见问题

**权限已开启，但仍无法录音**

确认授予权限的是当前运行的 DuoRec 副本，完全退出后从相同位置重新打开。可在 App 中打开权限设置并重新检查。自行构建或更换签名后，macOS 可能要求重新授权。

**找不到普通话模型或无法转写**

转写需要当前设备支持相关系统模型。首次使用时请允许模型下载；若仍不可用，可继续使用录音功能，并在其他支持该模型的设备上转写。

**系统声音或麦克风没有电平**

确认正在播放声音、麦克风选择正确，并检查两项权限。系统声音不包含 DuoRec 自身播放的声音。

**切换界面语言**

在“系统设置 > 通用 > 语言与地区 > 应用程序”中为 DuoRec 选择简体中文或英语，然后重新打开 App。

## 开发与验证

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

检查覆盖权限结果分类、退出等待与保存失败、选区安全、来源时间线、音频解码与分轨提取、重复保存、空录音、单路声音和中断文件恢复。它们不替代实际设备上的录音、权限弹窗与语音转写测试。

欢迎通过 Issue 反馈问题或提交 Pull Request。报告问题时请附上 macOS 和 Xcode 版本、复现步骤及错误提示；无需附上私人录音。

## 许可证

本项目采用 [MIT License](LICENSE)。Copyright (c) 2026 Frant1cc。
