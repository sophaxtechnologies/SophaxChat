// MeshManager.swift
// SophaxChatCore
//
// P2P mesh transport via MultipeerConnectivity (Bluetooth LE + WiFi Direct).
//
// Security:
//   • encryptionPreference: .required  → TLS-level transport encryption (defence-in-depth)
//   • MCPeerID display name = first 12 chars of identity key hash (no username at transport layer)
//   • Authentication happens at the application layer (X3DH + Ed25519 signatures)
//   • Malformed or undecryptable packets are silently dropped

import Foundation
@preconcurrency import MultipeerConnectivity

// MARK: - Delegate

public protocol MeshManagerDelegate: AnyObject {
    func meshManager(_ manager: MeshManager, didDiscoverPeer peerID: String, withName displayName: String)
    func meshManager(_ manager: MeshManager, didLosePeer peerID: String)
    func meshManager(_ manager: MeshManager, didConnectToPeer peerID: String)
    func meshManager(_ manager: MeshManager, didDisconnectFromPeer peerID: String)
    func meshManager(_ manager: MeshManager, didReceiveMessage message: WireMessage, fromPeer peerID: String)
    func meshManager(_ manager: MeshManager, sendDidFailForPeer peerID: String, error: Error)
}

// MARK: - MeshManager

public final class MeshManager: NSObject, @unchecked Sendable {

    // Lowercase, ≤ 15 chars, [a-z0-9\-] only
    private static let serviceType = "sophax-chat"

    private let localPeerID: MCPeerID
    private var session:    MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser:    MCNearbyServiceBrowser

    /// MCPeerID displayName → application-level peerID (learned from Hello messages)
    private var displayNameToPeerID: [String: String] = [:]
    /// application-level peerID → MCPeerID
    private var peerIDToMCPeer: [String: MCPeerID] = [:]
    /// Set of currently connected MCPeerIDs
    private var connectedMCPeers: Set<MCPeerID> = []

    private let queue = DispatchQueue(label: "com.sophax.mesh", qos: .userInitiated)

    public weak var delegate: MeshManagerDelegate?

    // MARK: - Init

    public init(localIdentityHash: String) {
        let mcID = MCPeerID(displayName: "sx-\(localIdentityHash.prefix(12))")
        self.localPeerID = mcID

        let sess = MCSession(
            peer: mcID,
            securityIdentity: nil,
            encryptionPreference: .required   // TLS transport encryption required
        )
        self.session = sess
        self.advertiser = MCNearbyServiceAdvertiser(
            peer: mcID,
            discoveryInfo: ["v": "1"],        // Protocol version only — no PII
            serviceType: Self.serviceType
        )
        self.browser = MCNearbyServiceBrowser(peer: mcID, serviceType: Self.serviceType)

        super.init()
        sess.delegate       = self
        advertiser.delegate = self
        browser.delegate    = self
    }

    // MARK: - Lifecycle

    public func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    public func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    // MARK: - Sending

    /// Reliable, ordered delivery to a specific directly-connected peer.
    public func send(_ message: WireMessage, toPeerID peerID: String) throws {
        guard let mcPeer = peerIDToMCPeer[peerID],
              connectedMCPeers.contains(mcPeer) else {
            throw MeshError.peerNotConnected(peerID)
        }
        let data = try JSONEncoder().encode(message)
        try session.send(data, toPeers: [mcPeer], with: .reliable)
    }

    /// Broadcast to all directly-connected peers, optionally excluding one.
    /// Used by the relay system to forward envelopes without looping.
    public func broadcast(_ message: WireMessage, excluding excludedPeerID: String? = nil) throws {
        let excludedMCPeer: MCPeerID? = excludedPeerID.flatMap { peerIDToMCPeer[$0] }
        let targets = connectedMCPeers.filter { $0 != excludedMCPeer }
        guard !targets.isEmpty else { return }
        let data = try JSONEncoder().encode(message)
        try session.send(data, toPeers: Array(targets), with: .reliable)
    }

    /// Whether a specific peer (by peerID) is directly connected.
    public func isConnected(peerID: String) -> Bool {
        guard let mc = peerIDToMCPeer[peerID] else { return false }
        return connectedMCPeers.contains(mc)
    }

    /// All directly-connected application-level peerIDs.
    public var connectedPeerIDs: [String] {
        connectedMCPeers.compactMap { displayNameToPeerID[$0.displayName] }
    }

    /// Number of directly connected peers.
    public var directPeerCount: Int { connectedMCPeers.count }
}

// MARK: - MCSessionDelegate

extension MeshManager: MCSessionDelegate {

    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        queue.async { [weak self] in
            guard let self else { return }
            let appID = self.displayNameToPeerID[peerID.displayName] ?? peerID.displayName
            switch state {
            case .connected:
                self.connectedMCPeers.insert(peerID)
                DispatchQueue.main.async { self.delegate?.meshManager(self, didConnectToPeer: appID) }
            case .notConnected:
                self.connectedMCPeers.remove(peerID)
                DispatchQueue.main.async { self.delegate?.meshManager(self, didDisconnectFromPeer: appID) }
            default:
                break
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let message = try? JSONDecoder().decode(WireMessage.self, from: data) else {
                return   // Malformed — drop silently
            }
            // Learn/update the mapping from MC display name to application peerID
            self.displayNameToPeerID[peerID.displayName] = message.senderID
            self.peerIDToMCPeer[message.senderID]        = peerID

            let senderID = message.senderID
            DispatchQueue.main.async {
                self.delegate?.meshManager(self, didReceiveMessage: message, fromPeer: senderID)
            }
        }
    }

    // Unused delegate stubs
    public func session(_ session: MCSession, didReceive stream: InputStream,
                        withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                        fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                        fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MeshManager: MCNearbyServiceAdvertiserDelegate {

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?,
                           invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Accept all transport connections — cryptographic authentication happens at app layer
        invitationHandler(true, session)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        #if DEBUG
        print("[MeshManager] Advertising error: \(error.localizedDescription)")
        #endif
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MeshManager: MCNearbyServiceBrowserDelegate {

    public func browser(_ browser: MCNearbyServiceBrowser,
                        foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        queue.async { [weak self] in
            guard let self else { return }
            browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 10)
            // Store temporary mapping (MC display name) until Hello arrives with real peerID
            self.peerIDToMCPeer[peerID.displayName] = peerID
            DispatchQueue.main.async {
                self.delegate?.meshManager(self, didDiscoverPeer: peerID.displayName,
                                           withName: peerID.displayName)
            }
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        queue.async { [weak self] in
            guard let self else { return }
            let appID = self.displayNameToPeerID[peerID.displayName] ?? peerID.displayName
            self.peerIDToMCPeer.removeValue(forKey: appID)
            self.displayNameToPeerID.removeValue(forKey: peerID.displayName)
            DispatchQueue.main.async {
                self.delegate?.meshManager(self, didLosePeer: appID)
            }
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        #if DEBUG
        print("[MeshManager] Browse error: \(error.localizedDescription)")
        #endif
    }
}

// MARK: - MeshError

public enum MeshError: Error, LocalizedError {
    case peerNotConnected(String)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .peerNotConnected(let id): "Peer \(id) is not directly connected"
        case .encodingFailed:           "Message encoding failed"
        }
    }
}
