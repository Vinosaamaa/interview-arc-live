import Foundation
import XCTest

@testable import InterviewArcLiveCodexAdapter
import InterviewArcLiveCore

@MainActor
final class CodexAppServerInterviewerRuntimeTests: XCTestCase {
    func testDefaultInterviewerModelIsPinnedToMeasuredFastPath() {
        XCTAssertEqual(
            CodexAppServerInterviewerRuntime.defaultInterviewerModel,
            "gpt-5.6-terra"
        )
    }

    func testCLIProtocolPinMatchesCurrentlyTestedCodex() {
        XCTAssertEqual(
            CodexAppServerInterviewerRuntime.testedCLIVersion,
            "codex-cli 0.148.0-alpha.9"
        )
    }

    func testPreflightInitializesChecksOnlyAuthPresenceAndReapsBeforeReturning() async throws {
        let connection = ScriptedCodexConnection(lines: Self.authenticationLines())
        let launcher = FixtureCodexLauncher(connection: connection)
        let runtime = Self.runtime(launcher: launcher)

        let readiness = await runtime.preflight()

        XCTAssertEqual(readiness, .ready)
        let didTerminate = await connection.isTerminated()
        XCTAssertTrue(didTerminate)
        let messages = try Self.objects(from: await connection.sentData())
        XCTAssertEqual(messages.map { $0["method"] as? String }, [
            "initialize", "initialized", "account/read",
        ])
        XCTAssertEqual(Set(messages[1].keys), Set(["method"]))

        let environments = await launcher.environments()
        XCTAssertFalse(environments.isEmpty)
        for environment in environments {
            XCTAssertEqual(
                Set(environment.keys),
                Set(["HOME", "PATH", "LANG", "LC_ALL", "TMPDIR"])
            )
            XCTAssertNil(environment["PARENT_SECRET"])
        }
    }

    func testPreflightReportsMissingIncompatibleUnauthenticatedAndSafeTransportFailure() async {
        let missing = CodexAppServerInterviewerRuntime(
            codexExecutableURL: URL(fileURLWithPath: "/private/tmp/no-such-codex-fixture"),
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp")
        )
        let missingReadiness = await missing.preflight()
        XCTAssertEqual(missingReadiness, .missing)

        let incompatibleConnection = ScriptedCodexConnection(lines: [])
        let incompatibleLauncher = FixtureCodexLauncher(
            version: "codex-cli 999.0.0",
            connection: incompatibleConnection
        )
        let incompatible = Self.runtime(launcher: incompatibleLauncher)
        let incompatibleReadiness = await incompatible.preflight()
        XCTAssertEqual(
            incompatibleReadiness,
            .incompatible(
                actualVersion: "codex-cli 999.0.0",
                requiredVersion: CodexAppServerInterviewerRuntime.testedCLIVersion
            )
        )

        let unauthenticatedConnection = ScriptedCodexConnection(
            lines: Self.authenticationLines(account: NSNull())
        )
        let unauthenticated = Self.runtime(
            launcher: FixtureCodexLauncher(connection: unauthenticatedConnection)
        )
        let unauthenticatedReadiness = await unauthenticated.preflight()
        let unauthenticatedDidTerminate = await unauthenticatedConnection.isTerminated()
        XCTAssertEqual(unauthenticatedReadiness, .unauthenticated)
        XCTAssertTrue(unauthenticatedDidTerminate)

        let apiKeyConnection = ScriptedCodexConnection(
            lines: Self.authenticationLines(account: ["type": "apiKey"])
        )
        let apiKeyRuntime = Self.runtime(
            launcher: FixtureCodexLauncher(connection: apiKeyConnection)
        )
        let apiKeyReadiness = await apiKeyRuntime.preflight()
        let apiKeyDidTerminate = await apiKeyConnection.isTerminated()
        XCTAssertEqual(apiKeyReadiness, .unauthenticated)
        XCTAssertTrue(apiKeyDidTerminate)

        let failedConnection = ScriptedCodexConnection(lines: [])
        let failed = Self.runtime(
            launcher: FixtureCodexLauncher(
                versionExitCode: 1,
                connection: failedConnection
            )
        )
        let failedReadiness = await failed.preflight()
        XCTAssertEqual(failedReadiness, .transportFailure)
        XCTAssertFalse(String(describing: failedReadiness).contains("/private/"))
    }

