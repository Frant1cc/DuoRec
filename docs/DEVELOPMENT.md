# 构建与开发

[← 返回 DuoRec](../README.md)

## 环境要求

- macOS 26 或更高版本。
- 从源码构建需要完整安装 Xcode 26 或更高版本；仅安装 Command Line Tools 不够。
- 录音需要“屏幕与系统音频录制”和“麦克风”权限。
- 转写依赖设备支持的 macOS SpeechTranscriber 与普通话模型。首次使用可能需要联网下载模型；无法使用模型时仍可录音。

录音与转写使用 Apple 系统框架，应用内更新使用 Sparkle 2。首次构建需要联网获取 Swift Package 依赖。当前已在 Xcode 26.6 下验证构建。

## 从源码构建

克隆仓库或下载并解压源码，然后在项目根目录操作。

### 使用 Xcode

1. 打开 `DuoRec.xcodeproj`。
2. 选择 `DuoRec` Scheme，运行目标选择 `My Mac`。
3. 在 `DuoRec` Target 的 `Signing & Capabilities` 中选择本机可用的签名方式，例如 `Sign to Run Locally`；也可使用自己的开发团队签名。
4. 按 ⌘R 构建并运行 DuoRec。

项目中的工程和 Scheme 名称为 `DuoRec`，生成的应用名称为 `DuoRec.app`。

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
