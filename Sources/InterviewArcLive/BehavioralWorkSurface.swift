import Foundation

/// Question family for one Behavioral room opening. Labels are presentation
/// only; project and claim bindings use stable IDs, never titles.
enum BehavioralQuestionFamily: String, CaseIterable, Identifiable, Sendable {
    case starBank
    case projectOverview
    case resumeClaim
    case focusedDeepDive
    case practiceScenario

    var id: String { rawValue }

    var title: String {
        switch self {
        case .starBank: "STAR bank"
        case .projectOverview: "Project overview"
        case .resumeClaim: "Resume claim"
        case .focusedDeepDive: "Focused deep dive"
        case .practiceScenario: "Practice scenario"
        }
    }

    var primaryKit: BehavioralKitKind {
        switch self {
        case .projectOverview: .project
        case .resumeClaim: .claim
        case .starBank, .focusedDeepDive, .practiceScenario: .story
        }
    }

    var isHypothetical: Bool { self == .practiceScenario }
}

enum BehavioralKitKind: String, CaseIterable, Sendable {
    case story
    case project
    case claim

    var title: String {
        switch self {
        case .story: "Story kit"
        case .project: "Project kit"
        case .claim: "Claim kit"
        }
    }
}

enum BehavioralInterviewMode: String, Sendable, Equatable {
    case interviewer
    case coachedDiscovery

    var title: String {
        switch self {
        case .interviewer: "Interviewer"
        case .coachedDiscovery: "Coached discovery"
        }
    }
}

enum BehavioralEvidenceStatus: String, CaseIterable, Sendable, Equatable {
    case ownerAttested = "owner-attested"
    case corroborated
    case partial
    case contradicted
    case pending

    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .ownerAttested: "checkmark.seal.fill"
        case .corroborated: "checkmark.circle.fill"
        case .partial: "minus.circle.fill"
        case .contradicted: "xmark.octagon.fill"
        case .pending: "clock.fill"
        }
    }
}

enum STARLLane: String, CaseIterable, Identifiable, Sendable {
    case situation
    case task
    case action
    case result
    case learning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .situation: "Situation"
        case .task: "Task"
        case .action: "Action"
        case .result: "Result"
        case .learning: "Learning"
        }
    }

    var shortTitle: String {
        switch self {
        case .situation: "S"
        case .task: "T"
        case .action: "A"
        case .result: "R"
        case .learning: "L"
        }
    }
}

/// Coverage only. STARL is not a live score.
enum STARLCoverageState: String, Sendable, Equatable {
    case filled
    case current
    case empty
}

struct STARLCoverage: Equatable, Sendable {
    var states: [STARLLane: STARLCoverageState]

    init(states: [STARLLane: STARLCoverageState]) {
        var resolved: [STARLLane: STARLCoverageState] = [:]
        for lane in STARLLane.allCases {
            resolved[lane] = states[lane] ?? .empty
        }
        self.states = resolved
    }

    static let empty = STARLCoverage(states: [:])

    func state(for lane: STARLLane) -> STARLCoverageState {
        states[lane] ?? .empty
    }

    var filledCount: Int {
        STARLLane.allCases.filter { state(for: $0) == .filled }.count
    }
}

struct BehavioralStoryCandidate: Equatable, Identifiable, Sendable {
    let storyId: String
    let displayLabel: String
    let status: BehavioralEvidenceStatus
    let acceptedFactCount: Int
    let gapCount: Int
    let summary: String
    let isHypothetical: Bool

    var id: String { storyId }
}

struct BehavioralStoryKit: Equatable, Sendable {
    static let maximumCandidates = 3

    let candidates: [BehavioralStoryCandidate]

    init(candidates: [BehavioralStoryCandidate]) {
        self.candidates = Array(candidates.prefix(Self.maximumCandidates))
    }
}

struct BehavioralProfileSection: Equatable, Identifiable, Sendable {
    let sectionKey: String
    let title: String
    let coverage: STARLCoverageState
    let gap: String?

    var id: String { sectionKey }
}

struct BehavioralProjectKit: Equatable, Sendable {
    static let sectionKeys = [
        "orientation",
        "architecture",
        "end_to_end_flows",
        "ownership_and_evidence",
        "decisions_and_tradeoffs",
        "operations_reliability_security",
        "results_and_gaps",
        "interview_walkthrough",
        "likely_follow_ups",
    ]

    /// Stable project identity. Titles are never binding authority.
    let projectId: String
    let sections: [BehavioralProfileSection]
    var selectedSectionKey: String
    let conspicuousGap: String?
}

struct BehavioralResumeClaimKit: Equatable, Sendable {
    static let sectionKeys = [
        "claim_and_evidence",
        "project_context",
        "problem_and_constraints",
        "implementation_mechanics",
        "ownership_and_decisions",
        "alternatives_and_tradeoffs",
        "operations_and_risks",
        "result_and_limitations",
        "interview_walkthrough",
        "likely_follow_ups",
    ]

