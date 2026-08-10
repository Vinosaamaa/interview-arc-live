import Foundation
import XCTest
@testable import InterviewArcLiveCore

@MainActor
final class BoardSessionTests: XCTestCase {
    func testSavedRevisionIsAtomicallyAttachedToHandOffAndSurvivesReplayAndRestore() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = InspectingInterviewerRuntime(
            store: store,
            response: CanonicalInterviewerResponse(
                displayMarkdown: "What fails when the cache is unavailable?",
                spokenText: "What fails when the cache is unavailable?"
            )
        )
        let sessionID = SessionID("public-board-session")
        let session = try await InterviewRoomSession.start(
            sessionID: sessionID,
            activityID: "public-system-design-activity",
            activityPrompt: try ActivityPrompt(
                specialty: .systemDesign,
                stage: "Architecture",
                question: "Design a public library catalog.",
                requestedParts: ["Draw the read path."]
            ),
            manifestStore: store,
            interviewerRuntime: runtime
        )
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("open-public-board-floor"))
        )

        let document = try BoardDocument(
            canvas: BoardCanvas(size: BoardSize(width: 1_200, height: 800)),
            elements: [
                .box(
                    BoardBox(
                        id: BoardElementID("catalog-service"),
                        frame: BoardRect(
                            origin: BoardPoint(x: 80, y: 100),
                            size: BoardSize(width: 240, height: 100)
                        ),
                        label: "Catalog service"
                    )
                )
            ]
        )
        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("persist-public-board-draft"),
                document: document
            )
        )
        let saved = try await session.execute(
            .saveBoardRevision(commandID: CommandID("save-public-board-revision"))
        )
        let revision = try XCTUnwrap(saved.board.revisions.first)
        XCTAssertEqual(revision.document, document)

        let handOff = InterviewRoomCommand.handOffWithBoard(
            commandID: CommandID("handoff-public-board-revision"),
            transcript: CandidateTranscript(
                body: "Reads pass through the catalog service.",
                quality: .verified
            ),
            boardAttachment: .revision(revision.id)
        )
        let first = try await session.execute(handOff)
        let replay = try await session.execute(handOff)

        XCTAssertEqual(replay, first)
        XCTAssertEqual(first.board.revisions, [revision])
        guard case .candidate(let candidate) = first.turns.first else {
            return XCTFail("Expected the durable Candidate Turn")
        }
        XCTAssertEqual(candidate.boardAttachment, .revision(revision.id))
        let persistedBeforeProvider = await runtime.candidateObservedBeforeResponse()
        XCTAssertEqual(persistedBeforeProvider, candidate)

        let loadedManifest = await store.load(sessionID: sessionID)
        let durableManifest = try XCTUnwrap(loadedManifest)
        let encodedManifest = try JSONEncoder().encode(durableManifest)
        let decodedManifest = try JSONDecoder().decode(
            SessionManifest.self,
            from: encodedManifest
        )
        let roundTripStore = InMemorySessionManifestStore(manifests: [decodedManifest])
        let restored = try await InterviewRoomSession.restore(
            sessionID: sessionID,
            manifestStore: roundTripStore,
            interviewerRuntime: runtime
        )
        let restoredSnapshot = await restored.snapshot()
        XCTAssertEqual(restoredSnapshot, first)
        XCTAssertEqual(restoredSnapshot.board.revisions, [revision])
        guard case .candidate(let restoredCandidate) = restoredSnapshot.turns.first else {
            return XCTFail("Expected the restored Candidate Turn")
        }
        XCTAssertEqual(restoredCandidate.boardAttachment, .revision(revision.id))
    }

    func testExplicitLaterAttachmentIsIdempotentAndCannotRewriteTurnEvidence() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = fixtureRuntime()
        let session = try await makeSession(store: store, runtime: runtime)
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("later-attachment-floor"))
        )
        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("later-attachment-draft-one"),
                document: try fixtureDocument(label: "Gateway")
            )
        )
        let firstSave = try await session.execute(
            .saveBoardRevision(commandID: CommandID("later-attachment-save-one"))
        )
        let firstRevision = try XCTUnwrap(firstSave.board.revisions.first)
        let handedOff = try await session.execute(
            .handOffWithBoard(
                commandID: CommandID("later-attachment-handoff"),
                transcript: CandidateTranscript(
                    body: "The gateway routes reads.",
                    quality: .verified
                ),
                boardAttachment: .noBoard
            )
        )
        guard case .candidate(let candidate) = handedOff.turns.first else {
            return XCTFail("Expected a Candidate Turn")
        }
        XCTAssertEqual(candidate.boardAttachment, .noBoard)

        let attachment = InterviewRoomCommand.attachBoardRevision(
            commandID: CommandID("attach-revision-later"),
            turnID: candidate.id,
            revisionID: firstRevision.id
        )
        let attached = try await session.execute(attachment)
        let replayed = try await session.execute(attachment)
        XCTAssertEqual(replayed, attached)
        guard case .candidate(let attachedCandidate) = attached.turns.first else {
            return XCTFail("Expected the attached Candidate Turn")
        }
        XCTAssertEqual(attachedCandidate.boardAttachment, .revision(firstRevision.id))

        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("later-attachment-draft-two"),
                document: try fixtureDocument(label: "Database")
            )
        )
        let secondSave = try await session.execute(
            .saveBoardRevision(commandID: CommandID("later-attachment-save-two"))
        )
        let secondRevision = try XCTUnwrap(secondSave.board.revisions.last)
        do {
            _ = try await session.execute(
                .attachBoardRevision(
                    commandID: CommandID("attempt-rewrite-attachment"),
                    turnID: candidate.id,
                    revisionID: secondRevision.id
                )
            )
            XCTFail("Expected immutable Turn evidence")
        } catch {
            XCTAssertEqual(
                error as? InterviewRoomSessionError,
                .boardAttachmentImmutable(turnID: candidate.id)
            )
        }
        let unchanged = await session.snapshot()
        XCTAssertEqual(unchanged, secondSave)
    }

    func testDraftRevisionHistoryAndHistoricalSelectionRestoreWithoutMutation() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = fixtureRuntime()
        let session = try await makeSession(store: store, runtime: runtime)
        let firstDocument = try fixtureDocument(label: "API")
        let secondDocument = try fixtureDocument(label: "Queue")

        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("history-draft-one"),
                document: firstDocument
            )
        )
        let firstSaveCommand = InterviewRoomCommand.saveBoardRevision(
            commandID: CommandID("history-save-one")
        )
        let firstSave = try await session.execute(firstSaveCommand)
        let firstReplay = try await session.execute(firstSaveCommand)
        XCTAssertEqual(firstReplay, firstSave)
        XCTAssertEqual(firstReplay.board.revisions.count, 1)
        let firstRevision = try XCTUnwrap(firstSave.board.revisions.first)

        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("history-draft-two"),
                document: secondDocument
            )
        )
        let secondSave = try await session.execute(
            .saveBoardRevision(commandID: CommandID("history-save-two"))
        )
        XCTAssertEqual(secondSave.board.draft, secondDocument)
        XCTAssertEqual(secondSave.board.revisions.map(\.document), [firstDocument, secondDocument])
        XCTAssertEqual(secondSave.board.revisions.map(\.ordinal), [0, 1])

        let selected = try await session.execute(
            .selectBoardRevision(
                commandID: CommandID("history-select-one"),
                revisionID: firstRevision.id
            )
        )
        XCTAssertEqual(selected.board.selectedRevisionID, firstRevision.id)
        XCTAssertEqual(selected.board.draft, secondDocument)

        let restored = try await InterviewRoomSession.restore(
            sessionID: selected.sessionID,
            manifestStore: store,
            interviewerRuntime: runtime
        )
        let restoredSnapshot = await restored.snapshot()
        XCTAssertEqual(restoredSnapshot, selected)
        XCTAssertEqual(restoredSnapshot.board.draft, secondDocument)
        XCTAssertEqual(restoredSnapshot.board.revisions[0].document, firstDocument)
    }

    func testExportAuthorizationIsDurableBeforeOutcomeAndRetryKeepsRevisionIdentity() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = fixtureRuntime()
        let session = try await makeSession(store: store, runtime: runtime)
        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("export-draft"),
                document: try fixtureDocument(label: "Read model")
            )
        )
        let saved = try await session.execute(
            .saveBoardRevision(commandID: CommandID("export-save"))
        )
        let revision = try XCTUnwrap(saved.board.revisions.first)
        let settings = try BoardExportSettings(
            viewport: BoardSize(width: 1_200, height: 800),
            scale: 2,
            background: .white
        )
        let firstAuthorization = InterviewRoomCommand.authorizeBoardExport(
            commandID: CommandID("export-authorize-interrupted"),
            revisionID: revision.id,
            settings: settings
        )

        let accepted = try await session.apply(firstAuthorization)
        XCTAssertEqual(accepted.disposition, .accepted)
        let firstOperation = try XCTUnwrap(accepted.snapshot.board.exports.first)
        XCTAssertEqual(firstOperation.lifecycle, .authorized)
        let loadedAuthorization = await store.load(sessionID: accepted.snapshot.sessionID)
        let persistedAuthorization = try XCTUnwrap(loadedAuthorization)
        XCTAssertEqual(persistedAuthorization.board.exports, [firstOperation])

        let replay = try await session.apply(firstAuthorization)
        XCTAssertEqual(replay.disposition, .alreadyApplied)
        XCTAssertEqual(replay.snapshot.board.exports, [firstOperation])
        _ = try await session.execute(
            .recordBoardExportOutcome(
                commandID: CommandID("export-interrupted-outcome"),
                exportID: firstOperation.id,
                outcome: .failed(BoardExportFailure(reason: .interrupted))
            )
        )

        let retryAuthorization = try await session.apply(
            .authorizeBoardExport(
                commandID: CommandID("export-authorize-retry"),
                revisionID: revision.id,
                settings: settings
            )
        )
        let retryOperation = try XCTUnwrap(retryAuthorization.snapshot.board.exports.last)
        XCTAssertNotEqual(retryOperation.id, firstOperation.id)
        XCTAssertEqual(retryOperation.revisionID, revision.id)
        let firstExportDirectory = firstOperation.artifactIdentities.source.rawValue
            .split(separator: "/").dropLast().joined(separator: "/")
        let retryExportDirectory = retryOperation.artifactIdentities.source.rawValue
            .split(separator: "/").dropLast().joined(separator: "/")
        XCTAssertNotEqual(firstExportDirectory, retryExportDirectory)
        XCTAssertTrue(
            [
                retryOperation.artifactIdentities.source,
                retryOperation.artifactIdentities.svg,
                retryOperation.artifactIdentities.png,
            ].allSatisfy {
                $0.rawValue.hasPrefix("\(retryExportDirectory)/")
            }
        )
        let bundle = fixtureBundle(identities: retryOperation.artifactIdentities)
        let mismatchedBundle = BoardArtifactBundle(
            source: BoardArtifactMetadata(
                identity: retryOperation.artifactIdentities.svg,
                byteCount: 1_024,
                sha256: String(repeating: "a", count: 64)
            ),
            svg: bundle.svg,
            png: bundle.png
        )
        do {
            _ = try await session.execute(
                .recordBoardExportOutcome(
                    commandID: CommandID("export-invalid-bundle-outcome"),
                    exportID: retryOperation.id,
                    outcome: .ready(mismatchedBundle)
                )
            )
            XCTFail("Expected all-or-nothing bundle validation")
        } catch {
            XCTAssertEqual(
                error as? InterviewRoomSessionError,
                .invalidBoardExportBundle
            )
        }
        let unchangedAuthorization = await session.snapshot()
        XCTAssertEqual(unchangedAuthorization, retryAuthorization.snapshot)

        let completed = try await session.execute(
            .recordBoardExportOutcome(
                commandID: CommandID("export-ready-outcome"),
                exportID: retryOperation.id,
                outcome: .ready(bundle)
            )
        )

        XCTAssertEqual(completed.board.revisions, [revision])
        XCTAssertEqual(completed.board.exports.count, 2)
        XCTAssertEqual(completed.board.exports[0].lifecycle, .failed)
        XCTAssertEqual(completed.board.exports[1].lifecycle, .ready)
        XCTAssertEqual(completed.board.exports[1].bundle, bundle)
        XCTAssertTrue(completed.turns.isEmpty)

        let loadedCompletedManifest = await store.load(sessionID: completed.sessionID)
        let completedManifest = try XCTUnwrap(loadedCompletedManifest)
        let completedData = try JSONEncoder().encode(completedManifest)
        let decodedCompletedManifest = try JSONDecoder().decode(
            SessionManifest.self,
            from: completedData
        )
        let roundTripStore = InMemorySessionManifestStore(
            manifests: [decodedCompletedManifest]
        )
        let restored = try await InterviewRoomSession.restore(
            sessionID: completed.sessionID,
            manifestStore: roundTripStore,
            interviewerRuntime: runtime
        )
        let restoredSnapshot = await restored.snapshot()
        XCTAssertEqual(restoredSnapshot, completed)
    }

    func testLegacyManifestAndCandidateTurnDecodeAsExplicitNoBoardState() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = fixtureRuntime()
        let session = try await makeSession(store: store, runtime: runtime)
        let initialSnapshot = await session.snapshot()
        let loadedManifest = await store.load(sessionID: initialSnapshot.sessionID)
        let initialManifest = try XCTUnwrap(loadedManifest)
        let legacyManifestData = try removingJSONKey(
            "board",
            from: JSONEncoder().encode(initialManifest)
        )
        let decodedManifest = try JSONDecoder().decode(
            SessionManifest.self,
            from: legacyManifestData
        )
        XCTAssertEqual(decodedManifest.board, .empty)

        let candidate = CandidateTurn(
            id: TurnID("legacy-candidate"),
            commandID: CommandID("legacy-handoff"),
            transcript: CandidateTranscript(body: "Public fixture.", quality: .verified)
        )
        let legacyCandidateData = try removingJSONKey(
            "boardAttachment",
            from: JSONEncoder().encode(candidate)
        )
        let decodedCandidate = try JSONDecoder().decode(
            CandidateTurn.self,
            from: legacyCandidateData
        )
        XCTAssertEqual(decodedCandidate.boardAttachment, .noBoard)

        let databaseBox = BoardBox(
            id: BoardElementID("legacy-database-node"),
            frame: BoardRect(
                origin: BoardPoint(x: 40, y: 50),
                size: BoardSize(width: 180, height: 90)
            ),
            label: "Catalog database",
            kind: .database
        )
        let decodedDatabaseBox = try JSONDecoder().decode(
            BoardBox.self,
            from: JSONEncoder().encode(databaseBox)
        )
        XCTAssertEqual(decodedDatabaseBox, databaseBox)
        let legacyBoxData = try removingJSONKey(
            "kind",
            from: JSONEncoder().encode(databaseBox)
        )
        let legacyBox = try JSONDecoder().decode(BoardBox.self, from: legacyBoxData)
        XCTAssertEqual(legacyBox.kind, .generic)

        let automaticEndpoint = BoardConnectorEndpoint(
            point: BoardPoint(x: 120, y: 80),
            elementID: databaseBox.id,
            anchorPolicy: .automatic
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                BoardConnectorEndpoint.self,
                from: JSONEncoder().encode(automaticEndpoint)
            ),
            automaticEndpoint
        )
        let legacyEndpointData = try removingJSONKey(
            "anchorPolicy",
            from: JSONEncoder().encode(automaticEndpoint)
        )
        let legacyEndpoint = try JSONDecoder().decode(
            BoardConnectorEndpoint.self,
            from: legacyEndpointData
        )
        XCTAssertEqual(legacyEndpoint.point, automaticEndpoint.point)
        XCTAssertEqual(legacyEndpoint.elementID, automaticEndpoint.elementID)
        XCTAssertEqual(legacyEndpoint.anchorPolicy, .preserved)
    }

    func testBoardDocumentAndArtifactInputsRejectUnboundedOrUnsafeIdentities() throws {
        let duplicateID = BoardElementID("duplicate")
        XCTAssertThrowsError(
            try BoardDocument(
                canvas: BoardCanvas(size: BoardSize(width: 800, height: 600)),
                elements: [
                    .label(
                        BoardLabel(
                            id: duplicateID,
                            origin: BoardPoint(x: 10, y: 10),
                            text: "First"
                        )
                    ),
                    .label(
                        BoardLabel(
                            id: duplicateID,
                            origin: BoardPoint(x: 20, y: 20),
                            text: "Second"
                        )
                    ),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? BoardDocumentValidationError,
                .duplicateElementID(duplicateID)
            )
        }

        XCTAssertThrowsError(
            try BoardDocument(
                canvas: BoardCanvas(size: BoardSize(width: .infinity, height: 600)),
                elements: []
            )
        ) { error in
            XCTAssertEqual(error as? BoardDocumentValidationError, .invalidCanvas)
        }
        XCTAssertThrowsError(try BoardArtifactIdentity(validating: "../../private.json"))
        XCTAssertThrowsError(try BoardArtifactIdentity(validating: "/private/board.svg"))
        XCTAssertThrowsError(try BoardArtifactIdentity(validating: "https://example.test/a.svg"))
        XCTAssertThrowsError(
            try BoardExportSettings(
                viewport: BoardSize(width: 8_192, height: 8_192),
                scale: 4
            )
        ) { error in
            XCTAssertEqual(
                error as? BoardExportSettingsValidationError,
                .invalidViewport
            )
        }

        let scriptLikeText = "<script src='https://example.test/x.js'>ignored as markup</script>"
        let dataOnlyDocument = try BoardDocument(
            canvas: BoardCanvas(size: BoardSize(width: 800, height: 600)),
            elements: [
                .label(
                    BoardLabel(
                        id: BoardElementID("data-only-label"),
                        origin: BoardPoint(x: 10, y: 10),
                        text: scriptLikeText
                    )
                )
            ]
        )
        guard let firstElement = dataOnlyDocument.elements.first,
              case .label(let label) = firstElement else {
            return XCTFail("Expected label data")
        }
        XCTAssertEqual(label.text, scriptLikeText)
    }

    func testAttachmentRejectsUnknownEvidenceAndCompletedSessionMutation() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = fixtureRuntime()
        let session = try await makeSession(store: store, runtime: runtime)
        let floor = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("invalid-attachment-floor"))
        )
        let unknownRevision = BoardRevisionID("unknown-public-revision")
        do {
            _ = try await session.execute(
                .handOffWithBoard(
                    commandID: CommandID("invalid-attachment-handoff"),
                    transcript: CandidateTranscript(
                        body: "Public answer.",
                        quality: .verified
                    ),
                    boardAttachment: .revision(unknownRevision)
                )
            )
            XCTFail("Expected an unknown Revision rejection")
        } catch {
            XCTAssertEqual(
                error as? InterviewRoomSessionError,
                .boardRevisionNotFound(unknownRevision)
            )
        }
        let unchangedFloor = await session.snapshot()
        XCTAssertEqual(unchangedFloor, floor)

        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("completed-attachment-draft"),
                document: try fixtureDocument(label: "Completed")
            )
        )
        let saved = try await session.execute(
            .saveBoardRevision(commandID: CommandID("completed-attachment-save"))
        )
        let revision = try XCTUnwrap(saved.board.revisions.first)
        let unknownTurn = TurnID("unknown-public-turn")
        do {
            _ = try await session.execute(
                .attachBoardRevision(
                    commandID: CommandID("unknown-turn-attachment-command"),
                    turnID: unknownTurn,
                    revisionID: revision.id
                )
            )
            XCTFail("Expected unknown Turn rejection")
        } catch {
            XCTAssertEqual(
                error as? InterviewRoomSessionError,
                .boardTurnNotFound(unknownTurn)
            )
        }
        let handedOff = try await session.execute(
            .handOffWithBoard(
                commandID: CommandID("completed-attachment-handoff"),
                transcript: CandidateTranscript(body: "Public answer.", quality: .verified),
                boardAttachment: .noBoard
            )
        )
        guard case .candidate(let candidate) = handedOff.turns.first else {
            return XCTFail("Expected Candidate Turn")
        }
        let completed = try await session.execute(
            .finish(commandID: CommandID("completed-attachment-finish"))
        )
        do {
            _ = try await session.execute(
                .attachBoardRevision(
                    commandID: CommandID("completed-attachment-command"),
                    turnID: candidate.id,
                    revisionID: revision.id
                )
            )
            XCTFail("Expected completed-session attachment rejection")
        } catch {
            XCTAssertEqual(
                error as? InterviewRoomSessionError,
                .invalidTransition(command: "attachBoardRevision", phase: .completed)
            )
        }
        let unchangedCompleted = await session.snapshot()
        XCTAssertEqual(unchangedCompleted, completed)
    }

    func testHandOffAttachesSpecifiedHistoricalRevisionNotLatestOrDirtyDraft() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = fixtureRuntime()
        let session = try await makeSession(store: store, runtime: runtime)
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("historical-handoff-floor"))
        )
        let firstDocument = try fixtureDocument(label: "Historical gateway")
        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("historical-handoff-draft-one"),
                document: firstDocument
            )
        )
        let firstSave = try await session.execute(
            .saveBoardRevision(commandID: CommandID("historical-handoff-save-one"))
        )
        let historicalRevision = try XCTUnwrap(firstSave.board.revisions.first)

        let latestDocument = try fixtureDocument(label: "Latest saved queue")
        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("historical-handoff-draft-two"),
                document: latestDocument
            )
        )
        let secondSave = try await session.execute(
            .saveBoardRevision(commandID: CommandID("historical-handoff-save-two"))
        )
        let latestRevision = try XCTUnwrap(secondSave.board.revisions.last)
        XCTAssertNotEqual(historicalRevision.id, latestRevision.id)

        let dirtyDraft = try fixtureDocument(label: "Unsaved dirty draft")
        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("historical-handoff-dirty-draft"),
                document: dirtyDraft
            )
        )
        let handedOff = try await session.execute(
            .handOffWithBoard(
                commandID: CommandID("historical-revision-handoff"),
                transcript: CandidateTranscript(
                    body: "The inspected historical diagram is the evidence for this answer.",
                    quality: .verified
                ),
                boardAttachment: .revision(historicalRevision.id)
            )
        )

        guard case .candidate(let candidate) = handedOff.turns.first else {
            return XCTFail("Expected Candidate Turn")
        }
        XCTAssertEqual(candidate.boardAttachment, .revision(historicalRevision.id))
        XCTAssertEqual(handedOff.board.draft, dirtyDraft)
        XCTAssertEqual(handedOff.board.revisions.last, latestRevision)
        XCTAssertEqual(handedOff.board.revisions.first?.document, firstDocument)
    }

    func testSaveThenEditAndRestoreKeepsEditableDraftSelected() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = fixtureRuntime()
        let session = try await makeSession(store: store, runtime: runtime)
        let savedDocument = try fixtureDocument(label: "Saved gateway")
        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("restore-draft-saved-document"),
                document: savedDocument
            )
        )
        let saved = try await session.execute(
            .saveBoardRevision(commandID: CommandID("restore-draft-save"))
        )
        XCTAssertNil(saved.board.selectedRevisionID)
        let revision = try XCTUnwrap(saved.board.revisions.first)

        let unsavedDocument = try fixtureDocument(label: "New unsaved queue")
        let edited = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("restore-draft-unsaved-edit"),
                document: unsavedDocument
            )
        )
        XCTAssertNil(edited.board.selectedRevisionID)
        XCTAssertEqual(edited.board.draft, unsavedDocument)

        let loadedManifest = await store.load(sessionID: edited.sessionID)
        let manifest = try XCTUnwrap(loadedManifest)
        let roundTripped = try JSONDecoder().decode(
            SessionManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        let restored = try await InterviewRoomSession.restore(
            sessionID: edited.sessionID,
            manifestStore: InMemorySessionManifestStore(manifests: [roundTripped]),
            interviewerRuntime: runtime
        )
        let restoredSnapshot = await restored.snapshot()

        XCTAssertNil(restoredSnapshot.board.selectedRevisionID)
        XCTAssertEqual(restoredSnapshot.board.draft, unsavedDocument)
        XCTAssertEqual(restoredSnapshot.board.revisions, [revision])
        XCTAssertEqual(restoredSnapshot.board.revisions.first?.document, savedDocument)
    }

    func testCompletedSessionAllowsHistoricalSelectionWithoutMutatingDraft() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = fixtureRuntime()
        let session = try await makeSession(store: store, runtime: runtime)
        let historicalDocument = try fixtureDocument(label: "Historical completed selection")
        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("completed-selection-historical-draft"),
                document: historicalDocument
            )
        )
        let saved = try await session.execute(
            .saveBoardRevision(commandID: CommandID("completed-selection-historical-save"))
        )
        let revision = try XCTUnwrap(saved.board.revisions.first)
        let currentDraft = try fixtureDocument(label: "Current editable draft")
        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("completed-selection-current-draft"),
                document: currentDraft
            )
        )
        _ = try await session.execute(
            .finish(commandID: CommandID("completed-selection-finish"))
        )

        let selected = try await session.execute(
            .selectBoardRevision(
                commandID: CommandID("completed-selection-select"),
                revisionID: revision.id
            )
        )
        XCTAssertEqual(selected.phase, .completed)
        XCTAssertEqual(selected.board.selectedRevisionID, revision.id)
        XCTAssertEqual(selected.board.revisions.first?.document, historicalDocument)
        XCTAssertEqual(selected.board.draft, currentDraft)
        let persisted = await store.load(sessionID: selected.sessionID)
        XCTAssertEqual(persisted?.board, selected.board)
    }

    func testCompletedSessionAllowsExplicitExportAuthorizationAndOutcome() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = fixtureRuntime()
        let session = try await makeSession(store: store, runtime: runtime)
        _ = try await session.execute(
            .updateBoardDraft(
                commandID: CommandID("completed-export-draft"),
                document: try fixtureDocument(label: "Completed export")
            )
        )
        let saved = try await session.execute(
            .saveBoardRevision(commandID: CommandID("completed-export-save"))
        )
        let revision = try XCTUnwrap(saved.board.revisions.first)
        let settings = try BoardExportSettings(
            viewport: BoardSize(width: 1_200, height: 800),
            scale: 2,
            background: .white
        )
        _ = try await session.execute(
            .finish(commandID: CommandID("completed-export-finish"))
        )
        let authorized = try await session.execute(
            .authorizeBoardExport(
                commandID: CommandID("completed-export-authorize-after-finish"),
                revisionID: revision.id,
                settings: settings
            )
        )
        let operation = try XCTUnwrap(authorized.board.exports.first)
        XCTAssertEqual(authorized.phase, .completed)
        XCTAssertEqual(operation.lifecycle, .authorized)
        let persistedAuthorization = await store.load(sessionID: authorized.sessionID)
        XCTAssertEqual(persistedAuthorization?.board, authorized.board)

        let reconciled = try await session.execute(
            .recordBoardExportOutcome(
                commandID: CommandID("completed-export-outcome-after-finish"),
                exportID: operation.id,
                outcome: .ready(fixtureBundle(identities: operation.artifactIdentities))
            )
        )
        XCTAssertEqual(reconciled.phase, .completed)
        XCTAssertEqual(reconciled.board.exports.first?.lifecycle, .ready)
        let persistedReconciliation = await store.load(sessionID: reconciled.sessionID)
        XCTAssertEqual(persistedReconciliation?.board, reconciled.board)
    }
}

