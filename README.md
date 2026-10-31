<p align="center">
  <img src="screen/Assets.xcassets/AppIcon.appiconset/DuoRecIcon-256.png" alt="DuoRec 应用图标" width="112" height="112">
</p>

<h1 align="center">DuoRec</h1>

<p align="center"><strong>电脑的声音，你的声音，一起记下来。</strong></p>
<p align="center">macOS 双路录音工具 · 本机普通话转写</p>

<p align="center">
  <a href="#开始使用">开始使用</a> ·
  <a href="docs/USER_GUIDE.md">使用指南</a> ·
  <a href="docs/DEVELOPMENT.md">构建与开发</a>
</p>

---

## DuoRec 是什么？

开线上会议、做远程访谈，或边听课程边口述想法时，你往往需要同时留下**电脑里播放的声音**和**自己对着麦克风说的话**。DuoRec 可以一次录下这两路声音，方便回听，之后再按来源转成文字。

它是一个轻量的原生 Mac 应用：在窗口或菜单栏开始录音，结束后文件留在本机。无需 API Key，录音与转写都在本机处理。

| 能做什么 | 对你有什么用 |
| --- | --- |
| **同时录两路声音** | 系统声音与所选麦克风一起录，实时电平方便确认两路输入。 |
| **回听与分轨转写** | 一个 MP4 文件内保留完整混音和两路独立来源音轨，供回听与按来源转写。 |
| **按来源整理文字** | 普通话转写按时间排列，标明“系统声音”和“麦克风”，可筛选、选中和复制。 |
| **本机保存与恢复** | 自选保存位置，退出时等待保存，意外中断后尝试恢复。 |

## 开始使用

需要 **macOS 26+**。目前通过源码构建，需安装完整的 **Xcode 26+**。

```sh
git clone https://github.com/Frant1cc/DuoRec.git
cd DuoRec
open screen.xcodeproj
```

在 Xcode 中选择 `screen` Scheme 和 `My Mac`，在 `Signing & Capabilities` 中选择 `Sign to Run Locally` 或自己的开发团队，按 **⌘R** 运行。

也可以使用[命令行构建](docs/DEVELOPMENT.md#使用命令行)。界面支持简体中文和英语。

## 三步录下声音

1. **授予权限** — 启动后允许“屏幕与系统音频录制”和“麦克风”访问；若系统要求，完全退出后重新打开。
2. **确认输入** — 选择麦克风，点击“测试输入”，确认系统声音与麦克风两条电平都会变化。
3. **开始与保存** — 点击“开始录音”，结束后“停止并保存”。默认保存到 `下载/DuoRec`，也可更换文件夹。

从当前源码构建的版本每次只保存一个 `.mp4` 音频文件，默认播放两路声音的混音，转写时分别识别系统声音与麦克风。移动或改名不需要配套文件。旧版 M4A 与同名双轨源文件仍可导入。建议佩戴耳机，避免扬声器的声音被麦克风再次录入。

## 把录音变成文字

点击 **“导入录音转文字”**，选择 DuoRec 录音，即可得到按时间排列、带声音来源标记的文字。筛选“系统声音”或“麦克风”，复制需要的片段，方便整理会议记录、访谈内容和学习笔记。

也支持导入普通单轨音频。当前识别语言为**普通话**，首次使用可能需要 macOS 下载模型，设备需支持该模型。来源标记用于区分两路输入，不区分同一路声音中的不同说话人。

转写文字不保留历史，关闭窗口前请复制所需内容。更多操作见[使用指南](docs/USER_GUIDE.md)。

## 了解更多

- [使用指南](docs/USER_GUIDE.md)：权限、文件格式、隐私、中断恢复与常见问题。
- [构建与开发](docs/DEVELOPMENT.md)：完整构建步骤、环境要求与回归检查。
- [反馈问题](https://github.com/Frant1cc/DuoRec/issues)：欢迎反馈使用体验或提交 Pull Request。

DuoRec 使用 [MIT License](LICENSE) 开源。