    func testTurnUsesNewEphemeralReadOnlyThreadStrictSchemaAndCanonicalFinalOnly() async throws {
        let privateInstructionPath = "/private/tmp/fixture-codex-home/AGENTS.md"
        let finalText = #"{"displayMarkdown":"What consistency model fits **edits**?","spokenText":"What consistency model fits edits?"}"#
        let lines = Self.authenticationLines() + [
            Self.line([
                "id": 3,
                "result": [
                    "approvalPolicy": "never",
                    "sandbox": ["type": "readOnly", "networkAccess": false],
                    "thread": [
                        "id": "live-owned-thread",
                        "ephemeral": true,
                        "forkedFromId": NSNull(),
                        "instructionSources": [[
                            "path": privateInstructionPath,
                            "kind": "user",
                        ]],
                    ],
                ],
            ]),
            Self.line([
                "id": 4,
                "result": [
                    "turn": [
                        "id": "live-owned-turn",
                        "status": "inProgress",
                        "items": [],
                    ],
                ],
            ]),
            Self.line([
                "method": "item/started",
                "params": [
                    "threadId": "live-owned-thread",
                    "turnId": "live-owned-turn",
                    "item": ["id": "reasoning-1", "type": "reasoning"],
                ],
            ]),
            Self.line([
                "method": "item/reasoning/summaryTextDelta",
                "params": [
                    "threadId": "live-owned-thread",
                    "turnId": "live-owned-turn",
                    "itemId": "reasoning-1",
                    "delta": "private work that must not cross the Adapter",
                ],
            ]),
            Self.line([
                "method": "item/completed",
                "params": [
                    "threadId": "live-owned-thread",
                    "turnId": "live-owned-turn",
                    "item": [
                        "id": "agent-1",
                        "type": "agentMessage",
                        "text": finalText,
                    ],
                ],
            ]),
            Self.line([
                "method": "turn/completed",
                "params": [
                    "threadId": "live-owned-thread",
                    "turn": ["id": "live-owned-turn", "status": "completed"],
                ],
            ]),
        ]
        let connection = ScriptedCodexConnection(lines: lines)
        let launcher = FixtureCodexLauncher(
            mcpOutput: Data(
                #"[{"name":"disabled-server","enabled":false},{"name":"safe_server-1","enabled":true}]"#.utf8
            ),
            connection: connection
        )
        let runtime = Self.runtime(launcher: launcher, model: "fixture-model")

        let response = try await runtime.respond(to: Self.request())

        XCTAssertEqual(response.displayMarkdown, "What consistency model fits **edits**?")
        XCTAssertEqual(response.spokenText, "What consistency model fits edits?")
        let didTerminate = await connection.isTerminated()
        XCTAssertTrue(didTerminate)

        let messages = try Self.objects(from: await connection.sentData())
        XCTAssertEqual(messages.map { $0["method"] as? String }, [
            "initialize", "initialized", "account/read", "thread/start", "turn/start",
        ])
        let threadParams = try XCTUnwrap(messages[3]["params"] as? [String: Any])
        XCTAssertEqual(threadParams["ephemeral"] as? Bool, true)
        XCTAssertEqual(threadParams["approvalPolicy"] as? String, "never")
        XCTAssertEqual(threadParams["sandbox"] as? String, "read-only")
        XCTAssertEqual(threadParams["model"] as? String, "fixture-model")
        XCTAssertNotNil(threadParams["baseInstructions"] as? String)
        let developerInstructions = try XCTUnwrap(threadParams["developerInstructions"] as? String)
        XCTAssertTrue(developerInstructions.contains("When kind is opening"))
        XCTAssertTrue(developerInstructions.contains("When kind is reply"))
        XCTAssertNil(threadParams["dynamicTools"])
        XCTAssertNil(threadParams["runtimeWorkspaceRoots"])
        XCTAssertNil(threadParams["selectedCapabilityRoots"])

        let turnParams = try XCTUnwrap(messages[4]["params"] as? [String: Any])
        XCTAssertEqual(turnParams["threadId"] as? String, "live-owned-thread")
        XCTAssertEqual(turnParams["clientUserMessageId"] as? String, "candidate-turn")
        XCTAssertEqual(turnParams["approvalPolicy"] as? String, "never")
        let sandbox = try XCTUnwrap(turnParams["sandboxPolicy"] as? [String: Any])
        XCTAssertEqual(sandbox["type"] as? String, "readOnly")
        XCTAssertEqual(sandbox["networkAccess"] as? Bool, false)
        XCTAssertNil(turnParams["runtimeWorkspaceRoots"])
        let schema = try XCTUnwrap(turnParams["outputSchema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let requiredFields = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(
            Set(requiredFields),
            Set(["displayMarkdown", "spokenText"])
        )
        let input = try XCTUnwrap(turnParams["input"] as? [[String: Any]])
        let prompt = try XCTUnwrap(input.first?["text"] as? String)
        XCTAssertTrue(prompt.contains("candidate answer verbatim"))
        XCTAssertTrue(prompt.contains("\"kind\":\"reply\""))
        XCTAssertTrue(prompt.contains("prior candidate answer"))
        XCTAssertTrue(prompt.contains("prior interviewer display"))
        XCTAssertTrue(prompt.contains("response-turn"))
        XCTAssertFalse(prompt.contains(privateInstructionPath))
        XCTAssertFalse(prompt.contains("private work that must not cross"))

        let recordedArguments = await launcher.connectionArguments()
        let arguments = try XCTUnwrap(recordedArguments)
        XCTAssertTrue(arguments.contains("--strict-config"))
        XCTAssertTrue(arguments.contains("web_search=\"disabled\""))
        XCTAssertTrue(arguments.contains("mcp_servers.safe_server-1.enabled=false"))
        XCTAssertFalse(arguments.contains("mcp_servers.disabled-server.enabled=false"))
        let disabled = Set(arguments.windows(ofCount: 2).compactMap { pair in
            pair[0] == "--disable" ? pair[1] : nil
        })
        XCTAssertEqual(disabled, Set(Self.expectedDisabledFeatures))
    }

    func testOpeningTurnEncodesKindWithoutCandidateAnswerAndUsesResponseTurnIdentity() async throws {
        let finalText = #"{"displayMarkdown":"Design a **notification** service. What scale first?","spokenText":"Design a notification service. What scale first?"}"#
        let connection = ScriptedCodexConnection(lines: Self.completeTurnLines(finalText: finalText))
        let runtime = Self.runtime(launcher: FixtureCodexLauncher(connection: connection))

        let response = try await runtime.respond(to: Self.openingRequest())

        XCTAssertEqual(
            response.displayMarkdown,
            "Design a **notification** service. What scale first?"
        )
        XCTAssertEqual(response.spokenText, "Design a notification service. What scale first?")
        let messages = try Self.objects(from: await connection.sentData())
        let turnParams = try XCTUnwrap(messages[4]["params"] as? [String: Any])
        XCTAssertEqual(turnParams["clientUserMessageId"] as? String, "opening-response-turn")
        let input = try XCTUnwrap(turnParams["input"] as? [[String: Any]])
        let prompt = try XCTUnwrap(input.first?["text"] as? String)
        XCTAssertTrue(prompt.contains("\"kind\":\"opening\""))
        XCTAssertFalse(prompt.contains("candidateAnswer"))
        XCTAssertFalse(prompt.contains("candidateTurnID"))
        XCTAssertTrue(prompt.contains("Design collaborative document editing."))
        XCTAssertFalse(prompt.contains("candidate answer verbatim"))
    }

    func testServerErrorCodeIsTypedAndConnectionIsReapedWithoutMessageLeak() async throws {
        let connection = ScriptedCodexConnection(lines: Self.authenticationLines() + [
            Self.line([
                "id": 3,
                "error": ["code": -32602, "message": "identity and path must not escape"],
            ]),
        ])
        let runtime = Self.runtime(launcher: FixtureCodexLauncher(connection: connection))

        do {
            _ = try await runtime.respond(to: Self.request())
            XCTFail("Expected server failure")
        } catch let error as CodexAppServerRuntimeError {
            XCTAssertEqual(error, .serverFailure(code: -32602))
            XCTAssertFalse(String(describing: error).contains("identity"))
        }
        let didTerminate = await connection.isTerminated()
        XCTAssertTrue(didTerminate)
    }

    func testUnknownFinalFieldFailsStrictlyAndReapsConnection() async throws {
        let connection = ScriptedCodexConnection(
            lines: Self.completeTurnLines(
                finalText: #"{"displayMarkdown":"Question","spokenText":"Question","work":"hidden"}"#
            )
        )
        let runtime = Self.runtime(launcher: FixtureCodexLauncher(connection: connection))

        await XCTAssertRuntimeError(.malformedFinalResponse) {
            _ = try await runtime.respond(to: Self.request())
        }
        let didTerminate = await connection.isTerminated()
        XCTAssertTrue(didTerminate)
    }

    func testToolItemFailsClosedAndIsNeverReturned() async throws {
        let lines = Self.authenticationLines() + Self.threadAndTurnStartLines() + [
            Self.line([
                "method": "item/started",
                "params": [
                    "threadId": "live-owned-thread",
                    "turnId": "live-owned-turn",
                    "item": ["id": "tool-1", "type": "commandExecution"],
                ],
            ]),
        ]
        let connection = ScriptedCodexConnection(lines: lines)
        let runtime = Self.runtime(launcher: FixtureCodexLauncher(connection: connection))

        await XCTAssertRuntimeError(.protocolFailure) {
            _ = try await runtime.respond(to: Self.request())
        }
        let didTerminate = await connection.isTerminated()
        XCTAssertTrue(didTerminate)
    }

    func testUnexpectedProcessExitFailsAsSafeTransportErrorAndReaps() async throws {
        let connection = ScriptedCodexConnection(
            lines: Self.authenticationLines() + Self.threadAndTurnStartLines(),
            endWhenExhausted: true
        )
        let runtime = Self.runtime(launcher: FixtureCodexLauncher(connection: connection))

        await XCTAssertRuntimeError(.transportFailure) {
            _ = try await runtime.respond(to: Self.request())
        }
        let didTerminate = await connection.isTerminated()
        XCTAssertTrue(didTerminate)
    }

    func testCancellationInterruptsKnownLiveOwnedTurnThenTerminates() async throws {
        let connection = ScriptedCodexConnection(
            lines: Self.authenticationLines() + Self.threadAndTurnStartLines(),
            endWhenExhausted: false
        )
        let runtime = Self.runtime(
            launcher: FixtureCodexLauncher(connection: connection),
            turnTimeoutNanoseconds: 30_000_000_000
        )
        let task = Task { try await runtime.respond(to: Self.request()) }

        for _ in 0..<2_000 {
            if (try? await connection.sentMethod("turn/start")) == true { break }
            await Task.yield()
        }
        let didStartTurn = try await connection.sentMethod("turn/start")
        XCTAssertTrue(didStartTurn)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as CodexAppServerRuntimeError {
            XCTAssertEqual(error, .cancelled)
        }
        let didInterrupt = try await connection.sentMethod("turn/interrupt")
        let didTerminate = await connection.isTerminated()
        XCTAssertTrue(didInterrupt)
        XCTAssertTrue(didTerminate)
    }

    func testNonEphemeralThreadResponseFailsClosed() async throws {
        var thread = Self.threadStartResult()
        var result = try XCTUnwrap(thread["result"] as? [String: Any])
        var value = try XCTUnwrap(result["thread"] as? [String: Any])
        value["ephemeral"] = false
        result["thread"] = value
        thread["result"] = result
        let connection = ScriptedCodexConnection(
            lines: Self.authenticationLines() + [Self.line(thread)]
        )
        let runtime = Self.runtime(launcher: FixtureCodexLauncher(connection: connection))

        await XCTAssertRuntimeError(.protocolFailure) {
            _ = try await runtime.respond(to: Self.request())
        }
        let didTerminate = await connection.isTerminated()
        XCTAssertTrue(didTerminate)
    }

    private func XCTAssertRuntimeError(
        _ expected: CodexAppServerRuntimeError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as CodexAppServerRuntimeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type", file: file, line: line)
        }
    }

