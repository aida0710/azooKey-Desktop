import Dispatch
import Foundation

private struct RecordedCandidate: Decodable {
    struct Token: Decodable { let text: String; let reading: String }
    let index: Int
    let text: String
    let tokens: [Token]
    let score: Double?
    let comparisonGroup: Int?
    let annotation: String?
    let commitScope: CandidateCommitScope?

    var entry: CandidateTree.Entry {
        .init(text: text, tokens: tokens.map { .init(text: $0.text, reading: $0.reading) }, candidateIndex: index,
              score: score, comparisonGroup: comparisonGroup, annotation: annotation, scope: commitScope)
    }
}

private struct RecordedConversion: Decodable {
    let name: String
    let stage: String
    let selection: Int
    let candidates: [RecordedCandidate]
}

private struct ProjectionTiming: Encodable {
    let name: String
    let stage: String
    let candidateCount: Int
    let iterations: Int
    let medianMicroseconds: Double
    let p95Microseconds: Double
    let checksum: Int
}

/// Replays only the pure tree projection; there is no converter or reanalysis.
@main
private struct CandidateTreeBenchmark {
    private enum ArgumentError: Error {
        case expectedRecordingPathAndAtLeast20Iterations
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let iterations = Int(CommandLine.arguments[2]), iterations >= 20 else {
            throw ArgumentError.expectedRecordingPathAndAtLeast20Iterations
        }
        let recordings = try JSONDecoder().decode([RecordedConversion].self,
                                                  from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let measurements = recordings.map { measure($0, iterations: iterations) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(measurements))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func measure(_ recording: RecordedConversion, iterations: Int) -> ProjectionTiming {
        let entries = recording.candidates.map(\.entry)
        // Warm allocator/code caches before collecting individual projections.
        let warmupCount = 10
        var samples: [Double] = []
        var checksum = 0
        for iteration in 0..<(iterations + warmupCount) {
            let start = DispatchTime.now().uptimeNanoseconds
            let tree = CandidateTree(entries: entries)
            let columns = tree.compactColumns(candidateIndex: recording.selection)
            checksum += tree.nodes.count + columns.count
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            if iteration >= warmupCount { samples.append(Double(elapsed) / 1_000) }
        }
        samples.sort()
        return .init(name: recording.name, stage: recording.stage, candidateCount: entries.count, iterations: iterations,
                     medianMicroseconds: samples[samples.count / 2],
                     p95Microseconds: samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))],
                     checksum: checksum)
    }
}
