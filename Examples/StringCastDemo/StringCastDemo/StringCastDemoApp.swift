import StringCast
import SwiftUI

@main
struct StringCastDemoApp: App {
    init() {
        // Local backend from `backend/` (`npm run dev` + `npm run seed`).
        StringCast.start(StringCastConfig(
            projectId: "p_demo",
            sdkKey: "pk_demo_local",
            baseURL: URL(string: "http://localhost:8787")!,
            // baseURL: URL(string: "https://console.stringcast.app")!, // production (also the default if omitted)
            refreshInterval: 60
        ))
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
