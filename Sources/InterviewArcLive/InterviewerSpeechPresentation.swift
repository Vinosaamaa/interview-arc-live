import InterviewArcLiveCore

struct InterviewerUtterancePresentation: Equatable {
    enum Tone: Equatable {
        case quiet
        case working
        case speaking
        case ready
        case warning
    }

    let title: String
    let detail: String
    let systemImage: String
    let tone: Tone
    let primaryActionTitle: String?
    let primaryActionSystemImage: String?
    let canStop: Bool
    let canPlay: Bool
    let canRetry: Bool

    static func make(
        utterance: InterviewerUtterance,
        isMuted: Bool
    ) -> InterviewerUtterancePresentation {
        let hasSelectedAudio = utterance.selectedAudio != nil
        if utterance.lifecycle == .ready,
           hasSelectedAudio,
           let latestAttempt = utterance.latestAttempt,
           latestAttempt.kind == .retry {
            switch latestAttempt.lifecycle {
            case .failed:
                return InterviewerUtterancePresentation(
                    title: "Retry failed",
                    detail: "The retry failed. Your prior saved voice remains available.",
                    systemImage: "exclamationmark.triangle.fill",
                    tone: .warning,
                    primaryActionTitle: "Play",
                    primaryActionSystemImage: "play.fill",
                    canStop: false,
                    canPlay: !isMuted,
                    canRetry: !isMuted
                )
            case .stopped:
                return InterviewerUtterancePresentation(
                    title: "Retry stopped",
                    detail: "The retry stopped. Your prior saved voice remains available.",
                    systemImage: "stop.circle",
                    tone: .quiet,
                    primaryActionTitle: "Play",
                    primaryActionSystemImage: "play.fill",
                    canStop: false,
                    canPlay: !isMuted,
                    canRetry: !isMuted
                )
            case .authorized, .speaking, .ready:
                break
            }
        }

        switch utterance.lifecycle {
        case .pending:
            return InterviewerUtterancePresentation(
                title: "Voice pending",
                detail: "The written turn is ready. Local speech has not run.",
                systemImage: "clock.arrow.circlepath",
                tone: .quiet,
                primaryActionTitle: "Generate",
                primaryActionSystemImage: "waveform",
                canStop: false,
                canPlay: false,
                canRetry: !isMuted
            )
        case .generating:
            return InterviewerUtterancePresentation(
                title: "Generating locally",
                detail: "The selected local voice is preparing this interviewer turn.",
                systemImage: "waveform",
                tone: .working,
                primaryActionTitle: "Stop",
                primaryActionSystemImage: "stop.fill",
                canStop: true,
                canPlay: false,
                canRetry: false
            )
        case .speaking:
            return InterviewerUtterancePresentation(
                title: "Speaking",
                detail: "Audio is streaming from the local model.",
                systemImage: "speaker.wave.2.fill",
                tone: .speaking,
                primaryActionTitle: "Stop",
                primaryActionSystemImage: "stop.fill",
                canStop: true,
                canPlay: false,
                canRetry: false
            )
        case .ready:
            return InterviewerUtterancePresentation(
                title: "Voice ready",
                detail: isMuted
                    ? "Saved locally. Unmute to play it."
                    : "Saved locally and available to replay.",
                systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                tone: .ready,
                primaryActionTitle: "Play",
                primaryActionSystemImage: "play.fill",
                canStop: false,
                canPlay: hasSelectedAudio && !isMuted,
                canRetry: !isMuted
            )
        case .stopped:
            return InterviewerUtterancePresentation(
                title: "Speech stopped",
                detail: hasSelectedAudio
                    ? "The prior saved voice remains available."
                    : "The written turn is unchanged. Generate again when ready.",
                systemImage: "stop.circle",
                tone: .quiet,
                primaryActionTitle: hasSelectedAudio ? "Play" : "Retry",
                primaryActionSystemImage: hasSelectedAudio ? "play.fill" : "arrow.clockwise",
                canStop: false,
                canPlay: hasSelectedAudio && !isMuted,
                canRetry: !isMuted
            )
        case .failed:
            return InterviewerUtterancePresentation(
                title: "Speech unavailable",
                detail: hasSelectedAudio
                    ? "The retry failed. Your prior saved voice remains available."
                    : "The written turn is safe. Retry only when you choose.",
                systemImage: "exclamationmark.triangle.fill",
                tone: .warning,
                primaryActionTitle: hasSelectedAudio ? "Play" : "Retry",
                primaryActionSystemImage: hasSelectedAudio ? "play.fill" : "arrow.clockwise",
                canStop: false,
                canPlay: hasSelectedAudio && !isMuted,
                canRetry: !isMuted
            )
        }
    }
}

