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
        }
        .formStyle(.grouped)
    }
}
