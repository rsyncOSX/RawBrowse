import Foundation
@testable import RawBrowse
import Testing

@Suite("Opt-in performance diagnostics")
struct BrowserPerformanceTests {
    @Test
    func workspaceSettingsSerializeAsJSONScalars() throws {
        let fields = BrowserPerformance.workspaceSettingsFields(BrowserSettings())
        let data = try #require(BrowserPerformance.serializedRecord([
            "event": "workspace.configuration", "time": 1.0, "fields": fields,
        ]))
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decodedFields = try #require(decoded["fields"] as? [String: Any])
        #expect(decodedFields["selected_clip_model"] as? String == CLIPManagedModel.defaultSelection.downloadID.rawValue)
        #expect(decodedFields["grid_pixels"] as? Int == 200)
    }

    @Test
    func unsupportedValuesAreRejectedBeforeFoundationEncoding() {
        let invalid: [String: Any] = ["model": CLIPManagedModel.defaultSelection.downloadID]
        #expect(BrowserPerformance.serializedRecord(invalid) == nil)
    }
}
