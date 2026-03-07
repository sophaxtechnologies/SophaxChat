// MeshManager.swift
// SophaxChatCore
//
// P2P mesh networking via Apple MultipeerConnectivity.
// MultipeerConnectivity automatically uses the best available transport:
//   • WiFi Direct (peer-to-peer WiFi) — longest range, highest bandwidth
//   • Bluetooth LE                    — works when WiFi unavailable
//   • Infrastructure WiFi             — when both peers on same network
//
// Security notes:
//   • MultipeerConnectivity provides transport-level encryption (TLS 1.3 equivalent)
//   • This is defense-in-depth; ALL message content is also E2EE via Double Ratchet
//   • The MCPeerID display name is derived from the identity key hash (not the username)
//     so it doesn't leak the username at the transport layer
//   • Connections are accepted automatically — authentication happens at the crypto layer

import Foundation
@preconcurrency import MultipeerConnectivity

// MARK: - Delegate protocol

public protocol MeshManagerDelegate: AnyObject {
    /// A new peer was discovered nearby.
    func meshManager(_ manager: MeshManager, didDiscoverPeer peerID: String, withName displayName: String)
    /// A previously discovered peer went away.
    func meshManager(_ manager: MeshManager, didLosePeer peerID: String)
    /// A peer connected (session established at transport layer).
    func meshManager(_ manager: MeshManager, didConnectToPeer peerID: String)
    /// A peer disconnected.
    func meshManager(_ manager: MeshManager, didDisconnectFromPeer peerID: String)
    /// Received a raw WireMessage from a peer.
    func meshManager(_ manager: MeshManager, didReceiveMessage message: WireMessage, fromPeer peerID: String)
    /// Failed to send a message.
    func meshManager(_ manager: MeshManager, sendDidFailForPeer peerID: String, error: Error)
}

// MARK: - MeshManager

public final class MeshManager: NSObject, @unchecked Sendable {

    // MultipeerConnectivity service type: lowercase, ≤ 15 chars, alphanumeric + hyphens
    private static let serviceType = "sophax-chat"

    private let localPeerID: MCPeerID
    private var session:    MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser:    MCNearbyServiceBrowser

    /// Maps MC display name → our application-level peerID
    private var displayNameToPeerID: [String: String] = [:]
    /// Maps our peerID → MCPeerID
    private var peerIDToMCPeer: [String: MCPeerID] = [:]
    /// Currently connected MCPeerIDs
    private var connectedMCPeers: Set<MCPeerID> = []

    private let queue = DispatchQueue(label: "com.sophax.mesh", qos: .userInitiated)

    public weak var delegate: MeshManagerDelegate?

    // MARK: - Init

