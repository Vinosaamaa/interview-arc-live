import XCTest
@testable import InterviewArcLive

final class BehavioralWorkSurfaceTests: XCTestCase {
    func testStoryKitCapsAtThreeCandidates() {
        let extras = (0..<5).map { index in
            BehavioralStoryCandidate(
                storyId: "story-\(index)",
                displayLabel: "Story \(index)",
                status: .pending,
                acceptedFactCount: 0,
                gapCount: 1,
                summary: "Fixture candidate \(index).",
                isHypothetical: false
            )
        }
        let kit = BehavioralStoryKit(candidates: extras)
        XCTAssertEqual(kit.candidates.count, BehavioralStoryKit.maximumCandidates)
        XCTAssertEqual(kit.candidates.map(\.storyId), ["story-0", "story-1", "story-2"])
        XCTAssertEqual(
            BehavioralWorkSurface.preflightFixture().storyKit.candidates.count,
            3
        )
    }

    func testPreflightStatusesCoverTheEvidenceVocabulary() {
        let statuses = Set(
            BehavioralWorkSurface.preflightFixture().storyKit.candidates.map(\.status)
        )
        XCTAssertTrue(statuses.contains(.ownerAttested))
        XCTAssertTrue(statuses.contains(.corroborated))
        XCTAssertTrue(statuses.contains(.partial))
        XCTAssertEqual(
            Set(BehavioralEvidenceStatus.allCases),
            [
                .ownerAttested,
                .corroborated,
                .partial,
                .contradicted,
                .pending,
            ]
        )
        XCTAssertFalse(
            BehavioralWorkSurface.preflightFixture().openGaps.isEmpty
        )
    }

    func testProjectAndResumeSectionKeysMatchTheContract() {
        XCTAssertEqual(
            BehavioralProjectKit.sectionKeys,
            [
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
        )
        XCTAssertEqual(
            BehavioralResumeClaimKit.sectionKeys,
            [
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
        )
        let project = BehavioralWorkSurface.projectKitFixture
        XCTAssertEqual(project.projectId, "payments-migration")
        XCTAssertEqual(project.sections.map(\.sectionKey), BehavioralProjectKit.sectionKeys)
        let claim = BehavioralWorkSurface.resumeClaimKitFixture
        XCTAssertEqual(claim.sourceClaimId, "claim-checkout-cache")
        XCTAssertEqual(claim.projectId, "payments-migration")
        XCTAssertEqual(
            claim.sections.map(\.sectionKey),
            BehavioralResumeClaimKit.sectionKeys
        )
        XCTAssertNotEqual(claim.sourceClaimId, claim.sections.first?.title)
    }

    func testLiveSidecarOmitsPreferredAnswerText() {
        let surface = BehavioralWorkSurface.preflightFixture()
        let sidecar = surface.liveSidecarText
        XCTAssertTrue(sidecar.contains("family=starBank"))
        XCTAssertTrue(sidecar.contains("projectId=payments-migration"))
        XCTAssertTrue(sidecar.contains("sourceClaimId=claim-checkout-cache"))
        XCTAssertFalse(sidecar.localizedCaseInsensitiveContains("preferred answer"))
        XCTAssertFalse(sidecar.localizedCaseInsensitiveContains("model answer"))
        XCTAssertFalse(sidecar.contains("A strong model answer"))
    }

    func testFamilySelectionDoesNotUseTitlesAsBindingAuthority() {
        var surface = BehavioralWorkSurface.preflightFixture(family: .projectOverview)
        XCTAssertEqual(surface.projectKit?.projectId, "payments-migration")
        surface.selectProjectSection("ownership_and_evidence")
        XCTAssertEqual(surface.projectKit?.selectedSectionKey, "ownership_and_evidence")

        surface.selectQuestionFamily(.resumeClaim)
        XCTAssertEqual(surface.resumeClaimKit?.sourceClaimId, "claim-checkout-cache")
        surface.selectResumeSection("likely_follow_ups")
        XCTAssertEqual(surface.resumeClaimKit?.selectedSectionKey, "likely_follow_ups")
    }

    func testCoachedDiscoveryAndReturnToInterviewer() {
        var surface = BehavioralWorkSurface.preflightFixture()
        XCTAssertEqual(surface.mode, .interviewer)
        surface.beginCoachedDiscovery()
        XCTAssertEqual(surface.mode, .coachedDiscovery)
        surface.returnToInterviewer()
        XCTAssertEqual(surface.mode, .interviewer)
    }

    func testStarlIsCoverageStatesNotAScore() {
        let coverage = STARLCoverage(
            states: [
                .situation: .filled,
                .action: .current,
            ]
        )
        XCTAssertEqual(coverage.state(for: .situation), .filled)
        XCTAssertEqual(coverage.state(for: .task), .empty)
        XCTAssertEqual(coverage.state(for: .action), .current)
        XCTAssertEqual(coverage.filledCount, 1)
        XCTAssertNil(
            Mirror(reflecting: coverage).children.first {
                $0.label == "score"
            }
        )
    }
}
