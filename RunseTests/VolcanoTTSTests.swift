import RunseCore
import XCTest

/// Response shapes verified live 2026-11-25 against the V3 async API.
final class VolcanoTTSTests: XCTestCase {
    func testParseSubmitResponseFindsTaskIDUnderData() throws {
        let data = """
        {"code": 20000000, "data": {"task_id": "task-123", "task_status": 1}}
        """.data(using: .utf8)!
        XCTAssertEqual(try VolcanoTTSClient.parseSubmitResponse(data), "task-123")
    }

    func testParseSubmitResponseRejectsErrorCode() {
        let data = """
        {"code": 40000001, "data": {"task_id": "task-123", "task_status": 1}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try VolcanoTTSClient.parseSubmitResponse(data))
    }

    func testParseQueryResponseRunning() throws {
        let data = """
        {"code": 20000000, "data": {"task_status": 1}}
        """.data(using: .utf8)!
        let (status, audioURL) = try VolcanoTTSClient.parseQueryResponse(data)
        XCTAssertEqual(status, 1)
        XCTAssertNil(audioURL)
    }

    func testParseQueryResponseSuccessHasAudioURL() throws {
        let data = """
        {"code": 20000000, "data": {"task_status": 2, "audio_url": "https://example.com/a.mp3?sig=abc"}}
        """.data(using: .utf8)!
        let (status, audioURL) = try VolcanoTTSClient.parseQueryResponse(data)
        XCTAssertEqual(status, 2)
        XCTAssertEqual(audioURL, "https://example.com/a.mp3?sig=abc")
    }

    func testParseQueryResponseFailed() throws {
        let data = """
        {"code": 20000000, "data": {"task_status": 3}}
        """.data(using: .utf8)!
        let (status, _) = try VolcanoTTSClient.parseQueryResponse(data)
        XCTAssertEqual(status, 3)
    }
}
