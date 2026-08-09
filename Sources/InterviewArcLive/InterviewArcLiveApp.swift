import SwiftUI

@main
struct InterviewArcLiveApp: App {
    @StateObject private var model = SystemDesignRoomModel()

    var body: some Scene {
        WindowGroup("Interview Arc Live") {
            SystemDesignRoomView(model: model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
