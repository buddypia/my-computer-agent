import MCACore
import Testing

@Suite("Observed feed evidence")
struct ObservedFeedPostTests {
    @Test("View notation requires an explicit metric label")
    func notation() {
        #expect(ObservedFeedPost.parseViews("5K views") == 5_000)
        #expect(ObservedFeedPost.parseViews("4,999 views") == 4_999)
        #expect(ObservedFeedPost.parseViews("1.2万 ビュー") == 12_000)
        #expect(ObservedFeedPost.parseViews("1M views") == 1_000_000)
        #expect(ObservedFeedPost.parseViews("5K likes") == nil)
        #expect(ObservedFeedPost.parseViews("5K") == nil)
        #expect(ObservedFeedPost.parseViews("I got 5K views yesterday") == nil)
    }
    @Test("Equal metrics on different posts survive, overlap deduplicates by author and body")
    func overlap() {
        let first = "@alice\nFirst post\n5K views\n@low\nBelow threshold\n4,999 views"
        let second = "@alice\nFirst post\n5K views\n@bob\nSecond post\n5K views"
        let records = ObservedFeedPost.extract(viewports: [first, second], minimumViews: 5_000)
        #expect(records.map(\.author) == ["@alice", "@bob"])
        #expect(records[0].viewports == [0, 1])
        #expect(records[1].views == 5_000)
        #expect(records.allSatisfy { $0.url == nil })
    }
    @Test("Missing or ambiguous evidence never becomes a qualifying post")
    func uncertainty() {
        #expect(ObservedFeedPost.extract(viewports: ["@alice\nBody\n5K", "@bob\nBody\n5K views\n8K views", "5K views"], minimumViews: 5_000).isEmpty)
    }
}
