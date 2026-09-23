# DuoRec

一个仅在本机运行的 macOS 双路录音工具，同时记录：

- Mac 正在播放的系统声音
- 你选择的麦克风

停止录音后，两路声音会合成为一份普通的 M4A 文件。默认保存到：

`下载/DuoRec`

也可以在主界面的“保存位置”中选择其他文件夹，选择结果会在下次启动时保留。

## 统一使用版本

日常使用统一打开 `/Applications/DuoRec.app`。项目目录内的 `DuoRec.app` 是指向该安装版的链接，两处打开的是同一个应用。

旧安装版、独立修复版以及重复构建已保存为 ZIP，位于 `.build/version-archives/`。这些文件只用于恢复备份。

后续更新应将构建结果安装到 `/Applications/DuoRec.app`，再从这个位置运行。Xcode 调试构建不作为日常使用入口。

## 语言

界面支持简体中文和英语，并自动跟随 macOS 为 DuoRec 设置的首选语言。可在“系统设置 > 通用 > 语言与地区 > 应用程序”中单独切换 DuoRec 的语言；更改后请重新打开 App。

## 运行要求

- macOS 26 或更高版本
- Xcode 26 或更高版本

## 首次运行

1. 打开“应用程序”中的 DuoRec，或项目目录内的 `DuoRec.app` 链接。
2. 在 App 中点击“授予权限”，允许：
   - 屏幕与系统音频录制
   - 麦克风
3. 如果 macOS 提示需要重新打开 App，请完全退出后，从同一位置重新打开。
4. 播放一段声音、对麦克风说话，开始录音后确认两条电平条都会变化。

也可以先点击“测试输入”查看实时电平；测试期间不会保存任何声音。

建议在面试时佩戴耳机，避免扬声器声音再次进入麦克风而产生重音。

## 当前范围

- 原生 SwiftUI 菜单栏和窗口界面
- ScreenCaptureKit 双路采集
- 系统声音 48 kHz / 128 kbps AAC
- 麦克风 48 kHz / 64 kbps AAC
- 停止后自动输出可播放的混音 M4A，并保留同名 `.tracks.mov` 双轨源文件
- 文件名以录制时间开头，便于按名称排序
- 麦克风增强可选择关闭、+6 dB 或 +12 dB
- 合成失败时保留原始双轨文件
- 可导入录音，用 macOS 本机普通话语音模型转写；DuoRec 双轨录音按时间线标明系统声音和麦克风，支持按来源筛选和复制
- 不录屏、不上传录音；转写文字只保留在当前窗口，关闭后清除

## 录音转文字

在主窗口点击“导入录音转文字”，选择一份音频文件。首次使用时，macOS 可能需要下载普通话语音模型。导入 DuoRec 新录音的 M4A 时，应用会查找同一文件夹内的同名 `.tracks.mov` 双轨源文件，按时间顺序显示每段话，并标明“系统声音”或“麦克风”；也可以直接导入 `.tracks.mov`。顶部可筛选全部、系统声音或麦克风，选中任意文字按 ⌘C 或点击“复制选中”，也可复制当前筛选结果的全文。普通单轨音频仍可转写和修改文字。此功能不生成文字文件，也不保留转写历史；导入的录音不会被修改。

如果移动或重命名 DuoRec 录音，请让 M4A 和同名 `.tracks.mov` 留在一起。旧版只保存了混音 M4A 的录音，无法准确区分这两路声音。

## 录音保存与中断恢复

- 采集发生异常时会停止计时并自动保存已经收到的声音；停止采集本身报错不会跳过文件收尾。
- 录音中按 ⌘Q 退出，会等待保存完成。无法保存可播放的文件时取消本次退出，并保留原始文件供恢复。
- 录制过程中使用带片段的 MOV 临时文件，首次约 1 秒、随后每 5 秒写入一个片段，正常保存仍输出 M4A。
- 意外崩溃或强制结束后，下次启动自动尝试将中断文件恢复到所选保存位置；无法恢复的文件保留，并提供“打开待恢复文件夹”入口。
- 强制结束可能丢失最后未写入的片段；第一片段完成前的短录音、磁盘故障，以及旧版未收尾的 M4A 不保证可恢复。
- 混音失败时，只有确认原始文件包含可读取的音频后，才将它显示为已保存的备份。

## 回归检查

以下检查使用合成音频，不采集真实系统声音或麦克风。音频检查需在允许访问 macOS 音频编码服务的本机会话运行。

```sh
mkdir -p .build
xcrun swiftc -parse-as-library -module-cache-path .build/ModuleCache.noindex screen/AudioCapture.swift screen/RecordingFinalizer.swift Tests/RecordingSafetyChecks.swift -o .build/recording-safety-checks
.build/recording-safety-checks "$PWD/.build"
xcrun swiftc -parse-as-library -module-cache-path .build/ModuleCache.noindex screen/RecordingTermination.swift Tests/TerminationChecks.swift -o .build/termination-checks
.build/termination-checks
xcrun swiftc -parse-as-library -module-cache-path .build/ModuleCache.noindex screen/AudioCapture.swift screen/TranscriptTimeline.swift Tests/TranscriptTimelineChecks.swift -o .build/transcript-timeline-checks
.build/transcript-timeline-checks
xcrun swiftc -parse-as-library -module-cache-path .build/ModuleCache.noindex screen/TranscriptSelection.swift Tests/TranscriptSelectionChecks.swift -o .build/transcript-selection-checks
.build/transcript-selection-checks
```

覆盖：停止失败后的文件收尾、音频解码、双轨来源标记和分轨提取、并发与重复保存、空录音、单路声音、中断文件恢复、按时间排列来源片段、文本变化后的选区安全，以及退出等待和失败取消。
