import SwiftUI

@main
struct PokerTableApp: App {
    var body: some Scene {
        WindowGroup {
            TableView()
        }
        #if os(macOS)
        .defaultSize(width: 460, height: 860)
        #endif
    }
}
