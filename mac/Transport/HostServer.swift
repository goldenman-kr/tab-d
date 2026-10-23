import Foundation
import Network
import Security
import CryptoKit
import Darwin

/// Native TLS server shared by ADB reverse and LAN. All connection state lives on `queue`.
final class HostServer {
    var onJSON: (([String: Any]) -> Void)?
    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Diagnostic event names contain no peer addresses, credentials or message bodies.
    var onDiagnostic: ((String) -> Void)?

    private let queue = DispatchQueue(label: "xyz.kryp.app.tabd.transport")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let identity: SecIdentity
    private let token: String
    private let pin: String
    private var listeners: [NWListener] = []
    private var lanListener: NWListener?
    private var peer: NWConnection?
    private var peerRoute: String?
    private var authenticated = false
    private var pendingBytes = 0
    private var decoder = ControlFrameDecoder()
    private var authTimer: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var acceptedPeers: UInt64 = 0
    private var rejectedBusyPeers: UInt64 = 0
    private var lastEvent = "initialized"
    private var lastPeerFailure: String?
    private var lastPeerFailureAtUptime: Double?
    private var listenerStates: [String: String] = [:]
    private static let maxPending = 8 * 1024 * 1024

    var pairing: [String: Any] {
        ["pin": pin, "token": token, "usbPort": 49832, "lanPort": 49833,
         "serverName": "tabd.local", "version": 1]
    }

    var isAuthenticated: Bool { onQueue { authenticated } }

    var diagnostics: [String: Any] {
        onQueue {
            ["authenticated": authenticated, "peerPresent": peer != nil,
             "peerRoute": peerRoute ?? "none", "pendingBytes": pendingBytes,
             "acceptedPeers": acceptedPeers, "rejectedBusyPeers": rejectedBusyPeers,
             "lastEvent": lastEvent, "lastPeerFailure": lastPeerFailure ?? "none",
             "lastPeerFailureAtUptime": lastPeerFailureAtUptime ?? 0,
             "listenerStates": listenerStates]
        }
    }

    init(stateDirectory: URL) throws {
        let material = try HostIdentity.loadOrCreate(at: stateDirectory)
        identity = material.identity
        pin = material.pin
        token = material.token
        queue.setSpecific(key: queueKey, value: true)
    }

    func start(allowLAN: Bool) throws {
        try onQueue {
            if listeners.isEmpty {
                generation &+= 1
                let usb = try makeListener(port: 49832, loopbackOnly: true,
                                           generation: generation)
                listeners.append(usb)
                usb.start(queue: queue)
            }
            if allowLAN, lanListener == nil {
                let lan = try makeListener(port: 49833, loopbackOnly: false,
                                           generation: generation)
                lan.service = NWListener.Service(name: "Tab-D", type: "_tabd._tcp")
                lanListener = lan
                listeners.append(lan)
                lan.start(queue: queue)
            } else if !allowLAN, let lan = lanListener {
                lanListener = nil
                listeners.removeAll { $0 === lan }
                listenerStates.removeValue(forKey: "LAN")
                lan.cancel()
                // Turning wireless off preserves an existing USB session.
                if peerRoute == "무선" { closePeer() }
            }
        }
    }

    func stop() {
        onQueue {
            generation &+= 1
            listeners.forEach { $0.cancel() }
            listeners.removeAll()
            lanListener = nil
            listenerStates.removeAll()
            closePeer()
        }
    }

    func sendJSON(_ object: [String: Any]) { sendObject(object, type: 1) }
    func sendConfig(_ object: [String: Any]) { sendObject(object, type: 2) }
    func sendVideo(_ payload: Data) { enqueue(payload, type: 3) }

