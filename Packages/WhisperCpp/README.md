# WhisperCpp

Local Swift Package exposing the `whisper` module from the official
[whisper.cpp v1.9.2 XCFramework](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.2).
The release archive and SHA-256 are pinned in `Package.swift`. The macOS framework
includes arm64 and x86_64; Xcode downloads and embeds it automatically.

The four multilingual ggml model files are downloaded separately by the app from
`ggerganov/whisper.cpp` on Hugging Face. Expected byte lengths and SHA-256 hashes
are recorded in `DuoRec/WhisperModels.swift`. Models are not bundled into the app.

See `DuoRec/WhisperNotices.txt` for the engine and model license notices.
