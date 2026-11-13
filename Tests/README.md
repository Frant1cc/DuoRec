# 回归测试

在项目根目录运行：

```sh
sh Tests/run.sh
```

需要完整安装的 Xcode、Python 3 和可访问 macOS 音频编码服务的本机会话。脚本使用本机 HTTP 服务检查下载与续传，使用合成音频检查 MP4 保存、默认混音、来源音轨、旧格式和中断恢复，也覆盖录音状态机、权限、退出、转写时间线、选区以及模型文件校验和取消。合成录音恢复检查只会强制结束它自己启动的测试子进程。

首次运行会解析 Swift Package 依赖。默认使用 `.build/WhisperBuild`，也可用 `DUOREC_DERIVED_DATA` 指定已有的 Xcode 构建目录。检查产物写入 `.build/Tests`。

要额外使用真实 Whisper 模型验证中、英、日语和语言切换，请准备原版 small 多语言模型和 macOS 的 Samantha、Tingting、Kyoko 语音，然后运行：

```sh
DUOREC_LANGUAGE_MODEL=/path/to/ggml-small.bin sh Tests/run.sh
```

测试使用合成语音，无需下载识别模型或申请录音权限。
