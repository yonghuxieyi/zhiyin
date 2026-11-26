import RunseCore
import XCTest

/// Fixtures generated with the official Python protogen code
/// (`/tmp/ast-ref`, Good-Interpreter `ast_service_pb2`) on
/// 2026-11-25. The Swift encoder must reproduce the request bytes
/// exactly, and the decoder must read the response bytes exactly.
/// If a fixture and the Swift codec disagree, the fixture wins.
final class ASTProtoTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    private var fixtureSessionID: String { "11111111-2222-3333-4444-555555555555" }

    private func fixtureConfig() -> ASTSessionConfig {
        ASTSessionConfig(
            sessionID: fixtureSessionID,
            userID: "zhiyin-test",
            deviceID: "zhiyin-test",
            sdkVersion: "m3-test",
            mode: .s2s,
            sourceLanguage: .zh,
            targetLanguage: .en,
            glossary: [("智音", "Zhiyin"), ("人工智能", "artificial intelligence")]
        )
    }

    func testStartSessionMatchesPythonFixture() {
        let expected = data("0a26322431313131313131312d323232322d333333332d343434342d35353535353535353535353510641a280a0b7a686979696e2d74657374120b7a686979696e2d746573741a03694f5322076d332d74657374220c220377617638807d401048012a09220370636d38c0bb01324b0a0373327312027a681a02656ea2063b52100a06e699bae99fb312065a686979696e52270a0ce4babae5b7a5e699bae883bd12176172746966696369616c20696e74656c6c6967656e6365")
        XCTAssertEqual(ASTRequest.startSession(config: fixtureConfig()), expected)
    }

    func testTaskRequestMatchesPythonFixture() {
        let expected = data("0a26322431313131313131312d323232322d333333332d343434342d35353535353535353535353510c801220a72080102030405060708")
        let audio = Data([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(ASTRequest.taskRequest(sessionID: fixtureSessionID, audio: audio), expected)
    }

    func testFinishSessionMatchesPythonFixture() {
        let expected = data("0a26322431313131313131312d323232322d333333332d343434342d3535353535353535353535351066")
        XCTAssertEqual(ASTRequest.finishSession(sessionID: fixtureSessionID), expected)
    }

    func testUpdateConfigMatchesPythonFixture() {
        let expected = data("0a26322431313131313131312d323232322d333333332d343434342d35353535353535353535353510c901322b0a03733273a2062352210a0ce9878fe5ad90e8aea1e7ae9712117175616e74756d20636f6d707574696e67")
        XCTAssertEqual(
            ASTRequest.updateConfig(sessionID: fixtureSessionID, mode: .s2s, glossary: [("量子计算", "quantum computing")]),
            expected
        )
    }

    func testDecodeSessionStarted() {
        let bytes = data("0a2b0a2431313131313131312d323232322d333333332d343434342d3535353535353535353535351880dac409109601")
        guard let response = ASTResponse.decode(bytes) else { return XCTFail("decode failed") }
        XCTAssertEqual(response.event, .sessionStarted)
        XCTAssertEqual(response.sessionID, fixtureSessionID)
        XCTAssertEqual(response.statusCode, 20000000)
        XCTAssertFalse(response.isError)
    }

    func testDecodeSubtitleEvents() {
        let start = data("0a2b0a2431313131313131312d323232322d333333332d343434342d3535353535353535353535351880dac409108a052828")
        XCTAssertEqual(ASTResponse.decode(start)?.event, .sourceSubtitleStart)
        XCTAssertEqual(ASTResponse.decode(start)?.startTime, 40)

        let text = data("0a2b0a2431313131313131312d323232322d333333332d343434342d3535353535353535353535351880dac409108b052206e4bda0e5a5bd")
        XCTAssertEqual(ASTResponse.decode(text)?.event, .sourceSubtitleResponse)
        XCTAssertEqual(ASTResponse.decode(text)?.text, "你好")

        let end = data("0a2b0a2431313131313131312d323232322d333333332d343434342d3535353535353535353535351880dac409108c05220fe4bda0e5a5bdefbc8ce4b896e7958c282830b009")
        XCTAssertEqual(ASTResponse.decode(end)?.event, .sourceSubtitleEnd)
        XCTAssertEqual(ASTResponse.decode(end)?.text, "你好，世界")
        XCTAssertEqual(ASTResponse.decode(end)?.startTime, 40)
        XCTAssertEqual(ASTResponse.decode(end)?.endTime, 1200)

        let translated = data("0a2b0a2431313131313131312d323232322d333333332d343434342d3535353535353535353535351880dac409108f05220c48656c6c6f2c20776f726c6428c41330f41c")
        XCTAssertEqual(ASTResponse.decode(translated)?.event, .translationSubtitleEnd)
        XCTAssertEqual(ASTResponse.decode(translated)?.text, "Hello, world")
        XCTAssertEqual(ASTResponse.decode(translated)?.startTime, 2500)
        XCTAssertEqual(ASTResponse.decode(translated)?.endTime, 3700)
    }

    func testDecodeTTSResponse() {
        let bytes = data("0a2b0a2431313131313131312d323232322d333333332d343434342d3535353535353535353535351880dac40910e0021a080908070605040302")
        guard let response = ASTResponse.decode(bytes) else { return XCTFail("decode failed") }
        XCTAssertEqual(response.event, .ttsResponse)
        XCTAssertEqual(response.data, Data([9, 8, 7, 6, 5, 4, 3, 2]))
    }

    func testDecodeUsageResponse() {
        let bytes = data("0a82010a2431313131313131312d323232322d333333332d343434342d3535353535353535353535351880dac4092a550a190a12696e7075745f617564696f5f746f6b656e7315000048420a190a126f75747075745f746578745f746f6b656e7315000070410a1a0a136f75747075745f617564696f5f746f6b656e73150000304110d03e109a01")
        guard let response = ASTResponse.decode(bytes) else { return XCTFail("decode failed") }
        XCTAssertEqual(response.event, .usageResponse)
        XCTAssertEqual(response.billing?.durationMsec, 8016)
        let items = response.billing?.items ?? []
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].unit, "input_audio_tokens")
        XCTAssertEqual(items[0].quantity, 50, accuracy: 0.001)
        XCTAssertEqual(items[1].unit, "output_text_tokens")
        XCTAssertEqual(items[1].quantity, 15, accuracy: 0.001)
        XCTAssertEqual(items[2].unit, "output_audio_tokens")
        XCTAssertEqual(items[2].quantity, 11, accuracy: 0.001)
    }

    func testDecodeSpeakerChangeAndMuted() {
        let spk = data("0a2b0a2431313131313131312d323232322d333333332d343434342d3535353535353535353535351880dac409108a0528283801")
        XCTAssertEqual(ASTResponse.decode(spk)?.speakerChanged, true)

        let muted = data("0a2b0a2431313131313131312d323232322d333333332d343434342d3535353535353535353535351880dac40910fa0140c413")
        XCTAssertEqual(ASTResponse.decode(muted)?.event, .audioMuted)
        XCTAssertEqual(ASTResponse.decode(muted)?.mutedDurationMs, 2500)
    }

    func testDecodeFailedResponse() {
        let bytes = data("0a3b0a2431313131313131312d323232322d333333332d343434342d35353535353535353535353518c1caba15220e696e76616c696420706172616d73109901")
        guard let response = ASTResponse.decode(bytes) else { return XCTFail("decode failed") }
        XCTAssertEqual(response.event, .sessionFailed)
        XCTAssertEqual(response.statusCode, 45000001)
        XCTAssertEqual(response.message, "invalid params")
        XCTAssertTrue(response.isError)
    }

    func testDecodeGarbageReturnsNil() {
        XCTAssertNil(ASTResponse.decode(Data([0xFF, 0xFF, 0xFF])))
        XCTAssertNil(ASTResponse.decode(Data()))
    }

    /// N4: a length-delimited field whose varint length exceeds
    /// Int.max must throw instead of trapping on `Int(length)`.
    /// Field 1, wire type 2, then a 10-byte varint encoding
    /// UInt64.max as the length.
    func testDecodeHugeLengthThrowsInsteadOfTrapping() {
        var bytes: [UInt8] = [0x0A]
        var value = UInt64.max
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        XCTAssertThrowsError(try Protobuf.decode(Data(bytes)))
    }

    func testVarintRoundTrip() {
        for value: UInt64 in [0, 1, 127, 128, 300, 16000, 24000, 20000000, 45000001, UInt64.max] {
            guard let fields = try? Protobuf.decode(Protobuf.encodeVarintField(field: 2, value: value)) else {
                return XCTFail("decode failed for \(value)")
            }
            XCTAssertEqual(fields.varint(2), value)
        }
    }
}
