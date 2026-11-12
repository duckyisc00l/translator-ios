import SwiftUI

@main
struct TranslatorApp: App {
    @StateObject private var model = TranslatorModel()
    @StateObject private var speech = SpeechManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(speech)
        }
    }
}
