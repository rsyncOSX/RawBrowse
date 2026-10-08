import CoreGraphics
import Foundation
import Observation

@Observable @MainActor
final class RAW9EditingSession {
    private var currentRAW9Adjustments = RAW9Adjustments()
    var raw9Adjustments: RAW9Adjustments {
        get { currentRAW9Adjustments }
        set { setAdjustments(newValue, persist: true) }
    }

    var copiedRAW9Adjustments: RAW9Adjustments?
    var raw9SidecarError: String?
    @ObservationIgnored private var raw9SidecarSaveTask: Task<Void, Never>?
    @ObservationIgnored private var raw9SidecarSaveURL: URL?
    private var raw9AdjustmentURL: URL?
    private var raw9LoadedSidecarURL: URL?
    @ObservationIgnored private let raw9Renderer = RAW9PreviewRenderer.zoom

    @ObservationIgnored private let load: @MainActor (URL) async throws -> RAW9Adjustments?
    @ObservationIgnored private let save: @MainActor (RAW9Adjustments, URL) async throws -> Void

    init(
        sidecarStore: RAW9SidecarStore = RAW9SidecarStore(),
        load: (@MainActor (URL) async throws -> RAW9Adjustments?)? = nil,
        save: (@MainActor (RAW9Adjustments, URL) async throws -> Void)? = nil,
    ) {
        self.load = load ?? { try await sidecarStore.load(for: $0) }
        self.save = save ?? { try await sidecarStore.save($0, for: $1) }
    }

    func prepare(for url: URL) -> Bool {
        let shouldLoad = raw9LoadedSidecarURL != url
        if raw9AdjustmentURL != url {
            setAdjustments(RAW9Adjustments(), persist: false)
            raw9AdjustmentURL = url
            raw9SidecarError = nil
        }
        return shouldLoad
    }

    func restore(for url: URL, initialAdjustments: RAW9Adjustments) async throws {
        let pendingSave = raw9SidecarSaveTask
        await pendingSave?.value
        try Task.checkCancellation()
        do {
            let saved = try await load(url)
            try Task.checkCancellation()
            guard raw9AdjustmentURL == url else { return }
            if raw9LoadedSidecarURL != url, raw9Adjustments == initialAdjustments, let saved {
                setAdjustments(saved, persist: false)
            }
            raw9LoadedSidecarURL = url
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard raw9AdjustmentURL == url else { return }
            raw9LoadedSidecarURL = url
            raw9SidecarError = "Could not read RAW 9 sidecar: \(error.localizedDescription)"
        }
    }

    func isEditing(_ url: URL?) -> Bool {
        raw9AdjustmentURL == url && url != nil
    }

    func hasRestored(_ url: URL?) -> Bool {
        raw9LoadedSidecarURL == url && url != nil
    }

    func close() {
        raw9AdjustmentURL = nil
        raw9LoadedSidecarURL = nil
        // Pending writes intentionally retain the session and access after navigation.
    }

    func finishSaving() async {
        await raw9SidecarSaveTask?.value
    }

    func render(url: URL, adjustments: RAW9Adjustments, bitDepth: RAWPreviewBitDepth) async throws -> CGImage {
        try await raw9Renderer.render(url: url, adjustments: adjustments, bitDepth: bitDepth)
    }

    private func setAdjustments(_ adjustments: RAW9Adjustments, persist: Bool) {
        guard currentRAW9Adjustments != adjustments else { return }
        currentRAW9Adjustments = adjustments
        if persist, let url = raw9AdjustmentURL {
            // User edits, including edits back to defaults, supersede a pending read.
            raw9LoadedSidecarURL = url
            scheduleRAW9SidecarSave(for: url)
        }
    }

    func copyRAW9Adjustments() {
        copiedRAW9Adjustments = raw9Adjustments
    }

    @discardableResult
    func pasteRAW9Adjustments() -> Bool {
        guard let adjustments = copiedRAW9Adjustments,
              let url = raw9AdjustmentURL else { return false }
        // A pending sidecar read must not replace pasted values, including defaults.
        raw9LoadedSidecarURL = url
        setAdjustments(adjustments, persist: false)
        scheduleRAW9SidecarSave(for: url)
        return true
    }

    private func scheduleRAW9SidecarSave(for url: URL) {
        let adjustments = raw9Adjustments
        let access = CatalogAccess.shared.lease(for: url)
        let previousSave = raw9SidecarSaveTask
        if raw9SidecarSaveURL == url {
            previousSave?.cancel()
        }
        raw9SidecarSaveURL = url
        // Coalesce drag events, preserve write order across files, and finish
        // the final save even after navigating away or closing zoom.
        raw9SidecarSaveTask = Task {
            defer { withExtendedLifetime(access) {} }
            do {
                // Debounce from the edit time, independently of earlier files.
                // Only the disk write waits for the previous save to finish.
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                await previousSave?.value
                try Task.checkCancellation()
                try await save(adjustments, url)
                if raw9AdjustmentURL == url {
                    raw9SidecarError = nil
                }
            } catch is CancellationError {
                return
            } catch {
                if raw9AdjustmentURL == url {
                    raw9SidecarError = "Could not save RAW 9 sidecar: \(error.localizedDescription)"
                }
            }
        }
    }

    func raw9ToneSettings() async throws -> RAW9ToneDefaults {
        guard let url = raw9AdjustmentURL else { throw CocoaError(.fileReadUnknown) }
        let access = CatalogAccess.shared.lease(for: url)
        defer { withExtendedLifetime(access) {} }
        return try await raw9Renderer.toneSettings(url: url)
    }

    func raw9WhiteBalance(normalizedPoint: CGPoint? = nil) async throws -> (temperature: Double, tint: Double) {
        guard let url = raw9AdjustmentURL else { throw CocoaError(.fileReadUnknown) }
        let access = CatalogAccess.shared.lease(for: url)
        defer { withExtendedLifetime(access) {} }
        return try await raw9Renderer.whiteBalance(url: url, normalizedPoint: normalizedPoint)
    }
}
