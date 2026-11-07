import AppKit
import SwiftUI

struct BrowserThumbnailCell: View {
    let file: BrowserFileItem
    let isFocused: Bool
    let isSelected: Bool
    let thumbnailSize: Int
    let displayPath: String?
    var showsRAW9Badge = false

    @State private var presentation = ThumbnailPresentationModel()

    var body: some View {
        let request = ThumbnailRequest(url: file.url, targetSize: thumbnailSize)
        VStack(alignment: .leading, spacing: 6) {
            thumbnail

            Text(displayPath ?? file.name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
        .task(id: request) {
            await presentation.load(request: request) {
                if let cached = await MemoryImageCache.shared.thumbnail(for: request.url, maxPixelSize: request.targetSize) {
                    return cached
                }
                return await BrowserImageLoader.shared.thumbnail(for: request.url, targetSize: request.targetSize)
            }
        }
        .onDisappear { presentation.invalidate() }
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .controlBackgroundColor))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    thumbnailContent
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 3 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: isFocused ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if showsRAW9Badge {
                    RAW9ThumbnailBadge(url: file.url)
                        .padding(6)
                }
            }
    }

    private var borderColor: Color {
        if isFocused {
            return .accentColor
        }
        if isSelected {
            return .accentColor.opacity(0.72)
        }
        return .primary.opacity(0.08)
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let image = presentation.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipped()
        } else if presentation.isLoading {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RAW9ThumbnailBadge: View {
    let url: URL

    @State private var supportedURL: URL?

    var body: some View {
        // Keep a concrete view mounted so its task runs before support is known.
        Text("RAW 9")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.7), in: .rect(cornerRadius: 4))
            .opacity(supportedURL == url ? 1 : 0)
            .accessibilityLabel("Supports RAW 9")
            .accessibilityHidden(supportedURL != url)
            .allowsHitTesting(false)
            .task(id: url) {
                supportedURL = nil
                let isSupported = await RAW9Support.isSupported(for: url)
                guard !Task.isCancelled else { return }
                supportedURL = isSupported ? url : nil
            }
    }
}
