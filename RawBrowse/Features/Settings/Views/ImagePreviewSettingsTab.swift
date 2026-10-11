import SwiftUI

struct ImagePreviewSettingsTab: View {
    @Environment(ZoomModel.self) private var zoom

    var body: some View {
        @Bindable var zoom = zoom

        Form {
            Section("RAW 9 Preview") {
                Picker("Bit depth", selection: $zoom.rawPreviewBitDepth) {
                    Text("8-bit").tag(RAWPreviewBitDepth.eightBit)
                    Text("16-bit").tag(RAWPreviewBitDepth.sixteenBit)
                }
                .pickerStyle(.segmented)

                Text("8-bit uses less display memory. 16-bit preserves finer tonal gradations using floating-point color. This setting affects RAW 9 previews; original files and sidecar adjustments stay unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SonyRAW9CameraSettingsSection()
        }
        .formStyle(.grouped)
    }
}

private struct SonyRAW9CameraSettingsSection: View {
    @State private var cameraModels: [String]?

    var body: some View {
        Section("Sony cameras supporting RAW 9") {
            Text("Camera support is provided by the RAW 9 decoder installed on this Mac and updates with macOS. Support can vary by RAW file format and camera shooting mode.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let cameraModels {
                if cameraModels.isEmpty {
                    Text("The installed RAW 9 decoder reports no supported Sony cameras.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(cameraModels.count) supported cameras")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(cameraModels, id: \.self) { model in
                        Text(verbatim: model)
                            .textSelection(.enabled)
                    }
                }
            } else {
                ProgressView("Loading supported cameras…")
            }
        }
        .task {
            let models = await RAW9Support.supportedSonyCameraModels()
            guard !Task.isCancelled else { return }
            cameraModels = models
        }
    }
}
