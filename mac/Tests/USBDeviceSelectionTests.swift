import Foundation

@main enum USBDeviceSelectionTests {
    static func main() {
        let listing = """
        List of devices attached
        tablet device usb:123 product:tablet model:Tablet
        phone device usb:456 product:phone
        locked unauthorized usb:789
        asleep offline usb:321
        192.168.1.2:5555 device product:tablet
        emulator-5554 device product:sdk
        """
        precondition(USBDeviceSelection.authorizedUSBDevices(listing) == ["tablet", "phone"])
        precondition(USBDeviceSelection.authorizedUSBDevices("").isEmpty)
        precondition(USBDeviceSelection.hasTabD("package:xyz.kryp.app.tabd\n"))
        precondition(!USBDeviceSelection.hasTabD("package:xyz.kryp.app.tabd.other"))
        precondition(!USBDeviceSelection.hasTabD(""))
        precondition(USBDeviceSelection.uniqueTarget([]) == nil)
        precondition(USBDeviceSelection.uniqueTarget(["tablet"]) == "tablet")
        precondition(USBDeviceSelection.uniqueTarget(["tablet", "secondTablet"]) == nil)
        precondition(USBDeviceSelection.uniqueTarget(["replacement"]) == "replacement")
        print("USBDeviceSelection: 9 authorization / USB / package / ambiguity checks passed")
    }
}
