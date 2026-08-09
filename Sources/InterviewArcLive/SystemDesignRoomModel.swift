import AVFoundation
import Foundation
import InterviewArcLiveCore
import InterviewArcLiveVoiceAdapter

@MainActor
final class SystemDesignRoomModel: ObservableObject {
    @Published private(set) var snapshot: InterviewRoomSnapshot?
    @Published private(set) var segments: [CandidateSegmentPresentation] = []
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = "Restoring local session…"
    @Published private(set) var errorMessage: String?

    @Published var isCredentialSetupPresented = false
    @Published private(set) var isSavingCredential = false
    @Published private(set) var credentialErrorMessage: String?

    let question = "Design a global notification system."

    private enum CredentialState {
        case checking
        case missing
        case readyFromKeychain
        case readyUntilQuit
        case unusable
    }

    private let sessionID = SessionID("local-system-design-tracer")
    private let credentialStore: LiveGroqCredentialStore
    private var credentialState: CredentialState = .checking
    private var coordinator: SegmentSpeechCoordinator?
    private var audioPlayer: AVAudioPlayer?

    init(credentialStore: LiveGroqCredentialStore = LiveGroqCredentialStore()) {
        self.credentialStore = credentialStore
    }

    var needsGroqCredential: Bool {
        credentialState == .missing || credentialState == .unusable
    }

    private var hasUsableGroqCredential: Bool {
        credentialState == .readyFromKeychain
            || credentialState == .readyUntilQuit
    }

    var canStopRecording: Bool {
        activeCaptureSegment != nil
    }

    var stopActionTitle: String {
        activeCaptureSegment?.lifecycle == .recording
            ? "Stop segment"
            : "Recover recording"
    }

    var stopActionIcon: String {
        activeCaptureSegment?.lifecycle == .recording
            ? "stop.fill"
            : "arrow.clockwise.circle.fill"
    }

    var showsRecordControl: Bool {
        snapshot?.phase == .candidateFloor && !canStopRecording
    }

    var canRecordSegment: Bool {
        guard !isWorking,
              hasUsableGroqCredential,
              snapshot?.phase == .candidateFloor else {
            return false
        }
        return !draftSegments.contains {
            $0.lifecycle == .captureAuthorized
                || $0.lifecycle == .recording
                || $0.lifecycle == .finalizationAuthorized
                || $0.lifecycle == .transcribing
        }
    }

    var recordActionTitle: String {
        draftSegments.isEmpty ? "Record segment" : "Add segment"
    }

    var canAct: Bool {
        guard !isWorking, let snapshot else { return false }
        switch snapshot.phase {
        case .candidateFloor:
            let unresolved = draftSegments.contains {
                $0.lifecycle != .excluded && $0.selectedCandidate == nil
            }
            let hasSelected = draftSegments.contains {
                $0.lifecycle != .excluded && $0.selectedCandidate != nil
            }
            return hasSelected && !unresolved
        case .interviewerProcessing, .interviewerTurn:
            return true
        case .ready, .completed:
            return false
        }
    }

    var actionTitle: String {
        switch snapshot?.phase {
        case .interviewerProcessing: "Retry interviewer"
        case .interviewerTurn: "Give me the floor"
        case .completed: "Session complete"
        default: "Hand off"
        }
    }

    var actionIcon: String {
        switch snapshot?.phase {
        case .interviewerProcessing: "arrow.clockwise.circle.fill"
        case .interviewerTurn: "arrow.uturn.backward.circle.fill"
        default: "arrowshape.right.circle.fill"
        }
    }

    func open() async {
        guard coordinator == nil, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        await refreshCredentialReadiness(presentWhenMissing: true)

        do {
            let runtime = DeterministicInterviewerRuntime(
                response: CanonicalInterviewerResponse(
                    displayMarkdown: "Good. How will clients observe delivery without coupling every channel to the request path?",
                    spokenText: "Good. How will clients observe delivery without coupling every channel to the request path?"
                )
            )
            let opened = try await SegmentSpeechCoordinator.openLocal(
                sessionID: sessionID,
                activityID: "local-system-design-tracer",
                interviewerRuntime: runtime,
                recording: VoiceCoreSegmentRecorder(),
                transcriber: VoiceCoreSegmentTranscriber(),
                credentialReader: credentialStore
            )
            coordinator = opened
            opened.setSnapshotHandler { [weak self, weak opened] nextSnapshot in
                guard let self,
                      let opened,
                      self.coordinator === opened else {
                    return
                }
                self.publish(nextSnapshot)
            }

            var restored = opened.snapshot
            do {
                restored = try await opened.resumePendingWork()
            } catch {
                restored = opened.snapshot
                errorMessage = "A recording recovery needs attention. Preserved evidence remains visible below."
            }
            if restored.phase == .ready {
                restored = try await opened.giveCandidateFloor(
                    commandID: CommandID("local-give-floor-0")
                )
            }
            publish(restored)
        } catch {
            statusMessage = "Local session unavailable"
            errorMessage = safeMessage(for: error)
        }
    }

