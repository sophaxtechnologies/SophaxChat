// NetworkTests.swift
// SophaxChatCoreTests
//
// Tests for:
//   • TCP length-prefix framing (4-byte big-endian: parse, multi-frame, partial)
//   • WireMessage encode/decode round-trip (all message types carry correctly)
//   • PreKeyBundle tcpAddress field propagation

import Testing
import Foundation
import CryptoKit
@testable import SophaxChatCore

// MARK: - TCP Framing Logic
//
// TCPTransport uses a 4-byte big-endian length prefix.
// These tests validate the framing algorithm independently of NWConnection
// so we can catch regressions without real networking.

private func encodeFrame(_ data: Data) -> Data {
    var len = UInt32(data.count).bigEndian
    return Data(bytes: &len, count: 4) + data
}

/// Decode as many complete frames from `buf` as possible.
/// Returns (frames, remainingBytes) — mirrors TCPTransport.didReceive(data:from:).
private func decodeFrames(from buf: Data, maxSize: Int = 4 * 1024 * 1024) -> (frames: [Data], remainder: Data) {
    var buf = buf
    var frames: [Data] = []
    while buf.count >= 4 {
        let length = buf.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length <= maxSize else { return (frames, Data()) }  // oversized: discard buffer
        guard buf.count >= 4 + Int(length) else { break }
        frames.append(Data(buf[4..<(4 + Int(length))]))
        buf = Data(buf[(4 + Int(length))...])
    }
    return (frames, buf)
}

@Suite("TCP Framing")
struct TCPFramingTests {

    @Test("Single frame round-trip")
    func singleFrameRoundTrip() {
        let payload = Data("hello sophaxchat".utf8)
        let framed  = encodeFrame(payload)
        let (frames, remainder) = decodeFrames(from: framed)
        #expect(frames.count == 1)
        #expect(frames[0] == payload)
        #expect(remainder.isEmpty)
    }

    @Test("Multiple frames in one buffer are all decoded")
    func multipleFrames() {
        let p1 = Data("frame one".utf8)
        let p2 = Data("frame two".utf8)
        let p3 = Data("frame three".utf8)
        let combined = encodeFrame(p1) + encodeFrame(p2) + encodeFrame(p3)
        let (frames, remainder) = decodeFrames(from: combined)
        #expect(frames.count == 3)
        #expect(frames[0] == p1)
        #expect(frames[1] == p2)
        #expect(frames[2] == p3)
        #expect(remainder.isEmpty)
    }

    @Test("Partial frame: header present but body incomplete → zero frames, full buffer preserved")
    func partialFrameHeaderOnly() {
        let payload = Data(repeating: 0xAB, count: 100)
        let full    = encodeFrame(payload)
        // Deliver only the 4-byte header — body missing
        let partial = full.prefix(4)
        let (frames, remainder) = decodeFrames(from: partial)
        #expect(frames.isEmpty)
        #expect(remainder == partial)
    }

    @Test("Partial frame: body truncated by 1 byte")
    func partialFrameBodyTruncated() {
        let payload = Data(repeating: 0xCD, count: 50)
        let full    = encodeFrame(payload)
        // Drop the last byte
        let truncated = full.dropLast(1)
        let (frames, remainder) = decodeFrames(from: Data(truncated))
        #expect(frames.isEmpty)
        #expect(remainder.count == full.count - 1)
    }

    @Test("Frame followed by partial next frame: first decoded, partial preserved")
    func completeThenPartial() {
        let p1 = Data("complete".utf8)
        let p2 = Data(repeating: 0xFF, count: 200)
        let buf = encodeFrame(p1) + encodeFrame(p2).prefix(10)  // only 10 bytes of second frame
        let (frames, remainder) = decodeFrames(from: buf)
        #expect(frames.count == 1)
        #expect(frames[0] == p1)
        #expect(remainder.count == 10)
    }

    @Test("Empty payload produces a 4-byte zero-length frame")
    func emptyPayload() {
        let framed = encodeFrame(Data())
        #expect(framed.count == 4)
        let (frames, _) = decodeFrames(from: framed)
        #expect(frames.count == 1)
        #expect(frames[0].isEmpty)
    }

    @Test("Oversized frame (> maxSize) causes buffer discard")
    func oversizedFrameDiscarded() {
        // Craft a 4-byte header claiming 10 MB (above the 4 MB cap)
        var len = UInt32(10 * 1024 * 1024).bigEndian
        let oversized = Data(bytes: &len, count: 4)
        let (frames, remainder) = decodeFrames(from: oversized, maxSize: 4 * 1024 * 1024)
        #expect(frames.isEmpty)
        #expect(remainder.isEmpty, "Buffer must be discarded when oversized frame detected")
    }

    @Test("Length prefix is big-endian")
    func bigEndianLength() {
        let payload = Data(repeating: 0x00, count: 256)
        let framed  = encodeFrame(payload)
        // Bytes [0..3] must encode 256 in big-endian = 0x00 0x00 0x01 0x00
        #expect(framed[0] == 0x00)
        #expect(framed[1] == 0x00)
        #expect(framed[2] == 0x01)
        #expect(framed[3] == 0x00)
    }
}