private func fixtureRuntime() -> DeterministicInterviewerRuntime {
    DeterministicInterviewerRuntime(
        response: CanonicalInterviewerResponse(
            displayMarkdown: "What would you change next?",
            spokenText: "What would you change next?"
        )
    )
}

private actor InspectingInterviewerRuntime: InterviewerRuntime {
    private let store: InMemorySessionManifestStore
    private let response: CanonicalInterviewerResponse
    private var observedCandidate: CandidateTurn?

    init(
        store: InMemorySessionManifestStore,
        response: CanonicalInterviewerResponse
    ) {
        self.store = store
        self.response = response
    }

    func respond(to request: InterviewerRequest) async throws -> CanonicalInterviewerResponse {
        let persisted = await store.load(sessionID: request.sessionID)
        if case .candidate(let candidate) = persisted?.turns.last {
            observedCandidate = candidate
        }
        return response
    }

    func candidateObservedBeforeResponse() -> CandidateTurn? {
        observedCandidate
    }
}

private func makeSession(
    store: InMemorySessionManifestStore,
    runtime: DeterministicInterviewerRuntime
) async throws -> InterviewRoomSession {
    try await InterviewRoomSession.start(
        sessionID: SessionID("public-board-fixture-session"),
        activityID: "public-board-fixture-activity",
        activityPrompt: try ActivityPrompt(
            specialty: .systemDesign,
            stage: "Architecture",
            question: "Design a public document service.",
            requestedParts: []
        ),
        manifestStore: store,
        interviewerRuntime: runtime
    )
}

private func fixtureDocument(label: String) throws -> BoardDocument {
    try BoardDocument(
        canvas: BoardCanvas(size: BoardSize(width: 1_200, height: 800)),
        elements: [
            .box(
                BoardBox(
                    id: BoardElementID("public-box"),
                    frame: BoardRect(
                        origin: BoardPoint(x: 100, y: 120),
                        size: BoardSize(width: 240, height: 100)
                    ),
                    label: label
                )
            )
        ]
    )
}

private func fixtureBundle(identities: BoardArtifactIdentities) -> BoardArtifactBundle {
    BoardArtifactBundle(
        source: BoardArtifactMetadata(
            identity: identities.source,
            byteCount: 1_024,
            sha256: String(repeating: "a", count: 64)
        ),
        svg: BoardArtifactMetadata(
            identity: identities.svg,
            byteCount: 2_048,
            sha256: String(repeating: "b", count: 64)
        ),
        png: BoardArtifactMetadata(
            identity: identities.png,
            byteCount: 4_096,
            sha256: String(repeating: "c", count: 64)
        )
    )
}

private func removingJSONKey(_ key: String, from data: Data) throws -> Data {
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object.removeValue(forKey: key)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
