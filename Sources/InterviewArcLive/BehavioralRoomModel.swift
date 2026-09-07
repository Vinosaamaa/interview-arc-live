import Combine
import Foundation
import InterviewArcLiveCore
import InterviewArcLiveVoiceAdapter

@MainActor
final class BehavioralRoomModel: ObservableObject {
    static let hostedWritesUnavailableChip =
        "Local behavioral room · hosted writes not enabled"

    @Published private(set) var snapshot: InterviewRoomSnapshot?
    @Published private(set) var segments: [CandidateSegmentPresentation] = []
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = "Restoring local session…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var workSurface: BehavioralWorkSurface
    @Published var isCredentialSetupPresented = false
    @Published private(set) var isSavingCredential = false
    @Published private(set) var credentialErrorMessage: String?
    @Published private(set) var isCheckingInterviewer = false
    @Published private(set) var isInterviewerReady = false
    @Published private(set) var isFinishingInterview = false
    @Published private(set) var isInterviewerRequestInFlight = false

    let hostedWritesEnabled = false

    private static let tracerActivityPrompt: ActivityPrompt = {
        do {
            return try ActivityPrompt(
                specialty: .behavioral,
                stage: "Behavioral interview",
                question: BehavioralWorkSurface.question(for: .starBank),
                requestedParts: [
                    "Ask the primary question cold.",
                    "Leave evidence gaps visible.",
                    "Do not reveal a preferred answer before an attempt.",
                ]
            )
        } catch {
            preconditionFailure("The built-in Behavioral Activity Prompt must remain valid.")
        }
    }()

    private static let fallbackSessionID = SessionID("local-behavioral-tracer-v1")

    private enum CredentialState {
        case checking
        case missing
        case readyFromKeychain
        case readyUntilQuit
        case unusable
    }

    private let activityPrompt: ActivityPrompt
    private let credentialStore: LiveGroqCredentialStore
    private let interviewerRuntime: any InterviewerProvider
    private let recording: (any SegmentRecording)?
    private let transcriber: (any SegmentTranscribing)?
    private let manifestStore: (any SessionManifestStore)?
    private var credentialState: CredentialState = .checking
    private(set) var coordinator: SegmentSpeechCoordinator?
    private var commandSequence = 0

    init(
        credentialStore: LiveGroqCredentialStore = LiveGroqCredentialStore(),
        interviewerRuntime: (any InterviewerProvider)? = nil,
        activityPrompt: ActivityPrompt? = nil,
        initialCoordinator: SegmentSpeechCoordinator? = nil,
        recording: (any SegmentRecording)? = nil,
        transcriber: (any SegmentTranscribing)? = nil,
        manifestStore: (any SessionManifestStore)? = nil,
        workSurface: BehavioralWorkSurface = .preflightFixture()
    ) {
        self.credentialStore = credentialStore
        self.interviewerRuntime = interviewerRuntime ?? LiveInterviewerProviders.makeDefault()
        self.activityPrompt = activityPrompt ?? Self.tracerActivityPrompt
        self.recording = recording
        self.transcriber = transcriber
        self.manifestStore = manifestStore
        self.workSurface = workSurface
        coordinator = initialCoordinator
        if let initialCoordinator {
            publish(initialCoordinator.snapshot)
        } else {
            statusMessage = "Ready for a local Behavioral room"
        }
    }

    var question: String { workSurface.question }

    var activityPromptForPresentation: ActivityPrompt {
        snapshot?.activityPrompt ?? activityPrompt
    }

    var hostedAvailabilityChip: String { Self.hostedWritesUnavailableChip }

    var canEditNotes: Bool {
        snapshot?.phase != .completed && !isFinishingInterview
    }

    var turnMode: TurnMode { snapshot?.turnMode ?? .continuousConversation }

    var availableTurnModes: [TurnMode] { [.continuousConversation, .patientAuto, .manual] }

    var advancedTurnModes: [TurnMode] { [.patientAuto, .manual] }

    var canSelectTurnMode: Bool {
        guard !isWorking, let snapshot else { return false }
        return snapshot.phase != .completed
    }

    func turnModeTitle(_ mode: TurnMode) -> String {
        switch mode {
        case .continuousConversation: "Automatic"
        case .manual: "Manual"
        case .patientAuto: "Patient Auto"
        case .cueOnly: "Cue Only"
        }
    }

    func selectTurnMode(_ mode: TurnMode) async {
        guard let coordinator, canSelectTurnMode else { return }
        do {
            let updated = try await coordinator.setTurnMode(
                mode,
                commandID: commandID("set-turn-mode")
            )
            publish(updated)
        } catch {
            errorMessage = safeMessage(for: error)
        }
    }

