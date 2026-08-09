import AVFoundation
import Foundation
import InterviewArcLiveCore
import InterviewArcLiveCodexAdapter
import InterviewArcLiveQwenAdapter
import InterviewArcLiveSpeechOutputAdapter
import InterviewArcLiveVoiceAdapter

protocol LiveCodexInterviewerRuntime: InterviewerRuntime {
    func preflight() async -> CodexAppServerReadiness
}

extension CodexAppServerInterviewerRuntime: LiveCodexInterviewerRuntime {}

@MainActor
protocol LiveInterviewerSpeechMuteControlling: AnyObject {
    var isMuted: Bool { get }

    func setMuted(_ muted: Bool, commandID: CommandID) async throws
}

extension InterviewerSpeechCoordinator: LiveInterviewerSpeechMuteControlling {}

@MainActor
final class SystemDesignRoomModel: ObservableObject {
    @Published private(set) var snapshot: InterviewRoomSnapshot?
    @Published private(set) var segments: [CandidateSegmentPresentation] = []
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = "Restoring local session…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var codexReadiness: CodexAppServerReadiness?
    @Published private(set) var isCheckingCodex = false
    @Published private(set) var isInterviewerRequestInFlight = false
    @Published private(set) var speechReadiness: InterviewerSpeechReadiness = .notInstalled
    @Published private(set) var isSpeechMuted: Bool
    @Published private(set) var isSpeechModelActionInFlight = false
    @Published private(set) var isSpeechControlActionInFlight = false
    @Published private(set) var playingUtteranceID: InterviewerUtteranceID?
    @Published private(set) var speechErrorMessage: String?

    @Published var isCredentialSetupPresented = false
    @Published private(set) var isSavingCredential = false
    @Published private(set) var credentialErrorMessage: String?

    private static let tracerActivityPrompt: ActivityPrompt = {
        do {
            return try ActivityPrompt(
                specialty: .systemDesign,
                stage: "High-level design",
                question: "Design a global notification system.",
                requestedParts: [
                    "Clarify scope and requirements.",
                    "Propose the high-level architecture and data flow.",
                    "Explain delivery reliability and tradeoffs.",
                ]
            )
        } catch {
            preconditionFailure("The built-in Activity Prompt must remain valid.")
        }
    }()

    private enum CredentialState {
        case checking
        case missing
        case readyFromKeychain
        case readyUntilQuit
        case unusable
    }

    // The first prompt-bound manifest uses a new identity. Existing tracer
    // manifests remain untouched because they predate durable ActivityPrompt.
    private let sessionID = SessionID("local-system-design-tracer-v2")
    private let activityPrompt: ActivityPrompt
    private let credentialStore: LiveGroqCredentialStore
    private let codexRuntime: any LiveCodexInterviewerRuntime
    private let preferences: UserDefaults
    private var speechProvider: (any InterviewerSpeechProvider)?
    private var speechPlayer: (any InterviewerSpeechPlaying)?
    private var speechAudioStore: (any InterviewerSpeechAudioStoring)?
    private var credentialState: CredentialState = .checking
    private var errorWasCodexFailure = false
    private var coordinator: SegmentSpeechCoordinator?
    private var interviewerSpeechCoordinator: InterviewerSpeechCoordinator?
    private var speechMuteController: (any LiveInterviewerSpeechMuteControlling)?
    private var speechPreparationTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?

    private static let speechMutedPreferenceKey =
        "interviewArcLive.interviewerSpeechMuted"