    private static func runtime(
        launcher: FixtureCodexLauncher,
        model: String? = nil,
        turnTimeoutNanoseconds: UInt64 = 1_000_000_000
    ) -> CodexAppServerInterviewerRuntime {
        CodexAppServerInterviewerRuntime(
            codexExecutableURL: URL(fileURLWithPath: "/bin/sh"),
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp"),
            model: model,
            launcher: launcher,
            environment: [
                "PATH": "/parent/secret/path",
                "PARENT_SECRET": "must-not-be-inherited",
                "TMPDIR": "/private/tmp",
            ],
            homeDirectoryURL: URL(fileURLWithPath: "/private/tmp/fixture-home"),
            commandTimeoutNanoseconds: 1_000_000_000,
            preflightTimeoutNanoseconds: 1_000_000_000,
            turnTimeoutNanoseconds: turnTimeoutNanoseconds
        )
    }

    private static func request() -> InterviewerRequest {
        let priorCandidate = CandidateTurn(
            id: TurnID("prior-candidate"),
            commandID: CommandID("prior-command"),
            transcript: CandidateTranscript(
                body: "prior candidate answer",
                quality: .verified
            )
        )
        let priorInterviewer = InterviewerTurn(
            id: TurnID("prior-interviewer"),
            commandID: CommandID("prior-command"),
            replyToTurnID: priorCandidate.id,
            response: CanonicalInterviewerResponse(
                displayMarkdown: "prior interviewer display",
                spokenText: "prior interviewer spoken"
            )
        )
        return InterviewerRequest(
            sessionID: SessionID("session-fixture"),
            activityID: "activity-fixture",
            activityPrompt: try! ActivityPrompt(
                specialty: .systemDesign,
                stage: "Architecture deep dive",
                question: "Design collaborative document editing.",
                requestedParts: ["Clarify requirements", "Discuss consistency"]
            ),
            candidateTurn: CandidateTurn(
                id: TurnID("candidate-turn"),
                commandID: CommandID("handoff-command"),
                transcript: CandidateTranscript(
                    body: "candidate answer verbatim",
                    quality: .bestAvailable
                )
            ),
            priorVisibleTurns: [
                .candidate(priorCandidate),
                .interviewer(priorInterviewer),
            ],
            responseTurnID: TurnID("response-turn")
        )
    }

