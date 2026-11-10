# 构建与开发

[← 返回 DuoRec](../README.md)

## 环境要求

- macOS 26 或更高版本。
- 从源码构建需要完整安装 Xcode 26 或更高版本；仅安装 Command Line Tools 不够。
- 录音需要“屏幕与系统音频录制”和“麦克风”权限。
- 转写仅使用 whisper.cpp 与多语言 Whisper 模型，提供 large-v3、large-v3-turbo、small、medium。模型由应用从 Hugging Face 下载并校验，也可导入本地原版 ggml 文件；无需 API Key。

录音使用 Apple 系统框架；转写通过本地 Swift Package `Packages/WhisperCpp` 接入官方 whisper.cpp v1.9.2 XCFramework（固定 SHA-256，包含 arm64 与 x86_64）；应用内更新使用 Sparkle 2。首次构建需要联网获取 Swift Package 依赖。当前已在 Xcode 26.6 下验证构建。

## 从源码构建

克隆仓库或下载并解压源码，然后在项目根目录操作。

### 使用 Xcode

1. 打开 `DuoRec.xcodeproj`。
2. 选择 `DuoRec` Scheme，运行目标选择 `My Mac`。
3. 在 `DuoRec` Target 的 `Signing & Capabilities` 中选择本机可用的签名方式，例如 `Sign to Run Locally`；也可使用自己的开发团队签名。
4. 按 ⌘R 构建并运行 DuoRec。

项目中的工程和 Scheme 名称为 `DuoRec`，生成的应用名称为 `DuoRec.app`。

模型文件与安装逻辑在 `WhisperModels.swift`，下载任务在 `WhisperDownloader.swift`，Whisper C API、音频解码与后台推理在 `WhisperTranscriber.swift`。模型文件先暂存并验证大小及 SHA-256，成功后才安装；文件长度通过 FileHandle 读取，避免 URL.resourceValues 对持续增长文件的 fileSize 缓存导致误判；下载文件校验失败后保留，支持重新校验。下载使用专用 URLSessionDataDelegate，将数据流写入稳定的 `.bin.partial` 文件；暂停和网络错误保留数据，重启时扫描缓存，继续时从实际文件长度发出 Range 请求并校验 Content-Range。服务器忽略 Range 时先截断再重下，避免错误拼接。连接、传输与暂停分别呈现，无数据请求超时为 30 秒。推理前将音频转换为 16 kHz 单声道 Float32 PCM 并映射读取，结束或取消后清理。推理按停顿切分连续音频，每段不超过 30 秒，复用模型上下文、每段重新自动检测语言（`language = nil`、`detect_language = false`、`translate = false`、`no_context = true`），再将时间戳与进度换算回音轨位置。根据引擎检测到的语言，仅对中文（`zh`）与粤语（`yue`）片段使用系统 Traditional-Simplified 文字转换，统一简体；不对日文等其他语言应用转换，以保留日文汉字。语言参数不再暴露给界面或持久化，启动时清理旧版 `whisper.language` 偏好，避免强制中文或英语。Apple 芯片优先使用 Metal，初始化失败时回退到 Whisper CPU。

运行 `sh Checks/run.sh` 可验证原有状态机与新的 Whisper 缓存、导入错误、取消、任务隔离，以及本机 HTTP 服务上的真实下载进度、持久化暂停、重建下载器后的续传、重定向、Range 异常、响应错误和无数据超时；首次检查会解析引擎构建依赖，不下载识别模型。

原语言转写集成检查可通过 `DUOREC_LANGUAGE_MODEL=/path/to/ggml-small.bin sh Checks/run.sh` 启用，需要已下载的原版 small 多语言模型及 macOS 的 Samantha、Tingting、Kyoko 语音。检查使用系统语音合成测试录音，验证中、英、日语，单轨内双向切换语言、超过 30 秒后切换语言、时间戳、进度与原生推理取消；不使用麦克风或下载模型。

状态所有权、允许的操作、异步取消规则及回归检查见[应用状态机清单](STATE_MACHINES.md)。

### 使用命令行

先启动一次 Xcode，完成首次运行所需的组件安装，并确认 `xcodebuild -version` 指向完整 Xcode。然后执行：

```sh
xcodebuild \
  -project DuoRec.xcodeproj \
  -scheme DuoRec \
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

## 应用内更新

应用使用 Sparkle 2 检查和安装维护者发布的更新。更新验证公钥随源码和应用公开，签署正式更新所需的私钥仅由维护者保管。开发者从源码构建应用不需要发布私钥。

欢迎通过 Issue 反馈问题或提交 Pull Request。报告问题时请附上 macOS 和 Xcode 版本、复现步骤及错误提示；无需附上私人录音。