    func recordSegment() async {
        guard let coordinator else { return }
        guard hasUsableGroqCredential else {
            presentCredentialSetup()
            return
        }
        guard canRecordSegment else { return }

        isWorking = true
        errorMessage = nil
        statusMessage = "Preparing microphone…"
        defer { isWorking = false }

        do {
            let updated = try await coordinator.beginSegment(
                commandID: commandID("begin-segment")
            )
            publish(updated)
        } catch {
            publish(coordinator.snapshot)
            errorMessage = safeMessage(for: error)
        }
    }

    func stopRecording() async {
        guard let coordinator,
              let activeSegment = activeCaptureSegment,
              !isWorking else {
            return
        }

        isWorking = true
        errorMessage = nil
        statusMessage = activeSegment.lifecycle == .recording
            ? "Saving recording before Groq transcription…"
            : "Recovering the source recording without contacting Groq…"
        defer { isWorking = false }

        do {
            let preserved = try await coordinator.finalizeSegment(
                commandID: commandID("finalize-segment")
            )
            publish(preserved)

            if activeSegment.lifecycle == .recording,
               let preservedSegment = preserved.segments.first(where: {
                   $0.id == activeSegment.id
               }),
               preservedSegment.canRetryTranscription {
                statusMessage = "Transcribing with Groq…"
                let transcribed = try await coordinator.transcribeSegment(
                    segmentID: activeSegment.id,
                    commandID: commandID("initial-transcription")
                )
                publish(transcribed)
            }
        } catch {
            publish(coordinator.snapshot)
            handleCredentialFailure(error)
            errorMessage = safeMessage(for: error)
        }
    }

    func transcribeSegment(id: String) async {
        guard let coordinator, !isWorking else { return }
        guard hasUsableGroqCredential else {
            credentialErrorMessage = "Add a Groq API key before retrying this transcript."
            presentCredentialSetup()
            return
        }
        guard let segment = draftSegments.first(where: { $0.id.rawValue == id }),
              segment.canRetryTranscription else {
            return
        }
        let isInitial = segment.transcriptionAttempts.isEmpty

        isWorking = true
        errorMessage = nil
        statusMessage = isInitial
            ? "Transcribing preserved recording with Groq…"
            : "Retrying one transcript with Groq…"
        defer { isWorking = false }

        do {
            let updated = try await coordinator.transcribeSegment(
                segmentID: segment.id,
                commandID: commandID(
                    isInitial ? "initial-transcription" : "retry-transcription"
                )
            )
            publish(updated)
        } catch {
            publish(coordinator.snapshot)
            handleCredentialFailure(error)
            errorMessage = safeMessage(for: error)
        }
    }

    func excludeSegment(id: String) async {
        guard let coordinator, !isWorking else { return }
        guard let segment = draftSegments.first(where: { $0.id.rawValue == id }),
              segment.canExcludeFromAnswer else {
            return
        }

        isWorking = true
        errorMessage = nil
        statusMessage = "Preserving recording and excluding segment…"
        defer { isWorking = false }

        do {
            let updated = try await coordinator.excludeSegment(
                segmentID: segment.id,
                reason: exclusionReason(for: segment),
                commandID: commandID("exclude-segment")
            )
            publish(updated)
        } catch {
            publish(coordinator.snapshot)
            errorMessage = safeMessage(for: error)
        }
    }

