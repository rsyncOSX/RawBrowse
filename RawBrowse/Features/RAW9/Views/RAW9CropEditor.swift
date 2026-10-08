import SwiftUI

struct RAW9CropSource: Identifiable {
    let url: URL
    let image: CGImage
    let crop: RAW9Crop?
    var id: URL {
        url
    }
}

struct RAW9CropEditor: View {
    @Environment(SelectionModel.self) private var selection

    @Environment(RAW9EditingSession.self) private var raw9

    let source: RAW9CropSource
    @Environment(\.dismiss) private var dismiss
    @State private var crop: RAW9Crop
    @State private var dragStart: RAW9Crop?

    /// Seed an independent draft so Cancel leaves the saved adjustments untouched.
    init(source: RAW9CropSource) {
        self.source = source
        _crop = State(initialValue: source.crop ?? RAW9Crop())
    }

    private let ratios: [Double] = [0, 1, 4.0 / 3, 3.0 / 2, 16.0 / 9, 3.0 / 4, 2.0 / 3, 9.0 / 16]
    private let labels = ["Free", "1:1", "4:3", "3:2", "16:9", "3:4", "2:3", "9:16"]

    var body: some View {
        VStack(spacing: 16) {
            Text("Crop RAW 9").font(.headline)
            GeometryReader { geometry in
                let scale = min(geometry.size.width / CGFloat(source.image.width), geometry.size.height / CGFloat(source.image.height))
                let size = CGSize(width: CGFloat(source.image.width) * scale, height: CGFloat(source.image.height) * scale)
                ZStack(alignment: .topLeading) {
                    Image(decorative: source.image, scale: 1)
                        .resizable().frame(width: size.width, height: size.height)
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size))
                        path.addRect(CGRect(x: crop.x * size.width, y: crop.y * size.height,
                                            width: crop.width * size.width, height: crop.height * size.height))
                    }
                    .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                    Rectangle().stroke(.white, lineWidth: 2)
                        .frame(width: crop.width * size.width, height: crop.height * size.height)
                        .offset(x: crop.x * size.width, y: crop.y * size.height)
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if dragStart == nil {
                                dragStart = crop
                            }
                            guard let start = dragStart else { return }
                            crop.x = min(1 - crop.width, max(0, start.x + value.translation.width / size.width))
                            crop.y = min(1 - crop.height, max(0, start.y + value.translation.height / size.height))
                        }.onEnded { _ in dragStart = nil })
                }
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 380)
            Picker("Constraint", selection: Binding(get: { crop.aspectRatio ?? 0 }, set: { ratio in
                crop.aspectRatio = ratio == 0 ? nil : ratio
                resize(width: crop.width)
            })) {
                ForEach(ratios, id: \.self) { ratio in
                    Text(labels[ratios.firstIndex(of: ratio)!]).tag(ratio)
                }
            }
            HStack {
                Text("Width")
                Slider(value: Binding(get: { crop.width }, set: { resize(width: $0) }), in: 0.01 ... 1)
                Text(crop.width, format: .percent.precision(.fractionLength(0))).frame(width: 45)
            }
            if crop.aspectRatio == nil {
                HStack {
                    Text("Height")
                    Slider(value: Binding(get: { crop.height }, set: {
                        crop.height = $0
                        crop.y = min(crop.y, 1 - crop.height)
                    }), in: 0.01 ... 1)
                    Text(crop.height, format: .percent.precision(.fractionLength(0))).frame(width: 45)
                }
            }
            Text("Drag the crop to position it. Use the sliders to resize.").font(.caption)
            HStack {
                Button("Remove Crop") {
                    guard selection.selectedFile?.url == source.url else { dismiss(); return }
                    raw9.raw9Adjustments.crop = nil
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply Crop") {
                    guard selection.selectedFile?.url == source.url else { dismiss(); return }
                    raw9.raw9Adjustments.crop = crop
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!crop.isValid || selection.selectedFile?.url != source.url)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func resize(width: Double) {
        var width = width
        if let ratio = crop.aspectRatio {
            let imageRatio = Double(source.image.width) / Double(source.image.height)
            width = min(width, ratio / imageRatio)
            crop.height = width * imageRatio / ratio
        }
        crop.width = width
        crop.x = min(crop.x, max(0, 1 - crop.width))
        crop.y = min(crop.y, max(0, 1 - crop.height))
    }
}
