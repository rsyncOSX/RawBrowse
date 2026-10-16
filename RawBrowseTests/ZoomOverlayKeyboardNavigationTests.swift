@testable import RawBrowse
import Testing

@Suite("Zoom overlay keyboard navigation")
struct ZoomOverlayKeyboardNavigationTests {
    @Test(arguments: ["j", "J"])
    func `J selects the JPG source`(characters: String) {
        #expect(ZoomOverlayKeyAction.resolve(
            characters: characters, keyCode: 38, navigationAxis: .horizontal,
        ) == .selectJPG)
    }

    @Test(arguments: ["r", "R"])
    func `R selects the developed RAW source`(characters: String) {
        #expect(ZoomOverlayKeyAction.resolve(
            characters: characters, keyCode: 15, navigationAxis: .vertical,
        ) == .selectRAW)
    }

    @Test(arguments: ["p", "P"])
    func `P toggles the image-only preview`(characters: String) {
        let action = ZoomOverlayKeyAction.resolve(
            characters: characters,
            keyCode: 0,
            navigationAxis: .horizontal,
        )

        #expect(action == .togglePreview)
    }

    @Test(arguments: ["x", "X"])
    func `X closes the zoom overlay`(characters: String) {
        let action = ZoomOverlayKeyAction.resolve(
            characters: characters,
            keyCode: 0,
            navigationAxis: .horizontal,
        )

        #expect(action == .escape)
    }

    @Test(arguments: ["s", "S"])
    func `S toggles the Deep Review subject outline`(characters: String) {
        let action = ZoomOverlayKeyAction.resolve(
            characters: characters,
            keyCode: 0,
            navigationAxis: .horizontal,
        )

        #expect(action == .toggleSubjectOutline)
    }
}
