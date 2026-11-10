#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/StateMachineChecks
derived_data="${DUOREC_DERIVED_DATA:-$PWD/.build/WhisperBuild}"
frameworks="$derived_data/SourcePackages/artifacts/whispercpp/WhisperFramework/whisper.xcframework/macos-arm64_x86_64"
if [ ! -d "$frameworks/whisper.framework" ]; then
  xcodebuild -resolvePackageDependencies -project DuoRec.xcodeproj -scheme DuoRec \
    -derivedDataPath "$derived_data" > .build/StateMachineChecks/dependencies.log 2>&1
fi
build_check() {
  xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path .build/StateMachineChecks/ModuleCache.noindex \
  -F "$frameworks" -framework whisper -Xlinker -rpath -Xlinker "$frameworks" \
  DuoRec/RecorderLifecycle.swift DuoRec/RecorderModel.swift \
  DuoRec/ScreenRecordingAccess.swift DuoRec/RecordingFinalizer.swift \
  DuoRec/RecordingTermination.swift DuoRec/AudioCapture.swift \
  DuoRec/TranscriptionView.swift DuoRec/TranscriptTimeline.swift \
  DuoRec/TranscriptSelection.swift DuoRec/WhisperModels.swift DuoRec/WhisperTranscriber.swift \
  DuoRec/WhisperDownloader.swift \
  "$1" -o "$2"
}
build_check Checks/StateMachineChecks.swift .build/StateMachineChecks/state-machine-checks
.build/StateMachineChecks/state-machine-checks
build_check Checks/WhisperChecks.swift .build/StateMachineChecks/whisper-checks
.build/StateMachineChecks/whisper-checks
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path .build/StateMachineChecks/ModuleCache.noindex \
  DuoRec/WhisperDownloader.swift DuoRec/WhisperModels.swift Checks/WhisperDownloadChecks.swift \
  -o .build/StateMachineChecks/whisper-download-checks
python3 Checks/check_downloads.py .build/StateMachineChecks/whisper-download-checks
if [ -n "${DUOREC_LANGUAGE_MODEL:-}" ]; then
  build_check Checks/WhisperLanguageChecks.swift .build/StateMachineChecks/whisper-language-checks
  .build/StateMachineChecks/whisper-language-checks "$DUOREC_LANGUAGE_MODEL"
fi
