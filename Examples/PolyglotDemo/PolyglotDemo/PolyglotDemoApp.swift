import Polyglot
import SwiftUI

@main
struct PolyglotDemoApp: App {
    init() {
        // Local backend from `backend/` (`npm run dev` + `npm run seed`).
        Polyglot.start(PolyglotConfig(
            projectId: "p_demo",
            sdkKey: "pk_demo_local",
            baseURL: URL(string: "http://localhost:8787")!,
            refreshInterval: 60
        ))
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