    /// Stable claim identity. Titles are never binding authority.
    let sourceClaimId: String
    let projectId: String
    let sections: [BehavioralProfileSection]
    var selectedSectionKey: String
    let contraryNote: String?
    let conspicuousGap: String?
}

enum BehavioralWorkSurfacePane: String, CaseIterable, Identifiable, Sendable {
    case kit
    case starl
    case notes

    var id: String { rawValue }

    func title(for family: BehavioralQuestionFamily) -> String {
        switch self {
        case .kit: family.primaryKit.title
        case .starl: "STARL"
        case .notes: "Notes"
        }
    }
}

/// Live sidecar payload. It must never carry a preferred or model answer.
struct BehavioralWorkSurface: Equatable, Sendable {
    var questionFamily: BehavioralQuestionFamily
    var mode: BehavioralInterviewMode
    var question: String
    var storyKit: BehavioralStoryKit
    var selectedStoryId: String?
    var starl: STARLCoverage
    var projectKit: BehavioralProjectKit?
    var resumeClaimKit: BehavioralResumeClaimKit?
    var notes: String
    var openGaps: [String]
    var selectedPane: BehavioralWorkSurfacePane

    var primaryKit: BehavioralKitKind { questionFamily.primaryKit }

    var selectedStory: BehavioralStoryCandidate? {
        storyKit.candidates.first { $0.storyId == selectedStoryId }
            ?? storyKit.candidates.first
    }

    var liveSidecarText: String {
        var lines = [
            "family=\(questionFamily.rawValue)",
            "mode=\(mode.rawValue)",
            "question=\(question)",
        ]
        for story in storyKit.candidates {
            lines.append(
                "story=\(story.storyId)|\(story.status.rawValue)|facts=\(story.acceptedFactCount)|gaps=\(story.gapCount)"
            )
        }
        for lane in STARLLane.allCases {
            lines.append("starl.\(lane.rawValue)=\(starl.state(for: lane).rawValue)")
        }
        if let projectKit {
            lines.append("projectId=\(projectKit.projectId)")
            lines.append(
                "projectSections=\(projectKit.sections.map(\.sectionKey).joined(separator: ","))"
            )
        }
        if let resumeClaimKit {
            lines.append("sourceClaimId=\(resumeClaimKit.sourceClaimId)")
            lines.append("claimProjectId=\(resumeClaimKit.projectId)")
            lines.append(
                "claimSections=\(resumeClaimKit.sections.map(\.sectionKey).joined(separator: ","))"
            )
        }
        lines.append("gaps=\(openGaps.joined(separator: "|"))")
        return lines.joined(separator: "\n")
    }

    mutating func selectQuestionFamily(_ family: BehavioralQuestionFamily) {
        questionFamily = family
        selectedPane = .kit
        if family.isHypothetical {
            storyKit = BehavioralWorkSurface.practiceScenarioKit
            selectedStoryId = storyKit.candidates.first?.storyId
            openGaps = ["Labeled hypothetical · not personal evidence"]
        }
    }

    mutating func beginCoachedDiscovery() {
        mode = .coachedDiscovery
    }

    mutating func returnToInterviewer() {
        mode = .interviewer
    }

    mutating func selectPane(_ pane: BehavioralWorkSurfacePane) {
        selectedPane = pane
    }

    mutating func selectStory(id: String) {
        guard storyKit.candidates.contains(where: { $0.storyId == id }) else { return }
        selectedStoryId = id
    }

    mutating func selectProjectSection(_ sectionKey: String) {
        guard var projectKit,
              projectKit.sections.contains(where: { $0.sectionKey == sectionKey }) else {
            return
        }
        projectKit.selectedSectionKey = sectionKey
        self.projectKit = projectKit
    }

    mutating func selectResumeSection(_ sectionKey: String) {
        guard var resumeClaimKit,
              resumeClaimKit.sections.contains(where: { $0.sectionKey == sectionKey }) else {
            return
        }
        resumeClaimKit.selectedSectionKey = sectionKey
        self.resumeClaimKit = resumeClaimKit
    }

    static func preflightFixture(
        family: BehavioralQuestionFamily = .starBank
    ) -> BehavioralWorkSurface {
        var surface = BehavioralWorkSurface(
            questionFamily: family,
            mode: .interviewer,
            question: Self.question(for: family),
            storyKit: family.isHypothetical ? practiceScenarioKit : starBankKit,
            selectedStoryId: nil,
            starl: STARLCoverage(
                states: [
                    .situation: .filled,
                    .task: .filled,
                    .action: .current,
                    .result: .empty,
                    .learning: .empty,
                ]
            ),
            projectKit: projectKitFixture,
            resumeClaimKit: resumeClaimKitFixture,
            notes: "",
            openGaps: [
                "Production impact is not confirmed.",
            ],
            selectedPane: .kit
        )
        surface.selectedStoryId = surface.storyKit.candidates.first?.storyId
        if family.isHypothetical {
            surface.openGaps = ["Labeled hypothetical · not personal evidence"]
        }
        return surface
    }

