import XCTest
@testable import LGKit

final class MockTVTests: XCTestCase {
    func testVolumeAndLog() async throws {
        let tv = MockTV()
        try await tv.connect()
        try await tv.volumeUp()
        let v = try await tv.volume()
        XCTAssertEqual(v.volume, 4)
        XCTAssertTrue(tv.log.contains("connect"))
    }
    func testJSONRoundTrip() throws {
        let j: JSON = ["a": 1, "b": [true, "x"], "c": nil]
        XCTAssertEqual(try JSON.parse(j.data()), j)
    }
}
