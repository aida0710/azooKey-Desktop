@testable import Core
import Testing

struct CandidatePageTests {
    @Test func oneThreeSixAndFiveHundredCandidatesKeepRealIndicesInBoundedPages() {
        for count in [1, 3, 6, 500] {
            let entries = (0..<count).map {
                CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0)
            }
            for index in 0..<count {
                let page = CandidatePage(entries: entries, selectionIndex: index)
                #expect(page.totalCount == count)
                #expect(page.position == index + 1)
                #expect(page.items.count <= 9)
                #expect(page.items.contains { $0.index == index && $0.text == "候補\(index)" })
            }
            var visited: [Int] = []
            var index: Int? = 0
            while let selected = index {
                let page = CandidatePage(entries: entries, selectionIndex: selected)
                visited += page.items.map(\.index)
                index = page.nextIndex
            }
            #expect(visited == Array(0..<count))
            let wrapped = CandidatePage(entries: entries, selectionIndex: 0)
            #expect(wrapped.position == 1)
            #expect(wrapped.previousIndex == nil)
        }
    }

    @Test func numberKeyWindowAndSparseSourceIndicesArePreserved() {
        let entries = (0..<20).map {
            CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0 + 100)
        }
        let page = CandidatePage(entries: entries, selectionIndex: 112, pageStart: 4)
        #expect(page.start == 4)
        #expect(page.items.map(\.index) == Array(104...112))
        #expect(page.nextIndex == 113)
        #expect(page.previousIndex == 100)
        #expect(page.position == 13)
        let empty = CandidatePage(entries: [], selectionIndex: nil)
        #expect(empty.totalCount == 0)
        #expect(empty.items.isEmpty)
        #expect(empty.position == nil)
    }
}
