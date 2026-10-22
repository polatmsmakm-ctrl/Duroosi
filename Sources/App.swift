import SwiftUI
import AVFoundation

@main
struct DuroosiApp: App {
    @StateObject private var store = Store()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            SubjectsView()
                .environmentObject(store)
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}
