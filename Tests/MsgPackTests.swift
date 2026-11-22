import XCTest
@testable import CoreV2

final class MsgPackTests: XCTestCase {
    func testRoundTrip() throws {
        let v: [String: Any] = ["set_module": [1, 0x05, 0x7f << 24], "s": "héllo", "neg": -200, "b": true, "n": NSNull(), "big": 70000]
        let d = MsgPack.encode(v)
        let back = try XCTUnwrap(try MsgPack.decode(d) as? [String: Any])
        XCTAssertEqual(back["set_module"] as? [Int], [1, 5, 0x7f << 24])
        XCTAssertEqual(back["s"] as? String, "héllo")
        XCTAssertEqual(back["neg"] as? Int, -200)
        XCTAssertEqual(back["big"] as? Int, 70000)
        XCTAssertEqual(back["b"] as? Bool, true)
        XCTAssertTrue(back["n"] is NSNull)
        // known encodings
        XCTAssertEqual(Array(MsgPack.encode(["get_check": true])), [0x81, 0xa9] + Array("get_check".utf8) + [0xc3])
        XCTAssertEqual(Array(MsgPack.encode(-1)), [0xff])
        XCTAssertEqual(Array(MsgPack.encode(255)), [0xcc, 0xff])
    }
}
