import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct BridgeRequest: Decodable {
    var operation: String
    var event: KeyEventCore?
    var index: Int?
    var node: Int?
    var generation: Int?
    var submit: Bool?
    var leftContext: String?
    var rightContext: String?
    var settings: DesktopSettings?
    var suggestions: [String]?
    var reading: String?
    var apiKey: String?
    var aiModel: String?
    var aiEndpoint: String?
    var includeContext: Bool?
    var prompt: String?
    var target: String?
    var privateInput: Bool?
    var context: String?
    var doubleTap: Bool?
    var reconversionContext: ReconversionContext?
    var reconversionToken: String?
    var items: [Config.UserDictionaryEntry]?
    var stagedSettingsPath: String?
    var importPath: String?
    var importFormat: UserDictionaryExchange.Format?
    var importEncoding: UserDictionaryExchange.TextEncoding?
}

@main
struct BridgeMain {
    @MainActor
    // The protocol router keeps every supported operation in one exhaustive switch.
    // swiftlint:disable:next cyclomatic_complexity
    static func main() async throws {
        // Keep converter debug output (which can contain typed text) out of both
        // the protocol and logs. The private pipe is the only output channel.
        let responseFD = dup(STDOUT_FILENO)
        guard responseFD >= 0 else {
            return
        }
        let output = FileHandle(fileDescriptor: responseFD, closeOnDealloc: true)
        let nullFD = open("/dev/null", O_WRONLY)
        guard nullFD >= 0 else {
            return
        }
        dup2(nullFD, STDOUT_FILENO)
        dup2(nullFD, STDERR_FILENO)
        close(nullFD)
        let environment = ProcessInfo.processInfo.environment
        if environment["AZOOKEY_BRIDGE_ROLE"] == "candidate" {
            try DesktopCandidateWorker.run(output: output, environment: environment)
            return
        }
        let dataPath = environment["AZOOKEY_DATA_DIR"] ??
            (environment["XDG_DATA_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path) + "/azookey-tree"
        let memoryDirectoryURL = URL(fileURLWithPath: dataPath, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        let resources = environment["AZOOKEY_RESOURCES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let zenzai = resources.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ggml-model-Q5_K_M.gguf").path) } ?? false
        let converter = KanaKanjiConverter.withDefaultDictionary()
        var sessions: [String: DesktopSession] = [:]
        defer { for session in sessions.values { session.close() } }
        while let line = readLine() {
            var response: DesktopSnapshot
            do {
                let request = try JSONDecoder().decode(BridgeRequest.self, from: Data(line.utf8))
                // Persist already permitted learning before another context or
                // preference can turn the shared converter's learning off.
                if request.privateInput == true || request.operation == "configure" {
                    converter.commitUpdateLearningData()
                }
                if let response = try await DesktopDictionaryController.response(
                    to: request, memoryDirectoryURL: memoryDirectoryURL, converter: converter
                ) {
                    try Self.write(response, to: output)
                    continue
                }
                let context = request.context ?? "default"
                let session: DesktopSession
                if let existing = sessions[context] {
                    session = existing
                } else {
                    session = try DesktopSession(dataDirectory: URL(fileURLWithPath: dataPath), resourcesDirectory: resources,
                                                 useZenzai: zenzai, converter: converter)
                    sessions[context] = session
                }
                session.privateInput = request.privateInput ?? false
                session.leftContext = String((request.leftContext ?? "").suffix(100))
                session.rightContext = String((request.rightContext ?? "").prefix(100))
                session.reconversionContext = request.reconversionContext
                switch request.operation {
                case "key":
                    guard let event = request.event else { throw ProtocolError.invalidRequest }
                    response = session.key(event, doubleTap: request.doubleTap ?? false)
                case "select":
                    guard let index = request.index, let generation = request.generation else { throw ProtocolError.invalidRequest }
                    response = session.select(candidateIndex: index, submit: request.submit ?? false, expectedGeneration: generation)
                case "node":
                    guard let node = request.node, let generation = request.generation else { throw ProtocolError.invalidRequest }
                    response = session.selectNode(node, submit: request.submit ?? false, expectedGeneration: generation)
                case "reset": response = session.reset(commit: request.submit ?? false)
                case "undo-commit": response = session.prepareReconversion(undo: true)
                case "reconvert": response = session.prepareReconversion(undo: false, reading: request.reading)
                case "reconversion-reading":
                    guard let event = request.event else { throw ProtocolError.invalidRequest }
                    response = session.editReconversionReading(event)
                case "confirm-reconversion":
                    guard let token = request.reconversionToken else { throw ProtocolError.invalidRequest }
                    response = session.confirmReconversion(token)
                case "snapshot": response = session.snapshot()
                case "configure":
                    guard let settings = request.settings else { throw ProtocolError.invalidRequest }
                    try await DesktopDictionaryController.applyDictionary(
                        settings.userDictionary.items, memoryDirectoryURL: memoryDirectoryURL, converter: converter
                    )
                    try settings.apply()
                    for item in sessions.values { try item.reloadSettings(rebuildDictionary: false) }
                    response = session.snapshot()
                case "close":
                    session.close()
                    sessions.removeValue(forKey: context)
                    response = DesktopSnapshot()
                case "download-typo-weights":
                    try await session.downloadTypoWeights()
                    response = DesktopSnapshot()
                case "reset-learning":
                    try session.resetLearning()
                    response = session.snapshot()
                case "suggestions":
                    guard let texts = request.suggestions, let generation = request.generation, let reading = request.reading else { throw ProtocolError.invalidRequest }
                    response = session.applySuggestions(texts, reading: reading, expectedGeneration: generation)
                case "ai":
                    guard !session.privateInput, let apiKey = request.apiKey, let target = request.target,
                          let model = request.aiModel, let endpoint = request.aiEndpoint else { throw ProtocolError.invalidRequest }
                    let scope = AIRequestScope(target: target, before: request.leftContext ?? "", after: request.rightContext ?? "",
                                               includeContext: request.includeContext ?? false)
                    let modelName = model.isEmpty ? Config.OpenAiModelName.default : model
                    response = DesktopSnapshot()
                    response.suggestions = try await OpenAIClient.sendRequest(
                        .init(prompt: scope.suggestionContext, target: target, modelName: modelName), apiKey: apiKey,
                        apiEndpoint: endpoint)
                case "transform":
                    guard !session.privateInput, let apiKey = request.apiKey, let prompt = request.prompt, let target = request.target,
                          let model = request.aiModel, let endpoint = request.aiEndpoint else { throw ProtocolError.invalidRequest }
                    let scope = AIRequestScope(target: target, before: request.leftContext ?? "", after: request.rightContext ?? "",
                                               includeContext: request.includeContext ?? false)
                    let modelName = model.isEmpty ? Config.OpenAiModelName.default : model
                    response = DesktopSnapshot()
                    response.suggestions = [try await OpenAIClient.sendTextTransformRequest(
                        prompt: scope.transformationPrompt(instructions: prompt), modelName: modelName,
                        apiKey: apiKey, apiEndpoint: endpoint)]
                default: throw ProtocolError.invalidRequest
                }
            } catch {
                response = DesktopSnapshot()
                response.consumed = false
                response.error = "invalid_request"
            }
            try Self.write(response, to: output)
        }
    }

    private static func write(_ response: DesktopSnapshot, to output: FileHandle) throws {
        var encoded = try JSONEncoder().encode(response)
        encoded.append(0x0a)
        try output.write(contentsOf: encoded)
    }
    enum ProtocolError: Error { case invalidRequest }
}