    private static func openingRequest() -> InterviewerRequest {
        InterviewerRequest(
            sessionID: SessionID("session-fixture"),
            activityID: "activity-fixture",
            activityPrompt: try! ActivityPrompt(
                specialty: .systemDesign,
                stage: "Architecture deep dive",
                question: "Design collaborative document editing.",
                requestedParts: ["Clarify requirements", "Discuss consistency"]
            ),
            candidateTurn: nil,
            priorVisibleTurns: [],
            responseTurnID: TurnID("opening-response-turn")
        )
    }

    private static func authenticationLines(account: Any = ["type": "chatgpt"]) -> [Data] {
        [
            line([
                "id": 1,
                "result": [
                    "userAgent": "codex-fixture",
                    "platformFamily": "unix",
                    "platformOs": "macos",
                ],
            ]),
            line([
                "id": 2,
                "result": [
                    "account": account,
                    "requiresOpenaiAuth": true,
                ],
            ]),
        ]
    }

    private static func threadStartResult() -> [String: Any] {
        [
            "id": 3,
            "result": [
                "approvalPolicy": "never",
                "sandbox": ["type": "readOnly", "networkAccess": false],
                "thread": [
                    "id": "live-owned-thread",
                    "ephemeral": true,
                    "forkedFromId": NSNull(),
                ],
            ],
        ]
    }

