#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="$PWD/.build/Tests"
mkdir -p "$output"
derived_data="${DUOREC_DERIVED_DATA:-$PWD/.build/WhisperBuild}"
frameworks="$derived_data/SourcePackages/artifacts/whispercpp/WhisperFramework/whisper.xcframework/macos-arm64_x86_64"
if [ ! -d "$frameworks/whisper.framework" ]; then
  xcodebuild -resolvePackageDependencies -project DuoRec.xcodeproj -scheme DuoRec \
    -derivedDataPath "$derived_data"
fi

compile_check() {
  check="$1"
  shift
  xcrun swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$output/ModuleCache.noindex" \
    "$@" "Tests/$check.swift" -o "$output/$check"
}

compile_transcription_check() {
  compile_check "$1" \
    -F "$frameworks" -framework whisper -Xlinker -rpath -Xlinker "$frameworks" \
    DuoRec/Audio/*.swift DuoRec/Recording/*.swift \
    DuoRec/Transcription/TranscriptionModel.swift DuoRec/Transcription/TranscriptTimeline.swift \
    DuoRec/Whisper/Whisper*.swift
}

for check in StateMachineChecks WhisperChecks; do
  compile_transcription_check "$check"
  "$output/$check"
done

compile_check PermissionChecks DuoRec/Audio/*.swift DuoRec/Recording/*.swift
"$output/PermissionChecks"
compile_check ScreenRecordingAccessChecks DuoRec/Recording/ScreenRecordingAccess.swift
"$output/ScreenRecordingAccessChecks"
compile_check TerminationChecks DuoRec/Recording/RecordingTermination.swift
"$output/TerminationChecks"
compile_check TranscriptSelectionChecks DuoRec/Transcription/TranscriptSelection.swift
"$output/TranscriptSelectionChecks"
compile_check TranscriptTimelineChecks DuoRec/Audio/AudioSource.swift DuoRec/Transcription/TranscriptTimeline.swift
"$output/TranscriptTimelineChecks"

compile_check WhisperDownloadChecks DuoRec/Whisper/WhisperDownloader.swift DuoRec/Whisper/WhisperModels.swift
python3 Tests/check_downloads.py "$output/WhisperDownloadChecks"

compile_check RecordingSafetyChecks DuoRec/Audio/*.swift DuoRec/Recording/RecordingFinalizer.swift
"$output/RecordingSafetyChecks" "$output"

if [ -n "${DUOREC_LANGUAGE_MODEL:-}" ]; then
  compile_transcription_check WhisperLanguageChecks
  "$output/WhisperLanguageChecks" "$DUOREC_LANGUAGE_MODEL"
fi
