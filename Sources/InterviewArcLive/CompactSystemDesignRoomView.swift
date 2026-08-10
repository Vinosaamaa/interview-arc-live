import SwiftUI

struct CompactSystemDesignRoomView: View {
    @ObservedObject var model: SystemDesignRoomModel
    let onExpand: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: CompactRoomPresentation {
        model.compactPresentation
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            capsuleContent

            ScrollView(.vertical) {
                capsuleContent
            }
            .scrollIndicators(.visible)
            .frame(height: CompactPanelLayout.maximumContentHeight)
        }
        .frame(width: CompactPanelLayout.contentWidth)
        .frame(
            minHeight: CompactPanelLayout.minimumContentHeight,
            maxHeight: CompactPanelLayout.maximumContentHeight,
            alignment: .topLeading
        )
        .background(
            LivePalette.shell,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .foregroundStyle(LivePalette.paper)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Interview Arc Live compact interview controls")
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: presentation.statusKind
        )
    }

    private var capsuleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            status

            Rectangle()
                .fill(LivePalette.line.opacity(0.42))
                .frame(height: 1)
                .accessibilityHidden(true)

            if !conversationControls.isEmpty {
                controlRow(conversationControls)
            }
            bottomControlRow
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var status: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: presentation.systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.floorTitle)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Text(presentation.statusValue)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(LivePalette.line)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(presentation.statusValue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("compact-room-status")
        .accessibilityLabel("Current interview status")
        .accessibilityValue(
            "\(presentation.floorTitle). \(presentation.statusValue)"
        )
        .accessibilitySortPriority(60)
    }

    private var conversationControls: [CompactRoomControl] {
        [presentation.candidateControl, presentation.phaseControl]
            .compactMap { $0 }
    }

    private func controlRow(
        _ controls: [CompactRoomControl]
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ForEach(controls) { control in
                    controlButton(control)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(controls) { control in
                    controlButton(control)
                }
            }
        }
    }

    private var bottomControlRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ForEach(presentation.speechControls) { control in
                    controlButton(control)
                }
                Spacer(minLength: 12)
                controlButton(presentation.expandControl)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(presentation.speechControls) { control in
                    controlButton(control)
                }
                controlButton(presentation.expandControl)
            }
        }
    }

    @ViewBuilder
    private func controlButton(
        _ control: CompactRoomControl
    ) -> some View {
        let button = Button {
            dispatch(control.action)
        } label: {
            Label(control.title, systemImage: control.systemImage)
                .font(.system(.body, design: .rounded, weight: .semibold))
        }
        .disabled(!control.isEnabled)
        .frame(minHeight: 34)
        .help(control.accessibilityHint)
        .accessibilityIdentifier("compact-room-\(control.action.rawValue)")
        .accessibilityHint(control.accessibilityHint)
        .optionalAccessibilityValue(control.accessibilityValue)
        .accessibilitySortPriority(accessibilityPriority(for: control.action))

        switch control.action {
        case .stopRecording, .primaryPhaseAction:
            button
                .buttonStyle(.borderedProminent)
                .tint(LivePalette.handoff)
        case .recordSegment:
            button
                .buttonStyle(.bordered)
                .tint(LivePalette.paper)
        case .stopSpeech:
            button
                .buttonStyle(.borderedProminent)
                .tint(LivePalette.interviewer)
        case .toggleSpeechMute, .expand:
            button
                .buttonStyle(.bordered)
                .tint(LivePalette.paper)
        }
    }

    private var statusColor: Color {
        switch presentation.tone {
        case .quiet: return LivePalette.line
        case .candidate: return LivePalette.liveSignal
        case .working: return LivePalette.interviewer
        case .interviewer: return LivePalette.interviewer
        case .warning: return LivePalette.handoff
        case .completed: return LivePalette.liveSignal
        }
    }

    private func accessibilityPriority(
        for action: CompactRoomAction
    ) -> Double {
        switch action {
        case .recordSegment, .stopRecording: return 50
        case .primaryPhaseAction: return 40
        case .stopSpeech: return 30
        case .toggleSpeechMute: return 20
        case .expand: return 10
        }
    }

    private func dispatch(_ action: CompactRoomAction) {
        switch action {
        case .recordSegment:
            Task { await model.recordSegment() }
        case .stopRecording:
            Task { await model.stopRecording() }
        case .primaryPhaseAction:
            Task { await model.performPrimaryAction() }
        case .stopSpeech:
            Task { await model.stopSpeech() }
        case .toggleSpeechMute:
            Task { await model.toggleSpeechMute() }
        case .expand:
            onExpand()
        }
    }
}

private extension View {
    @ViewBuilder
    func optionalAccessibilityValue(_ value: String?) -> some View {
        if let value {
            accessibilityValue(value)
        } else {
            self
        }
    }
}

private struct CompactSystemDesignRoomViewPreview: PreviewProvider {
    static var previews: some View {
        CompactSystemDesignRoomView(
            model: SystemDesignRoomModel(),
            onExpand: {}
        )
        .padding(30)
        .background(Color.gray.opacity(0.2))
        .previewDisplayName("Compact system design room")
    }
}
