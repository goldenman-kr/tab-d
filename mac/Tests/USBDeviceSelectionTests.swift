import Foundation

@main enum USBDeviceSelectionTests {
    static func main() {
        let listing = """
        List of devices attached
        tablet device usb:123 product:tablet model:Tablet
        phone device usb:456 product:phone
        hub-tablet device 1-2.4.1 product:tablet model:Tablet transport_id:6
        direct-tablet device 2-1 product:tablet transport_id:7
        locked unauthorized usb:789
        asleep offline usb:321
        locked-hub unauthorized 1-2.4.2
        asleep-hub offline 1-2.4.3
        192.168.1.2:5555 device product:tablet
        wireless-service._adb-tls-connect._tcp device product:tablet transport_id:8
        emulator-5554 device product:sdk
        malformed device 1-2.4.bad product:tablet
        metadata-only device product:tablet 1-2.4.1
        """
        precondition(USBDeviceSelection.authorizedUSBDevices(listing) == ["tablet", "phone", "hub-tablet", "direct-tablet"])
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
