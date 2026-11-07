import ProxyModel
import Testing
@testable import Viewing

@Suite struct TextDiffTests {
    @Test func unifiedLineDiff() {
        let (lines, truncated) = TextDiff.lines("a\nb\nc\nd", "a\nB\nc\nd\ne")
        #expect(!truncated)
        #expect(lines == [
            DiffLine(.same, "a"), DiffLine(.removed, "b"), DiffLine(.added, "B"),
            DiffLine(.same, "c"), DiffLine(.same, "d"), DiffLine(.added, "e"),
        ])
    }

    @Test func identicalAndEmpty() {
        #expect(TextDiff.lines("x", "x").lines == [DiffLine(.same, "x")])
        #expect(TextDiff.lines("", "y").lines == [DiffLine(.removed, ""), DiffLine(.added, "y")])
    }

    @Test func cutsLongInputs() {
        let long = Array(repeating: "z", count: TextDiff.maxLines + 5).joined(separator: "\n")
        let (lines, truncated) = TextDiff.lines(long, long)
        #expect(truncated)
        #expect(lines.count == TextDiff.maxLines)
    }

    @Test func headerChanges() {
        let a = [HeaderField(name: "Accept", value: "*/*"), HeaderField(name: "X-A", value: "1"), HeaderField(name: "x-a", value: "2"),
                 HeaderField(name: "Gone", value: "g")]
        let b = [HeaderField(name: "accept", value: "*/*"), HeaderField(name: "X-A", value: "1, 3"), HeaderField(name: "New", value: "n")]
        #expect(TextDiff.headers(a, b) == [
            .same(name: "Accept", value: "*/*"), .changed(name: "X-A", old: "1, 2", new: "1, 3"),
            .removed(name: "Gone", value: "g"), .added(name: "New", value: "n"),
        ])
    }
}