    init(
        credentialStore: LiveGroqCredentialStore = LiveGroqCredentialStore(),
        codexRuntime: (any LiveCodexInterviewerRuntime)? = nil,
        activityPrompt: ActivityPrompt? = nil,
        speechProvider: (any InterviewerSpeechProvider)? = nil,
        speechPlayer: (any InterviewerSpeechPlaying)? = nil,
        speechAudioStore: (any InterviewerSpeechAudioStoring)? = nil,
        speechMuteController: (any LiveInterviewerSpeechMuteControlling)? = nil,
        preferences: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.codexRuntime = codexRuntime ?? Self.makeDefaultCodexRuntime()
        self.activityPrompt = activityPrompt ?? Self.tracerActivityPrompt
        self.speechProvider = speechProvider
        self.speechPlayer = speechPlayer
        self.speechAudioStore = speechAudioStore
        self.speechMuteController = speechMuteController
        self.preferences = preferences
        isSpeechMuted = preferences.bool(
            forKey: Self.speechMutedPreferenceKey
        )
    }

    var question: String {
        snapshot?.activityPrompt.question ?? activityPrompt.question
    }

    var isCodexReady: Bool {
        codexReadiness == .ready
    }

    var codexStatusTitle: String {
        if isCheckingCodex || codexReadiness == nil {
            return "Checking Codex"
        }
        switch codexReadiness {
        case .ready: return "Codex ready"
        case .missing: return "Codex not found"
        case .incompatible: return "Codex update required"
        case .unauthenticated: return "Codex sign-in required"
        case .transportFailure: return "Codex unavailable"
        case nil: return "Checking Codex"
        }
    }

    var codexStatusIcon: String {
        if isCheckingCodex || codexReadiness == nil {
            return "hourglass"
        }
        switch codexReadiness {
        case .ready: return "checkmark.circle.fill"
        case .missing: return "questionmark.circle.fill"
        case .incompatible: return "arrow.down.circle.fill"
        case .unauthenticated:
            return "person.crop.circle.badge.exclamationmark"
        case .transportFailure: return "exclamationmark.triangle.fill"
        case nil: return "hourglass"
        }
    }

    var codexAttentionMessage: String? {
        guard !isCheckingCodex else { return nil }
        switch codexReadiness {
        case .ready, nil:
            return nil
        case .missing:
            return "Install or update ChatGPT or Codex, then check again. Your recorded segments remain saved."
        case .incompatible(_, let requiredVersion):
            return "This build requires \(requiredVersion). Update ChatGPT or Codex, then check again."
        case .unauthenticated:
            return "Open ChatGPT or Codex and sign in, then check again. Your recorded segments remain saved."
        case .transportFailure:
            return "Codex could not complete its local readiness check. Check again; your interview draft is unchanged."
        }
    }

    var needsGroqCredential: Bool {
        credentialState == .missing || credentialState == .unusable
    }

    var speechReadinessPresentation: InterviewerSpeechReadinessPresentation {
        InterviewerSpeechReadinessPresentation.make(
            readiness: speechReadiness
        )
    }

    var isSpeechReady: Bool {
        speechReadiness == .ready
    }

    var canToggleSpeechMute: Bool {
        speechMuteController != nil
    }

    var canStartSpeechModelDownload: Bool {
        interviewerSpeechCoordinator != nil
            && speechPreparationTask == nil
            && !isSpeechModelActionInFlight
    }

    var showsSpeechMuteControl: Bool {
        speechMuteController != nil
    }

    func utterance(
        for turnID: TurnID
    ) -> InterviewerUtterance? {
        snapshot?.interviewerUtterances.first { $0.turnID == turnID }
    }

    func speechPresentation(
        for utterance: InterviewerUtterance
    ) -> InterviewerUtterancePresentation {
        InterviewerUtterancePresentation.make(
            utterance: utterance,
            isMuted: isSpeechMuted
        )
    }

    func isPlayingSpeech(
        for utteranceID: InterviewerUtteranceID
    ) -> Bool {
        playingUtteranceID == utteranceID
    }

    var availableTurnModes: [TurnMode] {
        [.manual, .patientAuto]
    }

    var turnMode: TurnMode {
        snapshot?.turnMode ?? .manual
    }

    var canSelectTurnMode: Bool {
        guard !isWorking, let snapshot else { return false }
        return snapshot.phase != .completed
    }

