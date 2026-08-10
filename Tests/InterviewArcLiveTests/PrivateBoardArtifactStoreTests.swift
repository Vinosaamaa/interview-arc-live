import CryptoKit
import Foundation
import XCTest
import InterviewArcLiveCore
@testable import InterviewArcLive

@MainActor
final class PrivateBoardArtifactStoreTests: XCTestCase {
    func testPromotesAndRecoversOnePrivateIntegrityCheckedBundle() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = PrivateBoardArtifactStore(root: fixture.root)
        let input = try fixture.input()

        let receipt = try await store.persist(
            exportID: BoardExportID("export-1"),
            identities: fixture.identities,
            artifacts: input
        )
        let recovery = try await store.recover(identities: fixture.identities)
        let recoveredSource = try await store.readSource(
            identities: fixture.identities
        )

        XCTAssertEqual(recovery, .complete(receipt))
        XCTAssertEqual(recoveredSource, input.canonicalSource)
        try fixture.assertPrivateTree()
        XCTAssertFalse(
            fixture.allNames().contains { $0.contains("partial") }
        )
    }

    func testPostPromotionFailureLeavesNoVisibleBundleAndRetrySucceeds() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = FailFirstPromotionValidation()
        let failing = PrivateBoardArtifactStore(
            root: fixture.root,
            postPromotionValidation: { url in try gate.validate(url) }
        )
        let input = try fixture.input()

        do {
            _ = try await failing.persist(
                exportID: BoardExportID("export-1"),
                identities: fixture.identities,
                artifacts: input
            )
            XCTFail("Expected the injected post-promotion failure")
        } catch InjectedFailure.afterPromotion {
            // Expected.
        }
        let failedRecovery = try await failing.recover(
            identities: fixture.identities
        )
        XCTAssertEqual(failedRecovery, .missing)

        let retry = PrivateBoardArtifactStore(root: fixture.root)
        let receipt = try await retry.persist(
            exportID: BoardExportID("export-1"),
            identities: fixture.identities,
            artifacts: input
        )
        let retriedRecovery = try await retry.recover(
            identities: fixture.identities
        )
        XCTAssertEqual(retriedRecovery, .complete(receipt))
    }

    func testCorruptDerivativeKeepsCanonicalSourceAndRequiresRegeneration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = PrivateBoardArtifactStore(root: fixture.root)
        let input = try fixture.input()
        _ = try await store.persist(
            exportID: BoardExportID("export-1"),
            identities: fixture.identities,
            artifacts: input
        )
        let png = fixture.root.appendingPathComponent(
            fixture.identities.png.rawValue
        )
        try Data("corrupt derivative".utf8).write(to: png)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: png.path
        )

        let recovery = try await store.recover(identities: fixture.identities)
        let recoveredSource = try await store.readSource(
            identities: fixture.identities
        )

        guard case .needsRegeneration(let source) = recovery else {
            return XCTFail("Expected source-preserving recovery attention")
        }
        XCTAssertEqual(source, input.canonicalSource)
        XCTAssertEqual(recoveredSource, input.canonicalSource)
    }

    func testTwoExportsRemainIndependentlyRecoverableWithDistinctIntegrity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = PrivateBoardArtifactStore(root: fixture.root)
        let firstIdentities = try fixture.identities(named: "export-a")
        let secondIdentities = try fixture.identities(named: "export-b")
        let firstInput = try fixture.input(label: "Gateway A")
        let secondInput = try fixture.input(label: "Gateway B")

        let first = try await store.persist(
            exportID: BoardExportID("export-a"),
            identities: firstIdentities,
            artifacts: firstInput
        )
        let second = try await store.persist(
            exportID: BoardExportID("export-b"),
            identities: secondIdentities,
            artifacts: secondInput
        )
        let firstRecovery = try await store.recover(
            identities: firstIdentities
        )
        let secondRecovery = try await store.recover(
            identities: secondIdentities
        )
        let firstSource = try await store.readSource(
            identities: firstIdentities
        )
        let secondSource = try await store.readSource(
            identities: secondIdentities
        )

        XCTAssertNotEqual(first.source.sha256, second.source.sha256)
        XCTAssertEqual(firstRecovery, .complete(first))
        XCTAssertEqual(secondRecovery, .complete(second))
        XCTAssertEqual(firstSource, firstInput.canonicalSource)
        XCTAssertEqual(secondSource, secondInput.canonicalSource)
    }

    func testInterruptedBackupCanOnlyRestoreItsExactExportIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = PrivateBoardArtifactStore(root: fixture.root)
        let firstIdentities = try fixture.identities(named: "export-a")
        let secondIdentities = try fixture.identities(named: "export-b")
        let input = try fixture.input(label: "Gateway A")
        let receipt = try await store.persist(
            exportID: BoardExportID("export-a"),
            identities: firstIdentities,
            artifacts: input
        )

        let final = fixture.root.appendingPathComponent(
            "BoardArtifacts/board-export-a",
            isDirectory: true
        )
        let token = String(
            SHA256.hash(data: Data(firstIdentities.source.rawValue.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
                .prefix(16)
        )
        let previous = final.deletingLastPathComponent().appendingPathComponent(
            ".board-export-\(token).previous",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: final, to: previous)
        let secondRecovery = try await store.recover(
            identities: secondIdentities
        )
        let firstRecovery = try await store.recover(
            identities: firstIdentities
        )

        XCTAssertEqual(secondRecovery, .missing)
        XCTAssertEqual(firstRecovery, .complete(receipt))
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
    }
}

private final class Fixture {
    let root: URL
    let identities: BoardArtifactIdentities

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "interview-arc-live-board-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        identities = try Self.makeIdentities(named: "export-1")
    }

    func identities(named name: String) throws -> BoardArtifactIdentities {
        try Self.makeIdentities(named: name)
    }

    private static func makeIdentities(
        named name: String
    ) throws -> BoardArtifactIdentities {
        BoardArtifactIdentities(
            source: try BoardArtifactIdentity(
                validating: "BoardArtifacts/board-\(name)/board.drawio"
            ),
            svg: try BoardArtifactIdentity(
                validating: "BoardArtifacts/board-\(name)/board.svg"
            ),
            png: try BoardArtifactIdentity(
                validating: "BoardArtifacts/board-\(name)/board.png"
            )
        )
    }

    func input(label: String = "Public service") throws -> RenderedBoardArtifacts {
        let document = try BoardDocument(
            canvas: BoardCanvas(size: BoardSize(width: 640, height: 400)),
            elements: [
                .box(
                    BoardBox(
                        id: BoardElementID("public-service"),
                        frame: BoardRect(
                            origin: BoardPoint(x: 80, y: 100),
                            size: BoardSize(width: 180, height: 90)
                        ),
                        label: label
                    )
                )
            ]
        )
        return try DeterministicBoardRenderer().render(
            document,
            settings: BoardExportSettings(
                viewport: BoardSize(width: 640, height: 400),
                scale: 1,
                background: BoardColor(hexRGB: "fbfcfa")
            )
        )
    }

    func allNames() -> [String] {
        FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )?.compactMap { ($0 as? URL)?.lastPathComponent } ?? []
    }

    func assertPrivateTree() throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return XCTFail("Expected artifact tree")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let mode = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                    as? NSNumber
            ).intValue & 0o777
            XCTAssertEqual(mode, values.isDirectory == true ? 0o700 : 0o600)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum InjectedFailure: Error {
    case afterPromotion
}

final class FailFirstPromotionValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func validate(_ url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if shouldFail {
            shouldFail = false
            throw InjectedFailure.afterPromotion
        }
    }
}
