import AVFoundation
import Combine
import CryptoKit
import Foundation
import InterviewArcLiveCore
import InterviewArcLiveHostedClient
import InterviewArcLiveLocalSpeechAdapter
import InterviewArcLiveSpeechOutputAdapter
import InterviewArcLiveVoiceAdapter

@MainActor
protocol LiveInterviewerSpeechMuteControlling: AnyObject {
    var isMuted: Bool { get }

    func setMuted(_ muted: Bool, commandID: CommandID) async throws
}

extension InterviewerSpeechCoordinator: LiveInterviewerSpeechMuteControlling {}

@MainActor
struct LiveInterviewerSpeechDependencies {
    let provider: any InterviewerSpeechProvider
    let player: any InterviewerSpeechPlaying
    let audioStore: any InterviewerSpeechAudioStoring
}

enum BoardRevisionStatusPresentation: Equatable, Sendable {
    case savingRevision
    case error(String)
    case draftNotSaved
    case unsaved
    case unsavedChanges(revision: Int)
    case saved(revision: Int)
    case viewing(revision: Int)

    var fullText: String {
        switch self {
        case .savingRevision: "Saving revision…"
        case .error(let message): message
        case .draftNotSaved: "Draft not saved"
        case .unsaved: "Unsaved board"
        case .unsavedChanges(let revision):
            "Unsaved changes · revision \(revision)"
        case .saved(let revision):
            "Board saved · revision \(revision)"
        case .viewing(let revision):
            "Viewing revision \(revision) · read-only"
        }
    }

    var compactText: String {
        switch self {
        case .savingRevision: "Saving revision…"
        case .error: "Board issue"
        case .draftNotSaved: "Draft unsaved"
        case .unsaved: "Unsaved"
        case .unsavedChanges(let revision): "Unsaved · r\(revision)"
        case .saved(let revision): "Saved · r\(revision)"
        case .viewing(let revision): "Viewing r\(revision) · locked"
        }
    }
}

enum SystemDesignWorkSurfacePane: String, CaseIterable, Identifiable, Sendable {
    case board
    case brief
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .board: "Board"
        case .brief: "Brief"
        case .notes: "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .board: "square.grid.2x2"
        case .brief: "doc.text"
        case .notes: "note.text"
        }
    }
}

enum CandidateNotesSavePresentation: Equatable, Sendable {
    case saved
    case saving
    case error(String)

    var text: String {
        switch self {
        case .saved: "Saved locally"
        case .saving: "Saving notes…"
        case .error(let message): message
        }
    }
}

@MainActor
final class SystemDesignRoomModel: ObservableObject {
    let enhancedBoardBridgeController = ExcalidrawBoardBridgeController()

    @Published private(set) var snapshot: InterviewRoomSnapshot?
    @Published private(set) var segments: [CandidateSegmentPresentation] = []
    @Published private(set) var isWorking = false {
        didSet {
            if !isWorking {
                startCandidateNotesPersistenceIfNeeded()
            }
        }
    }
    @Published private(set) var statusMessage = "Restoring local session…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var interviewerReadiness: InterviewerReadiness?
    @Published private(set) var isCheckingInterviewer = false
    @Published private(set) var isInterviewerRequestInFlight = false
    @Published private(set) var speechReadiness: InterviewerSpeechReadiness = .notInstalled
    @Published private(set) var isSpeechMuted: Bool
    @Published private(set) var selectedSpeechEngine: LocalSpeechEngine
    @Published private(set) var isSwitchingSpeechEngine = false
    @Published private(set) var isSpeechModelActionInFlight = false
    @Published private(set) var isSpeechControlActionInFlight = false
    @Published private(set) var playingUtteranceID: InterviewerUtteranceID?
    @Published private(set) var speechErrorMessage: String?
    @Published private(set) var boardEditor = BoardEditorState(document: .empty)
    @Published private(set) var isBoardSaving = false
    @Published private(set) var isBoardRevisionSaving = false
    @Published private(set) var isBoardExporting = false
    @Published private(set) var boardErrorMessage: String?
    @Published private(set) var boardExportMessage: String?
    @Published private(set) var inspectedBoardRevisionID: BoardRevisionID?
    @Published private(set) var hostedSnapshot = HostedPracticeSnapshot(
        connection: .signedOut
    )
    @Published var isLiveIntegrationSetupPresented = false
    @Published private(set) var selectedWorkSurface: SystemDesignWorkSurfacePane = .board
    @Published private(set) var candidateNotesDraft = ""
    @Published private(set) var candidateNotesSavePresentation: CandidateNotesSavePresentation = .saved
    @Published private(set) var isFinishingInterview = false
    @Published private(set) var recordingPowerHistory: [Float] = []
    @Published private(set) var recordingElapsedSeconds: TimeInterval = 0

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
    private static let fallbackSessionID = SessionID("local-system-design-tracer-v2")
    private let activityPrompt: ActivityPrompt
    private let credentialStore: LiveGroqCredentialStore
    private let interviewerRuntime: any InterviewerProvider
    private let speechDependencies: LiveInterviewerSpeechDependencies?
    private let preferences: UserDefaults
    private let speechProviderFactory: (LocalSpeechEngine) throws -> any InterviewerSpeechProvider
    private static let speechEnginePreferenceKey = "live.interviewer-speech.engine"
    private var boardArtifactStore: PrivateBoardArtifactStore?
    private let boardRenderer: DeterministicBoardRenderer
    private let hostedController: HostedPracticeController?
    private var hostedSnapshotObservation: AnyCancellable?
    private var credentialState: CredentialState = .checking
    private var errorWasInterviewerFailure = false
    private var coordinator: SegmentSpeechCoordinator?
    private var segmentRecorder: VoiceCoreSegmentRecorder?
    private var interviewerSpeechCoordinator: InterviewerSpeechCoordinator?
    private var speechPreparationTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var localPersistenceTail: Task<Void, Never>?
    private var localPersistenceGeneration = 0
    private var pendingBoardWriteCount = 0
    private var didLoadInitialBoard = false
    private var candidateNotesPersistenceTask: Task<Void, Never>?
    private var pendingCandidateNotes: CandidateNotes?
    private var didLoadInitialCandidateNotes = false

    private static let speechMutedPreferenceKey =
        "interviewArcLive.interviewerSpeechMuted"
    private static let workSurfacePreferenceKey =
        "interviewArcLive.systemDesignWorkSurface"

    init(
        credentialStore: LiveGroqCredentialStore = LiveGroqCredentialStore(),
        interviewerRuntime: (any InterviewerProvider)? = nil,
        activityPrompt: ActivityPrompt? = nil,
        speechDependencies: LiveInterviewerSpeechDependencies? = nil,
        preferences: UserDefaults = .standard,
        speechProviderFactory: @escaping (LocalSpeechEngine) throws -> any InterviewerSpeechProvider = {
            try LocalInterviewerSpeechProvider(engine: $0)
        },
        initialCoordinator: SegmentSpeechCoordinator? = nil,
        boardArtifactStore: PrivateBoardArtifactStore? = nil,
        boardRenderer: DeterministicBoardRenderer = DeterministicBoardRenderer(),
        hostedController: HostedPracticeController? = nil
    ) {
        self.credentialStore = credentialStore
        self.interviewerRuntime = interviewerRuntime ?? LiveInterviewerProviders.makeDefault()
        self.activityPrompt = activityPrompt ?? Self.tracerActivityPrompt
        self.speechDependencies = speechDependencies
        self.preferences = preferences
        self.speechProviderFactory = speechProviderFactory
        selectedSpeechEngine = LocalSpeechEngine(
            rawValue: preferences.string(forKey: Self.speechEnginePreferenceKey) ?? ""
        ) ?? .qwen
        self.boardArtifactStore = boardArtifactStore
        self.boardRenderer = boardRenderer
        self.hostedController = hostedController
        coordinator = initialCoordinator
        isSpeechMuted = preferences.bool(
            forKey: Self.speechMutedPreferenceKey
        )
        selectedWorkSurface = SystemDesignWorkSurfacePane(
            rawValue: preferences.string(forKey: Self.workSurfacePreferenceKey) ?? ""
        ) ?? .board
        if let initialCoordinator {
            publish(initialCoordinator.snapshot)
        }
        if let hostedController {
            hostedSnapshot = hostedController.snapshot
            hostedSnapshotObservation = hostedController.$snapshot.sink {
                [weak self] snapshot in
                self?.hostedSnapshot = snapshot
            }
        }
    }

