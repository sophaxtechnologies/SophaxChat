// TCPTransport.swift
// SophaxChatCore
//
// Pluggable TCP transport — lets SophaxChat communicate over the internet.
//
// The cryptographic layer (X3DH + Double Ratchet + ChaCha20-Poly1305) is
// identical to the local BLE/WiFi path. TCP is just a carrier of already-
// encrypted WireMessage objects. The transport is trustless by design.
//
// Security properties preserved over TCP:
//   • End-to-end encryption: messages are sealed before hitting the wire
//   • Authentication: every WireMessage carries an Ed25519 signature
//   • Forward secrecy: Double Ratchet rotates keys per message
//   • Sealed sender: relay nodes cannot correlate sender and recipient
//
// Anonymity options:
//   a) System Tor via Orbot "VPN mode" — all iOS network traffic goes
//      through Tor automatically, no app-side config needed.
//   b) SOCKS5 proxy — set socksProxy = "127.0.0.1:9050" in Config
//      (requires Orbot or another local SOCKS5 proxy, iOS 17+).
//
// Peer discovery over TCP:
//   Peers exchange their TCP address (host:port) via QR code or out-of-band.
//   The address is also included in Hello messages so nearby (BLE/WiFi)
//   peers automatically learn each other's internet address.
//
// Framing: 4-byte big-endian length prefix + JSON-encoded WireMessage.
//
// Protocol:
//   After TCP connect, both peers immediately exchange their Hello message
//   (the same PreKeyBundle format used over BLE/WiFi). The peerID is
//   learned from WireMessage.senderID of the received Hello.

import Foundation
import Network

// MARK: - Errors

public enum TCPTransportError: Error, LocalizedError {
    case peerNotConnected
    case invalidAddress
    case helloNotAvailable

    public var errorDescription: String? {
        switch self {
        case .peerNotConnected:    return "Peer is not connected via TCP"
        case .invalidAddress:      return "Invalid address — expected host:port"
        case .helloNotAvailable:   return "Cannot send TCP Hello: hello provider not set"
        }
    }
}

// MARK: - Delegate

public protocol TCPTransportDelegate: AnyObject {
    /// A TCP connection completed Hello exchange. `address` is the remote host:port.
    func tcpTransport(_ transport: TCPTransport, didConnectToPeer peerID: String, address: String)
    /// A TCP connection was lost.
    func tcpTransport(_ transport: TCPTransport, didDisconnectFromPeer peerID: String)
    /// A WireMessage was received over a verified TCP connection.
    func tcpTransport(_ transport: TCPTransport,
                      didReceiveMessage message: WireMessage, fromPeer peerID: String)
    /// A `send` call failed.
    func tcpTransport(_ transport: TCPTransport, sendDidFailForPeer peerID: String, error: Error)
    /// The listener started and is ready to accept connections.
    func tcpTransportDidStartListening(_ transport: TCPTransport, onPort port: UInt16)
}

// MARK: - TCPTransport

// Threading contract: TCPTransport is internally thread-safe. All mutable
// state is protected by `lock` (NSLock). Delegate callbacks are always
// dispatched to the main thread.
public final class TCPTransport: @unchecked Sendable {

    // MARK: - Config

    public struct Config: Codable, Sendable {
        /// Local TCP port to listen on (default 25519 — homage to Curve25519).
        public var port: UInt16
        /// Optional SOCKS5 proxy "host:port" for routing through Tor (iOS 17+).
        /// Example: "127.0.0.1:9050" for a local Orbot SOCKS5 proxy.
        public var socksProxy: String?

        public init(port: UInt16 = 25519, socksProxy: String? = nil) {
            self.port       = port
            self.socksProxy = socksProxy
        }

        var proxyComponents: (host: String, port: UInt16)? {
            guard let s = socksProxy else { return nil }
            let parts = s.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let p = UInt16(parts[1]) else { return nil }
            return (String(parts[0]), p)
        }
    }

    // MARK: - Private state

    public let config: Config

    /// Called whenever TCPTransport needs to send a Hello to a newly-connected peer.
    /// ChatManager sets this to return a freshly-signed HelloMessage WireMessage.
    public var helloProvider: (() -> WireMessage?)?