struct InterviewerSpeechReadinessPresentation: Equatable {
    enum Tone: Equatable {
        case quiet
        case working
        case ready
        case warning
    }

    let title: String
    let detail: String
    let systemImage: String
    let tone: Tone
    let progress: Double?
    let showsInstallDisclosure: Bool
    let canDownload: Bool
    let canCancel: Bool
    let canRemove: Bool

    static func make(
        readiness: InterviewerSpeechReadiness,
        engineName: String = "Qwen",
        downloadSize: String = "1.838 GiB",
        minimumFreeSpace: String = "4 GiB"
    ) -> InterviewerSpeechReadinessPresentation {
        switch readiness {
        case .notInstalled:
            return InterviewerSpeechReadinessPresentation(
                title: "Add \(engineName) voice",
                detail: "Download \(downloadSize) once; \(minimumFreeSpace) free space required. Speech runs on this Mac with no usage fees.",
                systemImage: "arrow.down.circle",
                tone: .quiet,
                progress: nil,
                showsInstallDisclosure: true,
                canDownload: true,
                canCancel: false,
                canRemove: false
            )
        case .preparing(let progress):
            let total = max(progress.totalBytes, 1)
            let fraction = min(max(Double(progress.completedBytes) / Double(total), 0), 1)
            return InterviewerSpeechReadinessPresentation(
                title: preparationTitle(progress.stage),
                detail: "The exact public snapshot is staged and verified before it becomes ready.",
                systemImage: "arrow.down.circle",
                tone: .working,
                progress: fraction,
                showsInstallDisclosure: false,
                canDownload: false,
                canCancel: true,
                canRemove: false
            )
        case .ready:
            return InterviewerSpeechReadinessPresentation(
                title: "\(engineName) voice ready",
                detail: "Voice generation runs on this Mac with no usage fees.",
                systemImage: "waveform.circle.fill",
                tone: .ready,
                progress: nil,
                showsInstallDisclosure: false,
                canDownload: false,
                canCancel: false,
                canRemove: true
            )
        case .unavailable(let failure):
            return InterviewerSpeechReadinessPresentation(
                title: failure == .insufficientStorage ? "\(minimumFreeSpace) of free space required" : failureTitle(failure),
                detail: failure == .insufficientStorage ? "Free space, then start the \(downloadSize) download again." : failureDetail(failure),
                systemImage: "exclamationmark.triangle.fill",
                tone: .warning,
                progress: nil,
                showsInstallDisclosure: true,
                canDownload: failure != .incompatibleRuntime,
                canCancel: false,
                canRemove: false
            )
        }
    }

    private static func preparationTitle(
        _ stage: InterviewerSpeechPreparationStage
    ) -> String {
        switch stage {
        case .checkingStorage: return "Checking private model storage"
        case .downloading: return "Downloading Mara’s voice"
        case .verifying: return "Verifying the exact model"
        case .promoting: return "Finishing local installation"
        }
    }

    private static func failureTitle(
        _ failure: InterviewerSpeechReadinessFailure
    ) -> String {
        switch failure {
        case .insufficientStorage: return "More free space required"
        case .networkUnavailable: return "Model download unavailable"
        case .verificationFailed: return "Model verification failed"
        case .incompatibleRuntime: return "Local voice unavailable on this Mac"
        case .storageFailure: return "Private model storage unavailable"
        case .cancelled: return "Model download cancelled"
        }
    }

    private static func failureDetail(
        _ failure: InterviewerSpeechReadinessFailure
    ) -> String {
        switch failure {
        case .insufficientStorage:
            return "Free space, then explicitly start the download again."
        case .networkUnavailable:
            return "The interview remains usable. Try the explicit download again when online."
        case .verificationFailed:
            return "The staged files were not promoted. Start a fresh verified download."
        case .incompatibleRuntime:
            return "The written interviewer turn remains fully available."
        case .storageFailure:
            return "Interview Arc Live could not use its private Application Support model storage."
        case .cancelled:
            return "No historical interviewer turn will speak automatically."
        }
    }
}
