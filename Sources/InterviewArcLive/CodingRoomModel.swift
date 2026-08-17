import AVFoundation
import Combine
import CryptoKit
import Foundation
import InterviewArcLiveCodexAdapter
import InterviewArcLiveCore
import InterviewArcLiveHostedClient
import InterviewArcLiveQwenAdapter
import InterviewArcLiveSpeechOutputAdapter
import InterviewArcLiveVoiceAdapter

enum CodingLanguage: String, CaseIterable, Identifiable, Sendable {
    case java21 = "Java 21"
    case python = "Python"

    var id: String { rawValue }
    var isEnabled: Bool { self == .java21 }
}

enum CodingRoomOutputFocus: Equatable, Sendable {
    case harness
    case submission
}

@MainActor
final class CodingRoomModel: ObservableObject {
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
    @Published private(set) var hostedSnapshot = HostedPracticeSnapshot(
        connection: .signedOut
    )
    @Published var isLiveIntegrationSetupPresented = false
    @Published private(set) var isFinishingInterview = false
    @Published var isCredentialSetupPresented = false
    @Published private(set) var isSavingCredential = false
    @Published private(set) var credentialErrorMessage: String?

    @Published private(set) var sourceFileName = "solution.java"
    @Published private(set) var sourceText = ""
    @Published private(set) var sourceSavePresentation = "Saved locally"
    @Published private(set) var isJavaFileLoaded = false
    @Published private(set) var isSourceSaving = false
    @Published private(set) var selectedLanguage = CodingLanguage.java21
    @Published private(set) var latestRunReceipt: CodingHarnessReceipt?
    @Published private(set) var isHarnessRunning = false
    @Published private(set) var latestSubmissionReceipt: CodingSubmissionReceipt?
    @Published private(set) var isSubmitting = false
    @Published private(set) var outputFocus = CodingRoomOutputFocus.harness
    @Published private(set) var isControllerWarming = false
    @Published private(set) var isOpeningLeetCode = false
    @Published private(set) var workSurfaceMessage: String?

    private static let tracerActivityPrompt: ActivityPrompt = {
        do {
            return try ActivityPrompt(
                specialty: .coding,
                stage: "Coding interview",
                question: "Open a LeetCode activity on Today",
                requestedParts: [
                    "Restate the public statement in your own words.",
                    "Talk through the approach before coding.",
                    "Implement one evolving Java solution.",
                ]
            )
        } catch {
            preconditionFailure("The built-in coding Activity Prompt must remain valid.")
        }
    }()

    private enum CredentialState {
        case checking
        case missing
        case readyFromKeychain
        case readyUntilQuit
        case unusable
    }

    private static let fallbackSessionID = SessionID("local-coding-tracer-v1")
    private static let speechMutedPreferenceKey =
        "interviewArcLive.interviewerSpeechMuted"

    private let activityPrompt: ActivityPrompt
    private let credentialStore: LiveGroqCredentialStore
    private let codexRuntime: any LiveCodexInterviewerRuntime
    private let speechDependencies: LiveInterviewerSpeechDependencies?
    private let preferences: UserDefaults
    private let hostedController: HostedPracticeController?
    private let applicationSupportRoot: URL?
    private let harnessExecute: ((URL, [String], URL, [String: String]?) async throws -> CodingProcessResult)?
    private let controllerExecute: ((URL, [String], URL) async throws -> CodingProcessResult)?
    private var hostedSnapshotObservation: AnyCancellable?
    private var credentialState: CredentialState = .checking
    private var errorWasCodexFailure = false
    private var coordinator: SegmentSpeechCoordinator?
    private var interviewerSpeechCoordinator: InterviewerSpeechCoordinator?
    private var speechPreparationTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var sourceURL: URL?
    private var sourceSaveTask: Task<Void, Never>?
    private var pendingSourceText: String?
    private var didStartTimerAfterFileLoad = false
    private var harnessRunTask: Task<Void, Never>?
    private var harnessGeneration = 0

