import Foundation
import FoundationModels
import Hub
import MLX
import MLXLMCommon
import MLXLLM

struct Request: Decodable {
    let command: String
    let repoId: String?
    let system: String?
    let user: String?
    let maxTokens: Int?
    let jsonMode: Bool?
}

struct Availability: Codable {
    let available: Bool
    let status: String
    let message: String
}

struct Response: Encodable {
    let ok: Bool
    let value: String?
    let bool: Bool?
    let availability: Availability?
    let error: String?
}

func cacheDirectory(_ repoId: String) -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("huggingface/models/\(repoId)", isDirectory: true)
}

func validatedRepoId(_ value: String?) throws -> String {
    guard let value, !value.isEmpty else { throw NSError(domain: "SkimAI", code: 10, userInfo: [NSLocalizedDescriptionKey: "A model repository ID is required."]) }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard parts.count == 2, parts.allSatisfy({ part in
        part != "." && part != ".." && !part.isEmpty && part.unicodeScalars.allSatisfy(allowed.contains)
    }) else { throw NSError(domain: "SkimAI", code: 11, userInfo: [NSLocalizedDescriptionKey: "Invalid model repository ID. Expected publisher/model."]) }
    return value
}

func isDownloaded(_ repoId: String) -> Bool {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory(repoId).path)) ?? []
    return files.contains("config.json") && files.contains(where: { $0.hasSuffix(".safetensors") })
}

@available(macOS 26.0, *)
func foundationAvailability() -> Availability {
    switch SystemLanguageModel.default.availability {
    case .available:
        return Availability(available: true, status: "available", message: "Apple Intelligence is enabled and the on-device Foundation Model is ready.")
    case .unavailable(let reason):
        switch reason {
        case .deviceNotEligible: return Availability(available: false, status: "device-not-eligible", message: "This Mac is not eligible for Apple Intelligence Foundation Models.")
        case .appleIntelligenceNotEnabled: return Availability(available: false, status: "apple-intelligence-disabled", message: "Apple Intelligence is off. Enable it in System Settings, then relaunch Skim.")
        case .modelNotReady: return Availability(available: false, status: "model-not-ready", message: "The on-device Foundation Model is still downloading or preparing.")
        @unknown default: return Availability(available: false, status: "unknown-unavailable", message: "Foundation Models are unavailable for an unknown system reason.")
        }
    @unknown default: return Availability(available: false, status: "unknown", message: "Foundation Models returned an unknown availability state.")
    }
}

func emit(_ response: Response) {
    let data = try! JSONEncoder().encode(response)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

func emitProgress(_ fraction: Double) {
    let data = try! JSONSerialization.data(withJSONObject: ["progress": fraction])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

actor MLXWorker {
    private var repoId: String?
    private var container: ModelContainer?

    func complete(_ request: Request) async throws -> String {
      let repo = try validatedRepoId(request.repoId ?? "mlx-community/gemma-3-1b-it-4bit")
      guard isDownloaded(repo) else { throw NSError(domain: "SkimAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model \(repo) is not downloaded."]) }
      if container == nil || repoId != repo {
        // Directory-backed configurations avoid network access, but they also
        // bypass LLMRegistry metadata. Restore Gemma's turn terminator so
        // generation stops before decoding and continuing past the answer.
        let extraEOSTokens: Set<String> = repo.lowercased().contains("gemma") ? ["<end_of_turn>"] : []
        let configuration = ModelConfiguration(
            directory: cacheDirectory(repo),
            extraEOSTokens: extraEOSTokens
        )
        container = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { emitProgress($0.fractionCompleted) }
        repoId = repo
      }
      let container = container!
    let system = (request.system ?? "") + ((request.jsonMode ?? false) ? "\n\nRespond with a single JSON object. No prose, no code fences." : "")
    let input = UserInput(messages: [["role": "system", "content": system], ["role": "user", "content": request.user ?? ""]])
      return try await container.perform { context in
        let prepared = try await context.processor.prepare(input: input)
        let result = try MLXLMCommon.generate(input: prepared, parameters: GenerateParameters(temperature: 0.3), context: context) { tokens in
            tokens.count >= (request.maxTokens ?? 512) ? .stop : .more
        }
        return result.output
      }
    }

    func evict(_ repo: String) {
      if repoId == repo { container = nil; repoId = nil }
    }
}

let mlxWorker = MLXWorker()

func process(_ request: Request) async {
    do {
        switch request.command {
        case "mlx_available": emit(Response(ok: true, value: nil, bool: true, availability: nil, error: nil))
        case "mlx_downloaded": emit(Response(ok: true, value: nil, bool: isDownloaded(try validatedRepoId(request.repoId)), availability: nil, error: nil))
        case "mlx_delete":
            let repo = try validatedRepoId(request.repoId)
            try FileManager.default.removeItem(at: cacheDirectory(repo)); await mlxWorker.evict(repo)
            emit(Response(ok: true, value: nil, bool: nil, availability: nil, error: nil))
        case "mlx_download":
            let repo = try validatedRepoId(request.repoId)
            _ = try await MLXLMCommon.downloadModel(hub: HubApi(), configuration: ModelConfiguration(id: repo)) { emitProgress($0.fractionCompleted) }
            emit(Response(ok: true, value: nil, bool: nil, availability: nil, error: nil))
        case "mlx_complete": emit(Response(ok: true, value: try await mlxWorker.complete(request), bool: nil, availability: nil, error: nil))
        case "fm_availability":
            if #available(macOS 26.0, *) { emit(Response(ok: true, value: nil, bool: nil, availability: foundationAvailability(), error: nil)) }
            else { emit(Response(ok: true, value: nil, bool: nil, availability: Availability(available: false, status: "unsupported-os", message: "Apple Foundation Models require macOS 26 or later."), error: nil)) }
        case "fm_complete":
            guard #available(macOS 26.0, *) else { throw NSError(domain: "SkimAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple Foundation Models require macOS 26 or later."]) }
            let availability = foundationAvailability()
            guard availability.available else { throw NSError(domain: "SkimAI", code: 3, userInfo: [NSLocalizedDescriptionKey: availability.message]) }
            let instructions = (request.system ?? "") + ((request.jsonMode ?? false) ? "\n\nRespond with a single valid JSON object. No prose, no markdown fences." : "")
            let session = LanguageModelSession(instructions: instructions)
            let text = try await session.respond(to: request.user ?? "", options: GenerationOptions(maximumResponseTokens: request.maxTokens ?? 512)).content
            emit(Response(ok: true, value: text, bool: nil, availability: nil, error: nil))
        default: throw NSError(domain: "SkimAI", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown command"])
        }
    } catch { emit(Response(ok: false, value: nil, bool: nil, availability: nil, error: error.localizedDescription)) }
}

Task {
    while let line = readLine() {
        guard let data = line.data(using: .utf8), let request = try? JSONDecoder().decode(Request.self, from: data) else {
            emit(Response(ok: false, value: nil, bool: nil, availability: nil, error: "Invalid bridge request")); continue
        }
        await process(request)
    }
    exit(0)
}
dispatchMain()
