#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/StateMachineChecks
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path .build/StateMachineChecks/ModuleCache.noindex \
  DuoRec/RecorderLifecycle.swift DuoRec/RecorderModel.swift \
  DuoRec/ScreenRecordingAccess.swift DuoRec/RecordingFinalizer.swift \
  DuoRec/RecordingTermination.swift DuoRec/AudioCapture.swift \
  DuoRec/TranscriptionView.swift DuoRec/TranscriptTimeline.swift \
  DuoRec/TranscriptSelection.swift Checks/StateMachineChecks.swift \
  -o .build/StateMachineChecks/state-machine-checks
.build/StateMachineChecks/state-machine-checks
