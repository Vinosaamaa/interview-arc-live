import SwiftUI

@main
struct InterviewArcLiveApp: App {
    @StateObject private var model = SystemDesignRoomModel()

    var body: some Scene {
        WindowGroup("Interview Arc Live") {
            SystemDesignRoomView(model: model)
                .frame(minWidth: 1_080, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_180, height: 760)
    }
}