    func selectQuestionFamily(_ family: BehavioralQuestionFamily) {
        workSurface.selectQuestionFamily(family)
        workSurface.question = BehavioralWorkSurface.question(for: family)
    }

    func selectWorkSurfacePane(_ pane: BehavioralWorkSurfacePane) {
        workSurface.selectPane(pane)
    }

    func selectStory(id: String) {
        workSurface.selectStory(id: id)
    }

    func selectProjectSection(_ sectionKey: String) {
        workSurface.selectProjectSection(sectionKey)
    }

    func selectResumeSection(_ sectionKey: String) {
        workSurface.selectResumeSection(sectionKey)
    }

    func beginCoachedDiscovery() {
        workSurface.beginCoachedDiscovery()
        statusMessage = "Coached discovery · explicit mode switch"
    }

    func returnToInterviewer() {
        workSurface.returnToInterviewer()
        statusMessage = status(for: snapshot)
    }

    func updateNotes(_ body: String) {
        guard canEditNotes else { return }
        workSurface.notes = body
        guard let coordinator else { return }
        do {
            let notes = try CandidateNotes(body: body)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let updated = try await coordinator.updateCandidateNotes(
                        notes,
                        commandID: self.commandID("notes")
                    )
                    self.publish(updated)
                } catch {
                    self.errorMessage = self.safeMessage(for: error)
                }
            }
        } catch {
            errorMessage = "Notes are limited to 16 KB. Shorten the text to continue."
        }
    }

    var canStopRecording: Bool { activeCaptureSegment != nil }

    var stopActionTitle: String {
        activeCaptureSegment?.lifecycle == .recording
            ? "Pause"
            : "Recover recording"
    }

    var stopActionIcon: String {
        activeCaptureSegment?.lifecycle == .recording
            ? "pause.fill"
            : "arrow.clockwise.circle.fill"
    }

    var showsRecordControl: Bool {
        guard snapshot?.phase == .candidateFloor, !canStopRecording else {
            return false
        }
        if snapshot?.turnMode == .continuousConversation {
            return !hasUsableGroqCredential
                || draftSegments.contains {
                    $0.lifecycle == .failed
                        || ($0.lifecycle == .audioReady && $0.selectedCandidate == nil)
                }
        }
        return true
    }

    var isFloorHeld: Bool { snapshot?.isFloorHeld == true }

    var showsHoldFloorControl: Bool {
        snapshot?.turnMode == .continuousConversation
            && snapshot?.phase == .candidateFloor
            && !showsRecordControl
    }

    var holdFloorTitle: String { isFloorHeld ? "Send answer" : "Hold floor" }

    var canToggleFloorHold: Bool {
        guard showsHoldFloorControl, !isWorking else { return false }
        if isFloorHeld {
            let unresolved = draftSegments.contains {
                $0.lifecycle != .excluded && $0.selectedCandidate == nil
            }
            let hasSelected = draftSegments.contains {
                $0.lifecycle != .excluded && $0.selectedCandidate != nil
            }
            return hasSelected && !unresolved
        }
        return true
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
        draftSegments.isEmpty ? "Record" : "Add segment"
    }

    var canAct: Bool {
        guard !isWorking, let snapshot else { return false }
        switch snapshot.phase {
        case .candidateFloor:
            if snapshot.turnMode == .continuousConversation {
                return false
            }
            let unresolved = draftSegments.contains {
                $0.lifecycle != .excluded && $0.selectedCandidate == nil
            }
            let hasSelected = draftSegments.contains {
                $0.lifecycle != .excluded && $0.selectedCandidate != nil
            }
            return isInterviewerReady && hasSelected && !unresolved
        case .interviewerProcessing:
            return isInterviewerReady
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

    var hostedPauseIsEnabled: Bool { false }

    var hostedFinishIsEnabled: Bool { false }

    var canFinishLocally: Bool {
        guard !isWorking, let snapshot else { return false }
        return snapshot.phase != .completed
    }

    var activeEndpointGrace: EndpointGrace? {
        snapshot?.endpointGraces.last { $0.lifecycle == .pending }
    }

    var canKeepFloor: Bool {
        activeEndpointGrace != nil && !isWorking
    }

    func open() async {
        guard coordinator == nil, !isWorking else { return }
        isWorking = true
        isCheckingInterviewer = true
        errorMessage = nil
        defer { isWorking = false }

        async let interviewerCheck = interviewerRuntime.preflight()
        await refreshCredentialReadiness(presentWhenMissing: false)

        do {
            let opened: SegmentSpeechCoordinator
            if let recording, let transcriber, let manifestStore {
                opened = try await SegmentSpeechCoordinator.open(
                    sessionID: Self.fallbackSessionID,
                    activityID: "local-behavioral-tracer",
                    activityPrompt: activityPrompt,
                    manifestStore: manifestStore,
                    interviewerRuntime: interviewerRuntime,
                    recording: recording,
                    transcriber: transcriber,
                    credentialReader: credentialStore,
                    semanticEndpointClassifier: GroqEndpointClassifier(
                        credentialReader: credentialStore
                    ),
                    acousticSegmenter: VoiceCoreAcousticSegmenter()
                )
            } else {
                opened = try await SegmentSpeechCoordinator.openLocal(
                    sessionID: Self.fallbackSessionID,
                    activityID: "local-behavioral-tracer",
                    activityPrompt: activityPrompt,
                    interviewerRuntime: interviewerRuntime,
                    recording: VoiceCoreSegmentRecorder(),
                    transcriber: VoiceCoreSegmentTranscriber(),
                    credentialReader: credentialStore,
                    semanticEndpointClassifier: GroqEndpointClassifier(
                        credentialReader: credentialStore
                    ),
                    acousticSegmenter: VoiceCoreAcousticSegmenter()
                )
            }
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
                errorMessage = "A recording recovery needs attention. Preserved evidence remains visible."
            }
            if restored.turnMode == .continuousConversation {
                await opened.enableContinuousListening()
            }
            if restored.phase == .ready {
                restored = try await opened.giveCandidateFloor(
                    commandID: CommandID("local-behavioral-give-floor-0")
                )
            }
            publish(restored)
        } catch {
            statusMessage = "Local session unavailable"
            errorMessage = safeMessage(for: error)
        }

        applyInterviewerReadiness(await interviewerCheck)
        isCheckingInterviewer = false
        if snapshot == nil {
            statusMessage = "Local Behavioral room · session engine did not open"
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
            errorMessage = safeMessage(for: error)
        }
    }

    func keepMyFloor() async {
        guard let coordinator, let grace = activeEndpointGrace else { return }
        do {
            let updated = try await coordinator.cancelEndpointGrace(
                graceID: grace.id,
                commandID: commandID("keep-floor")
            )
            publish(updated)
        } catch {
            publish(coordinator.snapshot)
            errorMessage = "Automatic Hand off could not be cancelled."
        }
    }

    func toggleFloorHold() async {
        guard let coordinator, canToggleFloorHold else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            if isFloorHeld {
                let updated = try await coordinator.sendAnswer(
                    commandID: commandID("send-answer"),
                    boardAttachment: .noBoard
                )
                publish(updated)
            } else {
                let updated = try await coordinator.activateFloorHold(
                    commandID: commandID("hold-floor")
                )
                publish(updated)
            }
        } catch {
            publish(coordinator.snapshot)
            errorMessage = safeMessage(for: error)
        }
    }

    func performPrimaryAction() async {
        guard let coordinator, let snapshot, canAct else { return }

        isWorking = true
        errorMessage = nil
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
                    commandID: commandID("hand-off"),
                    boardAttachment: .noBoard
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
        } catch {
            publish(coordinator.snapshot)
            errorMessage = safeMessage(for: error)
        }
    }

    @discardableResult
    func finishInterview() async -> Bool {
        guard canFinishLocally, let coordinator else { return false }
        isFinishingInterview = true
        isWorking = true
        errorMessage = nil
        statusMessage = "Ending local session…"
        defer {
            isWorking = false
            isFinishingInterview = false
            statusMessage = status(for: snapshot)
        }
        do {
            let updated = try await coordinator.finishSession(
                commandID: commandID("finish-interview")
            )
            publish(updated)
            return updated.phase == .completed
        } catch {
            publish(coordinator.snapshot)
            errorMessage = safeMessage(for: error)
            return false
        }
    }

    func prepareLocalPersistenceForTermination() async -> Bool {
        guard !isWorking else {
            errorMessage = "A room operation is still finishing. Quit was cancelled so it can complete safely."
            return false
        }
        return true
    }

    func presentCredentialSetup() {
        credentialErrorMessage = nil
        isCredentialSetupPresented = true
    }

    func saveGroqCredential(_ value: String) async -> Bool {
        await persistGroqCredential(value, untilQuit: false)
    }

    func useGroqCredentialUntilQuit(_ value: String) async -> Bool {
        await persistGroqCredential(value, untilQuit: true)
    }

    private func persistGroqCredential(
        _ value: String,
        untilQuit: Bool
    ) async -> Bool {
        guard !isSavingCredential else { return false }
        isSavingCredential = true
        credentialErrorMessage = nil
        defer { isSavingCredential = false }
        do {
            if untilQuit {
                try await credentialStore.useUntilQuit(value)
                credentialState = .readyUntilQuit
            } else {
                try await credentialStore.saveAndVerify(value)
                credentialState = .readyFromKeychain
            }
            isCredentialSetupPresented = false
            return true
        } catch {
            credentialErrorMessage = "The Groq key could not be saved."
            return false
        }
    }

    func checkInterviewer() async {
        guard !isCheckingInterviewer else { return }
        isCheckingInterviewer = true
        defer { isCheckingInterviewer = false }
        applyInterviewerReadiness(await interviewerRuntime.preflight())
    }

    var floorStatePresentation: FloorStatePresentation {
        let draftLifecycles = snapshot?.segments
            .filter { $0.committedTurnID == nil }
            .map(\.lifecycle) ?? []
        return FloorStatePresentation.make(
            input: FloorStatePresentation.Input(
                phase: snapshot?.phase,
                candidateSegmentLifecycles: draftLifecycles,
                candidateSegmentCount: segments.count,
                statusMessage: statusMessage,
                attentionMessage: errorMessage,
                isInterviewerRequestInFlight: isInterviewerRequestInFlight,
                isInterviewerReady: isInterviewerReady,
                canStopRecording: canStopRecording,
                roomAvailability: snapshot == nil ? .restoring : .ready,
                turnMode: snapshot?.turnMode ?? .continuousConversation,
                isFloorHeld: snapshot?.isFloorHeld == true,
                isCheckingAnswer: snapshot?.endpointEvaluations.last?.lifecycle == .authorized
                    || snapshot?.endpointGraces.contains(where: { $0.lifecycle == .pending }) == true
            )
        )
    }

    var compactPresentation: CompactRoomPresentation {
        CompactRoomPresentation.make(
            input: CompactRoomPresentation.Input(
                phase: snapshot?.phase,
                isWorking: isWorking,
                canStopRecording: canStopRecording,
                stopRecordingTitle: stopActionTitle,
                stopRecordingSystemImage: stopActionIcon,
                showsRecordControl: showsRecordControl,
                canRecordSegment: canRecordSegment,
                recordTitle: recordActionTitle,
                showsKeepFloor: activeEndpointGrace != nil
                    && snapshot?.turnMode != .continuousConversation,
                canKeepFloor: canKeepFloor,
                showsHoldFloor: showsHoldFloorControl,
                canToggleFloorHold: canToggleFloorHold,
                holdFloorTitle: holdFloorTitle,
                holdFloorSystemImage: isFloorHeld ? "paperplane.fill" : "hand.raised.fill",
                phaseActionTitle: actionTitle,
                phaseActionSystemImage: actionIcon,
                canPerformPhaseAction: canAct
            ),
            floorState: floorStatePresentation
        )
    }

    private var hasUsableGroqCredential: Bool {
        credentialState == .readyFromKeychain
            || credentialState == .readyUntilQuit
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
        self.snapshot = snapshot
        segments = snapshot.segments
            .filter { $0.committedTurnID == nil }
            .sorted { $0.ordinal < $1.ordinal }
            .map(CandidateSegmentPresentation.init(segment:))
        if workSurface.notes != snapshot.candidateNotes.body,
           !workSurface.notes.isEmpty {
            // Keep the latest typed notes when the snapshot is empty.
        } else if workSurface.notes.isEmpty {
            workSurface.notes = snapshot.candidateNotes.body
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
                if presentWhenMissing {
                    isCredentialSetupPresented = true
                }
            }
        } catch {
            credentialState = .unusable
        }
    }

    private func applyInterviewerReadiness(_ readiness: InterviewerReadiness) {
        isInterviewerReady = readiness == .ready
    }

    private func status(for snapshot: InterviewRoomSnapshot?) -> String {
        if workSurface.mode == .coachedDiscovery {
            return "Coached discovery · explicit mode switch"
        }
        guard let snapshot else { return "Restoring local session…" }
        switch snapshot.phase {
        case .candidateFloor:
            return canStopRecording ? "Recording segment" : "Ready to record"
        case .interviewerProcessing:
            return "Answer saved · interviewer working"
        case .interviewerTurn:
            return "Interviewer response saved"
        case .completed:
            return "Session complete"
        case .ready:
            return "Preparing candidate floor"
        }
    }

    private func commandID(_ operation: String) -> CommandID {
        commandSequence += 1
        return CommandID("behavioral-\(operation)-\(commandSequence)")
    }

    private func safeMessage(for error: Error) -> String {
        if let coordinatorError = error as? SegmentSpeechCoordinatorError {
            switch coordinatorError {
            case .noActiveSegment:
                return "No active recording was available to stop."
            case .segmentAudioUnavailable:
                return "The source recording is unavailable for this segment."
            case .captureFailed:
                return "The microphone did not start. Check macOS microphone access."
            case .credentialUnavailable:
                return "The source recording is saved. Add a Groq key, then retry."
            case .transcriptionFailed:
                return "The source recording is saved, but this transcript attempt failed."
            }
        }
        return "The operation did not complete. The latest durable state is still shown."
    }
}