    init(
        credentialStore: LiveGroqCredentialStore = LiveGroqCredentialStore(),
        codexRuntime: (any LiveCodexInterviewerRuntime)? = nil,
        activityPrompt: ActivityPrompt? = nil,
        speechDependencies: LiveInterviewerSpeechDependencies? = nil,
        preferences: UserDefaults = .standard,
        initialCoordinator: SegmentSpeechCoordinator? = nil,
        hostedController: HostedPracticeController? = nil,
        applicationSupportRoot: URL? = nil,
        initialHostedSnapshot: HostedPracticeSnapshot? = nil,
        harnessExecute: ((URL, [String], URL, [String: String]?) async throws -> CodingProcessResult)? = nil,
        controllerExecute: ((URL, [String], URL) async throws -> CodingProcessResult)? = nil
    ) {
        self.credentialStore = credentialStore
        self.codexRuntime = codexRuntime ?? Self.makeDefaultCodexRuntime()
        self.activityPrompt = activityPrompt ?? Self.tracerActivityPrompt
        self.speechDependencies = speechDependencies
        self.preferences = preferences
        self.hostedController = hostedController
        self.applicationSupportRoot = applicationSupportRoot
        self.harnessExecute = harnessExecute
        self.controllerExecute = controllerExecute
        coordinator = initialCoordinator
        isSpeechMuted = preferences.bool(forKey: Self.speechMutedPreferenceKey)
        if let initialCoordinator {
            publish(initialCoordinator.snapshot)
        }
        if let initialHostedSnapshot {
            hostedSnapshot = initialHostedSnapshot
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
        if isCodingActivityMissing {
            return "Open a LeetCode activity on Today"
        }
        return hostedSnapshot.question
            ?? snapshot?.activityPrompt.question
            ?? activityPrompt.question
    }

    var hostedConnectionTitle: String {
        switch hostedSnapshot.connection {
        case .signedOut: "Connect Interview Arc"
        case .loading: "Syncing Interview Arc"
        case .noOpenSystemDesignActivity:
            hostedSnapshot.boundSpecialty == .leetcode
                ? "No coding activity"
                : "No System Design activity"
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

    var isCodingActivityMissing: Bool {
        hostedSnapshot.boundSpecialty == .leetcode
            && hostedSnapshot.activity == nil
            && hostedSnapshot.connection == .noOpenSystemDesignActivity
    }

    var hostedTimerIsRunning: Bool {
        hostedSnapshot.activity?.activity.timer?.runningSince != nil
            && hostedSnapshot.activity?.activity.timer?.completed == false
    }

    var hostedElapsedText: String? {
        guard let seconds = hostedSnapshot.elapsedSeconds(
            localNow: LiveEpochMilliseconds(
                (Date().timeIntervalSince1970 * 1_000).rounded()
            )
        ) else { return nil }
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var hostedResult: LiveResult? {
        hostedSnapshot.activity?.activity.result.value
    }

    var hostedPairs: [LivePair] { hostedSnapshot.activity?.pairs ?? [] }

    var hostedNextCodingActivityID: String? {
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
                    && $0.type == .leetcode
                    && $0.lifecycle != .completed
            }
        }
    }

    var activityPromptForPresentation: ActivityPrompt {
        snapshot?.activityPrompt ?? activityPrompt
    }

    var canToggleHostedTimer: Bool {
        isHostedWritable
            && !isCodingActivityMissing
            && (hostedTimerIsRunning || isJavaFileLoaded)
    }

    var canSetHostedResult: Bool {
        isHostedWritable && !isCodingActivityMissing
    }

    var leetCodeProblemURL: URL? {
        let activity = hostedSnapshot.activity?.activity
        return CodingSourceStore.leetCodeProblemURL(
            questionID: activity?.questionId,
            title: activity?.title ?? question
        )
    }

    var interviewArcRepositoryRoot: URL? {
        let linkFile: URL
        if let applicationSupportRoot {
            linkFile = applicationSupportRoot.appendingPathComponent("WorkspaceLink.json")
        } else if let defaultLink = try? LivePaths.workspaceLinkFile() {
            linkFile = defaultLink
        } else {
            return nil
        }
        guard let link = CodingSourceStore.loadWorkspaceLink(from: linkFile) else {
            return nil
        }
        return URL(fileURLWithPath: link.interviewArcRepositoryRoot, isDirectory: true)
    }

    private var hasPendingLocalPersistence: Bool {
        isSourceSaving || sourceSaveTask != nil || pendingSourceText != nil
    }

    var isCodexReady: Bool { codexReadiness == .ready }

    var codexStatusTitle: String {
        if isCheckingCodex || codexReadiness == nil { return "Checking Codex" }
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
        if isCheckingCodex || codexReadiness == nil { return "hourglass" }
        switch codexReadiness {
        case .ready: return "checkmark.circle.fill"
        case .missing: return "questionmark.circle.fill"
        case .incompatible: return "arrow.down.circle.fill"
        case .unauthenticated: return "person.crop.circle.badge.exclamationmark"
        case .transportFailure: return "exclamationmark.triangle.fill"
        case nil: return "hourglass"
        }
    }

    var codexAttentionMessage: String? {
        guard !isCheckingCodex else { return nil }
        switch codexReadiness {
        case .ready, nil: return nil
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
        InterviewerSpeechReadinessPresentation.make(readiness: speechReadiness)
    }

    var isSpeechReady: Bool { speechReadiness == .ready }
    var canToggleSpeechMute: Bool { interviewerSpeechCoordinator != nil }
    var showsSpeechMuteControl: Bool { interviewerSpeechCoordinator != nil }

    func utterance(for turnID: TurnID) -> InterviewerUtterance? {
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

    func isPlayingSpeech(for utteranceID: InterviewerUtteranceID) -> Bool {
        playingUtteranceID == utteranceID
    }

    var availableTurnModes: [TurnMode] { [.manual, .patientAuto] }
    var turnMode: TurnMode { snapshot?.turnMode ?? .manual }

    var canSelectTurnMode: Bool {
        guard !isWorking, !hasPendingLocalPersistence, let snapshot else {
            return false
        }
        return snapshot.phase != .completed
    }

    func turnModeTitle(_ mode: TurnMode) -> String {
        switch mode {
        case .manual: "Manual"
        case .patientAuto: "Patient Auto"
        case .cueOnly: "Cue Only"
        }
    }

    var activeEndpointGrace: EndpointGrace? {
        snapshot?.endpointGraces.last { $0.lifecycle == .pending }
    }

    var canKeepFloor: Bool {
        canKeepFloor(pendingGrace: activeEndpointGrace)
    }

    func canKeepFloor(pendingGrace: EndpointGrace?) -> Bool {
        pendingGrace != nil && !isWorking && !hasPendingLocalPersistence
    }

    var endpointHandoffPresentation: EndpointHandoffPresentation {
        guard let snapshot else {
            return EndpointHandoffPresentation.make(
                input: EndpointHandoffPresentation.Input(
                    turnMode: .manual,
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
                canAutomaticallyHandOff: true,
                hasSelectedDraft: !selectedCandidateIDs.isEmpty,
                hasUnresolvedDraft: hasUnresolvedDraft,
                hasStaleEvaluation: latestEvaluation != nil && currentEvaluation == nil
            )
        )
    }

    private var hasUsableGroqCredential: Bool {
        credentialState == .readyFromKeychain || credentialState == .readyUntilQuit
    }

    var canStopRecording: Bool { activeCaptureSegment != nil }

    var stopActionTitle: String {
        activeCaptureSegment?.lifecycle == .recording ? "Stop segment" : "Recover recording"
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
              !hasPendingLocalPersistence,
              hasUsableGroqCredential,
              snapshot?.phase == .candidateFloor else {
            return false
        }
        if usesHostedAuthority, !isCodingActivityMissing, !isHostedWritable {
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
        guard !isWorking, !hasPendingLocalPersistence, let snapshot else {
            return false
        }
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

        var launchPrompt = activityPrompt
        var launchSessionID = Self.fallbackSessionID
        var launchActivityID = "local-coding-tracer"
        var shouldLoadJavaFile = false
        if let hostedController {
            hostedSnapshot = await hostedController.open(selecting: .leetcode)
            switch hostedSnapshot.connection {
            case .signedOut:
                isLiveIntegrationSetupPresented = true
                statusMessage = "Connect Interview Arc to open Today’s coding activity"
                isCheckingCodex = false
                _ = await codexCheck
                return
            case .noOpenSystemDesignActivity:
                statusMessage = "No focused LeetCode activity"
                errorMessage = hostedController.errorMessage
                    ?? "Add a LeetCode activity to Today in Interview Arc."
            case .offline, .recoveryRequired:
                statusMessage = hostedController.errorMessage
                    ?? "Hosted recovery needs attention"
                errorMessage = hostedController.errorMessage
                isCheckingCodex = false
                _ = await codexCheck
                return
            case .loading:
                statusMessage = "Reading Interview Arc Today…"
            case .readOnly, .writable:
                break
            }

            if let hostedActivity = hostedSnapshot.activity?.activity {
                do {
                    launchPrompt = try ActivityPrompt(
                        specialty: .coding,
                        stage: hostedActivity.source ?? "Interview Arc Today",
                        question: hostedActivity.prompt ?? hostedActivity.title,
                        requestedParts: []
                    )
                    launchActivityID = hostedActivity.id
                    launchSessionID = SessionID("hosted-coding-\(hostedActivity.id)")
                    shouldLoadJavaFile = true
                    errorMessage = nil
                } catch {
                    statusMessage = "Hosted activity is incompatible"
                    errorMessage = "The selected coding activity has an invalid prompt. Fix it in Interview Arc."
                    isCheckingCodex = false
                    _ = await codexCheck
                    return
                }
            }
        }

        await refreshCredentialReadiness(presentWhenMissing: true)

        do {
            let opened = try await SegmentSpeechCoordinator.openLocal(
                sessionID: launchSessionID,
                activityID: launchActivityID,
                activityPrompt: launchPrompt,
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
                guard let self, let opened, self.coordinator === opened else {
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
            if shouldLoadJavaFile {
                await loadJavaSource()
                Task { [weak self] in
                    await self?.warmLeetCodeController()
                }
            }
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

    func saveLiveIntegrationToken(_ value: String, untilQuit: Bool) async {
        guard let hostedController else { return }
        await hostedController.saveToken(value, untilQuit: untilQuit)
        var snapshot = hostedController.snapshot
        if snapshot.connection != .signedOut, snapshot.boundSpecialty != .leetcode {
            snapshot = await hostedController.openPreferred()
        }
        hostedSnapshot = snapshot
        isLiveIntegrationSetupPresented = hostedController.isConnectionSetupPresented
        if coordinator == nil,
           snapshot.connection != .signedOut {
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

    func prepareLocalPersistenceForTermination() async -> Bool {
        guard !isWorking else {
            errorMessage = "A room operation is still finishing. Quit was cancelled so it can complete safely."
            return false
        }
        await flushSourceToDisk()
        guard pendingSourceText == nil, sourceSaveTask == nil else {
            errorMessage = "The latest Java file is still saving. Quit was cancelled so you can retry."
            return false
        }
        return true
    }

    func toggleHostedTimer() async {
        guard canToggleHostedTimer, let hostedController else {
            errorMessage = "Reconnect the hosted writer before changing the timer."
            return
        }
        do {
            if hostedTimerIsRunning { try await hostedController.pauseTimer() }
            else { try await hostedController.startTimer() }
            hostedSnapshot = hostedController.snapshot
            errorMessage = nil
        } catch {
            hostedSnapshot = hostedController.snapshot
            errorMessage = error.localizedDescription
        }
    }

    func setHostedResult(_ result: LiveResult?) async {
        guard canSetHostedResult, let hostedController else {
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
            publish(
                try await coordinator.setTurnMode(
                    mode,
                    commandID: commandID("set-turn-mode")
                )
            )
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
            publish(
                try await coordinator.beginSegment(
                    commandID: commandID("begin-segment")
                )
            )
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
                publish(
                    try await coordinator.transcribeSegment(
                        segmentID: activeSegment.id,
                        commandID: commandID("initial-transcription")
                    )
                )
            }
        } catch {
            publish(coordinator.snapshot)
            handleCredentialFailure(error)
            errorMessage = safeMessage(for: error)
        }
    }

    func transcribeSegment(id: String) async {
        guard let coordinator, !isWorking, !hasPendingLocalPersistence else { return }
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
            publish(
                try await coordinator.transcribeSegment(
                    segmentID: segment.id,
                    commandID: commandID(
                        isInitial ? "initial-transcription" : "retry-transcription"
                    )
                )
            )
        } catch {
            publish(coordinator.snapshot)
            handleCredentialFailure(error)
            errorMessage = safeMessage(for: error)
        }
    }

    func excludeSegment(id: String) async {
        guard let coordinator, !isWorking, !hasPendingLocalPersistence else { return }
        guard let segment = draftSegments.first(where: { $0.id.rawValue == id }),
              segment.canExcludeFromAnswer else {
            return
        }
        isWorking = true
        errorMessage = nil
        statusMessage = "Preserving recording and excluding segment…"
        defer { isWorking = false }
        do {
            publish(
                try await coordinator.excludeSegment(
                    segmentID: segment.id,
                    reason: exclusionReason(for: segment),
                    commandID: commandID("exclude-segment")
                )
            )
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
        guard let coordinator, let grace = activeEndpointGrace, canKeepFloor else {
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            publish(
                try await coordinator.cancelEndpointGrace(
                    graceID: grace.id,
                    commandID: commandID("keep-floor")
                )
            )
        } catch {
            publish(coordinator.snapshot)
            errorMessage = "Automatic Hand off could not be cancelled. Begin recording or retry Keep my floor."
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
                try await syncHostedPairs(from: snapshot)
                updated = try await coordinator.giveCandidateFloor(
                    commandID: commandID("give-floor")
                )
            case .ready, .completed:
                return
            }
            publish(updated)
            try await syncHostedPairs(from: updated)
            await interviewerSpeechCoordinator?
                .observeNewlyPersistedSnapshot(updated)
        } catch {
            publish(coordinator.snapshot)
            errorWasCodexFailure = applyCodexFailure(error)
            errorMessage = safeMessage(for: error)
        }
    }

    @discardableResult
    func finishInterview() async -> Bool {
        await finishInterview(hostedNextActivityID: nil)
    }

    @discardableResult
    func finishAndOpenNextInterview() async -> Bool {
        guard let nextActivityID = hostedNextCodingActivityID else {
            errorMessage = "There is no later coding activity in this hosted session."
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
        guard !isWorking, !hasPendingLocalPersistence else { return false }
        guard let coordinator, let snapshot else { return false }
        if snapshot.phase == .completed,
           (
               hostedController == nil
                   || hostedSnapshot.activity?.activity.lifecycle == .completed
           ) {
            return true
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
            await flushSourceToDisk()
            if snapshot.phase != .completed {
                try await syncHostedPairs(from: snapshot)
                publish(
                    try await coordinator.finishSession(
                        commandID: commandID("finish-interview")
                    )
                )
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
            return true
        } catch {
            publish(coordinator.snapshot)
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
        snapshot = nil
        segments = []
        sourceURL = nil
        sourceText = ""
        isJavaFileLoaded = false
        didStartTimerAfterFileLoad = false
        latestRunReceipt = nil
        latestSubmissionReceipt = nil
        isHarnessRunning = false
        isSubmitting = false
        outputFocus = .harness
        harnessRunTask?.cancel()
        harnessRunTask = nil
        harnessGeneration += 1
        errorMessage = nil
        statusMessage = "Opening the next hosted coding activity…"
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

    func startSpeechModelDownload() {
        guard speechPreparationTask == nil,
              let interviewerSpeechCoordinator else { return }
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
              let interviewerSpeechCoordinator else { return }
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
        isSpeechMuted = speechMuteController.isMuted
        preferences.set(isSpeechMuted, forKey: Self.speechMutedPreferenceKey)
        if isSpeechMuted { playingUtteranceID = nil }
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
              !isSpeechControlActionInFlight else { return }
        isSpeechControlActionInFlight = true
        playingUtteranceID = utteranceID
        speechErrorMessage = nil
        defer {
            playingUtteranceID = nil
            isSpeechControlActionInFlight = false
        }
        do {
            try await interviewerSpeechCoordinator.play(utteranceID: utteranceID)
        } catch is CancellationError {
        } catch {
            speechErrorMessage = safeSpeechMessage(for: error)
        }
    }

    func retrySpeech(utteranceID: InterviewerUtteranceID) async {
        guard let interviewerSpeechCoordinator,
              isSpeechReady,
              !isSpeechMuted,
              !isSpeechControlActionInFlight else { return }
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

    func updateSourceText(_ text: String) {
        guard isJavaFileLoaded, snapshot?.phase != .completed else { return }
        sourceText = text
        pendingSourceText = text
        sourceSavePresentation = "Saving…"
        scheduleSourceSave()
    }

    func bindLoadedJavaFileForTesting(fileURL: URL, text: String) {
        sourceURL = fileURL
        sourceText = text
        sourceFileName = fileURL.lastPathComponent
        isJavaFileLoaded = true
        pendingSourceText = nil
        sourceSavePresentation = "Saved locally"
    }

    func quickRun() async { await startHarnessRun(commandClass: .quickRun) }
    func fullRun() async { await startHarnessRun(commandClass: .fullRun) }

    func submitToLeetCode() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        await flushSourceToDisk()
        let command = nextSubmissionCommand()
        let invocationID = LeetCodeControllerClient.makeInvocationID(
            prefix: command == .retry ? "live-retry" : "live-submit"
        )
        guard let repositoryRoot = interviewArcRepositoryRoot else {
            presentSubmissionFailure(
                invocationID: invocationID,
                command: command,
                message: LeetCodeControllerError.controllerMissing.errorDescription
                    ?? "Open LeetCode needs a linked Interview Arc checkout with the checked-in Playwright controller."
            )
            return
        }
        guard let problemURL = leetCodeProblemURL else {
            presentSubmissionFailure(
                invocationID: invocationID,
                command: command,
                message: LeetCodeControllerError.missingProblemURL.errorDescription
                    ?? "This activity does not have a verified LeetCode URL."
            )
            return
        }
        guard let javaFile = sourceURL else {
            presentSubmissionFailure(
                invocationID: invocationID,
                command: command,
                message: "The Java file is not loaded."
            )
            return
        }

        outputFocus = .submission
        latestSubmissionReceipt = .submitting(
            invocationID: invocationID,
            command: command
        )

        let receipt = await LeetCodeControllerClient.submitRecoveringAmbiguousOutput(
            LeetCodeControllerRequest(
                repositoryRoot: repositoryRoot,
                problemURL: problemURL,
                title: hostedSnapshot.activity?.activity.title ?? question
            ),
            javaFile: javaFile,
            invocationID: invocationID,
            command: command,
            nodeExecutable: controllerNodeExecutable,
            execute: controllerExecute
        )
        latestSubmissionReceipt = receipt
        outputFocus = .submission
    }

    func openLeetCode() async {
        guard !isOpeningLeetCode else { return }
        guard let repositoryRoot = interviewArcRepositoryRoot else {
            workSurfaceMessage = LeetCodeControllerError.controllerMissing.errorDescription
            return
        }
        guard let url = leetCodeProblemURL else {
            workSurfaceMessage = LeetCodeControllerError.missingProblemURL.errorDescription
            return
        }
        isOpeningLeetCode = true
        defer { isOpeningLeetCode = false }
        let title = hostedSnapshot.activity?.activity.title ?? question
        let result = await LeetCodeControllerClient.openProblem(
            LeetCodeControllerRequest(
                repositoryRoot: repositoryRoot,
                problemURL: url,
                title: title
            ),
            nodeExecutable: controllerNodeExecutable,
            execute: controllerExecute
        )
        switch result {
        case .success(let message):
            workSurfaceMessage = message
        case .failure(let error):
            workSurfaceMessage = error.localizedDescription
        }
    }

    var outputDrawerTitle: String {
        if focusedOutputIsSubmission {
            return "Submit"
        }
        return latestRunReceipt?.commandClass.rawValue ?? "Output"
    }

    var outputDrawerSummary: String? {
        if focusedOutputIsSubmission {
            return latestSubmissionReceipt?.summaryLine
        }
        guard let receipt = latestRunReceipt else { return nil }
        if receipt.outcome == .running {
            return "\(receipt.commandClass.rawValue) · running"
        }
        return receipt.summaryLine
    }

    var outputDrawerIsSuccess: Bool {
        if focusedOutputIsSubmission {
            return latestSubmissionReceipt?.outcome.isAccepted == true
        }
        return latestRunReceipt?.outcome.isSuccess == true
    }

    var focusedOutputIsSubmission: Bool {
        outputFocus == .submission || isSubmitting
    }

    var focusedOutputDiagnostics: String {
        if focusedOutputIsSubmission {
            let receipt = latestSubmissionReceipt
            return receipt?.diagnostics.isEmpty == false
                ? receipt?.diagnostics ?? ""
                : receipt?.summaryLine ?? ""
        }
        let receipt = latestRunReceipt
        return receipt?.diagnostics.isEmpty == false
            ? receipt?.diagnostics ?? ""
            : receipt?.summaryLine ?? ""
    }

    private func loadJavaSource() async {
        guard let activity = hostedSnapshot.activity?.activity else { return }
        do {
            let identity = try CodingSourceStore.identity(
                activityID: activity.id,
                questionID: activity.questionId,
                title: activity.title
            )
            let supportRoot = try applicationSupportRoot
                ?? LivePaths.applicationSupportRoot()
            let url = try CodingSourceStore.resolveURL(
                identity: identity,
                applicationSupportRoot: supportRoot,
                interviewArcRepositoryRoot: interviewArcRepositoryRoot
            )
            sourceURL = url
            sourceFileName = identity.fileName
            if FileManager.default.fileExists(atPath: url.path),
               let existing = try? String(contentsOf: url, encoding: .utf8) {
                sourceText = existing
            } else {
                sourceText = CodingSourceStore.defaultJavaSource(
                    title: activity.title,
                    problemURL: CodingSourceStore.leetCodeProblemURL(
                        questionID: activity.questionId,
                        title: activity.title
                    )
                )
                try CodingSourceStore.atomicWrite(sourceText, to: url)
            }
            pendingSourceText = nil
            sourceSavePresentation = "Saved locally"
            isJavaFileLoaded = true
            await startHostedTimerAfterFileLoad()
        } catch {
            workSurfaceMessage = "The Java file could not be opened. Hand off remains available."
            isJavaFileLoaded = false
        }
    }

    private func startHostedTimerAfterFileLoad() async {
        guard !didStartTimerAfterFileLoad,
              isJavaFileLoaded,
              let hostedController,
              hostedSnapshot.connection == .writable,
              !hostedTimerIsRunning else {
            return
        }
        do {
            try await hostedController.startTimer()
            hostedSnapshot = hostedController.snapshot
            didStartTimerAfterFileLoad = true
        } catch {
            hostedSnapshot = hostedController.snapshot
            errorMessage = "The Java file is ready, but the hosted timer could not start. Use Start when the writer is available."
        }
    }

    private func scheduleSourceSave() {
        sourceSaveTask?.cancel()
        sourceSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.flushSourceToDisk()
        }
    }

    private func flushSourceToDisk() async {
        guard let text = pendingSourceText ?? (isJavaFileLoaded ? sourceText : nil),
              let url = sourceURL else {
            sourceSaveTask = nil
            return
        }
        isSourceSaving = true
        defer {
            isSourceSaving = false
            sourceSaveTask = nil
        }
        do {
            try CodingSourceStore.atomicWrite(text, to: url)
            if pendingSourceText == text {
                pendingSourceText = nil
            }
            sourceSavePresentation = "Saved locally"
        } catch {
            sourceSavePresentation = "Save failed · retry by editing"
        }
    }

    private func startHarnessRun(commandClass: CodingHarnessCommandClass) async {
        harnessRunTask?.cancel()
        harnessGeneration += 1
        let generation = harnessGeneration
        let task = Task { @MainActor [weak self] in
            await self?.runHarness(commandClass: commandClass, generation: generation)
        }
        harnessRunTask = task
        await task.value
    }

    private func runHarness(
        commandClass: CodingHarnessCommandClass,
        generation: Int
    ) async {
        await flushSourceToDisk()
        guard generation == harnessGeneration else { return }
        let identity = "run-\(UUID().uuidString.lowercased())"
        guard let repositoryRoot = interviewArcRepositoryRoot,
              let activityID = hostedSnapshot.activityID else {
            latestRunReceipt = .notReady(
                identity: identity,
                commandClass: commandClass
            )
            isHarnessRunning = false
            outputFocus = .harness
            return
        }

        isHarnessRunning = true
        outputFocus = .harness
        latestRunReceipt = .running(identity: identity, commandClass: commandClass)

        let receipt = await CodingHarnessClient.run(
            CodingHarnessInvocation(
                repositoryRoot: repositoryRoot,
                activityID: activityID,
                commandClass: commandClass,
                harnessStateRoot: applicationSupportRoot.map {
                    $0.appendingPathComponent("leetcode-java-harnesses", isDirectory: true)
                }
            ),
            identity: identity,
            nodeExecutable: harnessNodeExecutable,
            execute: harnessExecute,
            onOutput: { [weak self] chunk in
                Task { @MainActor in
                    self?.appendHarnessStream(
                        chunk,
                        identity: identity,
                        commandClass: commandClass,
                        generation: generation
                    )
                }
            }
        )
        guard generation == harnessGeneration else { return }
        latestRunReceipt = receipt
        isHarnessRunning = false
        outputFocus = .harness
    }

    private func appendHarnessStream(
        _ chunk: String,
        identity: String,
        commandClass: CodingHarnessCommandClass,
        generation: Int
    ) {
        guard generation == harnessGeneration,
              let current = latestRunReceipt,
              current.identity == identity,
              current.outcome == .running else {
            return
        }
        let combined = [current.diagnostics, chunk]
            .filter { !$0.isEmpty }
            .joined(separator: current.diagnostics.hasSuffix("\n") || chunk.hasPrefix("\n") ? "" : "\n")
        latestRunReceipt = CodingHarnessReceipt(
            identity: identity,
            commandClass: commandClass,
            exitCode: -1,
            outcome: .running,
            diagnostics: cappedStreamDiagnostics(combined)
        )
    }

    private func cappedStreamDiagnostics(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.suffix(80)).joined(separator: "\n")
    }

    private func nextSubmissionCommand() -> CodingSubmissionCommand {
        if case .accepted = latestSubmissionReceipt?.outcome {
            return .retry
        }
        if case .rejected(verdict: _) = latestSubmissionReceipt?.outcome {
            return .retry
        }
        return .submit
    }

    private func presentSubmissionFailure(
        invocationID: String,
        command: CodingSubmissionCommand,
        message: String
    ) {
        outputFocus = .submission
        workSurfaceMessage = message
        latestSubmissionReceipt = CodingSubmissionReceipt(
            invocationID: invocationID,
            command: command,
            outcome: .failed(code: nil, message: message),
            diagnostics: message
        )
    }

    private func warmLeetCodeController() async {
        guard !isControllerWarming else { return }
        guard let repositoryRoot = interviewArcRepositoryRoot,
              let url = leetCodeProblemURL else {
            return
        }
        isControllerWarming = true
        defer { isControllerWarming = false }
        let title = hostedSnapshot.activity?.activity.title ?? question
        let result = await LeetCodeControllerClient.openProblem(
            LeetCodeControllerRequest(
                repositoryRoot: repositoryRoot,
                problemURL: url,
                title: title
            ),
            nodeExecutable: controllerNodeExecutable,
            execute: controllerExecute
        )
        switch result {
        case .success(let message):
            workSurfaceMessage = message
        case .failure(let error):
            workSurfaceMessage = error.localizedDescription
        }
    }

    private var harnessNodeExecutable: URL? {
        harnessExecute == nil ? nil : URL(fileURLWithPath: "/usr/bin/true")
    }

    private var controllerNodeExecutable: URL? {
        controllerExecute == nil ? nil : URL(fileURLWithPath: "/usr/bin/true")
    }

    private func attachInterviewerSpeech(
        to conversation: SegmentSpeechCoordinator
    ) async {
        do {
            let dependencies: LiveInterviewerSpeechDependencies
            if let speechDependencies {
                dependencies = speechDependencies
            } else {
                dependencies = try Self.makeLiveSpeechDependencies()
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
                guard let self, let speech,
                      self.interviewerSpeechCoordinator === speech else { return }
                self.publish(next)
            }
            speech.setReadinessHandler { [weak self, weak speech] next in
                guard let self, let speech,
                      self.interviewerSpeechCoordinator === speech else { return }
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

    private static func makeLiveSpeechDependencies() throws
        -> LiveInterviewerSpeechDependencies
    {
        let audioStore = LiveInterviewerSpeechAudioStore()
        return LiveInterviewerSpeechDependencies(
            provider: try QwenInterviewerSpeechProvider(),
            player: AVAudioEngineInterviewerSpeechPlayer(audioStore: audioStore),
            audioStore: audioStore
        )
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
            return UnavailableCodingCodexRuntime()
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
                if presentWhenMissing { isCredentialSetupPresented = true }
            case .keychainUnavailable:
                credentialState = .unusable
                credentialErrorMessage = "macOS Keychain is unavailable. Use the key until quit to record in this app session."
                if presentWhenMissing { isCredentialSetupPresented = true }
            }
        } catch {
            credentialState = .unusable
            credentialErrorMessage = "macOS Keychain is unavailable."
            if presentWhenMissing { isCredentialSetupPresented = true }
        }
    }

    private func status(for snapshot: InterviewRoomSnapshot?) -> String {
        if isCodingActivityMissing {
            return "No focused LeetCode activity"
        }
        guard let snapshot else { return "Restoring local session…" }
        let draft = snapshot.segments.filter { $0.committedTurnID == nil }
        if snapshot.endpointGraces.contains(where: { $0.lifecycle == .pending }) {
            return "Handing off in 4 seconds · Keep my floor to cancel"
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
            if !hasUsableGroqCredential { return "Groq key required" }
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

    private func exclusionReason(for segment: CandidateSegment) -> SegmentExclusionReason {
        if segment.captureFailureReason != nil { return .captureFailed }
        if segment.capturedAudio?.integrityReasons.contains(.insufficientSignal) == true
            || segment.transcriptionAttempts.last?.failure?.reason == .insufficientSignal {
            return .insufficientSignal
        }
        if segment.selectedCandidate == nil { return .noUsableTranscript }
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

    @discardableResult
    private func applyCodexFailure(_ error: Error) -> Bool {
        guard let runtimeError = error as? CodexAppServerRuntimeError else {
            return false
        }
        switch runtimeError {
        case .missing: codexReadiness = .missing
        case .incompatible(let actualVersion, let requiredVersion):
            codexReadiness = .incompatible(
                actualVersion: actualVersion,
                requiredVersion: requiredVersion
            )
        case .unauthenticated: codexReadiness = .unauthenticated
        case .transportFailure: codexReadiness = .transportFailure
        case .protocolFailure, .serverFailure, .malformedFinalResponse, .cancelled:
            break
        }
        return true
    }

    private func safeSpeechMessage(for error: Error) -> String {
        if let coordinatorError = error as? InterviewerSpeechCoordinatorError {
            switch coordinatorError {
            case .modelNotReady:
                return "Install and verify Mara’s local model before generating speech. The written turn is ready."
            case .muted:
                return "Mara is muted. Unmute before playing or generating speech."
            case .operationInProgress, .playbackInProgress, .modelPreparationInProgress:
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

    private func safeMessage(for error: Error) -> String {
        if let runtimeError = error as? CodexAppServerRuntimeError {
            return SystemDesignRoomModel.safeCodexFailureMessage(for: runtimeError)
        }
        if let coordinatorError = error as? SegmentSpeechCoordinatorError {
            switch coordinatorError {
            case .noActiveSegment:
                return "No active recording was available to stop. The latest durable state is shown."
            case .segmentAudioUnavailable:
                return "The source recording is unavailable for this segment."
            case .captureFailed(.microphoneUnavailable), .captureFailed(.captureStartFailed):
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

private actor UnavailableCodingCodexRuntime: LiveCodexInterviewerRuntime {
    func preflight() async -> CodexAppServerReadiness { .transportFailure }

    func respond(
        to request: InterviewerRequest
    ) async throws -> CanonicalInterviewerResponse {
        throw CodexAppServerRuntimeError.transportFailure
    }
}