    private func sendObject(_ object: [String: Any], type: UInt8) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            report("제어 메시지를 직렬화할 수 없습니다.")
            return
        }
        enqueue(data, type: type)
    }

    private func enqueue(_ payload: Data, type: UInt8) {
        // Do not accumulate an unbounded queue of closures retaining video buffers.
        onQueue { send(payload, type: type) }
    }

    private func send(_ payload: Data, type: UInt8) {
        guard authenticated, let connection = peer else { return }
        guard payload.count < Self.maxPending else {
            recordDiagnostic("outgoing-frame-too-large", failure: true)
            report("영상 프레임이 전송 한도를 초과했습니다.")
            closePeer()
            return
        }
        let size = payload.count + 5
        guard pendingBytes <= Self.maxPending - size else {
            recordDiagnostic("outgoing-backpressure-limit", failure: true)
            report("전송 지연이 누적되어 연결을 다시 시작합니다.")
            closePeer()
            return
        }
        var length = UInt32(payload.count + 1).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(type)
        packet.append(payload)
        pendingBytes += size
        connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.peer === connection else { return }
            self.pendingBytes -= size
            if let error {
                self.recordDiagnostic("send-failed", error: error)
                self.closePeer()
            }
        })
    }

    private func makeListener(port: UInt16, loopbackOnly: Bool,
                              generation expectedGeneration: UInt64) throws -> NWListener {
        let tls = NWProtocolTLS.Options()
        guard let tlsIdentity = sec_identity_create(identity) else {
            throw HostTransportError.message("TLS 인증서를 사용할 수 없습니다.")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, tlsIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = false
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        }
        // Supplying both requiredLocalEndpoint and `on:` is rejected with EINVAL.
        let listener = try loopbackOnly ? NWListener(using: parameters)
                                        : NWListener(using: parameters, on: endpointPort)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.generation == expectedGeneration,
                  self.listeners.contains(where: { $0 === listener }) else { return }
            let route = loopbackOnly ? "USB" : "LAN"
            switch state {
            case .setup: self.listenerStates[route] = "setup"
            case .ready: self.listenerStates[route] = "ready"
            case .waiting(let error):
                self.listenerStates[route] = "waiting"
                self.recordDiagnostic("listener-\(route)-waiting", error: error)
            case .failed(let error):
                self.listenerStates[route] = "failed"
                self.recordDiagnostic("listener-\(route)-failed", error: error)
                self.report(loopbackOnly ? "USB 연결 포트를 열 수 없습니다." : "무선 연결 포트를 열 수 없습니다.")
            case .cancelled: self.listenerStates[route] = "cancelled"
            @unknown default: self.listenerStates[route] = "unknown"
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener, self.generation == expectedGeneration,
                  self.listeners.contains(where: { $0 === listener }) else {
                connection.cancel()
                return
            }
            self.accept(connection, route: loopbackOnly ? "USB" : "무선")
        }
        return listener
    }

    private func accept(_ connection: NWConnection, route: String) {
        // An unauthenticated handshake also owns the slot, bounded to five seconds.
        guard peer == nil else {
            rejectedBusyPeers &+= 1
            recordDiagnostic("peer-rejected-slot-busy", failure: true)
            connection.cancel()
            return
        }
        acceptedPeers &+= 1
        peer = connection
        peerRoute = route
        authenticated = false
        pendingBytes = 0
        decoder = ControlFrameDecoder()
        recordDiagnostic("peer-accepted")
        let timer = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.peer === connection, !self.authenticated else { return }
            self.recordDiagnostic("authentication-timeout", failure: true)
            self.closePeer()
        }
        authTimer = timer
        queue.asyncAfter(deadline: .now() + 5, execute: timer)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.peer === connection else { return }
            switch state {
            case .ready:
                self.recordDiagnostic("tls-ready")
                self.receive(connection, route: route)
            case .failed(let error):
                self.recordDiagnostic("connection-failed", error: error)
                self.closePeer()
            case .waiting(let error): self.recordDiagnostic("connection-waiting", error: error)
            case .cancelled:
                self.recordDiagnostic("connection-cancelled")
                self.closePeer()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, route: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.peer === connection else { return }
            do {
                if let data {
                    for object in try self.decoder.append(data) {
                        guard self.peer === connection else { return }
                        if !self.authenticated {
                            guard object["type"] as? String == "hello",
                                  object["version"] as? Int == 1,
                                  let supplied = object["token"] as? String,
                                  Self.equalToken(supplied, self.token) else {
                                self.recordDiagnostic("hello-rejected", failure: true)
                                self.closePeer()
                                return
                            }
                            self.authenticated = true
                            self.authTimer?.cancel()
                            self.authTimer = nil
                            self.recordDiagnostic("hello-authenticated")
                            let deviceName = (Host.current().localizedName ?? Host.current().name ?? "Mac")
                                .components(separatedBy:.controlCharacters).joined().trimmingCharacters(in:.whitespacesAndNewlines)
                            self.sendJSON(["type": "helloAck", "version": 1, "device": String(deviceName.prefix(128))])
                            self.emitForPeer(connection) { self.onConnected?(route) }
                            var redacted = object
                            redacted.removeValue(forKey: "token")
                            self.emitForPeer(connection) { self.onJSON?(redacted) }
                        } else {
                            guard object["type"] as? String != "hello" else {
                                self.recordDiagnostic("duplicate-hello-rejected", failure: true)
                                self.closePeer()
                                return
                            }
                            self.emitForPeer(connection) { self.onJSON?(object) }
                        }
                    }
                }
                if complete || error != nil {
                    if let error { self.recordDiagnostic("receive-failed", error: error) }
                    else { self.recordDiagnostic("receive-eof") }
                    self.closePeer()
                }
                else { self.receive(connection, route: route) }
            } catch {
                self.recordDiagnostic("malformed-control-frame", failure: true)
                self.closePeer()
            }
        }
    }

    private func closePeer() {
        let wasAuthenticated = authenticated
        let previous = peer
        peer = nil
        peerRoute = nil
        authenticated = false
        pendingBytes = 0
        decoder = ControlFrameDecoder()
        authTimer?.cancel()
        authTimer = nil
        previous?.cancel()
        if wasAuthenticated {
            // This is an event for the previous authenticated session, even if
            // another peer has since arrived. The serial transport queue enqueues
            // it before any new onConnected callback on the main queue.
            emit { self.onDisconnected?() }
        }
    }

    private func emit(_ callback: @escaping () -> Void) { DispatchQueue.main.async(execute: callback) }
    private func recordDiagnostic(_ event: String, error: NWError? = nil, failure: Bool = false) {
        var text = event
        if let error {
            switch error {
            case .posix(let code): text += ":POSIX:\(code.rawValue)"
            case .dns(let code): text += ":DNS:\(code)"
            case .tls(let code): text += ":TLS:\(code)"
            default: text += ":other-network-error"
            }
        }
        lastEvent = text
        if failure || error != nil {
            lastPeerFailure = text
            lastPeerFailureAtUptime = ProcessInfo.processInfo.systemUptime
        }
        emit { self.onDiagnostic?(text) }
    }
    private func emitForPeer(_ connection: NWConnection, _ callback: @escaping () -> Void) {
        emit { [weak self, weak connection] in
            guard let self, let connection,
                  self.onQueue({ self.peer === connection && self.authenticated }) else { return }
            callback()
        }
    }
    private func report(_ text: String) { emit { self.onError?(text) } }
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    private static func equalToken(_ supplied: String, _ expected: String) -> Bool {
        let a = Array(supplied.utf8), b = Array(expected.utf8)
        guard a.count == 64, b.count == 64 else { return false }
        return a.withUnsafeBytes { ap in
            b.withUnsafeBytes { bp in timingsafe_bcmp(ap.baseAddress!, bp.baseAddress!, 64) == 0 }
        }
    }
}

