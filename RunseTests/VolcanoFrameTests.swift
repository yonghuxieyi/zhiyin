import RunseCore
import XCTest

final class VolcanoFrameTests: XCTestCase {
    func testEncodeDecodeJSONFrameRoundTrip() {
        let payload = Data(#"{"hello":"world"}"#.utf8)
        let encoded = VolcanoFrame.encode(type: VolcanoFrame.fullClientRequest, flags: 0, jsonPayload: payload)
        // 0x11 header, type 0x1, JSON serialization, 4-byte size + payload.
        XCTAssertEqual(encoded[0], 0x11)
        XCTAssertEqual(encoded[1], 0x10)
        XCTAssertEqual(encoded[2], 0x10)
        guard let decoded = VolcanoFrame.decodeFirst(from: encoded) else {
            return XCTFail("frame did not decode")
        }
        XCTAssertEqual(decoded.frame.type, VolcanoFrame.fullClientRequest)
        XCTAssertEqual(decoded.frame.isJSON, true)
        XCTAssertEqual(decoded.frame.payload, payload)
        XCTAssertEqual(decoded.consumed, encoded.count)
    }

    func testEncodeDecodeRawAudioFrame() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let encoded = VolcanoFrame.encode(type: VolcanoFrame.audioOnlyRequest, flags: 0, jsonPayload: nil, rawPayload: pcm)
        XCTAssertEqual(encoded[1], 0x20)
        XCTAssertEqual(encoded[2], 0x00)
        guard let decoded = VolcanoFrame.decodeFirst(from: encoded) else {
            return XCTFail("frame did not decode")
        }
        XCTAssertEqual(decoded.frame.isJSON, false)
        XCTAssertEqual(decoded.frame.payload, pcm)
    }

    func testDecodeWaitsForCompleteFrame() {
        let payload = Data(#"{"a":1}"#.utf8)
        let encoded = VolcanoFrame.encode(type: VolcanoFrame.fullServerResponse, flags: 0, jsonPayload: payload)
        XCTAssertNil(VolcanoFrame.decodeFirst(from: encoded.prefix(6)))
        XCTAssertNotNil(VolcanoFrame.decodeFirst(from: encoded))
    }

    func testDecodeTwoFramesInOneBuffer() {
        let first = VolcanoFrame.encode(type: VolcanoFrame.fullServerResponse, flags: 0, jsonPayload: Data(#"{"a":1}"#.utf8))
        let second = VolcanoFrame.encode(type: VolcanoFrame.fullServerResponse, flags: 0, jsonPayload: Data(#"{"b":2}"#.utf8))
        var buffer = Data()
        buffer.append(first)
        buffer.append(second)
        guard let decoded = VolcanoFrame.decodeFirst(from: buffer) else {
            return XCTFail("first frame did not decode")
        }
        let rest = buffer.dropFirst(decoded.consumed)
        XCTAssertNotNil(VolcanoFrame.decodeFirst(from: Data(rest)))
    }

    func testEventFrameCarriesEventNumber() {
        let payload = Data(#"{}"#.utf8)
        let encoded = VolcanoFrame.encode(type: 0x1, flags: 0x4, jsonPayload: payload, event: 100)
        XCTAssertEqual(encoded[0], 0x12)
        guard let decoded = VolcanoFrame.decodeFirst(from: encoded) else {
            return XCTFail("frame did not decode")
        }
        XCTAssertEqual(decoded.frame.event, 100)
    }

    /// Server result frames on bigmodel_async carry a 4-byte
    /// big-endian sequence number after the header when flags bit
    /// 0x1 is set (captured live 2026-11-25). The decoder must skip
    /// it and read the size from the right offset, or it desyncs.
    func testDecodeSequencedServerFrame() {
        let payload = Data(#"{"result":{"text":"你好"}}"#.utf8)
        var frame = Data([0x11, 0x91, 0x10, 0x00])
        var sequence = UInt32(1).bigEndian
        frame.append(Data(bytes: &sequence, count: 4))
        var size = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &size, count: 4))
        frame.append(payload)
        guard let decoded = VolcanoFrame.decodeFirst(from: frame) else {
            return XCTFail("sequenced frame did not decode")
        }
        XCTAssertEqual(decoded.frame.type, 0x9)
        XCTAssertEqual(decoded.frame.sequence, 1)
        XCTAssertEqual(decoded.frame.payload, payload)
        XCTAssertEqual(decoded.consumed, frame.count)
    }

    func testDecodeMixedAckAndSequencedFrames() {
        // Session ack: no sequence (flags 0). Then a sequenced result.
        let ack = VolcanoFrame.encode(type: VolcanoFrame.fullServerResponse, flags: 0, jsonPayload: Data(#"{"result":{"additions":{"log_id":"x"}}}"#.utf8))
        let payload = Data(#"{"result":{"text":"欢迎"}}"#.utf8)
        var sequenced = Data([0x11, 0x91, 0x10, 0x00])
        var sequence = UInt32(2).bigEndian
        sequenced.append(Data(bytes: &sequence, count: 4))
        var size = UInt32(payload.count).bigEndian
        sequenced.append(Data(bytes: &size, count: 4))
        sequenced.append(payload)
        var buffer = Data()
        buffer.append(ack)
        buffer.append(sequenced)
        guard let first = VolcanoFrame.decodeFirst(from: buffer) else {
            return XCTFail("ack did not decode")
        }
        XCTAssertNil(first.frame.sequence)
        let rest = buffer.dropFirst(first.consumed)
        guard let second = VolcanoFrame.decodeFirst(from: Data(rest)) else {
            return XCTFail("sequenced frame did not decode")
        }
        XCTAssertEqual(second.frame.sequence, 2)
        XCTAssertEqual(second.frame.payload, payload)
    }
}