    private static func threadAndTurnStartLines() -> [Data] {
        [
            line(threadStartResult()),
            line([
                "id": 4,
                "result": [
                    "turn": [
                        "id": "live-owned-turn",
                        "status": "inProgress",
                        "items": [],
                    ],
                ],
            ]),
        ]
    }

    private static func completeTurnLines(finalText: String) -> [Data] {
        authenticationLines() + threadAndTurnStartLines() + [
            line([
                "method": "item/completed",
                "params": [
                    "threadId": "live-owned-thread",
                    "turnId": "live-owned-turn",
                    "item": [
                        "id": "agent-1",
                        "type": "agentMessage",
                        "text": finalText,
                    ],
                ],
            ]),
            line([
                "method": "turn/completed",
                "params": [
                    "threadId": "live-owned-thread",
                    "turn": ["id": "live-owned-turn", "status": "completed"],
                ],
            ]),
        ]
    }

    fileprivate static func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func objects(from values: [Data]) throws -> [[String: Any]] {
        try values.map { data in
            var line = data
            if line.last == 0x0A { line.removeLast() }
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: line) as? [String: Any]
            )
        }
    }

    private static let expectedDisabledFeatures = [
        "apply_patch_freeform", "apply_patch_streaming_events", "apps", "artifact",
        "auth_elicitation", "plugins", "hooks", "multi_agent", "multi_agent_mode",
        "multi_agent_v2", "browser_use", "browser_use_external",
        "browser_use_full_cdp_access", "code_mode", "code_mode_buffered_exec",
        "code_mode_host", "code_mode_only", "codex_git_commit", "computer_use",
        "current_time_reminder", "default_mode_request_user_input", "deferred_executor",
        "deferred_tool_world_state", "enable_fanout", "enable_mcp_apps",
        "exec_permission_approvals", "executor_capability_discovery",
        "external_agent_memory_import", "goals", "guardian_approval", "guardianv2",
        "image_generation", "in_app_browser", "js_repl", "js_repl_tools_only",
        "mcp_2026_07_28", "memories", "mentions_v2", "network_proxy",
        "plugin_hooks", "plugin_sharing", "recommended_plugins", "remote_plugin",
        "request_permissions_tool", "request_rule", "search_tool", "shell_snapshot",
        "skill_search", "skill_mcp_dependency_install", "shell_tool", "shell_zsh_fork",
        "standalone_web_search", "tool_call_mcp_elicitation", "tool_search",
        "tool_search_always_defer_mcp_tools", "tool_suggest", "unavailable_dummy_tools",
        "undo", "unified_exec", "unified_exec_zsh_fork", "use_agent_identity",
        "web_search_cached", "web_search_request", "workspace_dependencies",
    ]
}

