import SwiftUI

struct AISettingsTab: View {
    @Environment(ModelDownloadsModel.self) private var downloads

    @Environment(CLIPFeatureModel.self) private var clip

    @State private var showModelDownloads = false

    var body: some View {
        Form {
            Section("AI Models") {
                ForEach(CLIPModelDownloadCatalog.production.models) { descriptor in
                    AIModelStatusRow(
                        name: descriptor.displayName,
                        state: downloads.clipModelDownloadStates[descriptor.id] ?? .checking,
                    )
                }

                HStack {
                    Button("Download AI Models", systemImage: "arrow.down.circle") {
                        showModelDownloads = true
                    }

                    Button("Check Again", systemImage: "arrow.clockwise") {
                        Task { await downloads.refreshCLIPModels() }
                    }

                    Spacer()
                }

                Text("CLIP and SAM 3 download from rsyncOSX/AI-models on GitHub and are used automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Semantic Search") {
                LabeledContent("Maximum results") {
                    Stepper(value: Binding(
                        get: { clip.semanticSearchLimit },
                        set: { clip.adjustSemanticSearchLimit(by: $0 - clip.semanticSearchLimit) },
                    ), in: 10 ... 500, step: 10) {
                        Text(clip.semanticSearchLimit, format: .number)
                            .monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showModelDownloads) {
            CLIPModelDownloadsView()
        }
        .task { await downloads.refreshCLIPModels() }
    }
}

struct AIModelStatusRow: View {
    let name: String
    let state: CLIPModelDownloadState

    var body: some View {
        HStack(spacing: 8) {
            Text(name)

            Spacer()

            if state.isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text(state.title)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) model")
        .accessibilityValue(String(localized: state.title))
    }
}