    /// - Parameters:
    ///   - localIdentityHash: First 16 hex characters of the local identity key hash.
    ///     Used as the MCPeerID display name — does NOT include the username.
    public init(localIdentityHash: String) {
        // MCPeerID displayName is visible to nearby devices at the transport layer.
        // We use the identity key hash — not the username — to avoid leaking identity.
        let mcPeerID = MCPeerID(displayName: "sophax-\(localIdentityHash.prefix(12))")
        self.localPeerID = mcPeerID

        let session = MCSession(
            peer: mcPeerID,
            securityIdentity: nil,           // No TLS certificate pinning; see note below
            encryptionPreference: .required  // Require transport-layer encryption
        )
        // Note: MCSession's built-in encryption (TLS) prevents passive eavesdropping
        // at the transport layer. Application-level E2EE (Double Ratchet) is the
        // primary security mechanism — transport encryption is defense-in-depth.

        self.session = session
        self.advertiser = MCNearbyServiceAdvertiser(
            peer: mcPeerID,
            discoveryInfo: ["v": "1"],       // Protocol version — don't leak more info
            serviceType: Self.serviceType
        )
        self.browser = MCNearbyServiceBrowser(
            peer: mcPeerID,
            serviceType: Self.serviceType
        )
        super.init()

        session.delegate    = self
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

    /// Send a WireMessage to a specific peer. Reliable, ordered delivery.
    public func send(_ message: WireMessage, toPeerID peerID: String) throws {
        guard let mcPeer = peerIDToMCPeer[peerID],
              connectedMCPeers.contains(mcPeer) else {
            throw MeshError.peerNotConnected(peerID)
        }

        let data = try JSONEncoder().encode(message)
        try session.send(data, toPeers: [mcPeer], with: .reliable)
    }

    /// Send a WireMessage to all connected peers (broadcast).
    public func broadcast(_ message: WireMessage) throws {
        guard !connectedMCPeers.isEmpty else { return }
        let data  = try JSONEncoder().encode(message)
        let peers = Array(connectedMCPeers)
        try session.send(data, toPeers: peers, with: .reliable)
    }

    /// Whether a specific peer is currently connected.
    public func isConnected(peerID: String) -> Bool {
        guard let mcPeer = peerIDToMCPeer[peerID] else { return false }
        return connectedMCPeers.contains(mcPeer)
    }

    public var connectedPeerIDs: [String] {
        connectedMCPeers.compactMap { mc in
            displayNameToPeerID[mc.displayName]
        }
    }
}

// MARK: - MCSessionDelegate

extension MeshManager: MCSessionDelegate {

    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        queue.async { [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                self.connectedMCPeers.insert(peerID)
                let appPeerID = self.displayNameToPeerID[peerID.displayName] ?? peerID.displayName
                DispatchQueue.main.async {
                    self.delegate?.meshManager(self, didConnectToPeer: appPeerID)
                }
            case .notConnected:
                self.connectedMCPeers.remove(peerID)
                let appPeerID = self.displayNameToPeerID[peerID.displayName] ?? peerID.displayName
                DispatchQueue.main.async {
                    self.delegate?.meshManager(self, didDisconnectFromPeer: appPeerID)
                }
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let message = try? JSONDecoder().decode(WireMessage.self, from: data) else {
                // Malformed message — ignore silently
                return
            }
            // Update mapping from MC displayName → app peerID (from message envelope)
            self.displayNameToPeerID[peerID.displayName] = message.senderID
            self.peerIDToMCPeer[message.senderID] = peerID

            let senderID = message.senderID
            DispatchQueue.main.async {
                self.delegate?.meshManager(self, didReceiveMessage: message, fromPeer: senderID)
            }
        }
    }

    // Unused session delegate methods
    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MeshManager: MCNearbyServiceAdvertiserDelegate {

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Accept all connections — authentication happens at the application layer (X3DH)
        invitationHandler(true, session)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        // Log or surface the error in debug builds
        #if DEBUG
        print("[MeshManager] Advertising failed: \(error)")
        #endif
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MeshManager: MCNearbyServiceBrowserDelegate {

    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        queue.async { [weak self] in
            guard let self else { return }

            // Invite the peer to connect
            browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 10)

            let displayName = peerID.displayName
            // Use display name as a temporary peerID until we receive a Hello message
            self.peerIDToMCPeer[displayName] = peerID

            DispatchQueue.main.async {
                self.delegate?.meshManager(self, didDiscoverPeer: displayName, withName: displayName)
            }
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        queue.async { [weak self] in
            guard let self else { return }
            let appPeerID = self.displayNameToPeerID[peerID.displayName] ?? peerID.displayName
            self.peerIDToMCPeer.removeValue(forKey: appPeerID)
            self.displayNameToPeerID.removeValue(forKey: peerID.displayName)

            DispatchQueue.main.async {
                self.delegate?.meshManager(self, didLosePeer: appPeerID)
            }
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        #if DEBUG
        print("[MeshManager] Browsing failed: \(error)")
        #endif
    }
}

// MARK: - MeshError

public enum MeshError: Error, LocalizedError {
    case peerNotConnected(String)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .peerNotConnected(let id): return "Peer \(id) is not connected"
        case .encodingFailed:           return "Failed to encode message for transmission"
        }
    }
}
