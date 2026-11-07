import ProxyModel
import Storage
import Testing

@Suite struct FilterChipTests {
    @Test func defaultFilterShowsOnlyQuickChips() {
        #expect(FlowFilter().chips == FilterChip.quick)
        #expect(FilterChip.quick.map(\.title) == ["4xx", "5xx", "Failed", "JSON", "POST", "Highlighted"])
    }

    @Test func activeConditionsComeFirst() {
        var f = FlowFilter()
        f.methods = ["PUT", "POST"]
        f.statusClasses = [.success]
        f.contentTypes = [.image]
        f.showPinned = true
        #expect(f.chips == [.pinned, .method("PUT"), .status(.success), .content(.image)] + FilterChip.quick)
    }

    @Test func kindChipsShowDifferencesFromTheDefault() {
        var f = FlowFilter()
        f.kinds = [.https, .dns]
        let chips = f.chips
        #expect(Array(chips.prefix(2)) == [.kind(.http), .kind(.dns)])
        #expect(FilterChip.kind(.http).isOn(in: f) == false)
        #expect(FilterChip.kind(.dns).isOn(in: f))
        FilterChip.kind(.http).toggle(in: &f)
        FilterChip.kind(.dns).toggle(in: &f)
        #expect(f.kinds == [.http, .https])
        #expect(f.chips == FilterChip.quick)
    }

    @Test func toggleFlipsOnlyThatCondition() {
        var f = FlowFilter()
        FilterChip.status(.clientError).toggle(in: &f)
        FilterChip.marked.toggle(in: &f)
        FilterChip.method("POST").toggle(in: &f)
        #expect(f.statusClasses == [.clientError])
        #expect(f.markedOnly)
        #expect(f.methods == ["POST"])
        #expect(f.chips == FilterChip.quick)
        FilterChip.status(.clientError).toggle(in: &f)
        #expect(f.statusClasses.isEmpty)
        #expect(FilterChip.marked.isOn(in: f))
    }
}
