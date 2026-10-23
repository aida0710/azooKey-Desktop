import Foundation

func printJSON(_ value: Any) {
    do {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
    } catch {
        fputs("Cannot serialize smoke-test evidence: \(error)\n", stderr)
        exit(1)
    }
}
