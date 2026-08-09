import InterviewArcLiveCore
import SwiftUI

struct SystemDesignRoomView: View {
    @ObservedObject var model: SystemDesignRoomModel

    var body: some View {
        VStack(spacing: 0) {
            header
            question
            if let errorMessage = model.errorMessage {
                recoveryBanner(errorMessage)
            }
            if let codexMessage = model.codexAttentionMessage {
                codexReadinessBanner(codexMessage)
            }

            HSplitView {
                transcript
                    .frame(minWidth: 330, idealWidth: 390, maxWidth: 470)
                board
                    .frame(minWidth: 560)
            }

            floorRail
        }
        .background(LivePalette.room)
        .foregroundStyle(LivePalette.ink)
        .task { await model.open() }
        .sheet(isPresented: $model.isCredentialSetupPresented) {
            GroqCredentialSetupView(
                isSaving: model.isSavingCredential,
                errorMessage: model.credentialErrorMessage,
                onSaveToKeychain: model.saveGroqCredential,
                onUseUntilQuit: model.useGroqCredentialUntilQuit
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            LiveMark()
                .frame(width: 34, height: 34)
            Text("Interview Arc Live")
                .font(.system(.headline, design: .rounded, weight: .semibold))
            Spacer()
            Label("System design", systemImage: "point.3.connected.trianglepath.dotted")
            Rectangle()
                .fill(LivePalette.line.opacity(0.45))
                .frame(width: 1, height: 18)
            Text(model.statusMessage)
                .foregroundStyle(LivePalette.line)
                .lineLimit(1)
            if model.needsGroqCredential {
                Button("Add Groq key") {
                    model.presentCredentialSetup()
                }
                .buttonStyle(.bordered)
                .tint(LivePalette.liveSignal)
                .accessibilityHint("Opens secure Groq transcription setup")
            }
            Rectangle()
                .fill(LivePalette.line.opacity(0.45))
                .frame(width: 1, height: 18)
            codexStatus
            Rectangle()
                .fill(LivePalette.line.opacity(0.45))
                .frame(width: 1, height: 18)
            Label("Local source · Groq transcript", systemImage: "lock")
        }
        .font(.system(.body, design: .rounded))
        .foregroundStyle(LivePalette.paper)
        .padding(.horizontal, 22)
        .frame(height: 60)
        .background(LivePalette.shell)
    }

    private var codexStatus: some View {
        HStack(spacing: 6) {
            if model.isCheckingCodex {
                ProgressView()
                    .controlSize(.small)
                    .tint(LivePalette.paper)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: model.codexStatusIcon)
                    .accessibilityHidden(true)
            }
            Text(model.codexStatusTitle)
                .lineLimit(1)
        }
        .foregroundStyle(codexStatusColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex status: \(model.codexStatusTitle)")
    }

    private var codexStatusColor: Color {
        if model.isCheckingCodex {
            return LivePalette.paper
        }
        return model.isCodexReady ? LivePalette.liveSignal : LivePalette.handoff
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUESTION")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(LivePalette.muted)
            Text(model.question)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(LivePalette.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LivePalette.line).frame(height: 1)
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let snapshot = model.snapshot {
                    ForEach(snapshot.turns.indices, id: \.self) { index in
                        turnlineEntry(
                            snapshot.turns[index],
                            isLast: index == snapshot.turns.count - 1
                                && snapshot.phase != .candidateFloor
                        )
                    }

                    if snapshot.phase == .candidateFloor {
                        candidateFloorEntry
                    } else if snapshot.turns.isEmpty {
                        preparingEmptyState
                    }
                } else {
                    preparingEmptyState
                }
            }
        }
        .background(LivePalette.paper)
    }

    private var preparingEmptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PREPARING ROOM")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(LivePalette.interviewer)
            Text("Restoring the latest complete local session.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(LivePalette.muted)
        }
        .padding(28)
    }

    private var candidateFloorEntry: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 0) {
                Circle()
                    .fill(LivePalette.candidate)
                    .frame(width: 11, height: 11)
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 1)
                    .frame(minHeight: 82)
            }
            .padding(.top, 4)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("YOUR ANSWER DRAFT")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(LivePalette.candidate)
                    Spacer()
                    Text(segmentCountLabel)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(LivePalette.muted)
                }

                if model.segments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Record your first segment")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                        Text("Working pauses can become separate segments. Only Hand off commits them as one answer.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(LivePalette.muted)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LivePalette.room.opacity(0.48),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(LivePalette.line, style: StrokeStyle(lineWidth: 1, dash: [5]))
                    }
                } else {
                    ForEach(model.segments) { segment in
                        CandidateSegmentCard(
                            segment: segment,
                            isBusy: model.isWorking || model.canStopRecording,
                            onPlay: {
                                Task { await model.playSegment(id: segment.id) }
                            },
                            onTranscribe: {
                                Task { await model.transcribeSegment(id: segment.id) }
                            },
                            onExclude: {
                                Task { await model.excludeSegment(id: segment.id) }
                            }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
    }

    private func turnlineEntry(_ turn: InterviewTurn, isLast: Bool) -> some View {
        let role: String
        let body: String
        let color: Color
        let rendersMarkdown: Bool

        switch turn {
        case .candidate(let candidate):
            role = "YOU"
            body = candidate.transcript.body
            color = LivePalette.candidate
            rendersMarkdown = false
        case .interviewer(let interviewer):
            role = "MARA"
            body = interviewer.displayMarkdown
            color = LivePalette.interviewer
            rendersMarkdown = true
        }

        return HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 0) {
                Circle()
                    .fill(color)
                    .frame(width: 11, height: 11)
                Rectangle()
                    .fill(isLast ? Color.clear : LivePalette.line)
                    .frame(width: 1)
                    .frame(minHeight: 82)
            }
            .padding(.top, 4)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(role)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(color)
                Group {
                    if rendersMarkdown {
                        Text(.init(body))
                    } else {
                        Text(body)
                    }
                }
                    .font(.system(.title3, design: .rounded))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(role): \(body)")
    }

    private var board: some View {
        VStack(spacing: 0) {
            HStack {
                Text("BOARD")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .tracking(1.1)
                Spacer()
                Text("Draft revision \(model.snapshot?.revision ?? 0)")
                    .foregroundStyle(LivePalette.muted)
                Label("Reference draft · read-only", systemImage: "lock")
                    .foregroundStyle(LivePalette.muted)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(LivePalette.paper)

            Rectangle().fill(LivePalette.line).frame(height: 1)

            ZStack {
                DotGrid()
                HStack(spacing: 34) {
                    BoardNode(icon: "network", title: "API gateway")
                    BoardArrow()
                    BoardNode(icon: "tray.full", title: "Durable queue")
                    BoardArrow()
                    BoardNode(icon: "shippingbox", title: "Delivery workers")
                }
                .padding(30)
            }
        }
        .background(LivePalette.room)
    }

    private var floorRail: some View {
        HStack(spacing: 18) {
            Circle()
                .fill(LivePalette.liveSignal)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(floorLabel.uppercased())
                .font(.system(.caption, design: .monospaced, weight: .bold))
            Capsule()
                .fill(LivePalette.liveSignal.opacity(0.72))
                .frame(height: 3)

            if model.canStopRecording {
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Label(model.stopActionTitle, systemImage: model.stopActionIcon)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(LivePalette.handoff)
                .disabled(model.isWorking)
                .keyboardShortcut(.space, modifiers: [.command])
            } else if model.showsRecordControl {
                Button {
                    Task { await model.recordSegment() }
                } label: {
                    Label(model.recordActionTitle, systemImage: "record.circle")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(LivePalette.paper)
                .disabled(!model.canRecordSegment)
                .keyboardShortcut(.space, modifiers: [.command])
            }

            Button {
                Task { await model.performPrimaryAction() }
            } label: {
                Label(model.actionTitle, systemImage: model.actionIcon)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(LivePalette.handoff)
            .disabled(!model.canAct)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .foregroundStyle(LivePalette.paper)
        .padding(.horizontal, 24)
        .frame(height: 72)
        .background(LivePalette.shell)
    }

    private var floorLabel: String {
        if model.isInterviewerRequestInFlight {
            return "Answer saved · Codex working"
        }
        switch model.snapshot?.phase {
        case .candidateFloor:
            return "Your floor"
        case .interviewerProcessing:
            return model.isCodexReady
                ? "Answer saved · interviewer retry required"
                : "Answer saved · check Codex to retry"
        case .interviewerTurn:
            return "Interviewer turn"
        case .completed:
            return "Session complete"
        default:
            return "Preparing room"
        }
    }

    private var segmentCountLabel: String {
        let count = model.segments.count
        return count == 1 ? "1 SEGMENT" : "\(count) SEGMENTS"
    }

    private func recoveryBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LivePalette.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.needsGroqCredential {
                Button("Add Groq key") {
                    model.presentCredentialSetup()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(LivePalette.warning.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(LivePalette.warning.opacity(0.5)).frame(height: 1)
        }
    }

    private func codexReadinessBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.codexStatusIcon)
                .foregroundStyle(LivePalette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.codexStatusTitle)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                Text(message)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(LivePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Check Codex") {
                Task { await model.checkCodex() }
            }
            .disabled(model.isCheckingCodex)
            .accessibilityHint("Runs a private local compatibility and sign-in check")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(LivePalette.warning.opacity(0.1))
        .overlay(alignment: .bottom) {
            Rectangle().fill(LivePalette.warning.opacity(0.45)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

enum LivePalette {
    static let room = Color(red: 232 / 255, green: 239 / 255, blue: 236 / 255)
    static let paper = Color(red: 251 / 255, green: 252 / 255, blue: 250 / 255)
    static let ink = Color(red: 16 / 255, green: 42 / 255, blue: 42 / 255)
    static let muted = Color(red: 102 / 255, green: 122 / 255, blue: 118 / 255)
    static let line = Color(red: 198 / 255, green: 214 / 255, blue: 209 / 255)
    static let shell = Color(red: 11 / 255, green: 40 / 255, blue: 40 / 255)
    static let candidate = Color(red: 13 / 255, green: 148 / 255, blue: 136 / 255)
    static let interviewer = Color(red: 88 / 255, green: 105 / 255, blue: 201 / 255)
    static let handoff = Color(red: 223 / 255, green: 102 / 255, blue: 63 / 255)
    static let liveSignal = Color(red: 185 / 255, green: 219 / 255, blue: 87 / 255)
    static let warning = Color(red: 176 / 255, green: 78 / 255, blue: 39 / 255)
}

private struct LiveMark: View {
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.05, to: 0.43)
                .stroke(LivePalette.liveSignal, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-22))
            Circle()
                .trim(from: 0.55, to: 0.92)
                .stroke(LivePalette.handoff, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-22))
        }
        .padding(4)
        .accessibilityLabel("Interview Arc Live")
    }
}

private struct BoardNode: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(LivePalette.candidate)
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .multilineTextAlignment(.center)
        }
        .frame(width: 120, height: 108)
        .background(LivePalette.paper, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(LivePalette.line, lineWidth: 1.5)
        }
    }
}

private struct BoardArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .foregroundStyle(LivePalette.muted)
            .accessibilityHidden(true)
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            for x in stride(from: 10.0, through: size.width, by: 20) {
                for y in stride(from: 10.0, through: size.height, by: 20) {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                        with: .color(LivePalette.line.opacity(0.6))
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SystemDesignRoomViewPreview: PreviewProvider {
    static var previews: some View {
        SystemDesignRoomView(model: SystemDesignRoomModel())
            .frame(width: 1180, height: 760)
            .previewDisplayName("System design tracer")
    }
}
