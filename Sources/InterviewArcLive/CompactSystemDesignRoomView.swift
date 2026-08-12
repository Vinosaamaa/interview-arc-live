import SwiftUI

struct CompactSystemDesignRoomView: View {
  @ObservedObject var model: SystemDesignRoomModel
  let onExpand: () -> Void
  let dynamicTypeSizeOverride: DynamicTypeSize?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(
    model: SystemDesignRoomModel,
    onExpand: @escaping () -> Void,
    dynamicTypeSizeOverride: DynamicTypeSize? = nil
  ) {
    self.model = model
    self.onExpand = onExpand
    self.dynamicTypeSizeOverride = dynamicTypeSizeOverride
  }

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
    .foregroundStyle(CompactMockupPalette.ink)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Interview Arc Live compact interview controls")
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.16),
      value: presentation.statusKind
    )
  }

  private var capsuleContent: some View {
    Group {
      if effectiveDynamicTypeSize.isAccessibilitySize {
        stackedCapsule
      } else {
        ViewThatFits(in: .horizontal) {
          horizontalCapsule
          stackedCapsule
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var effectiveDynamicTypeSize: DynamicTypeSize {
    dynamicTypeSizeOverride ?? dynamicTypeSize
  }

  private var horizontalCapsule: some View {
    HStack(spacing: 12) {
      expandMarkButton
      status
      signalTrace
      Spacer(minLength: 4)
      utilityControls
      conversationControls
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      CompactMockupPalette.paper,
      in: RoundedRectangle(cornerRadius: 22, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(CompactMockupPalette.innerLine, lineWidth: 1)
        .accessibilityHidden(true)
    }
  }

  private var stackedCapsule: some View {
    VStack(spacing: 10) {
      HStack(spacing: 12) {
        expandMarkButton
        status
        signalTrace
        Spacer(minLength: 0)
      }

      Rectangle()
        .fill(CompactMockupPalette.innerLine)
        .frame(height: 1)
        .accessibilityHidden(true)

      HStack(spacing: 8) {
        Spacer(minLength: 0)
        utilityControls
        conversationControls
      }
    }
    .padding(12)
    .background(
      CompactMockupPalette.paper,
      in: RoundedRectangle(cornerRadius: 22, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(CompactMockupPalette.innerLine, lineWidth: 1)
        .accessibilityHidden(true)
    }
  }

  private var status: some View {
    HStack(spacing: 6) {
      Text(presentation.floorTitle)
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(statusColor)
        .lineLimit(1)
      Text("·")
        .foregroundStyle(CompactMockupPalette.muted)
        .accessibilityHidden(true)
      Text(presentation.statusValue)
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(CompactMockupPalette.muted)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(presentation.statusValue)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("compact-room-status")
    .accessibilityLabel("Current interview status")
    .accessibilityValue(
      "\(presentation.floorTitle). \(presentation.statusValue)"
    )
    .accessibilitySortPriority(60)
    .frame(maxWidth: 190, alignment: .leading)
  }

  private var signalTrace: some View {
    HStack(alignment: .center, spacing: 1.5) {
      ForEach(Array(Self.signalHeights.enumerated()), id: \.offset) { _, height in
        Capsule()
          .fill(statusColor)
          .frame(width: 1.5, height: height)
      }
    }
    .frame(width: 66, height: 22)
    .accessibilityHidden(true)
  }

  private var utilityControls: some View {
    HStack(spacing: 6) {
      ForEach(presentation.speechControls) { control in
        utilityButton(control)
      }
    }
  }

  private var conversationControls: some View {
    HStack(spacing: 8) {
      if let candidateControl = presentation.candidateControl {
        utilityButton(candidateControl)
      }
      if let phaseControl = presentation.phaseControl {
        conversationButton(phaseControl)
      }
    }
  }

  private var expandMarkButton: some View {
    Button {
      dispatch(.expand)
    } label: {
      Image(systemName: presentation.expandControl.systemImage)
        .font(.system(size: 16, weight: .semibold))
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
    .buttonStyle(CompactHoverIconButtonStyle())
    .help(presentation.expandControl.accessibilityHint)
    .accessibilityIdentifier("compact-room-expand")
    .accessibilityLabel(presentation.expandControl.title)
    .accessibilityHint(presentation.expandControl.accessibilityHint)
    .accessibilitySortPriority(10)
  }

  private func utilityButton(_ control: CompactRoomControl) -> some View {
    let foreground = control.action == .stopRecording
      || control.action == .stopSpeech
      ? CompactMockupPalette.stop
      : CompactMockupPalette.ink
    return Button {
      dispatch(control.action)
    } label: {
      Image(systemName: control.systemImage)
        .font(.system(size: 14, weight: .semibold))
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
    .buttonStyle(CompactHoverIconButtonStyle(foreground: foreground))
    .disabled(!control.isEnabled)
    .help(control.accessibilityHint)
    .accessibilityIdentifier("compact-room-\(control.action.rawValue)")
    .accessibilityLabel(control.title)
    .accessibilityHint(control.accessibilityHint)
    .optionalAccessibilityValue(control.accessibilityValue)
    .accessibilitySortPriority(accessibilityPriority(for: control.action))
  }

  @ViewBuilder
  private func conversationButton(_ control: CompactRoomControl) -> some View {
    let button = Button {
      dispatch(control.action)
    } label: {
      Label(control.title, systemImage: control.systemImage)
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .lineLimit(1)
    }
    .disabled(!control.isEnabled)
    .controlSize(.large)
    .help(control.accessibilityHint)
    .accessibilityIdentifier("compact-room-\(control.action.rawValue)")
    .accessibilityHint(control.accessibilityHint)
    .optionalAccessibilityValue(control.accessibilityValue)
    .accessibilitySortPriority(accessibilityPriority(for: control.action))

    switch control.action {
    case .stopRecording, .stopSpeech:
      button
        .buttonStyle(.borderedProminent)
        .tint(CompactMockupPalette.stop)
    case .recordSegment, .primaryPhaseAction:
      button
        .buttonStyle(.bordered)
        .tint(CompactMockupPalette.violet)
    case .toggleSpeechMute, .expand:
      EmptyView()
    }
  }

  private var statusColor: Color {
    switch presentation.tone {
    case .quiet: return CompactMockupPalette.muted
    case .candidate: return CompactMockupPalette.violet
    case .working: return CompactMockupPalette.violet
    case .interviewer: return CompactMockupPalette.violet
    case .warning: return CompactMockupPalette.stop
    case .completed: return CompactMockupPalette.violet
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

  private static let signalHeights: [CGFloat] = [
    4, 7, 11, 6, 15, 8, 5, 12, 18, 9, 6, 14, 8, 5, 11, 7,
    4, 9, 6, 12, 5, 8, 4, 7,
  ]
}

private enum CompactMockupPalette {
  static let innerLine = Color(red: 225 / 255, green: 228 / 255, blue: 241 / 255)
  static let paper = Color(red: 253 / 255, green: 253 / 255, blue: 1)
  static let ink = Color(red: 15 / 255, green: 26 / 255, blue: 67 / 255)
  static let muted = Color(red: 91 / 255, green: 102 / 255, blue: 142 / 255)
  static let violet = Color(red: 68 / 255, green: 48 / 255, blue: 184 / 255)
  static let stop = Color(red: 216 / 255, green: 48 / 255, blue: 32 / 255)
}

private struct CompactHoverIconButtonStyle: ButtonStyle {
  var foreground: Color = CompactMockupPalette.ink

  func makeBody(configuration: Configuration) -> some View {
    CompactHoverIconButtonBody(
      configuration: configuration,
      foreground: foreground
    )
  }

  private struct CompactHoverIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let foreground: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .foregroundStyle(
          isEnabled ? foreground : CompactMockupPalette.muted.opacity(0.55)
        )
        .background {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
              CompactMockupPalette.violet.opacity(
                isEnabled
                  ? (configuration.isPressed ? 0.16 : (isHovering ? 0.09 : 0))
                  : 0
              )
            )
        }
        .scaleEffect(
          reduceMotion
            ? 1
            : (isEnabled
              ? (configuration.isPressed ? 0.97 : (isHovering ? 1.02 : 1))
              : 1)
        )
        .onHover { isHovering = $0 }
        .animation(
          reduceMotion ? nil : .easeOut(duration: 0.14),
          value: isHovering
        )
        .animation(
          reduceMotion ? nil : .easeOut(duration: 0.08),
          value: configuration.isPressed
        )
    }
  }
}

extension View {
  @ViewBuilder
  fileprivate func optionalAccessibilityValue(_ value: String?) -> some View {
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
