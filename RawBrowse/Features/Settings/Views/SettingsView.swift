//
//  SettingsView.swift
//  RawBrowse
//
//  Created by Thomas Evensen on 05/02/2026.
//

import SwiftUI

struct SettingsView: View {
    @Environment(SettingsModel.self) private var settings
    var body: some View {
        TabView {
            Tab("Memory", systemImage: "rectangle.compress.vertical") {
                MemoryTab()
            }

            Tab("Cache", systemImage: "internaldrive") {
                ImageCacheSettingsTab()
            }

            Tab("AI Models", systemImage: "sparkle.magnifyingglass") {
                AISettingsTab()
            }

            Tab("Images", systemImage: "photo") {
                ImagePreviewSettingsTab()
            }

            Tab("CLIP Indexes", systemImage: "square.stack.3d.up") {
                CLIPIndexesSettingsTab()
            }
        }
        .disabled(!settings.isReady)
        .safeAreaInset(edge: .top) {
            if settings.loadState == .unread || settings.loadState == .loading {
                ProgressView("Loading settings…").padding()
            }
            if let error = settings.settingsError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).foregroundStyle(.red)
                    Button("Retry Settings") { Task { await settings.retryPersistence() } }
                }
                .padding()
            }
        }
        .padding(20)
        .frame(width: 520, height: 600)
    }
}