    func turnModeTitle(_ mode: TurnMode) -> String {
        switch mode {
        case .manual:
            return "Manual"
        case .patientAuto:
            return "Patient Auto · Shadow"
        case .cueOnly:
            return "Cue Only"
        }
    }

    var endpointShadowPresentation: EndpointShadowPresentation {
        guard let snapshot else {
            return EndpointShadowPresentation.make(
                turnMode: .manual,
                phase: nil,
                currentEvaluation: nil,
                hasSelectedDraft: false,
                hasUnresolvedDraft: false,
                hasStaleEvaluation: false
            )
        }

        let draftSegments = snapshot.segments.filter { $0.committedTurnID == nil }
        let includedDrafts = draftSegments
            .filter { $0.lifecycle != .excluded }
            .sorted { $0.ordinal < $1.ordinal }
        let hasUnresolvedDraft = includedDrafts.contains {
            $0.lifecycle == .captureAuthorized
                || $0.lifecycle == .recording
                || $0.lifecycle == .finalizationAuthorized
                || $0.lifecycle == .transcribing
                || $0.selectedCandidateID == nil
        }
        let selectedCandidateIDs = includedDrafts.compactMap(\.selectedCandidateID)
        let questionTurnID: TurnID? = snapshot.turns.reversed().lazy.compactMap { turn in
            guard case .interviewer(let interviewer) = turn else { return nil }
            return interviewer.id
        }.first
        let latestEvaluation = snapshot.endpointEvaluations.last
        let currentEvaluation = EndpointShadowPresentation.currentEvaluation(
            in: snapshot.endpointEvaluations,
            selectedCandidateIDs: selectedCandidateIDs,
            questionTurnID: questionTurnID,
            hasUnresolvedDraft: hasUnresolvedDraft
        )

        return EndpointShadowPresentation.make(
            turnMode: snapshot.turnMode,
            phase: snapshot.phase,
            currentEvaluation: currentEvaluation,
            hasSelectedDraft: !selectedCandidateIDs.isEmpty,
            hasUnresolvedDraft: hasUnresolvedDraft,
            hasStaleEvaluation: latestEvaluation != nil
                && currentEvaluation == nil
        )
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
            return isCodexReady && hasSelected && !unresolved
        case .interviewerProcessing:
            return isCodexReady
        case .interviewerTurn:
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
        isCheckingCodex = true
        errorMessage = nil
        errorWasCodexFailure = false
        defer { isWorking = false }

        async let codexCheck = codexRuntime.preflight()
        await refreshCredentialReadiness(presentWhenMissing: true)

        do {
            let opened = try await SegmentSpeechCoordinator.openLocal(
                sessionID: sessionID,
                activityID: "local-system-design-tracer",
                activityPrompt: activityPrompt,
                turnMode: .manual,
                interviewerRuntime: codexRuntime,
                recording: VoiceCoreSegmentRecorder(),
                transcriber: VoiceCoreSegmentTranscriber(),
                credentialReader: credentialStore,
                semanticEndpointClassifier: GroqEndpointClassifier(
                    credentialReader: credentialStore
                )
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
            await attachInterviewerSpeech(to: opened)
        } catch {
            statusMessage = "Local session unavailable"
            errorMessage = safeMessage(for: error)
        }

        applyCodexReadiness(await codexCheck)
        isCheckingCodex = false
    }

    func checkCodex() async {
        guard !isCheckingCodex else { return }
        isCheckingCodex = true
        defer { isCheckingCodex = false }

        applyCodexReadiness(await codexRuntime.preflight())
    }

    func selectTurnMode(_ mode: TurnMode) async {
        guard mode == .manual || mode == .patientAuto,
              mode != turnMode,
              canSelectTurnMode,
              let coordinator else {
            return
        }

        isWorking = true
        errorMessage = nil
        statusMessage = "Saving turn-taking mode…"
        defer { isWorking = false }

        do {
            let updated = try await coordinator.setTurnMode(
                mode,
                commandID: commandID("set-turn-mode")
            )
            publish(updated)
        } catch {
            publish(coordinator.snapshot)
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
        errorWasCodexFailure = false
        defer {
            isInterviewerRequestInFlight = false
            isWorking = false
            statusMessage = status(for: self.snapshot)
        }

        do {
            let updated: InterviewRoomSnapshot
            switch snapshot.phase {
            case .candidateFloor:
                isInterviewerRequestInFlight = true
                statusMessage = "Saving one ordered answer…"
                updated = try await coordinator.handOff(
                    commandID: commandID("hand-off")
                )
            case .interviewerProcessing:
                isInterviewerRequestInFlight = true
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
            await interviewerSpeechCoordinator?
                .observeNewlyPersistedSnapshot(updated)
        } catch {
            publish(coordinator.snapshot)
            errorWasCodexFailure = applyCodexFailure(error)
            errorMessage = safeMessage(for: error)
        }
    }

    func startSpeechModelDownload() {
        guard speechPreparationTask == nil,
              let interviewerSpeechCoordinator else {
            return
        }
        speechErrorMessage = nil
        isSpeechModelActionInFlight = true
        speechPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                speechPreparationTask = nil
                isSpeechModelActionInFlight = false
            }
            do {
                _ = try await interviewerSpeechCoordinator.prepareModel(
                    policy: .userAuthorizedDownload
                )
            } catch is CancellationError {
                _ = await interviewerSpeechCoordinator.refreshReadiness()
            } catch {
                speechErrorMessage = safeSpeechMessage(for: error)
                _ = await interviewerSpeechCoordinator.refreshReadiness()
            }
        }
    }

    func cancelSpeechModelDownload() {
        speechPreparationTask?.cancel()
    }

    func removeSpeechModel() async {
        guard speechPreparationTask == nil,
              !isSpeechModelActionInFlight,
              let interviewerSpeechCoordinator else {
            return
        }
        isSpeechModelActionInFlight = true
        speechErrorMessage = nil
        defer { isSpeechModelActionInFlight = false }
        do {
            _ = try await interviewerSpeechCoordinator.removeModel()
        } catch {
            speechErrorMessage = safeSpeechMessage(for: error)
            _ = await interviewerSpeechCoordinator.refreshReadiness()
        }
    }

    func toggleSpeechMute() async {
        guard let speechMuteController else { return }
        let next = !isSpeechMuted
        do {
            try await speechMuteController.setMuted(
                next,
                commandID: commandID(next ? "mute-speech" : "unmute-speech")
            )
        } catch {
            speechErrorMessage = safeSpeechMessage(for: error)
        }
        // Core applies the local mute state before it persists a stopped
        // active Attempt. Reconcile even when that durable write reports an
        // error so the toggle and preference never contradict audio output.
        isSpeechMuted = speechMuteController.isMuted
        preferences.set(
            isSpeechMuted,
            forKey: Self.speechMutedPreferenceKey
        )
        if isSpeechMuted {
            playingUtteranceID = nil
        }
    }

    func stopSpeech() async {
        guard let interviewerSpeechCoordinator else { return }
        do {
            try await interviewerSpeechCoordinator.stop(
                commandID: commandID("stop-speech")
            )
            playingUtteranceID = nil
        } catch {
            speechErrorMessage = safeSpeechMessage(for: error)
        }
    }

    func playSpeech(utteranceID: InterviewerUtteranceID) async {
        guard let interviewerSpeechCoordinator,
              !isSpeechMuted,
              !isSpeechControlActionInFlight else {
            return
        }
        isSpeechControlActionInFlight = true
        playingUtteranceID = utteranceID
        speechErrorMessage = nil
        defer {
            playingUtteranceID = nil
            isSpeechControlActionInFlight = false
        }
        do {
            try await interviewerSpeechCoordinator.play(
                utteranceID: utteranceID
            )
        } catch is CancellationError {
            // Stop or Mute intentionally releases playback immediately.
        } catch {
            speechErrorMessage = safeSpeechMessage(for: error)
        }
    }

    func retrySpeech(utteranceID: InterviewerUtteranceID) async {
        guard let interviewerSpeechCoordinator,
              isSpeechReady,
              !isSpeechMuted,
              !isSpeechControlActionInFlight else {
            return
        }
        isSpeechControlActionInFlight = true
        speechErrorMessage = nil
        defer { isSpeechControlActionInFlight = false }
        do {
            try await interviewerSpeechCoordinator.retry(
                utteranceID: utteranceID,
                commandID: commandID("retry-speech")
            )
        } catch {
            speechErrorMessage = safeSpeechMessage(for: error)
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

    private func attachInterviewerSpeech(
        to conversation: SegmentSpeechCoordinator
    ) async {
        do {
            let provider: any InterviewerSpeechProvider
            let player: any InterviewerSpeechPlaying
            let audioStore: any InterviewerSpeechAudioStoring

            if let injectedProvider = speechProvider,
               let injectedPlayer = speechPlayer,
               let injectedAudioStore = speechAudioStore {
                provider = injectedProvider
                player = injectedPlayer
                audioStore = injectedAudioStore
            } else {
                let liveAudioStore = LiveInterviewerSpeechAudioStore()
                provider = try QwenInterviewerSpeechProvider()
                player = AVAudioEngineInterviewerSpeechPlayer(
                    audioStore: liveAudioStore
                )
                audioStore = liveAudioStore
                speechProvider = provider
                speechPlayer = player
                speechAudioStore = audioStore
            }

            let speech = try await InterviewerSpeechCoordinator.attach(
                to: conversation,
                provider: provider,
                player: player,
                audioStore: audioStore,
                initiallyMuted: isSpeechMuted
            )
            interviewerSpeechCoordinator = speech
            speechMuteController = speech
            speech.setSnapshotHandler { [weak self, weak speech] next in
                guard let self,
                      let speech,
                      self.interviewerSpeechCoordinator === speech else {
                    return
                }
                self.publish(next)
            }
            speech.setReadinessHandler { [weak self, weak speech] next in
                guard let self,
                      let speech,
                      self.interviewerSpeechCoordinator === speech else {
                    return
                }
                self.speechReadiness = next
            }
            do {
                publish(try await speech.resumePendingWork())
            } catch {
                publish(speech.snapshot)
                speechErrorMessage = safeSpeechMessage(for: error)
            }
        } catch {
            speechReadiness = .unavailable(.storageFailure)
            speechErrorMessage = "Local interviewer voice could not start. The written interview remains fully usable."
        }
    }

    private static func makeDefaultCodexRuntime(
        fileManager: FileManager = .default
    ) -> any LiveCodexInterviewerRuntime {
        do {
            let root = try LivePaths.applicationSupportRoot(fileManager: fileManager)
            let workingDirectory = root.appendingPathComponent(
                "CodexRuntime",
                isDirectory: true
            )
            for directory in [root, workingDirectory] {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            }
            return CodexAppServerInterviewerRuntime(
                workingDirectoryURL: workingDirectory,
                model: CodexAppServerInterviewerRuntime.defaultInterviewerModel
            )
        } catch {
            return UnavailableLiveCodexRuntime()
        }
    }

    private func safeSpeechMessage(for error: Error) -> String {
        if let coordinatorError = error as? InterviewerSpeechCoordinatorError {
            switch coordinatorError {
            case .modelNotReady:
                return "Install and verify Mara’s local model before generating speech. The written turn is ready."
            case .muted:
                return "Mara is muted. Unmute before playing or generating speech."
            case .operationInProgress,
                 .playbackInProgress,
                 .modelPreparationInProgress:
                return "Another local speech operation is already running. Stop it before starting a new one."
            case .utteranceNotFound, .canonicalTurnNotFound:
                return "That written interviewer turn is safe, but its local speech record is unavailable."
            case .noSelectedAudio:
                return "No saved voice exists for this turn. Generate it explicitly when the model is ready."
            case .selectedAudioInvalid:
                return "The saved WAV no longer matches its durable receipt, so it was not played. Retry to create a new one."
            case .invalidProviderAudio, .providerFailed:
                return "Local speech generation failed. The written interviewer turn is unchanged."
            case .storageFailed:
                return "The private WAV could not be finalized. The written interviewer turn is unchanged."
            case .playbackFailed:
                return "Local audio output could not start. The written interviewer turn remains available."
            }
        }
        if error is CancellationError {
            return "The local speech operation was cancelled. No historical turn will play automatically."
        }
        return "Local interviewer speech did not complete. The written interview remains fully usable."
    }

    private func applyCodexReadiness(_ readiness: CodexAppServerReadiness) {
        codexReadiness = readiness
        if readiness == .ready, errorWasCodexFailure {
            errorMessage = nil
            errorWasCodexFailure = false
        }
        if snapshot != nil {
            statusMessage = status(for: snapshot)
        }
    }

    static func safeCodexFailureMessage(
        for error: CodexAppServerRuntimeError
    ) -> String {
        switch error {
        case .missing:
            "Your answer is saved. Install or update ChatGPT or Codex, check readiness, then retry the interviewer."
        case .incompatible(_, let requiredVersion):
            "Your answer is saved. This build requires \(requiredVersion); update Codex, check readiness, then retry."
        case .unauthenticated:
            "Your answer is saved. Sign in through ChatGPT or Codex, check readiness, then retry the interviewer."
        case .transportFailure:
            "Your answer is saved. Codex could not complete the local request; check readiness, then retry explicitly."
        case .protocolFailure:
            "Your answer is saved. The local Codex protocol failed; check readiness before an explicit retry."
        case .serverFailure:
            "Your answer is saved. Codex could not complete this interviewer turn; retry only when you choose."
        case .malformedFinalResponse:
            "Your answer is saved. Codex returned no usable interviewer response; nothing was added to the transcript."
        case .cancelled:
            "Your answer is saved. The Codex request was cancelled; retry only when you choose."
        }
    }

    @discardableResult
    private func applyCodexFailure(_ error: Error) -> Bool {
        guard let runtimeError = error as? CodexAppServerRuntimeError else {
            return false
        }
        switch runtimeError {
        case .missing:
            codexReadiness = .missing
        case .incompatible(let actualVersion, let requiredVersion):
            codexReadiness = .incompatible(
                actualVersion: actualVersion,
                requiredVersion: requiredVersion
            )
        case .unauthenticated:
            codexReadiness = .unauthenticated
        case .transportFailure:
            codexReadiness = .transportFailure
        case .protocolFailure,
             .serverFailure,
             .malformedFinalResponse,
             .cancelled:
            break
        }
        return true
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
            if isInterviewerRequestInFlight {
                return "Answer saved · Codex is preparing the next question"
            }
            return isCodexReady
                ? "Answer saved · interviewer retry available"
                : "Answer saved · check Codex to retry"
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
        if let runtimeError = error as? CodexAppServerRuntimeError {
            return Self.safeCodexFailureMessage(for: runtimeError)
        }

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
            case .invalidInterviewerResponse:
                return "Your answer is saved. No usable interviewer response was added to the transcript."
            case .candidateTranscriptTooLong:
                return "Your answer draft remains local. Shorten or split it before Hand off."
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

private actor UnavailableLiveCodexRuntime: LiveCodexInterviewerRuntime {
    func preflight() async -> CodexAppServerReadiness {
        .transportFailure
    }

    func respond(
        to request: InterviewerRequest
    ) async throws -> CanonicalInterviewerResponse {
        throw CodexAppServerRuntimeError.transportFailure
    }
}
