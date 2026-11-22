import XCTest
@testable import Knobtile

/// The 보조 디스플레이 stream: decoded the way the board's firmware does, it rebuilds the picture, and unchanged bands are not sent.
final class DisplayLinkTests: PluginCase {
    let W = DisplayLink.width, H = DisplayLink.height

    /// Mirror of feed() in Display/firmware/src/main.cpp.
    func apply(_ frames: [Data], to fb: inout [UInt16]) -> Int {
        let b = frames.flatMap { [UInt8]($0) }; var i = 0, bands = 0
        while i < b.count {
            XCTAssertEqual(b[i], UInt8(ascii: "K")); XCTAssertEqual(b[i + 1], UInt8(ascii: "T")); XCTAssertEqual(b[i + 2], 1)
            let y = Int(b[i + 3]) | Int(b[i + 4]) << 8, h = Int(b[i + 5]) | Int(b[i + 6]) << 8
            let len = Int(b[i + 7]) | Int(b[i + 8]) << 8 | Int(b[i + 9]) << 16 | Int(b[i + 10]) << 24
            i += 11
            var pos = y * W; let end = (y + h) * W
            for r in stride(from: i, to: i + len, by: 3) {
                for _ in 0..<Int(b[r]) where pos < end { fb[pos] = UInt16(b[r + 1]) | UInt16(b[r + 2]) << 8; pos += 1 }
            }
            XCTAssertEqual(pos, end)
            i += len; bands += 1
        }
        return bands
    }

    func testRoundTripAndDiff() {
        var img = (0..<(W * H)).map { UInt16(($0 / 300) % 7 == 0 ? $0 & 0xffff : 0x0841) } // long runs and noise
        var fb = [UInt16](repeating: 0, count: W * H)
        XCTAssertEqual(apply(DisplayLink.frames(img, since: []), to: &fb), H / DisplayLink.band)
        XCTAssertEqual(fb, img)
        XCTAssertTrue(DisplayLink.frames(img, since: img).isEmpty)
        let old = img
        img[W * 100 + 5] = 0xF800 // row 100: band 6 only
        XCTAssertEqual(apply(DisplayLink.frames(img, since: old), to: &fb), 1)
        XCTAssertEqual(fb, img)
    }
}
