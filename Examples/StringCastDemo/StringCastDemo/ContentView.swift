import DemoFeature
import StringCast
import SwiftUI

struct ContentView: View {
    @ObservedObject private var stringcast = StringCastStore.shared
    @State private var count = 1
    @State private var refreshing = false
    @State private var uploadStatus: String?
    @State private var overrideCode: String?

    private let languages: [(label: String, code: String?)] = [("Device", nil), ("en", "en"), ("es", "es"), ("fr", "fr")]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(verbatim: "StringCast.string / Text(stringcast:)")) {
                    Text(stringcast: "welcome_title").font(.title2.bold())
                    Text(stringcast: "welcome_body")
                }

                Section(header: Text(verbatim: "NSLocalizedString (intercepted Bundle.main)")) {
                    Text(verbatim: NSLocalizedString("welcome_title", comment: ""))
                }

                Section(header: Text(verbatim: "Swift package bundle (\(DemoFeature.bundleName), table Feature)")) {
                    // `stringcast.revision` makes this section re-render when a release arrives.
                    let _ = stringcast.revision
                    Text(verbatim: DemoFeature.title()).font(.headline)
                    Text(verbatim: DemoFeature.body())
                }

                Section(header: Text(verbatim: "Plurals")) {
                    Stepper(value: $count, in: 0...25) {
                        Text(stringcast: "items_count", count: count)
                    }
                }

                Section(header: Text(verbatim: stringcast.string("language_label", StringCast.currentLanguage))) {
                    Picker(selection: Binding(
                        get: { languages.firstIndex { $0.code == overrideCode } ?? 0 },
                        set: {
                            overrideCode = languages[$0].code
                            StringCast.setLanguage(overrideCode)
                        }
                    ), label: Text(verbatim: "")) {
                        ForEach(languages.indices, id: \.self) { Text(verbatim: languages[$0].label).tag($0) }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    Text(verbatim: "Release v\(stringcast.version)").foregroundColor(.secondary)
                }

                Section {
                    Button(stringcast.string("cta_refresh")) {
                        refreshing = true
                        Task {
                            await StringCast.refresh(force: true)
                            refreshing = false
                        }
                    }
                    .disabled(refreshing)
                    #if DEBUG
                    Button("Upload local strings (draft mode)") {
                        Task {
                            do {
                                let r = try await StringCast.uploadLocalStrings()
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
            .navigationBarTitle(Text(verbatim: "StringCast Demo"))
        }
    }
}
