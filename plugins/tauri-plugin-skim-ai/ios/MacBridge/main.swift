import Foundation
import SkimInferencePolicy
import FoundationModels
import SkimMLXEngine

struct Request: Decodable {
    let command: String
    let repoId: String?
    let system: String?
    let user: String?
    let messages: [LocalChatMessage]?
    let maxTokens: Int?
    let temperature: Float?
    let topP: Float?
    let repetitionPenalty: Float?
    let jsonMode: Bool?
    /// Text ending the prompt part the next request will repeat; its model
    /// state is kept so that request skips the prefill. Absent: no reuse.
    let reusablePrefixMarker: String?
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
    /// Speed and memory for an `mlx_complete`, for the eval tool. The app ignores it.
    var metrics: SkimGenerationMetrics? = nil
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
        && ModelChatTemplate.isUsable(in: cacheDirectory(repoId))
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
    private var model: SkimMLXModel?

    /// Macs have the memory for long prompts; this only stops a runaway one.
    private static let maxPromptTokens = 32_768

    func complete(_ request: Request) async throws -> SkimGeneration {
      let repo = try validatedRepoId(request.repoId ?? "mlx-community/Qwen3.5-4B-4bit")
      guard ModelChatTemplate.isUsable(in: cacheDirectory(repo)) else {
          throw NSError(domain: "SkimAI", code: 12, userInfo: [NSLocalizedDescriptionKey: "Model chat template missing or invalid — re-download this model."])
      }
      guard isDownloaded(repo) else { throw NSError(domain: "SkimAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model \(repo) is not downloaded."]) }
      if model == nil || repoId != repo {
        model = nil
        model = try await SkimMLXModel.load(directory: cacheDirectory(repo), family: MLXModelFamily.detect(from: repo))
        repoId = repo
      }
      let model = model!
      let preset = MLXSamplingPreset.preset(for: repo)
      let sampling = SkimSampling(
          maxTokens: request.maxTokens ?? 512,
          temperature: request.temperature ?? preset.temperature,
          topP: request.topP ?? preset.topP,
          repetitionPenalty: request.repetitionPenalty ?? preset.repetitionPenalty,
          repetitionContextSize: preset.repetitionContextSize
      )
      let messages = LocalChatMessages.prepare(messages: request.messages, system: request.system ?? "", user: request.user ?? "", jsonMode: request.jsonMode ?? false)
      let result = try await model.generate(
          messages: messages,
          sampling: sampling,
          reusablePrefixMarker: request.reusablePrefixMarker,
          maxPromptTokens: Self.maxPromptTokens
      )
      return SkimGeneration(text: LocalModelOutput.sanitize(result.text, family: model.family), metrics: result.metrics)
    }

    func evict(_ repo: String) {
      if repoId == repo { model = nil; repoId = nil }
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
            try Task.checkCancellation()
            _ = try await SkimHubDownloader(useBackgroundSession: false).downloadModel(repoId: repo) { emitProgress($0.fractionCompleted) }
            try Task.checkCancellation()
            guard ModelChatTemplate.isUsable(in: cacheDirectory(repo)) else {
                throw NSError(domain: "SkimAI", code: 12, userInfo: [NSLocalizedDescriptionKey: "Model chat template missing or invalid — re-download this model."])
            }
            await mlxWorker.evict(repo)
            emit(Response(ok: true, value: nil, bool: nil, availability: nil, error: nil))
        case "mlx_complete":
            let result = try await mlxWorker.complete(request)
            emit(Response(ok: true, value: result.text, bool: nil, availability: nil, error: nil, metrics: result.metrics))
        case "fm_availability":
            if #available(macOS 26.0, *) { emit(Response(ok: true, value: nil, bool: nil, availability: foundationAvailability(), error: nil)) }
            else { emit(Response(ok: true, value: nil, bool: nil, availability: Availability(available: false, status: "unsupported-os", message: "Apple Foundation Models require macOS 26 or later."), error: nil)) }
        case "fm_complete":
            guard #available(macOS 26.0, *) else { throw NSError(domain: "SkimAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple Foundation Models require macOS 26 or later."]) }
            let availability = foundationAvailability()
            guard availability.available else { throw NSError(domain: "SkimAI", code: 3, userInfo: [NSLocalizedDescriptionKey: availability.message]) }
            let instructions = (request.system ?? "") + ((request.jsonMode ?? false) ? "\n\nRespond with a single valid JSON object. No prose, no markdown fences." : "")
            let prepared = try FoundationChatMessages.prepare(instructions: instructions, messages: request.messages, user: request.user ?? "")
            let session = LanguageModelSession(transcript: prepared.transcript)
            let options: GenerationOptions
            if let temperature = request.temperature {
                options = GenerationOptions(sampling: temperature == 0 ? .greedy : .random(top: 50),
                    temperature: Double(temperature), maximumResponseTokens: request.maxTokens ?? 512)
            } else {
                options = GenerationOptions(maximumResponseTokens: request.maxTokens ?? 512)
            }
            let text = try await session.respond(to: prepared.prompt, options: options).content
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
