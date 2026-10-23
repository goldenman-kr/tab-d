import CoreGraphics
import Foundation

// A deliberately explicit test helper. It requests an origin change only for
// the owned virtual display and never selects a mode or configures a physical display.
@main private enum DisplayPlacement {
    private static func integer(_ text: String) -> Int32? {
        guard text.range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return Int32(text)
    }

    private static func finish(_ status: Int32, _ value: [String: Any]) -> Never {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys),
           let text = String(data: data, encoding: .utf8) { print(text) }
        exit(status)
    }

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              arguments[1].range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
              let displayID = UInt32(arguments[1]), displayID != 0,
              let x = integer(arguments[2]), let y = integer(arguments[3]) else {
            finish(64, ["error": "usage: display-placement displayID x y; coordinates must be Int32 decimal integers"])
        }
        guard CGDisplayVendorNumber(displayID) == 0x5444,
              CGDisplayIsActive(displayID) != 0,
              CGDisplayIsMain(displayID) == 0, CGMainDisplayID() != displayID,
              CGDisplayIsInMirrorSet(displayID) == 0,
              CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay else {
            finish(1, ["error": "target must be an active, non-main, non-mirrored Tab-D virtual display",
                       "displayID": displayID])
        }

        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else {
            finish(2, ["error": "cannot begin display configuration", "code": begin.rawValue])
        }
        let origin = CGConfigureDisplayOrigin(configuration, displayID, x, y)
        guard origin == .success else {
            CGCancelDisplayConfiguration(configuration)
            finish(2, ["error": "cannot configure virtual display origin", "code": origin.rawValue])
        }
        let completion = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard completion == .success else {
            finish(2, ["error": "cannot complete display configuration", "code": completion.rawValue])
        }
        // WindowServer can normalize placement. The caller must verify the
        // resulting virtual and physical topology through its fresh observer.
        finish(0, ["result": "requested", "displayID": displayID,
                   "requestedOrigin": [x, y], "scope": "session", "modeChanged": false])
    }
}
