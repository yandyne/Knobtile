import XCTest
@testable import Knobtile

final class JSONTests: XCTestCase {
    func testRoundTripAndLayoutFlatten() async throws {
        let j = JSON.parse(#"{"u":"CORE1","t":0,"i":255,"c":[{"u":"D1","t":2,"c":[]},null,{"u":"B1","t":33,"c":[]}]}"#)!
        XCTAssertEqual(j["c"][0]["u"].string, "D1")
        XCTAssertEqual(JSON.parse(#"{"a":0,"b":1,"c":true}"#)!.object.mapValues { $0.int }, ["a": 0, "b": 1, "c": nil]) // 0/1 must stay numbers
        XCTAssertEqual(JSON.parse(j.serialized()), j)
        let c = await MainActor.run { let s = ServiceClient(); s.layout = j; return s.modules() }
        XCTAssertEqual(c.map(\.uuid), ["CORE1::button1", "CORE1::button2", "D1", "B1"])
        XCTAssertEqual(c.map(\.type), ["button", "button", "dial", "button"]) // t & 0x1f
    }

    /// Real Condor layout captured from the service: Core (t=25) with a Dial3x (t=9) on port 2.
    func testCondorLayout() async {
        let j = JSON.parse(#"{"u":"?-L6z","i":0,"t":25,"c":[null,null,{"u":"?=hfL","i":1,"t":9,"c":[null,null,null,null,null]},null,null]}"#)!
        let c = await MainActor.run { let s = ServiceClient(); s.layout = j; return s.modules() }
        XCTAssertEqual(c.map(\.uuid), ["?-L6z::button1", "?-L6z::button2", "?=hfL::dial1", "?=hfL::dial2", "?=hfL::dial3"])
        XCTAssertEqual(c.map(\.type), ["button", "button", "dial", "dial", "dial"])
    }
}
