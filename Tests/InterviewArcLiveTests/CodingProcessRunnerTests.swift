import Foundation
import XCTest

@testable import InterviewArcLive

final class CodingProcessRunnerTests: XCTestCase {
    func testRunStreamsStdoutToOnOutputAndResult() async throws {
        let recorder = StreamRecorder()
        let result = try await CodingProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"printf "alpha\n"; printf "beta\n""#],
            currentDirectory: nil,
            onOutput: { event in
                recorder.append(event)
            }
        )

        let streamed = recorder.stdoutText()
        XCTAssertTrue(streamed.contains("alpha"), "streamed stdout was \(streamed)")
        XCTAssertTrue(streamed.contains("beta"), "streamed stdout was \(streamed)")
        XCTAssertTrue(result.stdout.contains("alpha"), "result.stdout was \(result.stdout)")
        XCTAssertTrue(result.stdout.contains("beta"), "result.stdout was \(result.stdout)")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCancelTerminatesLongSleepPromptly() async {
        let finished = expectation(description: "cancelled sleep finished")
        let task = Task {
            defer { finished.fulfill() }
            do {
                _ = try await CodingProcessRunner.run(
                    executable: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["20"],
                    currentDirectory: nil
                )
            } catch is CancellationError {
                return
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        defer { task.cancel() }

        try? await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        task.cancel()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
    }
}

private final class StreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CodingProcessStreamEvent] = []

    func append(_ event: CodingProcessStreamEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func stdoutText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return events
            .filter { $0.kind == .stdout }
            .map(\.text)
            .joined()
    }
}
