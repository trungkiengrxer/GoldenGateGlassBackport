// Golden Gate Glass management app.
import SwiftUI

@main
struct GoldenGateGlassApp: App {
    @State private var store = Store()

    var body: some Scene {
        Window("Golden Gate Glass", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 460, minHeight: 480)
                .onAppear { store.refresh() }
        }
        .defaultSize(width: 520, height: 640)
    }
}
