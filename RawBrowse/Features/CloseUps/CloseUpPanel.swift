import SwiftUI

/// Reusable host API: selected frame values, session model and a rendering service.
/// No browser environment, catalog, selection mutations or model runtime dependencies.
struct CloseUpPanel: View {
    let frames: [CloseUpFrame]
    @Bindable var model: CloseUpModel
    let renderer: any CloseUpRendering
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Close-ups (\(frames.count))").font(.headline)
                Spacer()
                Button("Close Close-ups", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
            }.padding(12)
            Picker("Inspection scale", selection: $model.mode) {
                Text("Fit region").tag(CloseUpScaleMode.fitRegion)
                Text("Source pixels").tag(CloseUpScaleMode.sourcePixels)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            Text(model.mode == .fitRegion
                 ? "Manual regions · magnification varies"
                 : "1 source pixel per point · embedded preview for RAW")
                .font(.caption).foregroundStyle(.secondary).padding(8)
            Divider()
            if frames.isEmpty {
                ContentUnavailableView("Select images", systemImage: "rectangle.stack",
                    description: Text("Select one or more images in the browser to inspect them here."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(frames) { frame in
                            CloseUpCard(frame: frame, region: Binding(
                                get: { model.region(for: frame.id) },
                                set: { model.setRegion($0, for: frame.id) }),
                                mode: model.mode, renderer: renderer,
                                onReset: { model.reset(frame.id) })
                        }
                    }.padding(12)
                }
            }
        }
        .frame(width: 304)
        .background(.background)
        .onChange(of: frames, initial: true) { _, updated in model.retainFrames(updated) }
    }
}

private struct CloseUpLoadKey: Equatable {
    let request: CloseUpRequest
    let retry: Int
}

private struct CloseUpCard: View {
    let frame: CloseUpFrame
    @Binding var region: CloseUpRegion
    let mode: CloseUpScaleMode
    let renderer: any CloseUpRendering
    let onReset: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var model = CloseUpCardModel()
    @State private var retry = 0

    private var request: CloseUpRequest {
        CloseUpRequest(frame: frame, region: region, mode: mode, displayScale: displayScale)
    }

    private func overviewBounds(for render: CloseUpRender) -> CGRect {
        // Update the selection rectangle immediately; crop rendering may finish
        // later, especially while the mouse is generating continuous edits.
        let requested = region.pixelBounds(width: render.sourceWidth, height: render.sourceHeight)
        let pixels: CGRect
        if mode == .sourcePixels {
            let width = min(requested.width, 280)
            let height = min(requested.height, 210)
            pixels = CGRect(x: floor(requested.midX - width / 2), y: floor(requested.midY - height / 2),
                            width: width, height: height)
        } else {
            pixels = requested
        }
        return CGRect(x: pixels.minX / Double(render.sourceWidth),
                      y: pixels.minY / Double(render.sourceHeight),
                      width: pixels.width / Double(render.sourceWidth),
                      height: pixels.height / Double(render.sourceHeight))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(frame.name).font(.caption.weight(.semibold)).lineLimit(1).help(frame.name)
            ZStack {
                Rectangle().fill(.black)
                if let render = model.render {
                    if mode == .sourcePixels {
                        Image(decorative: render.crop, scale: 1)
                            .frame(width: 280, height: 210).clipped()
                    } else {
                        Image(decorative: render.crop, scale: displayScale)
                            .resizable().scaledToFit()
                    }
                } else if model.isLoading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(height: 210).clipped()
            .overlay(alignment: .topTrailing) {
                if model.isLoading, model.render != nil {
                    ProgressView().controlSize(.small).padding(8)
                }
            }
            .accessibilityLabel("Inspection crop for \(frame.name)")
            if let render = model.render {
                CloseUpOverview(image: render.overview, bounds: overviewBounds(for: render)) { center in
                    region.center = center
                }
                Text("\(render.sourceLabel) · \(render.sourceWidth) × \(render.sourceHeight)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Text("Region size").font(.caption)
                Slider(value: $region.fraction, in: 0.05 ... 1)
                    .accessibilityLabel("Manual region size for \(frame.name)")
                Button("Reset", action: onReset).controlSize(.small)
            }
            HStack {
                Text("Center X").font(.caption)
                Slider(value: $region.center.x, in: 0 ... 1)
                    .accessibilityLabel("Horizontal region center for \(frame.name)")
            }
            HStack {
                Text("Center Y").font(.caption)
                Slider(value: $region.center.y, in: 0 ... 1)
                    .accessibilityLabel("Vertical region center for \(frame.name)")
            }
            Text("Click to center, or drag the blue region in the overview.")
                .font(.caption2).foregroundStyle(.secondary)
            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { retry += 1 }
            }
        }
        .padding(0)
        .task(id: CloseUpLoadKey(request: request, retry: retry)) {
            await model.load(request, using: renderer)
        }
        .onDisappear { model.release() }
    }
}

private struct CloseUpOverview: View {
    let image: CGImage
    let bounds: CGRect
    let onCenter: (CGPoint) -> Void
    @State private var dragAnchor: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / Double(image.width),
                            geometry.size.height / Double(image.height))
            let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
            let origin = CGPoint(x: (geometry.size.width - size.width) / 2,
                                 y: (geometry.size.height - size.height) / 2)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                Rectangle().stroke(.blue, lineWidth: 2)
                    .frame(width: bounds.width * size.width, height: bounds.height * size.height)
                    .offset(x: bounds.minX * size.width, y: bounds.minY * size.height)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard size.width > 0, size.height > 0 else { return }
                    if dragAnchor == nil {
                        let start = CGPoint(x: value.startLocation.x / size.width,
                                            y: value.startLocation.y / size.height)
                        // Preserve the grab offset when dragging inside the region.
                        // Clicking elsewhere centers the region under the pointer.
                        dragAnchor = bounds.contains(start)
                            ? CGPoint(x: bounds.midX, y: bounds.midY) : start
                    }
                    guard let anchor = dragAnchor else { return }
                    onCenter(CGPoint(
                        x: min(1, max(0, anchor.x + value.translation.width / size.width)),
                        y: min(1, max(0, anchor.y + value.translation.height / size.height))))
                }
                .onEnded { _ in dragAnchor = nil })
            .offset(x: origin.x, y: origin.y)
            .accessibilityLabel("Manual region overview")
            .accessibilityHint("Click or drag to move the region. Center sliders also support keyboard adjustment.")
        }
        .frame(height: 110)
    }
}
