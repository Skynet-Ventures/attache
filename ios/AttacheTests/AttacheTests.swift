import Foundation
import Testing
@testable import Attache

struct ThinkingLevelTests {
    @Test func cycleWraps() {
        #expect(ThinkingLevel.minimal.next == .low)
        #expect(ThinkingLevel.max.next == .minimal)
        #expect(ThinkingLevel.off.next == .minimal)
    }
}

struct SessionSummaryTests {
    @Test func ageLabels() {
        let now = SessionSummary(
            id: "1", title: "t", project: "p", cwd: "/", sessionPath: "",
            updatedAt: .now, live: false, status: .idle, shortId: "#1"
        )
        #expect(now.ageLabel == "now")
        var older = now
        older.updatedAt = .now.addingTimeInterval(-3 * 3600)
        #expect(older.ageLabel == "3h")
        older.updatedAt = .now.addingTimeInterval(-2 * 86_400)
        #expect(older.ageLabel == "2d")
    }
}

struct JSONValueTests {
    @Test func decodesNested() throws {
        let data = Data(#"{"a":{"b":[1,"x",true]},"n":null}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["a"]?["b"]?.arrayValue?.count == 3)
        #expect(value["a"]?["b"]?.arrayValue?.first?.intValue == 1)
        #expect(value["n"] == .null)
    }
}
