//
//  extension+Thread+Logger.swift
//  RawBrowse
//
//  Created by Thomas Evensen on 20/01/2026.
//

import Foundation
import OSLog

extension Logger {
    private nonisolated static let subsystem = Bundle.main.bundleIdentifier
    nonisolated static let process = Logger(subsystem: subsystem ?? "process", category: "process")

    nonisolated func debugMessageOnly(_ message: String) {
        #if DEBUG
            debug("\(message)")
        #endif
    }
}