    func playSegment(id: String) async {
        guard let coordinator, !isWorking else { return }
        guard draftSegments.contains(where: {
            $0.id.rawValue == id && $0.capturedAudio?.isPlayable == true
        }) else {
            return
        }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let url = try await coordinator.playbackURL(segmentID: SegmentID(id))
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            guard player.play() else {
                errorMessage = "The preserved recording could not start playback."
                return
            }
            audioPlayer = player
            statusMessage = "Playing preserved source recording"
        } catch {
            errorMessage = "The preserved recording is unavailable for playback."
        }
    }

    func performPrimaryAction() async {
        guard let coordinator, let snapshot, canAct else { return }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let updated: InterviewRoomSnapshot
            switch snapshot.phase {
            case .candidateFloor:
                statusMessage = "Saving one ordered answer…"
                updated = try await coordinator.handOff(
                    commandID: commandID("hand-off")
                )
            case .interviewerProcessing:
                statusMessage = "Retrying interviewer response…"
                updated = try await coordinator.retryInterviewerResponse(
                    commandID: commandID("retry-interviewer")
                )
            case .interviewerTurn:
                updated = try await coordinator.giveCandidateFloor(
                    commandID: commandID("give-floor")
                )
            case .ready, .completed:
                return
            }
            publish(updated)
        } catch {
            publish(coordinator.snapshot)
            errorMessage = safeMessage(for: error)
        }
    }

    func presentCredentialSetup() {
        credentialErrorMessage = nil
        isCredentialSetupPresented = true
    }

    func saveGroqCredential(_ value: String) async -> Bool {
        guard !isSavingCredential else { return false }
        isSavingCredential = true
        credentialErrorMessage = nil
        defer { isSavingCredential = false }

        do {
            try await credentialStore.saveAndVerify(value)
            credentialState = .readyFromKeychain
            statusMessage = segments.contains(where: { $0.transcriptionAction != nil })
                ? "Groq key saved to Keychain · transcribe the affected segment"
                : status(for: snapshot)
            return true
        } catch let error as LiveGroqCredentialStoreError {
            credentialState = .unusable
            credentialErrorMessage = error.localizedDescription
            return false
        } catch {
            credentialState = .unusable
            credentialErrorMessage = "macOS Keychain could not save the Groq API key."
            return false
        }
    }

    func useGroqCredentialUntilQuit(_ value: String) async -> Bool {
        guard !isSavingCredential else { return false }
        isSavingCredential = true
        credentialErrorMessage = nil
        defer { isSavingCredential = false }

        do {
            try await credentialStore.useUntilQuit(value)
            credentialState = .readyUntilQuit
            statusMessage = segments.contains(where: { $0.transcriptionAction != nil })
                ? "Groq key available until quit · transcribe the affected segment"
                : status(for: snapshot)
            return true
        } catch let error as LiveGroqCredentialStoreError {
            credentialErrorMessage = error.localizedDescription
            return false
        } catch {
            credentialErrorMessage = "The Groq API key could not be used for this app session."
            return false
        }
    }

    private var draftSegments: [CandidateSegment] {
        snapshot?.segments.filter { $0.committedTurnID == nil } ?? []
    }

    private var activeCaptureSegment: CandidateSegment? {
        draftSegments.first {
            $0.lifecycle == .captureAuthorized
                || $0.lifecycle == .recording
                || $0.lifecycle == .finalizationAuthorized
        }
    }

    private func publish(_ snapshot: InterviewRoomSnapshot) {
        if self.snapshot != snapshot {
            self.snapshot = snapshot
            segments = snapshot.segments
                .filter { $0.committedTurnID == nil }
                .sorted { $0.ordinal < $1.ordinal }
                .map(CandidateSegmentPresentation.init(segment:))
        }
        statusMessage = status(for: snapshot)
    }

    private func refreshCredentialReadiness(presentWhenMissing: Bool) async {
        do {
            switch try await credentialStore.readiness() {
            case .ready:
                credentialState = .readyFromKeychain
            case .readyUntilQuit:
                credentialState = .readyUntilQuit
            case .missing:
                credentialState = .missing
                if presentWhenMissing {
                    isCredentialSetupPresented = true
                }
            case .keychainUnavailable:
                credentialState = .unusable
                credentialErrorMessage = "macOS Keychain is unavailable. Use the key until quit to record in this app session."
                if presentWhenMissing {
                    isCredentialSetupPresented = true
                }
            }
        } catch {
            credentialState = .unusable
            credentialErrorMessage = "macOS Keychain is unavailable."
            if presentWhenMissing {
                isCredentialSetupPresented = true
            }
        }
    }

    private func status(for snapshot: InterviewRoomSnapshot?) -> String {
        guard let snapshot else { return "Restoring local session…" }
        let draft = snapshot.segments.filter { $0.committedTurnID == nil }

        if draft.contains(where: { $0.lifecycle == .captureAuthorized }) {
            return "Preparing microphone"
        }
        if draft.contains(where: { $0.lifecycle == .recording }) {
            return "Recording segment"
        }
        if draft.contains(where: { $0.lifecycle == .finalizationAuthorized }) {
            return "Saving source recording"
        }
        if draft.contains(where: { $0.lifecycle == .transcribing }) {
            return "Transcribing with Groq"
        }

        switch snapshot.phase {
        case .candidateFloor:
            if !hasUsableGroqCredential {
                return "Groq key required"
            }
            if draft.contains(where: {
                $0.lifecycle == .audioReady && $0.transcriptionAttempts.isEmpty
            }) {
                return "Recording preserved · choose Transcribe"
            }
            if draft.contains(where: {
                $0.lifecycle == .audioReady || $0.lifecycle == .failed
            }) {
                return "Recording preserved · recovery available"
            }
            let selectedCount = draft.filter {
                $0.lifecycle != .excluded && $0.selectedCandidate != nil
            }.count
            if selectedCount == 0 {
                return credentialState == .readyUntilQuit
                    ? "Ready to record · key available until quit"
                    : "Ready to record"
            }
            return "\(selectedCount) segment\(selectedCount == 1 ? "" : "s") ready"
        case .interviewerProcessing:
            return "Answer saved · interviewer retry available"
        case .interviewerTurn:
            return "Interviewer response saved"
        case .completed:
            return "Session complete"
        case .ready:
            return "Preparing candidate floor"
        }
    }

    private func commandID(_ operation: String) -> CommandID {
        CommandID("ui-\(operation)-\(UUID().uuidString.lowercased())")
    }

    private func exclusionReason(for segment: CandidateSegment) -> SegmentExclusionReason {
        if segment.captureFailureReason != nil {
            return .captureFailed
        }
        if segment.capturedAudio?.integrityReasons.contains(.insufficientSignal) == true
            || segment.transcriptionAttempts.last?.failure?.reason == .insufficientSignal {
            return .insufficientSignal
        }
        if segment.selectedCandidate == nil {
            return .noUsableTranscript
        }
        return .userSkipped
    }

    private func handleCredentialFailure(_ error: Error) {
        if let coordinatorError = error as? SegmentSpeechCoordinatorError {
            switch coordinatorError {
            case .credentialUnavailable:
                credentialState = .missing
                credentialErrorMessage = "Save a Groq API key to retry the preserved recording."
                isCredentialSetupPresented = true
            case .transcriptionFailed(.credentialRejected):
                credentialState = .unusable
                credentialErrorMessage = "Groq rejected this key. Save a different key before retrying."
                isCredentialSetupPresented = true
            default:
                break
            }
        } else if let sessionError = error as? InterviewRoomSessionError,
                  sessionError == .rejectedCredentialUnchanged {
            credentialState = .unusable
            credentialErrorMessage = "The rejected Groq key has not changed. Save a different key before retrying."
            isCredentialSetupPresented = true
        }
    }

    private func safeMessage(for error: Error) -> String {
        if let coordinatorError = error as? SegmentSpeechCoordinatorError {
            switch coordinatorError {
            case .noActiveSegment:
                return "No active recording was available to stop. The latest durable state is shown."
            case .segmentAudioUnavailable:
                return "The source recording is unavailable for this segment."
            case .captureFailed(.microphoneUnavailable),
                 .captureFailed(.captureStartFailed):
                return "The microphone did not start. Check macOS microphone access, then add a segment."
            case .captureFailed:
                return "Recording stopped with a capture failure. Any recoverable source evidence remains visible."
            case .credentialUnavailable:
                return "The source recording is saved. Add a Groq key, then retry its transcript."
            case .transcriptionFailed(.credentialRejected):
                return "The source recording is saved. Groq rejected the key; update it before retrying."
            case .transcriptionFailed(.providerUnavailable):
                return "The source recording is saved. Groq is unavailable; retry only when you choose."
            case .transcriptionFailed:
                return "The source recording is saved, but this transcript attempt failed."
            }
        }

        if let sessionError = error as? InterviewRoomSessionError {
            switch sessionError {
            case .rejectedCredentialUnchanged:
                return "The rejected Groq key has not changed. Save a different key before retrying."
            case .unresolvedSegmentsPreventHandOff:
                return "Retry or exclude every unresolved segment before Hand off. Recordings remain preserved."
            case .noTranscribedSegments:
                return "At least one selected transcript is required before Hand off."
            case .segmentHasInsufficientSignal:
                return "This recording has insufficient speech signal. Play it, then exclude it or add another segment."
            case .commandInProgress:
                return "Another durable room operation is still in progress."
            default:
                return "The room rejected this action. Its latest durable state is still shown."
            }
        }

        return "The operation did not complete. The latest durable state is still shown."
    }
}
