import Foundation

/// Only an unambiguous, authorized physical USB device may receive pairing secrets.
enum USBDeviceSelection {
    static func authorizedUSBDevices(_ inventory: String) -> [String] {
        inventory.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, fields[1] == "device",
                  fields.dropFirst(2).contains(where: { $0.hasPrefix("usb:") }) else { return nil }
            return String(fields[0])
        }
    }
    static func hasTabD(_ packages: String) -> Bool {
        packages.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "package:xyz.kryp.app.tabd" }
    }
    static func uniqueTarget(_ candidates: [String]) -> String? {
        let devices = Set(candidates)
        return devices.count == 1 ? devices.first : nil
    }
}
