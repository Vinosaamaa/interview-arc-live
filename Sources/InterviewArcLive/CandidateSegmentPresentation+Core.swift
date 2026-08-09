import Foundation
import InterviewArcLiveCore

extension CandidateSegmentPresentation {
    init(segment: CandidateSegment) {
        let selected = segment.selectedCandidate
        id = segment.id.rawValue
        ordinal = segment.ordinal + 1
        lifecycle = Self.presentationLifecycle(for: segment)
        duration = segment.capturedAudio.map {
            Self.durationLabel(milliseconds: $0.decodedDurationMilliseconds)
        }
        transcript = selected?.body
        detail = Self.detail(for: segment)
        quality = selected.map { Self.presentationQuality(for: $0.quality) }
        canPlay = segment.capturedAudio?.isPlayable == true
        if segment.canRetryTranscription && selected?.quality != .verified {
            transcriptionAction = segment.transcriptionAttempts.isEmpty ? .initial : .retry
        } else {
            transcriptionAction = nil
        }
        canExclude = segment.canExcludeFromAnswer
    }

    private static func presentationLifecycle(
        for segment: CandidateSegment
    ) -> Lifecycle {
        switch segment.lifecycle {
        case .captureAuthorized:
            .preparing
        case .recording:
            .recording
        case .finalizationAuthorized:
            .finalizing
        case .audioReady:
            segment.transcriptionAttempts.isEmpty ? .preserved : .recoverable
        case .transcribing:
            .transcribing
        case .transcribed:
            segment.capturedAudio?.isPartial == true ? .partial : .ready
        case .failed:
            .failed
        case .excluded:
            .excluded
        }
    }

    private static func presentationQuality(
        for quality: TranscriptQuality
    ) -> Quality {
        switch quality {
        case .verified: .verified
        case .bestAvailable: .bestAvailable
        case .possibleContamination: .possibleContamination
        }
    }

    private static func durationLabel(milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    }

    private static func detail(for segment: CandidateSegment) -> String {
        switch segment.lifecycle {
        case .captureAuthorized:
            return "The segment identity is saved. Starting the microphone now."
        case .recording:
            return "Recording now. Stop preserves this segment before transcription begins."
        case .finalizationAuthorized:
            return "Saving the source recording before contacting Groq."
        case .audioReady:
            if let failure = segment.transcriptionAttempts.last?.failure {
                return transcriptionFailureMessage(failure.reason)
            }
            return "Source recording preserved. Groq has not been contacted. Choose Transcribe when ready."
        case .transcribing:
            return "Source audio is saved. Groq transcription is in progress."
        case .transcribed:
            return segment.capturedAudio?.isPartial == true
                ? "The playable portion and its best transcript are preserved."
                : "The selected transcript is preserved verbatim."
        case .failed:
            return captureFailureMessage(segment.captureFailureReason)
        case .excluded:
            return exclusionMessage(segment.exclusionReason)
        }
    }

    private static func exclusionMessage(_ reason: SegmentExclusionReason?) -> String {
        switch reason {
        case .userSkipped:
            "Excluded from Hand off. The source recording remains preserved."
        case .noUsableTranscript:
            "Excluded because no usable transcript was selected. The recording remains preserved."
        case .insufficientSignal:
            "Excluded because speech signal was insufficient. The recording remains preserved."
        case .captureFailed:
            "Excluded after capture failure. Any recovered source evidence remains preserved."
        case nil:
            "Excluded from Hand off. Source evidence remains preserved."
        }
    }

    private static func transcriptionFailureMessage(
        _ reason: SegmentTranscriptionFailureReason
    ) -> String {
        switch reason {
        case .missingCredential:
            "Recording saved. Add a Groq key, then retry the transcript."
        case .credentialRejected:
            "Recording saved. Update the Groq key, then retry the transcript."
        case .invalidAudio:
            "Recording kept, but Groq could not read its audio. Play it before retrying."
        case .insufficientSignal:
            "Recording kept. Groq found too little speech; play it before retrying."
        case .emptyProviderResult:
            "Recording kept. Groq returned no words; retry only when you choose."
        case .providerUnavailable:
            "Recording kept. Groq was unavailable; retry when the provider recovers."
        case .interrupted:
            "Recording kept. The provider attempt was interrupted and was not replayed."
        }
    }

    private static func captureFailureMessage(
        _ reason: SegmentCaptureFailureReason?
    ) -> String {
        switch reason {
        case .microphoneUnavailable:
            "Microphone access is unavailable. Check macOS access before adding a segment."
        case .captureStartFailed:
            "The microphone did not start. No speech was claimed or transcribed."
        case .captureFinalizationFailed:
            "The recording could not be finalized. The last durable state remains available."
        case .noPlayableAudio:
            "No playable audio was recovered. Add a new segment when ready."
        case .storageFailed:
            "Private recording storage failed. No provider request was started."
        case .interruptedWithoutAudio:
            "Recording ended before a playable source file was available."
        case nil:
            "This segment failed without a playable source recording."
        }
    }
}
