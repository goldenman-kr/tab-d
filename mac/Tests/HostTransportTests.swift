import Foundation

@main
enum HostTransportTests {
    static func frame(_ payload: Data, type: UInt8 = 1) -> Data {
        var count = UInt32(payload.count + 1).bigEndian
        var packet = Data(bytes: &count, count: 4)
        packet.append(type)
        packet.append(payload)
        return packet
    }

    static func reject(_ packet: Data) throws {
        var decoder = ControlFrameDecoder()
        do {
            _ = try decoder.append(packet)
            fatalError("Invalid input was accepted")
        } catch is HostTransportError {} catch is CocoaError {}
    }

    static func main() throws {
        let first = frame(Data(#"{"type":"pause"}"#.utf8))
        let second = frame(Data(#"{"type":"resume"}"#.utf8))
        var decoder = ControlFrameDecoder()
        var decoded: [[String: Any]] = []
        // Fragment every byte, including length, type and JSON boundaries.
        for byte in first + second { decoded += try decoder.append(Data([byte])) }
        precondition(decoded.count == 2)
        precondition(decoded[0]["type"] as? String == "pause")
        precondition(decoded[1]["type"] as? String == "resume")
        var coalesced = ControlFrameDecoder()
        let coalescedObjects = try coalesced.append(first + second)
        precondition(coalescedObjects.count == 2)
        try reject(Data([0, 0, 0, 0]))
        try reject(Data([0, 1, 0, 2])) // Reject oversized length without waiting for body.
        try reject(frame(Data("{}".utf8), type: 3))
        try reject(frame(Data("[]".utf8)))
        try reject(frame(Data("{".utf8)))
        let largeObject = try JSONSerialization.data(withJSONObject: ["text": String(repeating: "x", count: 65_500)])
        var largeDecoder = ControlFrameDecoder()
        let largeObjects = try largeDecoder.append(frame(largeObject))
        precondition(largeObjects.count == 1)
        print("PASS: fragmented/coalesced control frames, type/length/JSON rejection, near-limit payload")
        if CommandLine.arguments.contains("--identity") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tabd-identity-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let firstServer = try HostServer(stateDirectory: directory)
            let secondServer = try HostServer(stateDirectory: directory)
            precondition(firstServer.pairing["pin"] as? String == secondServer.pairing["pin"] as? String)
            precondition(firstServer.pairing["token"] as? String == secondServer.pairing["token"] as? String)
            precondition((firstServer.pairing["pin"] as? String)?.count == 64)
            precondition(!firstServer.isAuthenticated)
            for file in ["server-cert.der", "server-key.der", "pairing-token"] {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)
                precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            }
            print("PASS: local TLS identity generation, memory-only import, stable reload, private file permissions")
        }
    }
}
