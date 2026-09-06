import SwiftUI

@main
struct 音频切换伴侣App: App {
    @State private var session = CompanionAudioSession()
    @State private var client = CompanionSessionClient()

    var body: some Scene {
        WindowGroup {
            CompanionRootView(session: session, client: client)
        }
    }
}