enum HostTransportError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Incoming traffic is control-only; rejecting its length before allocation bounds memory.
struct ControlFrameDecoder {
    private var buffer = Data()
    mutating func append(_ input: Data) throws -> [[String: Any]] {
        buffer.append(input)
        var output: [[String: Any]] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length >= 2, length <= 65_537 else {
                throw HostTransportError.message("잘못된 제어 프레임 길이입니다.")
            }
            guard buffer.count >= Int(length) + 4 else { break }
            guard buffer[buffer.startIndex + 4] == 1 else {
                throw HostTransportError.message("지원하지 않는 입력 프레임입니다.")
            }
            let payload = buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + 4 + Int(length)))
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw HostTransportError.message("제어 메시지는 JSON 객체여야 합니다.")
            }
            output.append(object)
            buffer.removeFirst(Int(length) + 4)
        }
        return output
    }
}

private struct HostIdentity {
    let identity: SecIdentity
    let pin: String
    let token: String

    static func loadOrCreate(at directory: URL) throws -> HostIdentity {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let certificate = directory.appendingPathComponent("server-cert.der")
        let privateKey = directory.appendingPathComponent("server-key.der")
        let tokenFile = directory.appendingPathComponent("pairing-token")
        let exists = [certificate, privateKey, tokenFile].map { fm.fileExists(atPath: $0.path) }
        if exists.contains(true) && exists.contains(false) {
            throw HostTransportError.message("연결 인증 파일이 불완전합니다. 기존 페어링을 확인해 주세요.")
        }
        if !exists.contains(true) {
            let staging = directory.appendingPathComponent("identity-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            let pemKey = staging.appendingPathComponent("key.pem")
            let pemCert = staging.appendingPathComponent("cert.pem")
            try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
                         "-days", "3650", "-subj", "/CN=tabd.local", "-addext", "subjectAltName=DNS:tabd.local",
                         "-addext", "extendedKeyUsage=serverAuth", "-addext", "basicConstraints=critical,CA:FALSE",
                         "-keyout", pemKey.path, "-out", pemCert.path])
            let stagedKey = staging.appendingPathComponent("server-key.der")
            let stagedCert = staging.appendingPathComponent("server-cert.der")
            try openssl(["rsa", "-in", pemKey.path, "-outform", "DER", "-out", stagedKey.path])
            try openssl(["x509", "-in", pemCert.path, "-outform", "DER", "-out", stagedCert.path])
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw HostTransportError.message("페어링 키를 생성할 수 없습니다.")
            }
            let stagedToken = staging.appendingPathComponent("pairing-token")
            try Data(random.map { String(format: "%02x", $0) }.joined().utf8).write(to: stagedToken)
            for url in [stagedKey, stagedCert, stagedToken] {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try fm.moveItem(at: stagedKey, to: privateKey)
            try fm.moveItem(at: stagedCert, to: certificate)
            try fm.moveItem(at: stagedToken, to: tokenFile)
        }
        for url in [privateKey, certificate, tokenFile] {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw HostTransportError.message("연결 인증 파일 형식이 올바르지 않습니다.")
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let certData = try Data(contentsOf: certificate)
        let keyData = try Data(contentsOf: privateKey)
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData),
              let key = SecKeyCreateWithData(keyData as CFData,
                  [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil),
              let identity = SecIdentityCreate(nil, cert, key) else {
            throw HostTransportError.message("저장된 TLS 인증서를 읽을 수 없습니다.")
        }
        let token = try String(contentsOf: tokenFile, encoding: .utf8)
        guard token.utf8.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw HostTransportError.message("저장된 페어링 키가 올바르지 않습니다.")
        }
        let pin = SHA256.hash(data: certData).map { String(format: "%02x", $0) }.joined()
        return HostIdentity(identity: identity, pin: pin, token: token)
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        // Never include private material or subprocess output in diagnostics.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HostTransportError.message("로컬 TLS 인증서를 생성할 수 없습니다.")
        }
    }
}
