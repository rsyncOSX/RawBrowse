//
//  SettingsView.swift
//  RawBrowse
//
//  Created by Thomas Evensen on 05/02/2026.
//

import SwiftUI

struct SettingsView: View {
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
        .padding(20)
        .frame(width: 520, height: 600)
    }
}