    var question: String {
        hostedSnapshot.question
            ?? snapshot?.activityPrompt.question
            ?? activityPrompt.question
    }

    var hostedConnectionTitle: String {
        switch hostedSnapshot.connection {
        case .signedOut: "Connect Interview Arc"
        case .loading: "Syncing Interview Arc"
        case .noOpenSystemDesignActivity: "No System Design activity"
        case .readOnly: "Hosted read-only"
        case .writable: "Hosted and writable"
        case .offline: "Hosted offline"
        case .recoveryRequired: "Hosted recovery required"
        }
    }

    var isHostedWritable: Bool {
        hostedController == nil || hostedSnapshot.connection == .writable
    }

    var usesHostedAuthority: Bool { hostedController != nil }

    var hostedTimerIsRunning: Bool {
        hostedSnapshot.activity?.activity.timer?.runningSince != nil
            && hostedSnapshot.activity?.activity.timer?.completed == false
    }

    var hostedElapsedText: String? {
        hostedElapsedText(at: Date())
    }

    func hostedElapsedText(at date: Date) -> String? {
        guard let timer = hostedSnapshot.activity?.activity.timer else {
            return nil
        }
        let hasLiveRun = timer.runningSince != nil && timer.completed == false
        let hasAccumulatedTime = timer.accumulatedSeconds > 0.5
        guard hasLiveRun || hasAccumulatedTime || timer.completed else {
            return nil
        }
        guard let seconds = hostedSnapshot.elapsedSeconds(
            localNow: LiveEpochMilliseconds(
                (date.timeIntervalSince1970 * 1_000).rounded()
            )
        ) else { return nil }
        return FullRoomHostedTimerLayout.elapsedText(seconds: seconds)
    }

    var hostedResult: LiveResult? {
        hostedSnapshot.activity?.activity.result.value
    }

    var hostedPairs: [LivePair] { hostedSnapshot.activity?.pairs ?? [] }

    /// Local-only Opening Turn. Hosted pairs stay candidate-then-interviewer.
    var localOpeningInterviewerTurn: InterviewerTurn? {
        guard case .interviewer(let opening)? = snapshot?.turns.first,
              opening.replyToTurnID == nil else {
            return nil
        }
        return opening
    }

    var hostedNextSystemDesignActivityID: String? {
        guard let today = hostedSnapshot.today,
              let current = hostedSnapshot.activity?.activity,
              let sessionID = current.sessionId,
              let session = today.sessions.first(where: { $0.id == sessionID }),
              let currentIndex = session.activityIds.firstIndex(of: current.id) else {
            return nil
        }
        let remainingIDs = session.activityIds.dropFirst(currentIndex + 1)
        return remainingIDs.first { activityID in
            today.activities.contains {
                $0.id == activityID
                    && $0.type == .systemDesign
                    && $0.lifecycle != .completed
            }
        }
    }

    var activityPromptForPresentation: ActivityPrompt {
        snapshot?.activityPrompt ?? activityPrompt
    }

    var canEditCandidateNotes: Bool {
        guard let snapshot else { return false }
        return snapshot.phase != .completed && !isFinishingInterview
    }

    private var hasPendingLocalPersistence: Bool {
        isBoardSaving
            || candidateNotesPersistenceTask != nil
            || pendingCandidateNotes != nil
    }

    func selectWorkSurface(_ pane: SystemDesignWorkSurfacePane) {
        guard snapshot != nil else { return }
        selectedWorkSurface = pane
        preferences.set(pane.rawValue, forKey: Self.workSurfacePreferenceKey)
    }

    func updateCandidateNotesDraft(_ body: String) {
        guard canEditCandidateNotes else { return }
        do {
            let notes = try CandidateNotes(body: body)
            candidateNotesDraft = body
            pendingCandidateNotes = notes
            candidateNotesSavePresentation = .saving
            startCandidateNotesPersistenceIfNeeded()
        } catch {
            candidateNotesSavePresentation = .error(
                "Notes are limited to 16 KB. Shorten the text to continue saving."
            )
        }
    }

    func retryCandidateNotesSave() {
        guard canEditCandidateNotes else { return }
        guard let notes = try? CandidateNotes(body: candidateNotesDraft) else {
            return
        }
        pendingCandidateNotes = notes
        candidateNotesSavePresentation = .saving
        startCandidateNotesPersistenceIfNeeded()
    }

    func waitForCandidateNotesPersistence() async {
        await waitForLocalPersistence()
    }

    var interviewerProviderName: String { interviewerRuntime.providerName }

    var isInterviewerReady: Bool {
        interviewerReadiness == .ready
    }

    var interviewerStatusTitle: String {
        if isCheckingInterviewer || interviewerReadiness == nil {
            return "Checking \(interviewerProviderName)"
        }
        switch interviewerReadiness {
        case .ready: return "\(interviewerProviderName) ready"
        case .missing: return "\(interviewerProviderName) not found"
        case .unauthenticated: return "\(interviewerProviderName) sign-in required"
        case .transportFailure: return "\(interviewerProviderName) unavailable"
        case nil: return "Checking \(interviewerProviderName)"
        }
    }

    var interviewerStatusIcon: String {
        if isCheckingInterviewer || interviewerReadiness == nil {
            return "hourglass"
        }
        switch interviewerReadiness {
        case .ready: return "checkmark.circle.fill"
        case .missing: return "questionmark.circle.fill"
        case .unauthenticated:
            return "person.crop.circle.badge.exclamationmark"
        case .transportFailure: return "exclamationmark.triangle.fill"
        case nil: return "hourglass"
        }
    }

    var interviewerAttentionMessage: String? {
        guard !isCheckingInterviewer else { return nil }
        switch interviewerReadiness {
        case .ready, nil:
            return nil
        case .missing:
            return "Install or configure \(interviewerProviderName), then check again. Your recorded segments remain saved."
        case .unauthenticated:
            return "Open \(interviewerProviderName) and sign in, then check again. Your recorded segments remain saved."
        case .transportFailure:
            return "\(interviewerProviderName) could not complete its readiness check. Check again; your interview draft is unchanged."
        }
    }

    var needsGroqCredential: Bool {
        credentialState == .missing || credentialState == .unusable
    }

    var speechReadinessPresentation: InterviewerSpeechReadinessPresentation {
        InterviewerSpeechReadinessPresentation.make(
            readiness: speechReadiness,
            engineName: selectedSpeechEngine.displayName,
            downloadSize: selectedSpeechEngine.downloadSizeLabel,
            minimumFreeSpace: selectedSpeechEngine.minimumFreeSpaceLabel
        )
    }

    var isSpeechReady: Bool {
        speechReadiness == .ready
    }

    var canToggleSpeechMute: Bool {
        interviewerSpeechCoordinator != nil
    }

    var canStartSpeechModelDownload: Bool {
        interviewerSpeechCoordinator != nil
            && speechPreparationTask == nil
            && !isSpeechModelActionInFlight
    }

    var showsSpeechMuteControl: Bool {
        interviewerSpeechCoordinator != nil
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
        [.continuousConversation, .patientAuto, .manual]
    }

    var advancedTurnModes: [TurnMode] {
        [.patientAuto, .manual]
    }

    var turnMode: TurnMode {
        snapshot?.turnMode ?? .continuousConversation
    }

    var canSelectTurnMode: Bool {
        guard !isWorking,
              !hasPendingLocalPersistence,
              let snapshot else { return false }
        return snapshot.phase != .completed
    }

    func turnModeTitle(_ mode: TurnMode) -> String {
        switch mode {
        case .continuousConversation:
            return "Automatic"
        case .manual:
            return "Manual"
        case .patientAuto:
            return "Patient Auto"
        case .cueOnly:
            return "Cue Only"
        }
    }

    var isFloorHeld: Bool {
        snapshot?.isFloorHeld == true
    }

    var showsHoldFloorControl: Bool {
        snapshot?.turnMode == .continuousConversation
            && snapshot?.phase == .candidateFloor
            && !showsManualCaptureRecovery
    }

    var holdFloorTitle: String {
        isFloorHeld ? "Send answer" : "Hold floor"
    }

