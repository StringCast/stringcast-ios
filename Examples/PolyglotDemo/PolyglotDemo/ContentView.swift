import Polyglot
import SwiftUI

struct ContentView: View {
    @ObservedObject private var polyglot = PolyglotStore.shared
    @State private var count = 1
    @State private var refreshing = false
    @State private var uploadStatus: String?
    @State private var overrideCode: String?

    private let languages: [(label: String, code: String?)] = [("Device", nil), ("en", "en"), ("es", "es"), ("fr", "fr")]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(verbatim: "Polyglot.string / Text(polyglot:)")) {
                    Text(polyglot: "welcome_title").font(.title2.bold())
                    Text(polyglot: "welcome_body")
                }

                Section(header: Text(verbatim: "NSLocalizedString (intercepted Bundle.main)")) {
                    Text(verbatim: NSLocalizedString("welcome_title", comment: ""))
                }

                Section(header: Text(verbatim: "Plurals")) {
                    Stepper(value: $count, in: 0...25) {
                        Text(polyglot: "items_count", count: count)
                    }
                }

                Section(header: Text(verbatim: polyglot.string("language_label", Polyglot.currentLanguage))) {
                    Picker(selection: Binding(
                        get: { languages.firstIndex { $0.code == overrideCode } ?? 0 },
                        set: {
                            overrideCode = languages[$0].code
                            Polyglot.setLanguage(overrideCode)
                        }
                    ), label: Text(verbatim: "")) {
                        ForEach(languages.indices, id: \.self) { Text(verbatim: languages[$0].label).tag($0) }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    Text(verbatim: "Release v\(polyglot.version)").foregroundColor(.secondary)
                }

                Section {
                    Button(polyglot.string("cta_refresh")) {
                        refreshing = true
                        Task {
                            await Polyglot.refresh(force: true)
                            refreshing = false
                        }
                    }
                    .disabled(refreshing)
                    #if DEBUG
                    Button("Upload local strings (draft mode)") {
                        Task {
                            do {
                                let r = try await Polyglot.uploadLocalStrings()
                                uploadStatus = "created \(r.created), ignored \(r.ignored)"
                            } catch {
                                uploadStatus = "\(error)"
                            }
                        }
                    }
                    if let status = uploadStatus { Text(verbatim: status).font(.footnote) }
                    #endif
                }
            }
            .navigationBarTitle(Text(verbatim: "Polyglot Demo"))
        }
    }
}
