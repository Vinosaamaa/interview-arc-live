import Foundation
import Darwin
import XCTest

@testable import InterviewArcLiveCodexAdapter

@MainActor
final class CodexAppServerProcessTests: XCTestCase {
    func testConnectionRetainsPipesAcrossMultipleStreamingWrites() async throws {
        let launcher = FoundationCodexAppServerProcessLauncher()
        let connection = try await launcher.connect(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "while IFS= read -r line; do echo \"$line\"; [ \"$line\" = second ] && exit 0; done",
            ],
            environment: [
                "HOME": "/private/tmp",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
            ],
            lineLimit: 1_024,
            totalOutputLimit: 4_096
        )

        try await connection.send(Data("first\n".utf8))
        let first = try await connection.receiveLine()
        try await connection.send(Data("second\n".utf8))
        let second = try await connection.receiveLine()

        XCTAssertEqual(first, Data("first".utf8))
        XCTAssertEqual(second, Data("second".utf8))
        let exitCode = await connection.waitForExit()
        XCTAssertEqual(exitCode, 0)
        await connection.terminate()
    }

    func testWaitForNaturalExitCompletesFromDetachedWorkerWithoutRunLoopPolling() async throws {
        let launcher = FoundationCodexAppServerProcessLauncher()
        let connection = try await launcher.connect(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 23"],
            environment: [
                "HOME": "/private/tmp",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
            ],
            lineLimit: 1_024,
            totalOutputLimit: 1_024
        )

        let exitCode = await Task.detached {
            await connection.waitForExit()
        }.value

        XCTAssertEqual(exitCode, 23)
        await connection.terminate()
    }

    func testTerminateEscalatesTermIgnoringChildAndReapsWithinBound() async throws {
        let launcher = FoundationCodexAppServerProcessLauncher()
        let connection = try await launcher.connect(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; echo ready; while :; do :; done"],
            environment: [
                "HOME": "/private/tmp",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
            ],
            lineLimit: 1_024,
            totalOutputLimit: 1_024
        )
        let readyLine = try await connection.receiveLine()
        XCTAssertEqual(readyLine, Data("ready".utf8))

        let exitWaiters = (0..<8).map { _ in
            Task.detached {
                await connection.waitForExit()
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await connection.terminate()
                }
            }
        }
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .seconds(3))
        for waiter in exitWaiters {
            let exitCode = await waiter.value
            XCTAssertEqual(exitCode, SIGKILL)
        }
        let repeatedExitCode = await connection.waitForExit()
        XCTAssertEqual(repeatedExitCode, SIGKILL)
        await connection.terminate()
    }

    func testLargeWriteToNonReadingChildCanBeCancelledAndReaped() async throws {
        let launcher = FoundationCodexAppServerProcessLauncher()
        let connection = try await launcher.connect(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; echo ready; while :; do :; done"],
            environment: [
                "HOME": "/private/tmp",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
            ],
            lineLimit: 1_024,
            totalOutputLimit: 1_024
        )
        let readyLine = try await connection.receiveLine()
        XCTAssertEqual(readyLine, Data("ready".utf8))
        let blockedWrite = Task {
            try await connection.send(Data(repeating: 0x78, count: 2 * 1_024 * 1_024))
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let clock = ContinuousClock()
        let started = clock.now
        await connection.terminate()
        _ = try? await blockedWrite.value
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .seconds(3))
        let exitCode = await connection.waitForExit()
        XCTAssertEqual(exitCode, SIGKILL)
    }

    func testRunOutputLimitTerminatesTermIgnoringChildBeforeThrowing() async throws {
        let launcher = FoundationCodexAppServerProcessLauncher()
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await launcher.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; echo too-much-output; while :; do :; done"],
                environment: [
                    "HOME": "/private/tmp",
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "LANG": "en_US.UTF-8",
                    "LC_ALL": "en_US.UTF-8",
                ],
                timeoutNanoseconds: 5_000_000_000,
                outputLimit: 4
            )
            XCTFail("Expected bounded output failure")
        } catch let error as CodexProcessFailure {
            XCTAssertEqual(error, .outputLimit)
        }

        XCTAssertLessThan(started.duration(to: clock.now), .seconds(3))
    }
}
