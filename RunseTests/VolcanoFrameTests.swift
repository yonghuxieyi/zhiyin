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
}
