import RawParserKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserZoomOverlayView: View {
    @Environment(SelectionModel.self) private var selection

    @Environment(DeepReviewModel.self) private var deepReview

    @Environment(ZoomPresentationState.self) private var zoomPresentation

    @Environment(ZoomModel.self) private var zoom

    @Environment(RAW9EditingSession.self) private var raw9

    @Environment(FileBrowserViewModel.self) private var viewModel

    private var supportsRAW9: Bool {
        raw9SupportedURL != nil && raw9SupportedURL == selection.selectedFile?.url
    }

    private static let whiteBalanceCursor: NSCursor = {
        let image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "White balance picker")!
        image.size = NSSize(width: 24, height: 24)
        return NSCursor(image: image, hotSpot: NSPoint(x: 2, y: 22))
    }()

    private var copyAction: (() -> [NSItemProvider])? {
        guard let file = selection.selectedFile else { return nil }

        return {
            [NSItemProvider(object: file.url as NSURL)]
        }
    }

    private struct SubjectOutlineTaskID: Hashable {
        // Used by synthesized Hashable and Equatable to restart the subject outline task.
        // periphery:ignore
        let fileID: BrowserFileItem.ID?
        // Used by synthesized Hashable and Equatable to restart the subject outline task.
        // periphery:ignore
        let prompt: String?
        // Used by synthesized Hashable and Equatable to restart the subject outline task.
        // periphery:ignore
        let isPresented: Bool
    }

    @State private var cropSource: RAW9CropSource?
    @State private var isPreparingCrop = false
    private let exportQueue = RAW9ExportQueue.shared
    @State private var rawExportError: String?
    @State private var isPickingWhiteBalance = false
    @State private var isSamplingWhiteBalance = false
    @State private var whiteBalanceTask: Task<Void, Never>?
    @State private var cameraTemperature: Double = 6500
    @State private var cameraTint: Double = 0
    @State private var toneDefaults = RAW9ToneDefaults()
    @State private var raw9SupportedURL: URL?
    @State private var isEditingRAWAdjustment = false
    @State private var isRAWAdjustmentRefreshPending = false
    @State private var adjustmentRefreshTask: Task<Void, Never>?
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    @State private var lastMetadataOffset: CGSize = .zero
    @FocusState private var isFocused: Bool

    @State private var keyMonitor: Any?
    @State private var pendingInitialZoomMode: BrowserZoomInitialMode?
    @State private var viewportSize: CGSize = .zero
    @State private var subjectOutline: CGImage?
    @State private var showSubjectOutline = false
    @State private var isLoadingSubjectOutline = false

    private var subjectOutlineCandidate: DeepAIReviewCandidate? {
        guard let fileID = selection.selectedFile?.id else { return nil }
        return deepReview.deepAIReviewController.maskCandidate(for: fileID)
    }

    private var subjectOutlineTaskID: SubjectOutlineTaskID {
        SubjectOutlineTaskID(
            fileID: selection.selectedFile?.id,
            prompt: subjectOutlineCandidate?.maskPromptUsed?.rawValue,
            isPresented: showSubjectOutline,
        )
    }

    var body: some View {
        @Bindable var zoomPresentation = zoomPresentation

        return ZStack {
            Color.black.opacity(0.98)
                .ignoresSafeArea()

            GeometryReader { geometry in
                if let image = zoom.zoomImage {
                    ZStack {
                        Image(decorative: image, scale: 1.0, orientation: .up)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)

                        if showSubjectOutline, !zoom.useDevelopedRAW || raw9.raw9Adjustments.crop == nil, let subjectOutline {
                            Image(decorative: subjectOutline, scale: 1, orientation: .up)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .colorMultiply(.orange)
                                .blendMode(.screen)
                                .opacity(0.95)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }

                        if zoomPresentation.isZoomFocusPointVisible,
                           let focusPoint = normalizedFocusPoint {
                            FocusPointMarker(
                                normalizedFocusPoint: focusPoint,
                                imageSize: CGSize(width: image.width, height: image.height),
                                containerSize: geometry.size,
                            )
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(zoomPresentation.zoomScale)
                    .offset(zoomPresentation.zoomOffset)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            (isPickingWhiteBalance ? Self.whiteBalanceCursor : NSCursor.arrow).set()

                        case .ended:
                            NSCursor.arrow.set()
                        }
                    }
                    .gesture(zoomPanGesture)
                    .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                        guard isPickingWhiteBalance else { return }
                        pickWhiteBalance(at: tap.location, image: image, containerSize: geometry.size)
                    })
                    .onAppear {
                        viewportSize = geometry.size
                        applyPendingInitialZoomIfNeeded(
                            imageSize: CGSize(width: image.width, height: image.height),
                            viewportSize: geometry.size,
                        )
                    }
                    .onChange(of: geometry.size) { _, size in
                        viewportSize = size
                        applyPendingInitialZoomIfNeeded(
                            imageSize: CGSize(width: image.width, height: image.height),
                            viewportSize: size,
                        )
                    }
                    .onChange(of: zoom.zoomImage?.hashValue) { _, _ in
                        applyPendingInitialZoomIfNeeded(
                            imageSize: CGSize(width: image.width, height: image.height),
                            viewportSize: geometry.size,
                        )
                    }
                    .onChange(of: zoom.zoomExifInfo?.focusPoint) { _, _ in
                        applyPendingInitialZoomIfNeeded(
                            imageSize: CGSize(width: image.width, height: image.height),
                            viewportSize: geometry.size,
                        )
                    }
                    .onTapGesture(count: 2) {
                        guard !isPickingWhiteBalance else { return }
                        withAnimation(.spring()) {
                            zoomPresentation.zoomScale > 1.0 ? resetToFit() : zoomToTwoX()
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        if zoom.zoomImageError == nil {
                            ProgressView().controlSize(.large)
                        }
                        Text(zoom.zoomImageError ?? "Loading image...")
                            .font(.title3)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            VStack {
                ZStack(alignment: .top) {
                    if zoomPresentation.isZoomMetadataVisible {
                        ZoomMetadataPanel(
                            fileName: selection.selectedFile?.name,
                            exifInfo: zoom.zoomExifInfo,
                            image: zoom.zoomImage,
                            isCollapsed: $zoomPresentation.isZoomMetadataCollapsed,
                        )
                        .offset(zoomPresentation.zoomMetadataOffset)
                        .gesture(metadataDragGesture)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }

                    HStack(spacing: 12) {
                        Button {
                            viewModel.navigateSelection(by: -1)
                        } label: {
                            Image(systemName: "chevron.left.circle")
                        }
                        .help("Previous image")

                        Button {
                            viewModel.navigateSelection(by: 1)
                        } label: {
                            Image(systemName: "chevron.right.circle")
                        }
                        .help("Next image")

                        Button {
                            close()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .help("Close")
                    }
                    .font(.title2)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
                .padding()

                Spacer()

                VStack(spacing: 8) {
                    if isPickingWhiteBalance {
                        Text("Click a neutral white or gray area in the photo. Escape cancels.")
                            .font(.callout)
                            .padding(8)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if zoom.useDevelopedRAW,
                       raw9SupportedURL != nil,
                       raw9SupportedURL == selection.selectedFile?.url {
                        centeredControlRow(height: 50) {
                            rawAdjustmentControls
                        }
                    }

                    centeredControlRow(height: 66) {
                        zoomControlRow
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }

            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled(true)
        .onCopyCommand(perform: copyAction)
        .onKeyPress(.leftArrow) {
            handleKeyAction(ZoomOverlayKeyAction.resolve(
                characters: nil,
                keyCode: 123,
                navigationAxis: zoomPresentation.zoomOverlayNavigationAxis,
            ))
        }
        .onKeyPress(.rightArrow) {
            handleKeyAction(ZoomOverlayKeyAction.resolve(
                characters: nil,
                keyCode: 124,
                navigationAxis: zoomPresentation.zoomOverlayNavigationAxis,
            ))
        }
        .onKeyPress(.upArrow) {
            handleKeyAction(ZoomOverlayKeyAction.resolve(
                characters: nil,
                keyCode: 126,
                navigationAxis: zoomPresentation.zoomOverlayNavigationAxis,
            ))
        }
        .onKeyPress(.downArrow) {
            handleKeyAction(ZoomOverlayKeyAction.resolve(
                characters: nil,
                keyCode: 125,
                navigationAxis: zoomPresentation.zoomOverlayNavigationAxis,
            ))
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "+-sSaAeExX")) { press in
            handleKeyAction(ZoomOverlayKeyAction.resolve(
                characters: press.characters,
                keyCode: 0,
                navigationAxis: zoomPresentation.zoomOverlayNavigationAxis,
            ))
        }
        .onAppear {
            pendingInitialZoomMode = zoomPresentation.zoomLaunchContext.initialZoomMode
            installKeyMonitor()
        }
        .onDisappear {
            adjustmentRefreshTask?.cancel()
            isRAWAdjustmentRefreshPending = false
            isEditingRAWAdjustment = false
            whiteBalanceTask?.cancel()
            removeKeyMonitor()
            NSCursor.arrow.set()
            subjectOutline = nil
            isLoadingSubjectOutline = false
        }
        .task(id: selection.selectedFile?.url) {
            adjustmentRefreshTask?.cancel()
            isRAWAdjustmentRefreshPending = false
            isEditingRAWAdjustment = false
            whiteBalanceTask?.cancel()
            isPickingWhiteBalance = false
            isSamplingWhiteBalance = false
            raw9SupportedURL = nil
            toneDefaults = RAW9ToneDefaults()
            guard let url = selection.selectedFile?.url else { return }
            let supported = await RAW9Support.isSupported(for: url)
            guard !Task.isCancelled else { return }
            if supported, let balance = try? await raw9.raw9WhiteBalance() {
                guard !Task.isCancelled, selection.selectedFile?.url == url else { return }
                cameraTemperature = balance.temperature
                cameraTint = balance.tint
            }
            if supported, let defaults = try? await raw9.raw9ToneSettings() {
                guard !Task.isCancelled, selection.selectedFile?.url == url else { return }
                toneDefaults = defaults
            }
            raw9SupportedURL = supported ? url : nil
        }
        .onChange(of: isPickingWhiteBalance) {
            if !isPickingWhiteBalance {
                NSCursor.arrow.set()
            }
        }
        .onChange(of: raw9.raw9Adjustments) {
            guard !isEditingRAWAdjustment else { return }
            scheduleRAWAdjustmentRefresh()
        }
        .task(id: subjectOutlineTaskID) {
            await loadSubjectOutline()
        }
    }

    private func scheduleRAWAdjustmentRefresh() {
        adjustmentRefreshTask?.cancel()
        guard zoom.useDevelopedRAW,
              raw9SupportedURL == selection.selectedFile?.url, raw9SupportedURL != nil else { return }
        isRAWAdjustmentRefreshPending = true
        adjustmentRefreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            zoom.refreshRAW9Preview()
            isRAWAdjustmentRefreshPending = false
        }
    }

    private func centeredControlRow(height: CGFloat, @ViewBuilder content: @escaping () -> some View) -> some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                content()
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: height)
    }

    private var rawAdjustmentControls: some View {
        @Bindable var raw9 = raw9

        return HStack(spacing: 8) {
            rawControlGroup {
                adjustmentSlider("Temp K", value: Binding(
                    get: { raw9.raw9Adjustments.temperature ?? cameraTemperature },
                    set: { raw9.raw9Adjustments.temperature = $0 },
                ), range: 2000 ... 50000, fractionDigits: 0)
                adjustmentSlider("Tint", value: Binding(
                    get: { raw9.raw9Adjustments.tint ?? cameraTint },
                    set: { raw9.raw9Adjustments.tint = $0 },
                ), range: -150 ... 150)
                Button {
                    isPickingWhiteBalance.toggle()
                } label: {
                    Label(isPickingWhiteBalance ? "Cancel picker" : "White balance", systemImage: "eyedropper")
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 24, minHeight: 24)
                .foregroundStyle(isPickingWhiteBalance ? .yellow : .secondary)
                .disabled(isSamplingWhiteBalance || zoom.zoomImage == nil)
                .help("Click a neutral white or gray area to set white balance")
            }
            rawControlGroup {
                adjustmentSlider("Exposure", value: $raw9.raw9Adjustments.exposure, range: -3 ... 3)
                    .help("Exposure compensation in stops. Zero preserves the default; move left to darken or right to brighten.")
            }
            rawControlGroup {
                adjustmentSlider("Noise", value: $raw9.raw9Adjustments.noiseReduction, range: -1 ... 1)
                adjustmentSlider("Sharpness", value: $raw9.raw9Adjustments.sharpness, range: -1 ... 1)
            }
            rawControlGroup {
                adjustmentSlider("Contrast", value: $raw9.raw9Adjustments.contrast, range: -1 ... 1)
                adjustmentSlider("Shadows", value: Binding(
                    get: { raw9.raw9Adjustments.shadowBoost ?? toneDefaults.shadowBoost },
                    set: { raw9.raw9Adjustments.shadowBoost = $0 },
                ), range: 0 ... 2)
                    .disabled((raw9.raw9Adjustments.globalToneMap ?? toneDefaults.globalToneMap) == 0)
                    .help("Shadow amount starts at the photo’s decoder default. Lower values darken shadows; higher values lighten them. Requires a nonzero tone curve.")
                adjustmentSlider("Tone curve", value: Binding(
                    get: { raw9.raw9Adjustments.globalToneMap ?? toneDefaults.globalToneMap },
                    set: { raw9.raw9Adjustments.globalToneMap = $0 },
                ), range: 0 ... 1)
                    .help("RAW tone curve: 0 is linear; 1 is the full default curve. This is an amount, not a centered adjustment.")
            }
            rawControlGroup {
                Button { prepareCrop() } label: {
                    Label("Crop", systemImage: "crop")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .disabled(isPreparingCrop)
                .sheet(item: $cropSource) { source in
                    RAW9CropEditor(source: source)
                }
                Menu {
                    ForEach(RAW9PreviewRenderer.exportTypes, id: \.self) { identifier in
                        if let type = UTType(identifier) {
                            Button(type.localizedDescription ?? identifier) { exportRAW(type: type) }
                        }
                    }
                    Button("HEIF (10-bit)") { exportRAW(type: .heic, heif10: true) }
                    if !RAW9PreviewRenderer.exportTypes.contains("com.ilm.openexr-image") {
                        Button("OpenEXR") {
                            exportRAW(type: UTType(filenameExtension: "exr") ?? UTType(exportedAs: "com.ilm.openexr-image"))
                        }
                    }
                } label: {
                    Label(exportQueue.outstandingCount > 0 ? "Export (\(exportQueue.outstandingCount))" : "Export", systemImage: "square.and.arrow.up")
                }
                .disabled(isPreparingCrop)
                .help("Exports run in the background in request order, even after Zoom View closes.")
                .alert("RAW 9", isPresented: Binding(get: { rawExportError != nil || exportQueue.lastError != nil }, set: {
                    if !$0 {
                        rawExportError = nil
                        exportQueue.lastError = nil
                    }
                })) {
                    Button("OK") { rawExportError = nil; exportQueue.lastError = nil }
                } message: { Text(rawExportError ?? exportQueue.lastError ?? "") }
                if let error = raw9.raw9SidecarError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help(error)
                        .accessibilityLabel(error)
                }
                Button("Reset") {
                    whiteBalanceTask?.cancel()
                    isSamplingWhiteBalance = false
                    isPickingWhiteBalance = false
                    raw9.raw9Adjustments = RAW9Adjustments()
                }
                .disabled(raw9.raw9Adjustments == RAW9Adjustments())
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16, height: 16)
                    .opacity(isRAW9ControlBusy ? 1 : 0)
                    .accessibilityLabel("Applying RAW 9 changes")
                    .accessibilityHidden(!isRAW9ControlBusy)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .controlSize(.mini)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .tint(.white.opacity(0.65))
        .help("RAW 9 adjustments are saved automatically to a sidecar beside the original. Noise, sharpness and contrast are offsets from camera defaults.")
    }

    private var isRAW9ControlBusy: Bool {
        isEditingRAWAdjustment || isRAWAdjustmentRefreshPending || zoom.isApplyingRAW9
            || isPreparingCrop || isSamplingWhiteBalance || exportQueue.outstandingCount > 0
    }

    private func rawControlGroup(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8, content: content)
            .frame(minHeight: 32)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(ZoomBadgeStyle.fill, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
    }

    private func prepareCrop() {
        guard let url = selection.selectedFile?.url else { return }
        isPickingWhiteBalance = false
        var adjustments = raw9.raw9Adjustments
        adjustments.crop = nil
        isPreparingCrop = true
        Task {
            defer { isPreparingCrop = false }
            do {
                let image = try await RAW9PreviewRenderer().render(url: url, adjustments: adjustments, maximumDimension: 1280)
                guard selection.selectedFile?.url == url else { return }
                cropSource = RAW9CropSource(url: url, image: image, crop: raw9.raw9Adjustments.crop)
            } catch { rawExportError = error.localizedDescription }
        }
    }

    private func exportRAW(type: UTType, heif10: Bool = false) {
        guard let url = selection.selectedFile?.url else { return }
        let adjustments = raw9.raw9Adjustments
        let sourceAccessURL = viewModel.catalogAccessURL
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-edited." + (type.preferredFilenameExtension ?? "img")
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            guard destination.resolvingSymlinksInPath() != url.resolvingSymlinksInPath(),
                  destination.resolvingSymlinksInPath() != RAW9SidecarStore.sidecarURL(for: url).resolvingSymlinksInPath()
            else {
                rawExportError = "Choose a destination other than the original RAW or its sidecar."
                return
            }
            exportQueue.enqueue(RAW9ExportJob(
                source: url, adjustments: adjustments, destination: destination,
                type: type.identifier, heif10: heif10, sourceAccessURL: sourceAccessURL,
            ))
        }
    }

    private func adjustmentSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, fractionDigits: Int = 1) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Text(title)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(fractionDigits)))
                    .monospacedDigit()
            }
            .font(.caption2)
            Slider(value: value, in: range) { editing in
                isEditingRAWAdjustment = editing
                adjustmentRefreshTask?.cancel()
                isRAWAdjustmentRefreshPending = false
                if !editing {
                    scheduleRAWAdjustmentRefresh()
                }
            }
            .accessibilityLabel(title)
        }
        .frame(width: 74)
    }

    private var zoomControlRow: some View {
        @Bindable var zoom = zoom
        @Bindable var zoomPresentation = zoomPresentation

        return HStack(spacing: 12) {
            Picker("", selection: $zoom.useDevelopedRAW) {
                Text("JPG").tag(false)
                Text(raw9SupportedURL != nil && raw9SupportedURL == selection.selectedFile?.url ? "RAW 9" : "RAW").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .disabled(selection.selectedFile.map { SupportedFileType.isRenderedImage($0.url) } ?? true)
            .help("Show the embedded JPEG or develop the full-size RAW image. RAW 9 is preferred when supported.")
            .onChange(of: zoom.useDevelopedRAW) {
                whiteBalanceTask?.cancel()
                isPickingWhiteBalance = false
                isSamplingWhiteBalance = false
                viewModel.openZoom()
            }
            Button { decreaseZoom() } label: {
                ZoomControlBadge {
                    Image(systemName: "minus.magnifyingglass")
                }
            }
            Button { withAnimation(.spring()) { resetToFit() } } label: {
                ZoomControlBadge {
                    Image(systemName: "1.magnifyingglass")
                }
            }
            Button { increaseZoom() } label: {
                ZoomControlBadge {
                    Image(systemName: "plus.magnifyingglass")
                }
            }
            Toggle(isOn: $zoomPresentation.isZoomFocusPointVisible) {
                ZoomControlBadge(width: 62) {
                    HStack(spacing: 6) {
                        Image(systemName: zoomPresentation.isZoomFocusPointVisible ? "dot.circle.viewfinder" : "dot.viewfinder")
                            .foregroundStyle(zoomPresentation.isZoomFocusPointVisible ? .yellow : .primary)
                            .symbolEffect(.bounce, value: zoomPresentation.isZoomFocusPointVisible)

                        Text("A")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .toggleStyle(.button)
            .disabled(zoom.zoomExifInfo?.focusPoint == nil)
            .accessibilityLabel("Focus Point")
            .help(zoom.zoomExifInfo?.focusPoint == nil ? "No focus point found in EXIF data" : "Show focus point")

            Toggle(isOn: $showSubjectOutline) {
                ZoomControlBadge(width: 62) {
                    HStack(spacing: 6) {
                        if isLoadingSubjectOutline {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: showSubjectOutline ? "person.crop.circle.fill" : "person.crop.circle")
                                .foregroundStyle(showSubjectOutline ? .orange : .primary)
                        }

                        Text("S")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .toggleStyle(.button)
            .disabled(subjectOutlineCandidate == nil)
            .accessibilityLabel("Subject Outline")
            .help(subjectOutlineCandidate == nil ? "Run Deep Review for this image first" : "Show Deep Review subject outline (S)")
        }
    }

    private func pickWhiteBalance(at location: CGPoint, image: CGImage, containerSize: CGSize) {
        guard !isSamplingWhiteBalance, let url = selection.selectedFile?.url,
              zoom.useDevelopedRAW, raw9SupportedURL == url else { return }
        // The tap is in the image container's local coordinates, before zoom and pan.
        let scale = min(containerSize.width / CGFloat(image.width), containerSize.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let origin = CGPoint(x: (containerSize.width - size.width) / 2, y: (containerSize.height - size.height) / 2)
        var point = CGPoint(x: (location.x - origin.x) / size.width, y: (location.y - origin.y) / size.height)
        guard (0 ... 1).contains(point.x), (0 ... 1).contains(point.y) else { return }
        if let crop = raw9.raw9Adjustments.crop {
            point = CGPoint(x: crop.x + point.x * crop.width, y: crop.y + point.y * crop.height)
        }
        isPickingWhiteBalance = false
        isSamplingWhiteBalance = true
        let originalAdjustments = raw9.raw9Adjustments
        whiteBalanceTask = Task {
            defer { isSamplingWhiteBalance = false }
            do {
                let balance = try await raw9.raw9WhiteBalance(normalizedPoint: point)
                guard !Task.isCancelled, selection.selectedFile?.url == url,
                      zoom.useDevelopedRAW, raw9.raw9Adjustments == originalAdjustments else { return }
                var adjustments = originalAdjustments
                adjustments.temperature = balance.temperature
                adjustments.tint = balance.tint
                raw9.raw9Adjustments = adjustments
            } catch {
                guard !Task.isCancelled, selection.selectedFile?.url == url else { return }
                raw9.raw9SidecarError = "Could not sample white balance: \(error.localizedDescription)"
            }
        }
    }

    private var zoomPanGesture: some Gesture {
        SimultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    zoomPresentation.zoomScale = min(max(lastScale * value.magnification, 0.5), 5.0)
                }
                .onEnded { _ in
                    lastScale = zoomPresentation.zoomScale
                    if zoomPresentation.zoomScale < 1.0 {
                        withAnimation(.spring()) { resetToFit() }
                    }
                },
            DragGesture()
                .onChanged { value in
                    guard zoomPresentation.zoomScale > 1.0 else { return }
                    zoomPresentation.zoomOffset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height,
                    )
                }
                .onEnded { _ in
                    lastOffset = zoomPresentation.zoomOffset
                },
        )
    }

    private var metadataDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                zoomPresentation.zoomMetadataOffset = CGSize(
                    width: lastMetadataOffset.width + value.translation.width,
                    height: lastMetadataOffset.height + value.translation.height,
                )
            }
            .onEnded { _ in
                lastMetadataOffset = zoomPresentation.zoomMetadataOffset
            }
    }

    private func increaseZoom() {
        withAnimation(.spring()) {
            zoomPresentation.zoomScale = min(zoomPresentation.zoomScale + 0.25, 5.0)
            lastScale = zoomPresentation.zoomScale
        }
    }

    private func toggleFocusPoint() {
        guard zoom.zoomExifInfo?.focusPoint != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomPresentation.isZoomFocusPointVisible.toggle()
        }
    }

    private func decreaseZoom() {
        withAnimation(.spring()) {
            zoomPresentation.zoomScale = max(zoomPresentation.zoomScale - 0.25, 0.5)
            lastScale = zoomPresentation.zoomScale
            if zoomPresentation.zoomScale <= 1.0 {
                zoomPresentation.zoomOffset = .zero
                lastOffset = .zero
            }
        }
    }

    private func zoomToTwoX() {
        zoomPresentation.zoomScale = 2.0
        lastScale = 2.0
    }

    private func resetToFit() {
        zoomPresentation.zoomScale = 1.0
        lastScale = 1.0
        zoomPresentation.zoomOffset = .zero
        lastOffset = .zero
    }

    private func applyPendingInitialZoomIfNeeded(imageSize: CGSize, viewportSize: CGSize) {
        guard pendingInitialZoomMode == .actualPixels,
              viewportSize.width > 0,
              viewportSize.height > 0
        else { return }
        if zoomPresentation.zoomLaunchContext.showFocusPointOnOpen,
           !zoom.isZoomExifInfoLoaded {
            return
        }
        applyActualPixelsZoom(imageSize: imageSize, viewportSize: viewportSize)
        pendingInitialZoomMode = nil
    }

    private func applyActualPixelsZoom(imageSize: CGSize, viewportSize: CGSize) {
        let transform = BrowserZoomViewportMath.actualPixelsTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
            normalizedFocusPoint: normalizedFocusPoint,
        )
        zoomPresentation.zoomScale = transform.scale
        lastScale = transform.scale
        zoomPresentation.zoomOffset = transform.offset
        lastOffset = transform.offset
        zoomPresentation.isZoomFocusPointVisible = zoom.zoomExifInfo?.focusPoint != nil
    }

    private var normalizedFocusPoint: CGPoint? {
        guard let focusPoint = zoom.zoomExifInfo?.focusPoint else { return nil }
        return BrowserZoomViewportMath.displayedFocusPoint(
            CGPoint(x: CGFloat(focusPoint.normalizedX), y: CGFloat(focusPoint.normalizedY)),
            crop: zoom.useDevelopedRAW ? raw9.raw9Adjustments.crop : nil,
        )
    }

    private func close() {
        zoom.closeZoom()
    }

    private func handleKeyAction(_ action: ZoomOverlayKeyAction?) -> KeyPress.Result {
        guard cropSource == nil, !isPreparingCrop, NSApp.keyWindow?.attachedSheet == nil,
              let action else { return .ignored }

        switch action {
        case .navigatePrevious:
            viewModel.navigateSelection(by: -1)
            return .handled

        case .navigateNext:
            viewModel.navigateSelection(by: 1)
            return .handled

        case .escape:
            dismiss()
            return .handled

        case .zoomIn:
            increaseZoom()
            return .handled

        case .zoomOut:
            decreaseZoom()
            return .handled

        case .toggleSubjectOutline:
            guard subjectOutlineCandidate != nil else { return .ignored }
            showSubjectOutline.toggle()
            return .handled

        case .toggleMetadata:
            zoomPresentation.isZoomMetadataVisible.toggle()
            return .handled

        case .toggleFocusPoints:
            toggleFocusPoint()
            return .handled
        }
    }

    private func dismiss() {
        if isPickingWhiteBalance {
            isPickingWhiteBalance = false
            return
        }
        zoom.closeZoom()
        resetToFit()
        subjectOutline = nil
    }

    private func loadSubjectOutline() async {
        subjectOutline = nil
        isLoadingSubjectOutline = false
        guard showSubjectOutline,
              let file = selection.selectedFile,
              let candidate = subjectOutlineCandidate
        else { return }

        isLoadingSubjectOutline = true
        let mask = await deepReview.deepAIReviewController.mask(
            for: candidate,
            in: [file],
        )
        guard !Task.isCancelled,
              selection.selectedFile?.id == file.id
        else {
            isLoadingSubjectOutline = false
            return
        }

        if let mask {
            subjectOutline = await DeepAIReviewMaskOutlineRenderer.outline(from: mask) ?? mask
        }
        guard !Task.isCancelled,
              selection.selectedFile?.id == file.id
        else {
            subjectOutline = nil
            isLoadingSubjectOutline = false
            return
        }
        isLoadingSubjectOutline = false
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard zoomPresentation.zoomOverlayVisible,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .command, supportsRAW9 {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c":
                    raw9.copyRAW9Adjustments()
                    return nil

                case "v" where raw9.copiedRAW9Adjustments != nil:
                    zoom.pasteRAW9Adjustments()
                    return nil

                default:
                    return event
                }
            }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }

            return handleKeyEvent(event) == .handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> KeyPress.Result {
        handleKeyAction(ZoomOverlayKeyAction.resolve(
            characters: event.characters,
            keyCode: event.keyCode,
            navigationAxis: zoomPresentation.zoomOverlayNavigationAxis,
        ))
    }
}