    var holdFloorSystemImage: String {
        isFloorHeld ? "paperplane.fill" : "hand.raised.fill"
    }

    var canToggleFloorHold: Bool {
        guard showsHoldFloorControl,
              !isWorking,
              !hasPendingLocalPersistence,
              isHostedWritable else { return false }
        if isFloorHeld {
            let unresolved = draftSegments.contains {
                $0.lifecycle != .excluded && $0.selectedCandidate == nil
            }
            let hasSelected = draftSegments.contains {
                $0.lifecycle != .excluded && $0.selectedCandidate != nil
            }
            return hasSelected && !unresolved && boardAttachmentForHandOff != nil
        }
        return true
    }

    var showsManualCaptureRecovery: Bool {
        guard snapshot?.turnMode == .continuousConversation else { return false }
        if !hasUsableGroqCredential { return true }
        return draftSegments.contains {
            $0.lifecycle == .failed
                || ($0.lifecycle == .audioReady && $0.selectedCandidate == nil)
        }
    }

    var activeEndpointGrace: EndpointGrace? {
        snapshot?.endpointGraces.last { $0.lifecycle == .pending }
    }

    var canKeepFloor: Bool {
        canKeepFloor(pendingGrace: activeEndpointGrace)
    }

    func canKeepFloor(pendingGrace: EndpointGrace?) -> Bool {
        pendingGrace != nil
            && !isWorking
            && !hasPendingLocalPersistence
    }