    static func question(for family: BehavioralQuestionFamily) -> String {
        switch family {
        case .starBank:
            return "Tell me about a time you disagreed with a technical decision."
        case .projectOverview:
            return "Walk me through this project from orientation through the follow-ups you expect."
        case .resumeClaim:
            return "Walk me through this résumé claim using the bound evidence, not the title."
        case .focusedDeepDive:
            return "Stay on the decision you owned. What constraints forced the tradeoff?"
        case .practiceScenario:
            return "Practice scenario: a teammate wants to skip a rollback plan. What do you do?"
        }
    }

    static let starBankKit = BehavioralStoryKit(
        candidates: [
            BehavioralStoryCandidate(
                storyId: "story-migration-rollout",
                displayLabel: "Migration rollout",
                status: .ownerAttested,
                acceptedFactCount: 2,
                gapCount: 1,
                summary: "Owner-attested cutover ownership with one open impact gap.",
                isHypothetical: false
            ),
            BehavioralStoryCandidate(
                storyId: "story-incident-recovery",
                displayLabel: "Incident recovery",
                status: .corroborated,
                acceptedFactCount: 3,
                gapCount: 0,
                summary: "Corroborated recovery path with accepted facts only.",
                isHypothetical: false
            ),
            BehavioralStoryCandidate(
                storyId: "story-cross-team-launch",
                displayLabel: "Cross-team launch",
                status: .partial,
                acceptedFactCount: 0,
                gapCount: 1,
                summary: "Partial result metric. Unconfirmed.",
                isHypothetical: false
            ),
        ]
    )

    static let practiceScenarioKit = BehavioralStoryKit(
        candidates: [
            BehavioralStoryCandidate(
                storyId: "scenario-rollback-plan",
                displayLabel: "Rollback plan (hypothetical)",
                status: .pending,
                acceptedFactCount: 0,
                gapCount: 1,
                summary: "Labeled practice scenario. Not personal evidence.",
                isHypothetical: true
            ),
            BehavioralStoryCandidate(
                storyId: "scenario-oncall-page",
                displayLabel: "On-call page (hypothetical)",
                status: .pending,
                acceptedFactCount: 0,
                gapCount: 1,
                summary: "Labeled practice scenario. Not personal evidence.",
                isHypothetical: true
            ),
            BehavioralStoryCandidate(
                storyId: "scenario-api-freeze",
                displayLabel: "API freeze (hypothetical)",
                status: .pending,
                acceptedFactCount: 0,
                gapCount: 1,
                summary: "Labeled practice scenario. Not personal evidence.",
                isHypothetical: true
            ),
        ]
    )

    static let projectKitFixture = BehavioralProjectKit(
        projectId: "payments-migration",
        sections: BehavioralProjectKit.sectionKeys.enumerated().map { index, key in
            BehavioralProfileSection(
                sectionKey: key,
                title: Self.projectSectionTitle(key),
                coverage: index == 0 ? .filled : (index == 1 ? .current : .empty),
                gap: key == "ownership_and_evidence"
                    ? "On-call ownership after cutover is unknown."
                    : nil
            )
        },
        selectedSectionKey: "architecture",
        conspicuousGap: "On-call ownership after cutover is unknown."
    )

    static let resumeClaimKitFixture = BehavioralResumeClaimKit(
        sourceClaimId: "claim-checkout-cache",
        projectId: "payments-migration",
        sections: BehavioralResumeClaimKit.sectionKeys.enumerated().map { index, key in
            BehavioralProfileSection(
                sectionKey: key,
                title: Self.resumeSectionTitle(key),
                coverage: index == 0 ? .current : .empty,
                gap: key == "claim_and_evidence"
                    ? "Exact p99 baseline timestamp unknown."
                    : nil
            )
        },
        selectedSectionKey: "claim_and_evidence",
        contraryNote: "Doc says 18% but answer said about 20%.",
        conspicuousGap: "Exact p99 baseline timestamp unknown."
    )

    static func projectSectionTitle(_ key: String) -> String {
        switch key {
        case "orientation": "Orientation"
        case "architecture": "Architecture"
        case "end_to_end_flows": "End-to-end flows"
        case "ownership_and_evidence": "Ownership and evidence"
        case "decisions_and_tradeoffs": "Decisions and tradeoffs"
        case "operations_reliability_security": "Operations, reliability, security"
        case "results_and_gaps": "Results and gaps"
        case "interview_walkthrough": "Interview walkthrough"
        case "likely_follow_ups": "Likely follow-ups"
        default: key
        }
    }

    static func resumeSectionTitle(_ key: String) -> String {
        switch key {
        case "claim_and_evidence": "Claim and evidence"
        case "project_context": "Project context"
        case "problem_and_constraints": "Problem and constraints"
        case "implementation_mechanics": "Implementation mechanics"
        case "ownership_and_decisions": "Ownership and decisions"
        case "alternatives_and_tradeoffs": "Alternatives and tradeoffs"
        case "operations_and_risks": "Operations and risks"
        case "result_and_limitations": "Result and limitations"
        case "interview_walkthrough": "Interview walkthrough"
        case "likely_follow_ups": "Likely follow-ups"
        default: key
        }
    }
}
