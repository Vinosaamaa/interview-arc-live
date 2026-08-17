import SwiftUI

struct CompactBehavioralRoomView: View {
    @ObservedObject var model: BehavioralRoomModel
    let onExpand: () -> Void

    var body: some View {
        let presentation = model.compactPresentation
        HStack(spacing: 12) {
            Button(action: onExpand) {
                BehavioralCompactMark()
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .frame(
                width: FullRoomLayout.minimumActionHitTarget,
                height: FullRoomLayout.minimumActionHitTarget
            )
            .accessibilityLabel("Expand Behavioral room")

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.floorTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(BehavioralRoomPalette.violet)
                    .lineLimit(1)
                Text(presentation.statusValue)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(BehavioralRoomPalette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: 190, alignment: .leading)

            Spacer(minLength: 4)

            if let phase = presentation.phaseControl {
                Button {
                    Task { await model.performPrimaryAction() }
                } label: {
                    Label(phase.title, systemImage: phase.systemImage)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(minHeight: FullRoomLayout.minimumActionHitTarget)
                }
                .buttonStyle(.bordered)
                .disabled(!phase.isEnabled)
                .accessibilityLabel(phase.title)
            }

            Button {
                Task { _ = await model.finishInterview() }
            } label: {
                Label("End", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(minHeight: FullRoomLayout.minimumActionHitTarget)
            }
            .buttonStyle(.bordered)
            .tint(BehavioralRoomPalette.candidateText)
            .disabled(!model.canFinishLocally)
            .accessibilityLabel("End local interview")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: CompactPanelLayout.contentWidth)
        .background(
            BehavioralRoomPalette.paper,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(BehavioralRoomPalette.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(BehavioralRoomAccessibility.compactRoot)
        .accessibilityLabel("Interview Arc Live compact Behavioral controls")
    }
}

private struct BehavioralCompactMark: View {
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.05, to: 0.43)
                .stroke(
                    BehavioralRoomPalette.violet,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-22))
            Circle()
                .trim(from: 0.55, to: 0.92)
                .stroke(
                    BehavioralRoomPalette.navy,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-22))
        }
        .accessibilityHidden(true)
    }
}