    var endpointHandoffPresentation: EndpointHandoffPresentation {
        guard let snapshot else {
            return EndpointHandoffPresentation.make(
                input: EndpointHandoffPresentation.Input(
                    turnMode: .continuousConversation,
                    phase: nil,
                    currentEvaluation: nil,
                    endpointGrace: nil,
                    canAutomaticallyHandOff: false,
                    hasSelectedDraft: false,
                    hasUnresolvedDraft: false,
                    hasStaleEvaluation: false
                )
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
        let currentEvaluation = EndpointHandoffPresentation.currentEvaluation(
            in: snapshot.endpointEvaluations,
            selectedCandidateIDs: selectedCandidateIDs,
            questionTurnID: questionTurnID,
            hasUnresolvedDraft: hasUnresolvedDraft
        )
        let currentGrace = currentEvaluation.flatMap { evaluation in
            snapshot.endpointGraces.last { $0.evaluationID == evaluation.id }
        }

        return EndpointHandoffPresentation.make(
            input: EndpointHandoffPresentation.Input(
                turnMode: snapshot.turnMode,
                phase: snapshot.phase,
                currentEvaluation: currentEvaluation,
                endpointGrace: currentGrace,
                canAutomaticallyHandOff: boardAttachmentForHandOff != nil,
                hasSelectedDraft: !selectedCandidateIDs.isEmpty,
                hasUnresolvedDraft: hasUnresolvedDraft,
                hasStaleEvaluation: latestEvaluation != nil
                    && currentEvaluation == nil
            )
        )
    }

    var boardDocumentForPresentation: BoardDocument {
        if let inspectedBoardRevisionID,
           let revision = snapshot?.board.revisions.first(where: {
               $0.id == inspectedBoardRevisionID
           }) {
            return revision.document
        }
        return boardEditor.document
    }

    var boardSelectedElementIDForPresentation: BoardElementID? {
        guard !isInspectingBoardRevision,
              let selectedElementID = boardEditor.selectedElementID,
              boardDocumentForPresentation.elements.contains(where: {
                  $0.boardID == selectedElementID
              }) else {
            return nil
        }
        return selectedElementID
    }

    var isInspectingBoardRevision: Bool {
        inspectedBoardRevisionID != nil
    }

    var inspectedBoardRevision: BoardRevision? {
        guard let inspectedBoardRevisionID else { return nil }
        return snapshot?.board.revisions.first {
            $0.id == inspectedBoardRevisionID
        }
    }

    var latestBoardRevision: BoardRevision? {
        snapshot?.board.revisions.last
    }

    var selectedBoardRevision: BoardRevision? {
        let selectedID = inspectedBoardRevisionID
            ?? snapshot?.board.selectedRevisionID
        return snapshot?.board.revisions.first { $0.id == selectedID }
            ?? latestBoardRevision
    }

    var boardRevisionStatusPresentation: BoardRevisionStatusPresentation {
        if let boardErrorMessage { return .error(boardErrorMessage) }
        if let inspectedBoardRevision {
            return .viewing(revision: inspectedBoardRevision.ordinal + 1)
        }
        if isBoardRevisionSaving { return .savingRevision }
        guard let latestBoardRevision else {
            return boardEditor.document.elements.isEmpty
                ? .draftNotSaved
                : .unsaved
        }
        let revision = latestBoardRevision.ordinal + 1
        if boardEditor.document != latestBoardRevision.document {
            return .unsavedChanges(revision: revision)
        }
        return .saved(revision: revision)
    }

    var boardRevisionStatus: String {
        boardRevisionStatusPresentation.fullText
    }

    var isBoardDraftDirty: Bool {
        guard let latestBoardRevision else { return true }
        return boardEditor.document != latestBoardRevision.document
    }

    var boardAttachmentForHandOff: CandidateTurnBoardAttachment? {
        if let inspectedBoardRevisionID {
            guard snapshot?.board.revisions.contains(where: {
                $0.id == inspectedBoardRevisionID
            }) == true else {
                return nil
            }
            return .revision(inspectedBoardRevisionID)
        }
        guard let snapshot else { return nil }
        let board = BoardWorkspace(
            draft: boardEditor.document,
            revisions: snapshot.board.revisions,
            selectedRevisionID: snapshot.board.selectedRevisionID,
            exports: snapshot.board.exports
        )
        return BoardHandoffAttachmentPolicy.currentDraftAttachment(in: board)
    }

    var canSaveBoardRevision: Bool {
        Self.boardRevisionSaveIsAvailable(
            coordinatorIsAvailable: coordinator != nil,
            phase: snapshot?.phase,
            isWorking: isWorking,
            isInspectingRevision: isInspectingBoardRevision,
            isRevisionSaving: isBoardRevisionSaving,
            isExporting: isBoardExporting
        )
    }

    static func boardRevisionSaveIsAvailable(
        coordinatorIsAvailable: Bool,
        phase: InterviewRoomPhase?,
        isWorking: Bool,
        isInspectingRevision: Bool,
        isRevisionSaving: Bool,
        isExporting: Bool
    ) -> Bool {
        coordinatorIsAvailable
            && phase != nil
            && phase != .completed
            && !isWorking
            && !isInspectingRevision
            && !isRevisionSaving
            && !isExporting
    }

    var canAttachBoardRevision: Bool {
        guard snapshot?.phase != .completed,
              selectedBoardRevision != nil else { return false }
        return snapshot?.turns.reversed().contains { turn in
            guard case .candidate(let candidate) = turn else { return false }
            return candidate.boardAttachment == .noBoard
        } == true
    }

    var canExportBoardRevision: Bool {
        guard selectedBoardRevision != nil else { return false }
        if isInspectingBoardRevision { return true }
        return selectedBoardRevision?.document == boardEditor.document
    }

    @discardableResult
    func applyBoardAction(_ action: BoardEditorAction) -> Bool {
        guard coordinator != nil, snapshot != nil else {
            boardErrorMessage = "Wait for the local room to finish restoring before editing."
            return false
        }
        if isInspectingBoardRevision {
            switch action {
            case .setZoom(_), .resetZoom:
                break
            default:
                boardErrorMessage = "Return to the draft before editing."
                return false
            }
        }

        do {
            var updated = boardEditor
            if case .replaceDocument(_, let requestedSelection) = action {
                ExcalidrawBoardDiagnostics.record(
                    kind: "board-replace-before",
                    fields: [
                        "requestedHasSelection": requestedSelection != nil,
                        "modelHasSelection": boardEditor.selectedElementID != nil,
                        "selectionMatches": requestedSelection
                            == boardEditor.selectedElementID,
                    ]
                )
            }
            let mutation = try updated.applyReportingMutation(action)
            boardEditor = updated
            if case .replaceDocument(_, let requestedSelection) = action {
                ExcalidrawBoardDiagnostics.record(
                    kind: "board-replace-after",
                    fields: [
                        "requestedHasSelection": requestedSelection != nil,
                        "modelHasSelection": boardEditor.selectedElementID != nil,
                        "selectionMatches": requestedSelection
                            == boardEditor.selectedElementID,
                        "documentChanged": mutation.documentChanged,
                    ]
                )
            }
            boardErrorMessage = nil
            if mutation.documentChanged {
                persistBoardDraft(updated.document)
            }
            return mutation.documentChanged
        } catch {
            boardErrorMessage = "That board change is outside the supported canvas bounds."
            return false
        }
    }

    func waitForBoardPersistence() async {
        await waitForLocalPersistence()
    }

    func prepareLocalPersistenceForTermination() async -> Bool {
        guard !isWorking else {
            candidateNotesSavePresentation = .error(
                "A room operation is still finishing. Quit was cancelled so it can complete safely."
            )
            return false
        }

        guard await enhancedBoardBridgeController.flushPendingScene() else {
            boardErrorMessage = "The latest canvas edit could not be confirmed. Quit was cancelled so you can retry."
            return false
        }

        startCandidateNotesPersistenceIfNeeded()
        await waitForLocalPersistence()

        guard pendingCandidateNotes == nil,
              candidateNotesPersistenceTask == nil,
              pendingBoardWriteCount == 0 else {
            candidateNotesSavePresentation = .error(
                "The latest local changes are still saving. Quit was cancelled so you can retry."
            )
            return false
        }
        guard let coordinator else { return snapshot == nil }
        guard coordinator.snapshot.board.draft == boardEditor.document else {
            boardErrorMessage = "The latest Board edit is not durable yet. Quit was cancelled so you can retry."
            return false
        }
        guard coordinator.snapshot.candidateNotes.body == candidateNotesDraft else {
            candidateNotesSavePresentation = .error(
                "The latest Notes text is not durable yet. Quit was cancelled so you can retry."
            )
            return false
        }
        return true
    }

    func saveBoardRevision() async {
        guard canSaveBoardRevision,
              let coordinator else { return }
        isBoardRevisionSaving = true
        beginBoardWork()
        boardErrorMessage = nil
        defer {
            endBoardWork()
            isBoardRevisionSaving = false
        }

        await waitForBoardPersistence()
        guard coordinator.snapshot.board.draft == boardEditor.document else {
            boardErrorMessage = "The latest board draft was not saved. Try Save revision again."
            return
        }
        do {
            let updated = try await coordinator.saveBoardRevision(
                commandID: commandID("save-board-revision")
            )
            publish(updated)
            inspectedBoardRevisionID = nil
        } catch {
            publish(coordinator.snapshot)
            boardErrorMessage = "The board revision could not be saved. Your editable draft remains available."
        }
    }

    func inspectBoardRevision(_ revisionID: BoardRevisionID) async {
        guard !hasPendingLocalPersistence,
              let coordinator,
              snapshot?.board.revisions.contains(where: { $0.id == revisionID }) == true else {
            boardErrorMessage = "That saved board revision is unavailable."
            return
        }
        do {
            let updated = try await coordinator.selectBoardRevision(
                revisionID,
                commandID: commandID("select-board-revision")
            )
            publish(updated)
            inspectedBoardRevisionID = revisionID
            boardErrorMessage = nil
        } catch {
            publish(coordinator.snapshot)
            boardErrorMessage = "That saved board revision could not be opened."
        }
    }

    func returnToBoardDraft() async {
        guard !hasPendingLocalPersistence else { return }
        guard let coordinator else {
            inspectedBoardRevisionID = nil
            return
        }
        do {
            let updated = try await coordinator.selectBoardRevision(
                nil,
                commandID: commandID("return-to-board-draft")
            )
            publish(updated)
            inspectedBoardRevisionID = nil
            boardErrorMessage = nil
        } catch {
            publish(coordinator.snapshot)
            boardErrorMessage = "The editable board draft could not be reopened."
        }
    }

    func attachSelectedBoardRevision() async {
        guard !hasPendingLocalPersistence,
              let coordinator,
              let revision = selectedBoardRevision,
              let turn = snapshot?.turns.reversed().compactMap({ turn -> CandidateTurn? in
                  guard case .candidate(let candidate) = turn,
                        candidate.boardAttachment == .noBoard else {
                      return nil
                  }
                  return candidate
              }).first else {
            boardErrorMessage = "Save a revision and choose an unattached answer first."
            return
        }
        do {
            let updated = try await coordinator.attachBoardRevision(
                revision.id,
                to: turn.id,
                commandID: commandID("attach-board-revision")
            )
            publish(updated)
            boardErrorMessage = nil
        } catch {
            publish(coordinator.snapshot)
            boardErrorMessage = "The selected revision could not be attached to that answer."
        }
    }

    func exportSelectedBoardRevision() async {
        guard !isBoardExporting,
              !hasPendingLocalPersistence,
              let coordinator,
              canExportBoardRevision,
              let revision = selectedBoardRevision else {
            boardErrorMessage = "Save the displayed board revision before exporting."
            return
        }
        guard let boardArtifactStore else {
            boardErrorMessage = "Private board storage is unavailable on this Mac."
            return
        }

        isBoardExporting = true
        boardErrorMessage = nil
        boardExportMessage = nil
        defer { isBoardExporting = false }

        // Terminal export operations are immutable. Retrying intentionally
        // obtains a fresh authorization, export identity, and private subtree.
        var operation = coordinator.snapshot.board.exports.last {
            $0.revisionID == revision.id && $0.lifecycle == .authorized
        }
        do {
            if operation == nil {
                let settings = try BoardExportSettings(
                    viewport: revision.document.canvas.size,
                    scale: 1,
                    background: BoardColor(hexRGB: "fbfcfa")
                )
                let application = try await coordinator.authorizeBoardExport(
                    revisionID: revision.id,
                    settings: settings,
                    commandID: commandID("authorize-board-export")
                )
                publish(application.snapshot)
                operation = application.snapshot.board.exports.last {
                    $0.revisionID == revision.id && $0.lifecycle == .authorized
                }
            }
            guard let operation else {
                boardErrorMessage = "The board export authorization could not be recovered."
                return
            }

            let rendered: RenderedBoardArtifacts
            do {
                rendered = try boardRenderer.render(
                    revision.document,
                    settings: operation.settings
                )
            } catch {
                try await recordBoardExportFailure(
                    operation,
                    reason: .renderingFailed,
                    coordinator: coordinator
                )
                boardErrorMessage = "The board could not be rendered. The saved revision is unchanged."
                return
            }

            let bundle: BoardArtifactBundle
            do {
                bundle = try await boardArtifactStore.persist(
                    exportID: operation.id,
                    identities: operation.artifactIdentities,
                    artifacts: rendered
                )
            } catch {
                try await recordBoardExportFailure(
                    operation,
                    reason: .storageFailed,
                    coordinator: coordinator
                )
                boardErrorMessage = "The export bundle was not completed. The saved revision remains retryable."
                return
            }

            let updated = try await coordinator.recordBoardExportOutcome(
                exportID: operation.id,
                outcome: .ready(bundle),
                commandID: commandID("complete-board-export")
            )
            publish(updated)
            boardExportMessage = "Editable source · SVG + PNG available"
        } catch {
            publish(coordinator.snapshot)
            boardErrorMessage = "The export did not complete. The saved revision remains available."
        }
    }

    private func persistBoardDraft(_ document: BoardDocument) {
        guard let coordinator else {
            boardErrorMessage = "The room is still restoring. This board change is not durable yet."
            return
        }
        let previous = localPersistenceTail
        ExcalidrawBoardDiagnostics.record(
            kind: "board-persistence-queued",
            fields: [
                "modelHasSelection": boardEditor.selectedElementID != nil,
                "elementCount": document.elements.count,
            ]
        )
        beginBoardWork()
        let operation = Task { @MainActor [weak self, weak coordinator] in
            await previous?.value
            guard let self, let coordinator else { return }
            ExcalidrawBoardDiagnostics.record(
                kind: "board-persistence-started",
                fields: [
                    "modelHasSelection": boardEditor.selectedElementID != nil,
                    "elementCount": document.elements.count,
                ]
            )
            defer {
                endBoardWork()
            }
            do {
                let updated = try await coordinator.updateBoardDraft(
                    document,
                    commandID: commandID("update-board-draft")
                )
                publish(updated)
                ExcalidrawBoardDiagnostics.record(
                    kind: "board-persistence-published",
                    fields: [
                        "modelHasSelection": boardEditor.selectedElementID != nil,
                        "elementCount": document.elements.count,
                    ]
                )
            } catch {
                publish(coordinator.snapshot)
                boardErrorMessage = "The latest board change is visible but not saved. Try the action again."
            }
        }
        localPersistenceGeneration += 1
        localPersistenceTail = operation
    }

    private func beginBoardWork() {
        pendingBoardWriteCount += 1
        isBoardSaving = true
    }

    private func endBoardWork() {
        pendingBoardWriteCount = max(0, pendingBoardWriteCount - 1)
        isBoardSaving = pendingBoardWriteCount > 0
    }

    private func recordBoardExportFailure(
        _ operation: BoardExportOperation,
        reason: BoardExportFailureReason,
        coordinator: SegmentSpeechCoordinator
    ) async throws {
        let updated = try await coordinator.recordBoardExportOutcome(
            exportID: operation.id,
            outcome: .failed(BoardExportFailure(reason: reason)),
            commandID: commandID("fail-board-export")
        )
        publish(updated)
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
        guard snapshot?.phase == .candidateFloor, !canStopRecording else {
            return false
        }
        if snapshot?.turnMode == .continuousConversation {
            return showsManualCaptureRecovery
        }
        return true
    }

    var canRecordSegment: Bool {
        guard !isWorking,
              !hasPendingLocalPersistence,
              hasUsableGroqCredential,
              isHostedWritable,
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
        guard !isWorking,
              !hasPendingLocalPersistence,
              isHostedWritable,
              let snapshot else { return false }
        switch snapshot.phase {
        case .candidateFloor:
            if snapshot.turnMode == .continuousConversation, !showsManualCaptureRecovery {
                return false
            }
            guard boardAttachmentForHandOff != nil else { return false }
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

    func open() async {
        guard coordinator == nil, !isWorking else { return }
        isWorking = true
        isCheckingInterviewer = true
        errorMessage = nil
        errorWasInterviewerFailure = false
        defer {
            isWorking = false
            LiveDebugTrace.event(
                "room.open.end",
                ["ok": coordinator == nil ? "false" : "true"]
            )
        }

        async let interviewerCheck = interviewerRuntime.preflight()

        var launchPrompt = activityPrompt
        var launchSessionID = Self.fallbackSessionID
        var launchActivityID = "local-system-design-tracer"
        if let hostedController {
            hostedSnapshot = await hostedController.open()
            LiveDebugTrace.event(
                "room.open.hosted",
                ["connection": hostedSnapshot.connection.debugCode]
            )
            switch hostedSnapshot.connection {
            case .signedOut:
                isLiveIntegrationSetupPresented = true
                statusMessage = "Connect Interview Arc to open Today’s System Design activity"
                isCheckingInterviewer = false
                _ = await interviewerCheck
                return
            case .noOpenSystemDesignActivity:
                statusMessage = "No System Design activity is open in Interview Arc Today"
                errorMessage = "Add a System Design activity to Today, then reopen this room."
                isCheckingInterviewer = false
                _ = await interviewerCheck
                return
            case .offline, .recoveryRequired:
                statusMessage = hostedController.errorMessage
                    ?? "Hosted recovery needs attention"
                errorMessage = hostedController.errorMessage
                if hostedSnapshot.activity == nil {
                    isCheckingInterviewer = false
                    _ = await interviewerCheck
                    return
                }
            case .loading:
                statusMessage = "Reading Interview Arc Today…"
            case .readOnly, .writable:
                break
            }

            if let hostedActivity = hostedSnapshot.activity?.activity {
                do {
                    launchPrompt = try ActivityPrompt(
                        specialty: .systemDesign,
                        stage: hostedActivity.source ?? "Interview Arc Today",
                        question: hostedActivity.prompt ?? hostedActivity.title,
                        requestedParts: []
                    )
                    launchActivityID = hostedActivity.id
                    launchSessionID = SessionID(
                        "hosted-system-design-\(hostedActivity.id)"
                    )
                } catch {
                    statusMessage = "Hosted activity is incompatible"
                    errorMessage = "The selected System Design activity has an invalid prompt. Fix it in Interview Arc."
                    isCheckingInterviewer = false
                    _ = await interviewerCheck
                    return
                }
            }
        }

        await refreshCredentialReadiness(presentWhenMissing: true)

        if boardArtifactStore == nil {
            boardArtifactStore = Self.makeDefaultBoardArtifactStore(
                sessionIdentity: launchSessionID.rawValue
            )
        }

        do {
            let conversationEngine = AVAudioEngine()
            let opened = try await SegmentSpeechCoordinator.openLocal(
                sessionID: launchSessionID,
                activityID: launchActivityID,
                activityPrompt: launchPrompt,
                interviewerRuntime: interviewerRuntime,
                recording: makeBoundSegmentRecorder(),
                transcriber: VoiceCoreSegmentTranscriber(),
                credentialReader: credentialStore,
                semanticEndpointClassifier: GroqEndpointClassifier(
                    credentialReader: credentialStore
                ),
                acousticSegmenter: VoiceCoreAcousticSegmenter(
                    engine: conversationEngine,
                    sharesEngine: true
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
            await attachInterviewerSpeech(
                to: opened,
                conversationEngine: conversationEngine
            )
            if restored.turnMode == .continuousConversation {
                await opened.enableContinuousListening()
            }
            if restored.phase == .ready {
                isInterviewerRequestInFlight = true
                statusMessage = "Mara is opening the interview…"
                do {
                    restored = try await opened.requestOpeningInterviewerTurn(
                        commandID: CommandID("local-opening-0")
                    )
                } catch {
                    restored = opened.snapshot
                    errorWasInterviewerFailure = applyInterviewerFailure(error)
                    errorMessage = safeMessage(for: error)
                }
                isInterviewerRequestInFlight = false
            }
            publish(restored)
            await recoverBoardArtifacts(in: restored.board)
            await interviewerSpeechCoordinator?.observeNewlyPersistedSnapshot(restored)
        } catch {
            statusMessage = "Local session unavailable"
            errorMessage = safeMessage(for: error)
        }

        applyInterviewerReadiness(await interviewerCheck)
        isCheckingInterviewer = false
    }

    /// Audits persisted export bundles during app restore. Recovery is
    /// intentionally read-only here: the candidate must explicitly choose
    /// Export before any derivatives are regenerated or session state changes.
    func recoverBoardArtifacts(in workspace: BoardWorkspace) async {
        guard let boardArtifactStore else {
            if !workspace.exports.isEmpty {
                boardErrorMessage = "Private board storage is unavailable, so saved exports could not be verified. Saved revisions remain available."
            }
            return
        }

        var foundMissingReadyBundle = false
        var foundRegenerationNeed = false
        var foundInterruptedExport = false
        var foundIntegrityFailure = false

        for operation in workspace.exports where operation.lifecycle != .failed {
            do {
                switch try await boardArtifactStore.recover(
                    identities: operation.artifactIdentities
                ) {
                case .missing:
                    if operation.lifecycle == .ready {
                        foundMissingReadyBundle = true
                    } else {
                        foundInterruptedExport = true
                    }
                case .needsRegeneration:
                    foundRegenerationNeed = true
                case .complete(let recovered):
                    if operation.lifecycle == .ready {
                        if operation.bundle != recovered {
                            foundIntegrityFailure = true
                        }
                    } else {
                        foundInterruptedExport = true
                    }
                }
            } catch {
                foundIntegrityFailure = true
            }
        }

        if foundIntegrityFailure {
            boardErrorMessage = "A saved board export could not be verified. Select its revision and choose Export to create a new private bundle."
        } else if foundRegenerationNeed {
            boardErrorMessage = "A board export kept its editable source, but its SVG or PNG needs regeneration. Select its revision and choose Export."
        } else if foundMissingReadyBundle {
            boardErrorMessage = "A saved board export bundle is missing. Select its revision and choose Export to create it again."
        } else if foundInterruptedExport {
            boardErrorMessage = "An interrupted board export is ready to retry. Select its revision and choose Export."
        }
    }

    func checkInterviewer() async {
        guard !isCheckingInterviewer else { return }
        isCheckingInterviewer = true
        defer { isCheckingInterviewer = false }

        applyInterviewerReadiness(await interviewerRuntime.preflight())
        LiveDebugTrace.event(
            "interviewer.preflight",
            ["ok": isInterviewerReady ? "true" : "false"]
        )
    }

    func saveLiveIntegrationToken(_ value: String, untilQuit: Bool) async {
        guard let hostedController else { return }
        await hostedController.saveToken(value, untilQuit: untilQuit)
        hostedSnapshot = hostedController.snapshot
        isLiveIntegrationSetupPresented = hostedController.isConnectionSetupPresented
        if hostedSnapshot.activity != nil, coordinator == nil {
            await open()
        }
    }

    func disconnectLiveIntegration() async {
        guard let hostedController else { return }
        await hostedController.disconnect()
        hostedSnapshot = hostedController.snapshot
        isLiveIntegrationSetupPresented = true
    }

    func refreshHostedAuthority() async {
        guard let hostedController,
              hostedSnapshot.connection != .signedOut else { return }
        await hostedController.refresh()
        hostedSnapshot = hostedController.snapshot
        errorMessage = hostedController.errorMessage
        if hostedSnapshot.activity != nil, coordinator == nil {
            await open()
        }
    }

    func prepareHostedForTermination() async -> Bool {
        guard let hostedController else { return true }
        let prepared = await hostedController.prepareForTermination()
        hostedSnapshot = hostedController.snapshot
        if !prepared {
            errorMessage = hostedController.errorMessage
                ?? "Hosted writes are still pending. Retry Quit after recovery."
        }
        return prepared
    }

    func toggleHostedTimer() async {
        guard let hostedController else { return }
        if hostedSnapshot.connection != .writable {
            await hostedController.refresh()
            hostedSnapshot = hostedController.snapshot
        }
        guard hostedSnapshot.connection == .writable else {
            errorMessage = hostedController.errorMessage
                ?? "Reconnect the hosted writer before changing the timer."
            return
        }
        do {
            if hostedTimerIsRunning { try await hostedController.pauseTimer() }
            else { try await hostedController.startTimer() }
            hostedSnapshot = hostedController.snapshot
            errorMessage = nil
        } catch {
            hostedSnapshot = hostedController.snapshot
            if hostedSnapshot.connection == .writable, !hostedTimerIsRunning {
                do {
                    try await hostedController.startTimer()
                    hostedSnapshot = hostedController.snapshot
                    errorMessage = nil
                    return
                } catch {
                    hostedSnapshot = hostedController.snapshot
                    errorMessage = error.localizedDescription
                    return
                }
            }
            errorMessage = error.localizedDescription
        }
    }

    func setHostedResult(_ result: LiveResult?) async {
        guard let hostedController, hostedSnapshot.connection == .writable else {
            errorMessage = "Reconnect the hosted writer before changing the result."
            return
        }
        do {
            if let result { try await hostedController.setResult(result) }
            else { try await hostedController.clearResult() }
            hostedSnapshot = hostedController.snapshot
            errorMessage = nil
        } catch {
            hostedSnapshot = hostedController.snapshot
            errorMessage = error.localizedDescription
        }
    }

    func selectTurnMode(_ mode: TurnMode) async {
        guard mode != turnMode,
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
        LiveDebugTrace.event(
            "room.record",
            ["ok": canRecordSegment ? "true" : "false"]
        )
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
            if let hostedController, !hostedTimerIsRunning {
                do {
                    try await hostedController.startTimer()
                    hostedSnapshot = hostedController.snapshot
                } catch {
                    // Capture already started and is locally durable. Stop and
                    // preserve its source bytes rather than leaving a hidden
                    // microphone or a false hosted timer.
                    let preserved = try await coordinator.finalizeSegment(
                        commandID: commandID("hosted-timer-start-failed")
                    )
                    publish(preserved)
                    hostedSnapshot = hostedController.snapshot
                    errorMessage = "Recording was preserved, but the hosted timer could not start. Refresh Interview Arc before recording again."
                }
            }
        } catch {
            publish(coordinator.snapshot)
            errorMessage = safeMessage(for: error)
        }
    }

    func stopRecording() async {
        guard let coordinator,
              let activeSegment = activeCaptureSegment,
              !isWorking,
              !hasPendingLocalPersistence else {
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
        guard let coordinator,
              !isWorking,
              !hasPendingLocalPersistence else { return }
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
        guard let coordinator,
              !isWorking,
              !hasPendingLocalPersistence else { return }
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

    func keepMyFloor() async {
        guard let coordinator,
              let grace = activeEndpointGrace,
              canKeepFloor else { return }

        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            statusMessage = status(for: snapshot)
        }

        do {
            let updated = try await coordinator.cancelEndpointGrace(
                graceID: grace.id,
                commandID: commandID("keep-floor")
            )
            publish(updated)
        } catch {
            publish(coordinator.snapshot)
            errorMessage = "Automatic Hand off could not be cancelled. Begin recording or retry Keep my floor."
        }
    }

    func pauseMicrophone() async {
        guard let coordinator, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            statusMessage = status(for: snapshot)
        }
        do {
            let updated = try await coordinator.pauseMicrophone(
                commandID: commandID("pause-microphone")
            )
            publish(updated)
        } catch {
            publish(coordinator.snapshot)
            errorMessage = safeMessage(for: error)
        }
    }

    func toggleFloorHold() async {
        guard let coordinator, canToggleFloorHold else { return }
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            statusMessage = status(for: snapshot)
        }

        do {
            if isFloorHeld {
                statusMessage = "Sending answer…"
                let updated = try await coordinator.sendAnswer(
                    commandID: commandID("send-answer"),
                    boardAttachment: boardAttachmentForHandOff ?? .noBoard
                )
                publish(updated)
            } else {
                statusMessage = "Holding your floor…"
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
        LiveDebugTrace.event(
            "room.handoff",
            [
                "phase": snapshot?.phase.rawValue ?? "none",
                "ok": canAct ? "true" : "false",
            ]
        )
        guard let coordinator, let snapshot else { return }
        if snapshot.phase == .candidateFloor,
           boardAttachmentForHandOff == nil {
            boardErrorMessage = "Save the displayed board as a revision before Hand off."
            return
        }
        guard canAct else { return }

        isWorking = true
        errorMessage = nil
        errorWasInterviewerFailure = false
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
                guard let boardAttachment = boardAttachmentForHandOff else {
                    boardErrorMessage = "Save the displayed board as a revision before Hand off."
                    return
                }
                updated = try await coordinator.handOff(
                    commandID: commandID("hand-off"),
                    boardAttachment: boardAttachment
                )
            case .interviewerProcessing:
                isInterviewerRequestInFlight = true
                statusMessage = "Retrying interviewer response…"
                updated = try await coordinator.retryInterviewerResponse(
                    commandID: commandID("retry-interviewer")
                )
            case .interviewerTurn:
                try await syncHostedPairs(from: snapshot)
                try await interviewerSpeechCoordinator?.stop(
                    commandID: commandID("stop-speech-before-floor")
                )
                if coordinator.snapshot.phase == .interviewerTurn {
                    updated = try await coordinator.giveCandidateFloor(
                        commandID: commandID("give-floor")
                    )
                } else {
                    updated = coordinator.snapshot
                }
            case .ready, .completed:
                return
            }
            publish(updated)
            try await syncHostedPairs(from: updated)
            await interviewerSpeechCoordinator?
                .observeNewlyPersistedSnapshot(updated)
        } catch {
            publish(coordinator.snapshot)
            errorWasInterviewerFailure = applyInterviewerFailure(error)
            errorMessage = safeMessage(for: error)
        }
    }

    /// Hosted finish is authoritative. Local completion follows only after
    /// the hosted activity actually finishes, so a gate such as missing
    /// result cannot leave the room looking ended while Today stays open.
    /// Presentation close remains fail-closed when the current phase cannot
    /// finish safely. An operation already awaiting its Adapter keeps sole
    /// ownership of the model's visible and durable state.
    @discardableResult
    func finishInterview() async -> Bool {
        await finishInterview(hostedNextActivityID: nil)
    }

    @discardableResult
    func finishAndOpenNextInterview() async -> Bool {
        guard let nextActivityID = hostedNextSystemDesignActivityID else {
            errorMessage = "There is no later System Design activity in this hosted session."
            return false
        }
        guard await finishInterview(hostedNextActivityID: nextActivityID) else {
            return false
        }

        resetForNextHostedActivity()
        await open()
        return hostedSnapshot.activityID == nextActivityID && coordinator != nil
    }

    private func finishInterview(hostedNextActivityID: String?) async -> Bool {
        guard !isWorking else { return false }
        if hasPendingLocalPersistence {
            errorMessage = "Wait for the latest local save to finish, then press End again."
            return false
        }
        guard let coordinator, let snapshot else {
            errorMessage = "The interview room is not open yet, so End cannot finish this activity."
            return false
        }
        if snapshot.phase == .completed,
           (
               hostedController == nil
                   || hostedSnapshot.activity?.activity.lifecycle == .completed
           ) {
            return true
        }
        if hostedController != nil {
            switch hostedSnapshot.connection {
            case .writable:
                break
            case .recoveryRequired(let code):
                errorMessage = "Hosted recovery is required before ending (\(code))."
                return false
            case .offline:
                errorMessage = "Interview Arc is offline. End needs a hosted connection; local work is kept."
                return false
            default:
                errorMessage = HostedPracticeSessionError.leaseUnavailable.errorDescription
                return false
            }
        }
        if snapshot.segments.contains(where: { segment in
            switch segment.lifecycle {
            case .captureAuthorized, .recording, .finalizationAuthorized, .transcribing:
                return true
            default:
                return false
            }
        }) {
            errorMessage = "Stop the in-progress recording before ending. Local work stays saved."
            return false
        }

        isFinishingInterview = true
        isWorking = true
        errorMessage = nil
        statusMessage = "Ending interview…"
        defer {
            isWorking = false
            isFinishingInterview = false
            statusMessage = status(for: self.snapshot)
        }

        do {
            await waitForBoardPersistence()
            if snapshot.phase != .completed {
                try await syncHostedPairs(from: snapshot)
            }
            if let hostedController {
                if let hostedNextActivityID {
                    try await hostedController.finishNext(
                        nextActivityID: hostedNextActivityID
                    )
                } else {
                    try await hostedController.finish()
                }
                hostedSnapshot = hostedController.snapshot
            }
            if coordinator.snapshot.phase != .completed {
                let updated = try await coordinator.finishSession(
                    commandID: commandID("finish-interview")
                )
                publish(updated)
            }
            return true
        } catch {
            publish(coordinator.snapshot)
            if let hostedController {
                hostedSnapshot = hostedController.snapshot
            }
            errorMessage = safeMessage(for: error)
            return false
        }
    }

    private func resetForNextHostedActivity() {
        audioPlayer?.stop()
        audioPlayer = nil
        speechPreparationTask?.cancel()
        speechPreparationTask = nil
        interviewerSpeechCoordinator = nil
        coordinator = nil
        segmentRecorder?.onMetering = nil
        segmentRecorder = nil
        recordingPowerHistory = []
        recordingElapsedSeconds = 0
        snapshot = nil
        segments = []
        localPersistenceTail = nil
        localPersistenceGeneration = 0
        pendingBoardWriteCount = 0
        candidateNotesPersistenceTask = nil
        pendingCandidateNotes = nil
        didLoadInitialCandidateNotes = false
        candidateNotesDraft = ""
        candidateNotesSavePresentation = .saved
        boardArtifactStore = nil
        boardEditor = BoardEditorState(document: .empty)
        inspectedBoardRevisionID = nil
        didLoadInitialBoard = false
        boardErrorMessage = nil
        boardExportMessage = nil
        errorMessage = nil
        statusMessage = "Opening the next hosted System Design activity…"
    }

    func confirmHostedCandidateEvidence(pairID: String) async {
        guard let hostedController else { return }
        do {
            try await hostedController.confirmCandidateEvidence(pairID: pairID)
            hostedSnapshot = hostedController.snapshot
            errorMessage = nil
        } catch {
            hostedSnapshot = hostedController.snapshot
            errorMessage = error.localizedDescription
        }
    }

    private func syncHostedPairs(from snapshot: InterviewRoomSnapshot) async throws {
        guard let hostedController else { return }
        guard hostedSnapshot.connection == .writable else {
            throw HostedPracticeSessionError.leaseUnavailable
        }
        let hostedCandidateIDs = Set(
            hostedSnapshot.activity?.pairs.map(\.candidate.turnId) ?? []
        )
        var index = 0
        while index + 1 < snapshot.turns.count {
            guard case .candidate(let candidate) = snapshot.turns[index],
                  case .interviewer(let interviewer) = snapshot.turns[index + 1],
                  interviewer.replyToTurnID == candidate.id else {
                index += 1
                continue
            }
            defer { index += 2 }
            guard !hostedCandidateIDs.contains(candidate.id.rawValue) else {
                continue
            }
            let candidateOccurredAt = snapshot.segments
                .filter { $0.committedTurnID == candidate.id }
                .compactMap(\.capturedAudio?.endedAtMilliseconds)
                .max()
                ?? hostedSnapshot.activity?.serverTime
                ?? LiveEpochMilliseconds(
                    (Date().timeIntervalSince1970 * 1_000).rounded()
                )
            let evidence: LiveCandidateEvidenceStatus = switch candidate.transcript.quality {
            case .verified: .verified
            case .bestAvailable: .bestAvailable
            case .possibleContamination: .possibleContamination
            }
            try await hostedController.commitPair(
                pairID: Self.hostedPairID(candidateTurnID: candidate.id.rawValue),
                candidate: LiveCandidatePairInput(
                    turnId: candidate.id.rawValue,
                    text: candidate.transcript.body,
                    evidenceStatus: evidence,
                    occurredAt: candidateOccurredAt
                ),
                interviewer: LiveInterviewerPairInput(
                    turnId: interviewer.id.rawValue,
                    displayMarkdown: interviewer.displayMarkdown,
                    spokenText: interviewer.spokenText,
                    occurredAt: candidateOccurredAt + 1
                )
            )
            hostedSnapshot = hostedController.snapshot
        }
    }

    private static func hostedPairID(candidateTurnID: String) -> String {
        let digest = SHA256.hash(data: Data(candidateTurnID.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return "pair-\(digest)"
    }

    func selectSpeechEngine(_ engine: LocalSpeechEngine) async {
        guard engine != selectedSpeechEngine, !isSwitchingSpeechEngine,
              !isWorking, !isFinishingInterview else { return }
        isSwitchingSpeechEngine = true
        defer { isSwitchingSpeechEngine = false }
        speechErrorMessage = nil
        // Preparation cancellation must finish before swapping or releasing its model.
        if let preparation = speechPreparationTask {
            preparation.cancel()
            await preparation.value
        }
        guard !isSpeechModelActionInFlight else { return }
        do {
            if let interviewerSpeechCoordinator {
                let provider = try speechProviderFactory(engine)
                _ = try await interviewerSpeechCoordinator.replaceProvider(
                    with: provider, commandID: commandID("switch-speech-engine"))
                publish(interviewerSpeechCoordinator.snapshot)
            } else {
                speechReadiness = .notInstalled
            }
            selectedSpeechEngine = engine
            preferences.set(engine.rawValue, forKey: Self.speechEnginePreferenceKey)
            playingUtteranceID = nil
        } catch {
            speechErrorMessage = safeSpeechMessage(for: error)
        }
    }

    func startSpeechModelDownload() {
        guard !isSwitchingSpeechEngine, !isSpeechModelActionInFlight,
              speechPreparationTask == nil,
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
        guard !isSwitchingSpeechEngine, speechPreparationTask == nil,
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
        guard let interviewerSpeechCoordinator else { return }
        await toggleSpeechMute(using: interviewerSpeechCoordinator)
    }

    func toggleSpeechMute(
        using speechMuteController: any LiveInterviewerSpeechMuteControlling
    ) async {
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
            LiveDebugTrace.event("groq.save", ["ok": "true"])
            credentialState = .readyFromKeychain
            statusMessage = segments.contains(where: { $0.transcriptionAction != nil })
                ? "Groq key saved to Keychain · transcribe the affected segment"
                : status(for: snapshot)
            return true
        } catch let error as LiveGroqCredentialStoreError {
            LiveDebugTrace.event("groq.save", ["ok": "false"])
            credentialState = .unusable
            credentialErrorMessage = error.localizedDescription
            return false
        } catch {
            LiveDebugTrace.event("groq.save", ["ok": "false"])
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
        to conversation: SegmentSpeechCoordinator,
        conversationEngine: AVAudioEngine
    ) async {
        do {
            let dependencies: LiveInterviewerSpeechDependencies
            if let speechDependencies {
                dependencies = speechDependencies
            } else {
                dependencies = try Self.makeLiveSpeechDependencies(
                    engine: conversationEngine,
                    provider: speechProviderFactory(selectedSpeechEngine)
                )
            }

            let speech = try await InterviewerSpeechCoordinator.attach(
                to: conversation,
                provider: dependencies.provider,
                player: dependencies.player,
                audioStore: dependencies.audioStore,
                initiallyMuted: isSpeechMuted
            )
            interviewerSpeechCoordinator = speech
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

    private static func makeLiveSpeechDependencies(
        engine: AVAudioEngine,
        provider: any InterviewerSpeechProvider
    ) throws -> LiveInterviewerSpeechDependencies {
        let audioStore = LiveInterviewerSpeechAudioStore()
        return LiveInterviewerSpeechDependencies(
            provider: provider,
            player: AVAudioEngineInterviewerSpeechPlayer(
                audioStore: audioStore,
                engine: engine,
                ownsEngine: false
            ),
            audioStore: audioStore
        )
    }

    private func makeBoundSegmentRecorder() -> VoiceCoreSegmentRecorder {
        let recorder = VoiceCoreSegmentRecorder()
        segmentRecorder = recorder
        recorder.onMetering = { [weak self] sample in
            self?.recordingPowerHistory = sample.powerHistory
            self?.recordingElapsedSeconds = sample.elapsedSeconds
        }
        return recorder
    }

    private static func makeDefaultBoardArtifactStore(
        sessionIdentity: String
    ) -> PrivateBoardArtifactStore? {
        let pathFileManager = FileManager()
        guard let applicationSupportRoot = try? LivePaths.applicationSupportRoot(
            fileManager: pathFileManager
        ) else {
            return nil
        }
        let digest = SHA256.hash(data: Data(sessionIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let root = applicationSupportRoot
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(
                "session-\(digest)",
                isDirectory: true
            )
        // The store actor owns a distinct FileManager instance. Reusing the
        // main-actor path helper here would send an already-isolated mutable
        // reference across the actor boundary under Swift 6.
        return PrivateBoardArtifactStore(root: root, fileManager: FileManager())
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

    private func applyInterviewerReadiness(_ readiness: InterviewerReadiness) {
        interviewerReadiness = readiness
        if readiness == .ready, errorWasInterviewerFailure {
            errorMessage = nil
            errorWasInterviewerFailure = false
        }
        if snapshot != nil {
            statusMessage = status(for: snapshot)
        }
    }

    static func safeInterviewerFailureMessage(
        for error: InterviewerRuntimeError,
        providerName: String = "Interviewer"
    ) -> String {
        switch error {
        case .missing:
            "Your answer is saved. Install or configure \(providerName), check readiness, then retry the interviewer."
        case .unauthenticated:
            "Your answer is saved. Sign in through \(providerName), check readiness, then retry the interviewer."
        case .transportFailure:
            "Your answer is saved. \(providerName) could not complete the local request; check readiness, then retry explicitly."
        case .protocolFailure:
            "Your answer is saved. The local \(providerName) protocol failed; check readiness before an explicit retry."
        case .serverFailure:
            "Your answer is saved. \(providerName) could not complete this interviewer turn; retry only when you choose."
        case .malformedFinalResponse:
            "Your answer is saved. \(providerName) returned no usable interviewer response; nothing was added to the transcript."
        case .cancelled:
            "Your answer is saved. The \(providerName) request was cancelled; retry only when you choose."
        }
    }

    @discardableResult
    private func applyInterviewerFailure(_ error: Error) -> Bool {
        guard let runtimeError = error as? InterviewerRuntimeError else {
            return false
        }
        switch runtimeError {
        case .missing:
            interviewerReadiness = .missing
        case .unauthenticated:
            interviewerReadiness = .unauthenticated
        case .transportFailure:
            interviewerReadiness = .transportFailure
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

    private func startCandidateNotesPersistenceIfNeeded() {
        guard !isWorking,
              pendingCandidateNotes != nil,
              candidateNotesPersistenceTask == nil else { return }
        let previous = localPersistenceTail
        let operation = Task { @MainActor [weak self] in
            await previous?.value
            await self?.drainCandidateNotesPersistence()
        }
        candidateNotesPersistenceTask = operation
        localPersistenceGeneration += 1
        localPersistenceTail = operation
    }

    private func waitForLocalPersistence() async {
        while true {
            startCandidateNotesPersistenceIfNeeded()
            let observedGeneration = localPersistenceGeneration
            let observed = localPersistenceTail
            await observed?.value
            if pendingCandidateNotes == nil,
               candidateNotesPersistenceTask == nil,
               localPersistenceGeneration == observedGeneration {
                return
            }
            if isWorking {
                return
            }
        }
    }

    private func drainCandidateNotesPersistence() async {
        while let notes = pendingCandidateNotes {
            pendingCandidateNotes = nil
            guard let coordinator else {
                candidateNotesSavePresentation = .error(
                    "Wait for the local room to finish restoring, then retry."
                )
                break
            }
            do {
                let updated = try await coordinator.updateCandidateNotes(
                    notes,
                    commandID: commandID("update-candidate-notes")
                )
                publish(updated)
                if pendingCandidateNotes == nil,
                   candidateNotesDraft == notes.body {
                    candidateNotesSavePresentation = .saved
                }
            } catch {
                publish(coordinator.snapshot)
                candidateNotesSavePresentation = .error(
                    "Notes were not saved. Your text remains here; choose Retry."
                )
                break
            }
        }
        candidateNotesPersistenceTask = nil
        if pendingCandidateNotes != nil {
            startCandidateNotesPersistenceIfNeeded()
        }
    }

    private func publish(_ snapshot: InterviewRoomSnapshot) {
        if !didLoadInitialBoard {
            boardEditor = BoardEditorState(document: snapshot.board.draft)
            inspectedBoardRevisionID = snapshot.board.selectedRevisionID
            didLoadInitialBoard = true
        }
        if !didLoadInitialCandidateNotes {
            candidateNotesDraft = snapshot.candidateNotes.body
            didLoadInitialCandidateNotes = true
        }
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

        if snapshot.endpointGraces.contains(where: { $0.lifecycle == .pending }) {
            if snapshot.turnMode == .continuousConversation {
                return "Handing off · Hold floor to keep answering"
            }
            return "Handing off in 4 seconds · Keep my floor to cancel"
        }
        if snapshot.isFloorHeld {
            return "Holding your floor"
        }

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
            if snapshot.turns.isEmpty {
                if isInterviewerRequestInFlight {
                    return "Mara is opening the interview…"
                }
                return isInterviewerReady
                    ? "Opening greeting needs retry"
                    : "Opening greeting needs the interviewer to retry"
            }
            if isInterviewerRequestInFlight {
                return "Answer saved · interviewer is preparing the next question"
            }
            return isInterviewerReady
                ? "Answer saved · interviewer retry available"
                : "Answer saved · check the interviewer to retry"
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
        if let runtimeError = error as? InterviewerRuntimeError {
            return Self.safeInterviewerFailureMessage(
                for: runtimeError, providerName: interviewerProviderName
            )
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
            case .invalidTransition(let command, _):
                if command == "finish" {
                    return "Stop the in-progress recording before ending. Local work stays saved."
                }
                return "The room rejected this action. Its latest durable state is still shown."
            default:
                return "The room rejected this action. Its latest durable state is still shown."
            }
        }

        if let hostedError = error as? LiveV1ClientError {
            return hostedError.errorDescription
                ?? "Interview Arc rejected this action. Local work is still shown."
        }
        if let hostedSessionError = error as? HostedPracticeSessionError {
            return hostedSessionError.errorDescription
                ?? "Hosted recovery is required before this action."
        }

        return "The operation did not complete. The latest durable state is still shown."
    }
}