// MARK: - WireMessage Codec

@Suite("WireMessage Codec")
struct WireMessageCodecTests {

    private func makeIdentity() throws -> IdentityManager {
        let kc = KeychainManager(service: "test.wire.\(UUID().uuidString)")
        return try IdentityManager(keychain: kc)
    }

    @Test("Hello WireMessage encodes and decodes correctly")
    func helloRoundTrip() throws {
        let identity = try makeIdentity()
        let kc       = KeychainManager(service: "test.wire.pk.\(UUID().uuidString)")
        let preKeys  = try PreKeyManager(identity: identity, keychain: kc)
        let bundle   = try preKeys.generateBundle(tcpAddress: "127.0.0.1:25519")
        let hello    = HelloMessage(bundle: bundle)
        let builder  = WireMessageBuilder(identity: identity)
        let wire     = try builder.build(.hello, payload: hello)

        let data     = try JSONEncoder().encode(wire)
        let decoded  = try JSONDecoder().decode(WireMessage.self, from: data)

        #expect(decoded.type == .hello)
        #expect(decoded.senderID == identity.publicIdentity.peerID)

        let decodedHello = try builder.decodePayload(HelloMessage.self, from: decoded)
        #expect(decodedHello.bundle.username == identity.publicIdentity.username)
        #expect(decodedHello.bundle.tcpAddress == "127.0.0.1:25519")
    }

    @Test("WireMessage signature round-trip verifies correctly")
    func signatureVerifies() throws {
        let identity = try makeIdentity()
        let builder  = WireMessageBuilder(identity: identity)
        let kc       = KeychainManager(service: "test.wire.pk2.\(UUID().uuidString)")
        let preKeys  = try PreKeyManager(identity: identity, keychain: kc)
        let bundle   = try preKeys.generateBundle()
        let hello    = HelloMessage(bundle: bundle)
        let wire     = try builder.build(.hello, payload: hello)

        let isValid = try WireMessageBuilder.verify(wire, signingKeyPublic: identity.publicIdentity.signingKeyPublic)
        #expect(isValid, "Signature on self-generated message must verify")
    }

    @Test("Tampered payload fails signature verification")
    func tamperedPayloadFails() throws {
        let identity = try makeIdentity()
        let builder  = WireMessageBuilder(identity: identity)
        let kc       = KeychainManager(service: "test.wire.pk3.\(UUID().uuidString)")
        let preKeys  = try PreKeyManager(identity: identity, keychain: kc)
        let bundle   = try preKeys.generateBundle()
        let hello    = HelloMessage(bundle: bundle)
        var wire     = try builder.build(.hello, payload: hello)

        // Flip one bit in the payload
        var payload  = wire.payload
        payload[0]  ^= 0xFF
        wire = WireMessage(type: wire.type, payload: payload, senderID: wire.senderID,
                           timestamp: wire.timestamp, signature: wire.signature)

        let isValid = try WireMessageBuilder.verify(wire, signingKeyPublic: identity.publicIdentity.signingKeyPublic)
        #expect(!isValid, "Tampered payload must not verify")
    }
}

// MARK: - PreKeyBundle tcpAddress propagation

@Suite("PreKeyBundle TCP address")
struct PreKeyBundleTCPAddressTests {

    private func makeBundle(tcpAddress: String?) throws -> PreKeyBundle {
        let kc       = KeychainManager(service: "test.pkb.\(UUID().uuidString)")
        let identity = try IdentityManager(keychain: kc)
        let preKeys  = try PreKeyManager(identity: identity, keychain: kc)
        return try preKeys.generateBundle(tcpAddress: tcpAddress)
    }

    @Test("tcpAddress is nil when not provided")
    func nilTCPAddress() throws {
        let bundle = try makeBundle(tcpAddress: nil)
        #expect(bundle.tcpAddress == nil)
    }

    @Test("tcpAddress is preserved through bundle generation")
    func tcpAddressPreserved() throws {
        let addr   = "203.0.113.42:25519"
        let bundle = try makeBundle(tcpAddress: addr)
        #expect(bundle.tcpAddress == addr)
    }

    @Test("Tor .onion address is accepted as tcpAddress")
    func onionAddressAccepted() throws {
        let onion  = "abcdefghijklmnop.onion:25519"
        let bundle = try makeBundle(tcpAddress: onion)
        #expect(bundle.tcpAddress == onion)
    }

    @Test("PreKeyBundle encodes and decodes tcpAddress correctly")
    func bundleCodableWithTCPAddress() throws {
        let addr   = "198.51.100.1:25519"
        let bundle = try makeBundle(tcpAddress: addr)
        let data   = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(PreKeyBundle.self, from: data)
        #expect(decoded.tcpAddress == addr)
    }

    @Test("KnownPeer learns tcpAddress from PreKeyBundle")
    func knownPeerLearnsTCPAddress() throws {
        let addr   = "198.51.100.2:25519"
        let bundle = try makeBundle(tcpAddress: addr)
        let peer   = KnownPeer(from: bundle, safetyNumber: "test-sn")
        #expect(peer.tcpAddress == addr)
    }
}