private actor FixtureCodexLauncher: CodexAppServerProcessLaunching {
    private let version: String
    private let versionExitCode: Int32
    private let mcpOutput: Data
    private let connection: ScriptedCodexConnection
    private var recordedEnvironments: [[String: String]] = []
    private var recordedConnectionArguments: [String]?

    init(
        version: String = CodexAppServerInterviewerRuntime.testedCLIVersion,
        versionExitCode: Int32 = 0,
        mcpOutput: Data = Data("[]".utf8),
        connection: ScriptedCodexConnection
    ) {
        self.version = version
        self.versionExitCode = versionExitCode
        self.mcpOutput = mcpOutput
        self.connection = connection
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeoutNanoseconds: UInt64,
        outputLimit: Int
    ) async throws -> CodexCommandResult {
        recordedEnvironments.append(environment)
        if arguments == ["--version"] {
            return CodexCommandResult(
                standardOutput: Data(version.utf8),
                exitCode: versionExitCode
            )
        }
        guard arguments.starts(with: ["mcp", "list", "--json"]) else {
            throw CodexProcessFailure.launch
        }
        return CodexCommandResult(
            standardOutput: mcpOutput,
            exitCode: 0
        )
    }

    func connect(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        lineLimit: Int,
        totalOutputLimit: Int
    ) async throws -> any CodexAppServerProcessConnection {
        recordedEnvironments.append(environment)
        recordedConnectionArguments = arguments
        return connection
    }

    func environments() -> [[String: String]] {
        recordedEnvironments
    }

    func connectionArguments() -> [String]? {
        recordedConnectionArguments
    }
}

private actor ScriptedCodexConnection: CodexAppServerProcessConnection {
    private var lines: [Data]
    private let endWhenExhausted: Bool
    private var sent: [Data] = []
    private var terminated = false

    init(lines: [Data], endWhenExhausted: Bool = true) {
        self.lines = lines
        self.endWhenExhausted = endWhenExhausted
    }

    func send(_ data: Data) async throws {
        guard !terminated else { throw CodexProcessFailure.io }
        sent.append(data)
    }

    func receiveLine() async throws -> Data? {
        while lines.isEmpty, !terminated, !endWhenExhausted {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard !terminated else { return nil }
        guard !lines.isEmpty else { return nil }
        return lines.removeFirst()
    }

    func waitForExit() async -> Int32 { 0 }

    func terminate() async {
        terminated = true
    }

    func isTerminated() -> Bool { terminated }

    func sentMethod(_ method: String) throws -> Bool {
        try sent.contains { data in
            var line = data
            if line.last == 0x0A { line.removeLast() }
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { return false }
            return object["method"] as? String == method
        }
    }

    func sentData() -> [Data] { sent }
}

private extension Array where Element: Equatable {
    func windows(ofCount count: Int) -> [[Element]] {
        guard count > 0, self.count >= count else { return [] }
        return (0...(self.count - count)).map {
            Array(self[$0..<($0 + count)])
        }
    }
}
