// MessageTransport.swift
// SophaxChatCore
//
// Pluggable transport layer protocol.
//
// SophaxChat's cryptographic layer is completely independent of the physical
// transport. All message routing goes through WireMessage objects, which are
// already serialized, signed, and (for targeted messages) encrypted.
//
// A transport adapter needs to:
//   1. Discover peers in its medium (BLE, WiFi, LoRa, audio covert channel, …)
//   2. Send/broadcast WireMessage objects to one or all peers
//   3. Notify the delegate of incoming messages and peer state changes
//
// Current implementation: MeshManager (MultipeerConnectivity — BLE + WiFi Direct)
// Future adapters:
//   - LoRaTransport  — long-range low-bandwidth radio (e.g. TTGO T-Beam)
//   - AudioTransport — acoustic covert channel via microphone/speaker
//   - SerialTransport — USB/serial cable for air-gapped transfer

import Foundation

// MARK: - Delegate

/// Callbacks fired by a MessageTransport when peers or messages arrive.
/// All callbacks MUST be dispatched to the main thread by the transport.
public protocol MessageTransportDelegate: AnyObject {

    /// A new peer became visible in the transport medium (before identity exchange).
    func transport(_ transport: any MessageTransport,
                   didDiscoverPeer peerID: String, withName displayName: String)

    /// A peer is no longer reachable via this transport.
    func transport(_ transport: any MessageTransport, didLosePeer peerID: String)

    /// A direct transport-layer connection was established (Hello exchange can begin).
    func transport(_ transport: any MessageTransport, didConnectToPeer peerID: String)

    /// A direct transport-layer connection was torn down.
    func transport(_ transport: any MessageTransport, didDisconnectFromPeer peerID: String)

    /// A wire message was received from a peer.
    func transport(_ transport: any MessageTransport,
                   didReceiveMessage message: WireMessage, fromPeer peerID: String)

    /// A previous `send` call failed to deliver to a peer.
    func transport(_ transport: any MessageTransport,
                   sendDidFailForPeer peerID: String, error: Error)
}

// MARK: - MessageTransport protocol

/// Abstraction over a physical/logical message delivery medium.
///
/// Implementations must be thread-safe for `send` and `broadcast` (they may be
/// called from any thread). All delegate callbacks must be delivered on the main thread.
public protocol MessageTransport: AnyObject {

    /// The delegate to notify on peer events and inbound messages.
    var delegate: (any MessageTransportDelegate)? { get set }

    // MARK: Lifecycle

    /// Start advertising and discovering peers.
    func start()

    /// Stop all peer discovery and advertising. Active connections may be dropped.
    func stop()

    // MARK: Addressing

    /// Returns `true` if `peerID` is currently directly reachable (no relay needed).
    func isConnected(peerID: String) -> Bool

    /// Number of directly-connected peers (used to decide direct vs. relay routing).
    var directPeerCount: Int { get }

    // MARK: Sending

    /// Send a message to a specific peer.
    /// Throws if the peer is not currently connected or if serialization fails.
    func send(_ message: WireMessage, toPeerID peerID: String) throws

    /// Broadcast a message to all currently connected peers.
    /// - Parameter excluding: optionally skip one peer (relay loop prevention).
    func broadcast(_ message: WireMessage, excluding excludedPeerID: String?) throws
}

// MARK: - Default broadcast convenience

public extension MessageTransport {
    /// Broadcast to all peers without exclusion.
    func broadcast(_ message: WireMessage) throws {
        try broadcast(message, excluding: nil)
    }
}

// MARK: - Future adapter stubs (not yet implemented)

// LoRaTransport will conform to MessageTransport.
// Minimum viable LoRa implementation requires:
//   - Serial/Bluetooth connection to a LoRa radio module (e.g. TTGO T-Beam via BLE)
//   - Packet fragmentation for WireMessage payloads > LoRa MTU (~240 bytes)
//   - Link-layer acknowledgement (LoRaWAN ACK or custom)
//   - Long-range mode: typically 1–10 km in open terrain at SF12/BW125

// AudioTransport will conform to MessageTransport.
// A near-ultrasonic (18–22 kHz) acoustic channel using OFDM or chirp spread spectrum.
// Achievable in short range (<5 m) with device speakers/mic at ~100 bps.
// Useful for extreme scenarios (air-gapped rooms, no wireless hardware).
