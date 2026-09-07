import Foundation
import XCTest
import InterviewArcLiveCore
@testable import InterviewArcLiveLocalSpeechAdapter

final class KokoroSpeechTests: XCTestCase {
    func testChunkingPreservesLongTechnicalTextAndBoundsEveryInput() {
        let text = String(repeating: "Discuss idempotency, backpressure, retries, and consistency. ", count: 30)
            + String(repeating: "x", count: 600)
        let chunks = KokoroTextChunks.split(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 180 })
    }

    func testUnicodeChunkingPreservesEveryCharacter() {
        let text = String(repeating: "Queues → workers; naïve retries aren’t enough. ", count: 20)
        XCTAssertEqual(KokoroTextChunks.split(text).joined(), text)
        XCTAssertTrue(KokoroTextChunks.split("   ").isEmpty)
    }

    func testEngineProvenanceAndStorageBudgetsRemainDistinct() {
        let qwen = LocalSpeechEngine.qwen
        let kokoro = LocalSpeechEngine.kokoro
        XCTAssertNotEqual(qwen.provenance.providerID, kokoro.provenance.providerID)
        XCTAssertNotEqual(qwen.provenance.profile.fingerprint, kokoro.provenance.profile.fingerprint)
        XCTAssertEqual(qwen.provenance.profile, .maraV1)
        XCTAssertEqual(kokoro.provenance.profile.conditioning, "af_heart")
        XCTAssertEqual(KokoroProvenance.publicSnapshot.byteCount, KokoroProvenance.snapshotByteCount)
        XCTAssertEqual(KokoroProvenance.publicSnapshot.files.count, 7)
        XCTAssertGreaterThan(kokoro.minimumFreeByteCount, KokoroProvenance.snapshotByteCount * 2)
    }
}