    private let lock = NSLock()

    /// peerID → active NWConnection (post Hello exchange).
    private var connections: [String: NWConnection] = [:]
    /// ObjectIdentifier → receive buffer (for connections whose Hello is still pending).
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    /// ObjectIdentifier → resolved remote address string (filled on TCP connect).
    private var pendingAddresses: [ObjectIdentifier: String] = [:]

    private var listener: NWListener?

    private static let helloTimeout: TimeInterval = 30
    private static let maxFrameSize: Int = 4 * 1024 * 1024  // 4 MiB safety cap

    public weak var delegate: TCPTransportDelegate?

    // MARK: - Init

    public init(config: Config) {
        self.config = config
    }

    // MARK: - Lifecycle

    public func start() {
        let params = makeNWParameters(isListener: true)
        guard let listener = try? NWListener(using: params,
                                             on: NWEndpoint.Port(rawValue: config.port) ?? .any) else { return }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let port = listener.port?.rawValue {
                DispatchQueue.main.async { self.delegate?.tcpTransportDidStartListening(self, onPort: port) }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(connection: conn)
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let allConns = Array(connections.values)
        connections.removeAll()
        receiveBuffers.removeAll()
        pendingAddresses.removeAll()
        lock.unlock()
        allConns.forEach { $0.cancel() }
    }

    // MARK: - Outbound connect

    /// Connect to a remote peer. Address must be "host:port".
    /// Completion fires on the main thread with the connected peerID, or nil on failure.
    public func connect(to address: String) throws {
        guard let (host, port) = parseAddress(address),
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TCPTransportError.invalidAddress
        }
        let params     = makeNWParameters(isListener: false)
        let endpoint   = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: params)
        let oid        = ObjectIdentifier(connection)
        lock.lock()
        receiveBuffers[oid]  = Data()
        pendingAddresses[oid] = address
        lock.unlock()
        setup(connection: connection)
    }

    // MARK: - Send

    public func send(_ message: WireMessage, toPeerID peerID: String) throws {
        lock.lock()
        let conn = connections[peerID]
        lock.unlock()
        guard let conn else { throw TCPTransportError.peerNotConnected }
        guard let data = try? JSONEncoder().encode(message) else { return }
        sendFramed(data, over: conn, failurePeerID: peerID)
    }

    // MARK: - Query

    public func isConnected(peerID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return connections[peerID] != nil
    }

    public var connectedPeerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }

    public var connectedPeerIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(connections.keys)
    }

    // MARK: - Private: accept inbound

    private func accept(connection: NWConnection) {
        let oid = ObjectIdentifier(connection)
        let addr = addressString(for: connection)
        lock.lock()
        receiveBuffers[oid]   = Data()
        pendingAddresses[oid] = addr
        lock.unlock()
        setup(connection: connection)
    }

    // MARK: - Private: connection setup

    private func setup(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                // Send our Hello immediately after TCP handshake
                if let hello = self.helloProvider?(),
                   let data  = try? JSONEncoder().encode(hello) {
                    self.sendFramed(data, over: connection, failurePeerID: nil)
                }
                self.scheduleHelloTimeout(for: connection)
                self.startReceiving(from: connection)

            case .failed, .cancelled:
                self.teardown(connection: connection)

            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    // MARK: - Private: Hello timeout

    private func scheduleHelloTimeout(for connection: NWConnection) {
        let oid = ObjectIdentifier(connection)
        DispatchQueue.global().asyncAfter(deadline: .now() + TCPTransport.helloTimeout) {
            [weak self, weak connection] in
            guard let self, let connection else { return }
            self.lock.lock()
            let isPending = self.receiveBuffers[oid] != nil &&
                !self.connections.values.contains { ObjectIdentifier($0) == oid }
            self.lock.unlock()
            if isPending { connection.cancel() }
        }
    }

    // MARK: - Private: receive loop

    private func startReceiving(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let data { self.didReceive(data: data, from: connection) }
            if isComplete || error != nil { self.teardown(connection: connection); return }
            self.startReceiving(from: connection)
        }
    }

    // MARK: - Private: framing

    private func didReceive(data: Data, from connection: NWConnection) {
        let oid = ObjectIdentifier(connection)
        lock.lock()
        receiveBuffers[oid, default: Data()].append(data)
        var buf = receiveBuffers[oid] ?? Data()
        var frames: [Data] = []
        while buf.count >= 4 {
            let length = buf.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length <= TCPTransport.maxFrameSize else { buf.removeAll(); break }
            guard buf.count >= 4 + Int(length) else { break }
            frames.append(Data(buf[4..<(4 + Int(length))]))
            buf = Data(buf[(4 + Int(length))...])
        }
        receiveBuffers[oid] = buf
        lock.unlock()
        frames.forEach { dispatch(frame: $0, from: connection) }
    }

    private func sendFramed(_ data: Data, over connection: NWConnection, failurePeerID: String?) {
        var len = UInt32(data.count).bigEndian
        let frame = Data(bytes: &len, count: 4) + data
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let error, let self, let pid = failurePeerID else { return }
            DispatchQueue.main.async {
                self.delegate?.tcpTransport(self, sendDidFailForPeer: pid, error: error)
            }
        })
    }

    // MARK: - Private: dispatch received frame

    private func dispatch(frame: Data, from connection: NWConnection) {
        guard let message = try? JSONDecoder().decode(WireMessage.self, from: frame) else { return }
        let oid = ObjectIdentifier(connection)

        lock.lock()
        let knownPeerID = connections.first(where: { ObjectIdentifier($0.value) == oid })?.key
        lock.unlock()

        if let peerID = knownPeerID {
            // Normal message from a known peer
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.tcpTransport(self, didReceiveMessage: message, fromPeer: peerID)
            }
            return
        }

        // Pending Hello — the first received message MUST be a Hello
        guard message.type == .hello else { connection.cancel(); return }
        let peerID = message.senderID

        lock.lock()
        // Evict any stale connection for this peer (reconnect race)
        connections[peerID]?.cancel()
        connections[peerID] = connection
        let addr = pendingAddresses[oid] ?? addressString(for: connection)
        pendingAddresses.removeValue(forKey: oid)
        lock.unlock()

        let address = addr
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.tcpTransport(self, didConnectToPeer: peerID, address: address)
            // Deliver the Hello to ChatManager so it can process the PreKeyBundle
            self.delegate?.tcpTransport(self, didReceiveMessage: message, fromPeer: peerID)
        }
    }

    // MARK: - Private: teardown

    private func teardown(connection: NWConnection) {
        let oid = ObjectIdentifier(connection)
        lock.lock()
        let peerID = connections.first(where: { ObjectIdentifier($0.value) == oid })?.key
        if let p = peerID { connections.removeValue(forKey: p) }
        receiveBuffers.removeValue(forKey: oid)
        pendingAddresses.removeValue(forKey: oid)
        lock.unlock()
        connection.cancel()
        if let peerID {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.tcpTransport(self, didDisconnectFromPeer: peerID)
            }
        }
    }

    // MARK: - Private: NWParameters

    private func makeNWParameters(isListener: Bool) -> NWParameters {
        let params = NWParameters.tcp
        // SOCKS5 proxy (iOS 17+ / macOS 14+): routes connections through Tor or similar.
        if #available(iOS 17.0, macOS 14.0, *),
           let (host, port) = config.proxyComponents,
           let nwPort = NWEndpoint.Port(rawValue: port) {
            let proxyEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
            let proxyCfg      = ProxyConfiguration(socksv5Proxy: proxyEndpoint)
            let privacyCtx    = NWParameters.PrivacyContext(description: "SophaxChat")
            privacyCtx.proxyConfigurations = [proxyCfg]
            params.setPrivacyContext(privacyCtx)
        }
        return params
    }

    // MARK: - Private: utilities

    private func parseAddress(_ s: String) -> (host: String, port: UInt16)? {
        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let p = UInt16(parts[1]) else { return nil }
        return (String(parts[0]), p)
    }

    private func addressString(for connection: NWConnection) -> String {
        switch connection.endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return connection.endpoint.debugDescription
        }
    }
}
