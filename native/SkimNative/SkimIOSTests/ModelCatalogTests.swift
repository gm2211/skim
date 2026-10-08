import Testing
import Foundation
import SkimCore
@testable import Skim

/// Pure-function coverage for `ModelCatalog` (skim-vexn): the shared model
/// resolution/apply logic behind every inline model picker surface. No
/// networking or MLXRunner state here — those paths are exercised by hand
/// against a device/simulator, not unit tested. One exception: unpinned MLX
/// resolution goes through `NativeMLX.effectiveDefaultRepoId`, which reads
/// this run's on-disk download state; `NativeMLX.effectiveDefaultRepoId(downloaded:)`
/// below is the pure, disk-independent variant used to cover its actual logic.
@Suite("ModelCatalog")
struct ModelCatalogTests {

    // MARK: - applying

    @Test func testApplyingMLXSetsBothLocalModelPathAndModel() {
        let base = AISettings(provider: "mlx", model: "mlx-community/gemma-3-1b-it-4bit")
        let next = ModelCatalog.applying("mlx-community/Qwen3-1.7B-4bit", to: base, forChat: false)
        #expect(next.localModelPath == "mlx-community/Qwen3-1.7B-4bit")
        #expect(next.model == "mlx-community/Qwen3-1.7B-4bit")
    }

    @Test func testApplyingNonMLXSetsModelOnly() {
        let base = AISettings(provider: "claude-subscription", model: "claude-sonnet-5")
        let next = ModelCatalog.applying("claude-opus-4-1", to: base, forChat: false)
        #expect(next.model == "claude-opus-4-1")
        #expect(next.localModelPath == nil)
    }

    @Test func testApplyingForChatClearsChatModelOverride() {
        var base = AISettings(provider: "claude-subscription", model: "claude-sonnet-5")
        base.chatModel = "claude-haiku-4-5"
        let next = ModelCatalog.applying("claude-opus-4-1", to: base, forChat: true)
        #expect(next.model == "claude-opus-4-1")
        #expect(next.chatModel == nil)
    }

    @Test func testApplyingNotForChatPreservesChatModelOverride() {
        var base = AISettings(provider: "claude-subscription", model: "claude-sonnet-5")
        base.chatModel = "claude-haiku-4-5"
        let next = ModelCatalog.applying("claude-opus-4-1", to: base, forChat: false)
        #expect(next.chatModel == "claude-haiku-4-5")
    }

    // MARK: - mlxChoices

    @Test func testMLXChoicesMarksAvailabilityFromDownloadedSet() {
        let downloaded: Set<String> = ["mlx-community/LFM2.5-1.2B-Instruct-4bit"]
        let choices = ModelCatalog.mlxChoices(downloaded: downloaded, current: "mlx-community/LFM2.5-1.2B-Instruct-4bit")
        let lfm = choices.first { $0.id == "mlx-community/LFM2.5-1.2B-Instruct-4bit" }
        let qwen = choices.first { $0.id == "mlx-community/Qwen3.5-2B-4bit" }
        #expect(lfm?.isAvailable == true)
        #expect(qwen?.isAvailable == false)
    }

    @Test func testMLXChoicesNamesRetiredModelInLegacyEntry() {
        let downloaded: Set<String> = ["mlx-community/gemma-3-1b-it-4bit"]
        let choices = ModelCatalog.mlxChoices(downloaded: downloaded, current: "mlx-community/gemma-3-1b-it-4bit")
        let gemma = choices.first { $0.id == "mlx-community/gemma-3-1b-it-4bit" }
        #expect(gemma?.label == "Gemma 3 1B (legacy)")
        #expect(gemma?.isAvailable == true)
    }

    @Test func testMLXChoicesAppendsLegacyEntryForUnknownCurrent() {
        let choices = ModelCatalog.mlxChoices(downloaded: [], current: "mlx-community/some-removed-model-4bit")
        let legacy = choices.first { $0.id == "mlx-community/some-removed-model-4bit" }
        #expect(legacy != nil)
        #expect(legacy?.label == "mlx-community/some-removed-model-4bit (legacy)")
        #expect(legacy?.isAvailable == false)
    }

    @Test func testMLXChoicesOmitsLegacyEntryWhenCurrentIsCataloged() {
        let choices = ModelCatalog.mlxChoices(downloaded: [], current: "mlx-community/Qwen3.5-2B-4bit")
        let legacyCount = choices.filter { $0.label.hasSuffix("(legacy)") }.count
        #expect(legacyCount == 0)
    }

    // MARK: - currentLabel / currentID

    @Test func testCurrentLabelFoundationModels() {
        let ai = AISettings(provider: "foundation-models")
        #expect(ModelCatalog.currentLabel(ai) == "Apple Intelligence")
    }

    @Test func testCurrentLabelMLXUsesShortCatalogName() {
        let ai = AISettings(provider: "mlx", model: "mlx-community/gemma-3-1b-it-4bit")
        #expect(ModelCatalog.currentLabel(ai) == "Gemma 3 1B")
    }

    @Test func testCurrentLabelMLXFallsBackToDefaultRepoWhenModelNil() {
        let ai = AISettings(provider: "mlx")
        #expect(ModelCatalog.currentID(ai) == NativeMLX.effectiveDefaultRepoId)
        #expect(ModelCatalog.currentLabel(ai) == NativeMLX.option(for: NativeMLX.effectiveDefaultRepoId).shortLabel)
    }

    @Test func testCurrentIDPinnedGemmaStaysGemmaRegardlessOfDefault() {
        // A pinned `settings.model`/`localModelPath` always wins over the
        // unpinned default, whatever NativeMLX.effectiveDefaultRepoId resolves to.
        let ai = AISettings(provider: "mlx", model: "mlx-community/gemma-3-1b-it-4bit")
        #expect(ModelCatalog.currentID(ai) == "mlx-community/gemma-3-1b-it-4bit")
    }

    // MARK: - NativeMLX.effectiveDefaultRepoId (pure, download-state driven)

    @Test func testEffectiveDefaultRepoIdNothingDownloadedUsesLFM25() {
        #expect(NativeMLX.effectiveDefaultRepoId(downloaded: []) == "mlx-community/LFM2.5-1.2B-Instruct-4bit")
    }

    @Test func testEffectiveDefaultRepoIdGemmaDownloadedOnlyStaysGemma() {
        // Existing installs must not be silently switched to a new download.
        let downloaded: Set<String> = ["mlx-community/gemma-3-1b-it-4bit"]
        #expect(NativeMLX.effectiveDefaultRepoId(downloaded: downloaded) == "mlx-community/gemma-3-1b-it-4bit")
    }

    @Test func testEffectiveDefaultRepoIdBothDownloadedIsQwen3() {
        let downloaded: Set<String> = ["mlx-community/gemma-3-1b-it-4bit", "mlx-community/Qwen3-1.7B-4bit"]
        #expect(NativeMLX.effectiveDefaultRepoId(downloaded: downloaded) == "mlx-community/Qwen3-1.7B-4bit")
    }

    @Test func testEffectiveDefaultRepoIdQwen3DownloadedOnlyIsQwen3() {
        let downloaded: Set<String> = ["mlx-community/Qwen3-1.7B-4bit"]
        #expect(NativeMLX.effectiveDefaultRepoId(downloaded: downloaded) == "mlx-community/Qwen3-1.7B-4bit")
    }

    @Test func testNewDefaultDownloadedTakesPrecedence() {
        let downloaded: Set<String> = ["mlx-community/Qwen3-1.7B-4bit", "mlx-community/LFM2.5-1.2B-Instruct-4bit"]
        #expect(NativeMLX.effectiveDefaultRepoId(downloaded: downloaded) == NativeMLX.defaultRepoId)
    }

    @Test func testUnpinnedExistingAlternativeNeedsNoNewDownload() {
        let repo = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        #expect(NativeMLX.effectiveDefaultRepoId(downloaded: [repo]) == repo)
    }

    @Test func testPhoneMemoryGatesLargerAlternatives() {
        let small = NativeMLX.offeredOptions(isPhone: true, memoryGB: 8)
        #expect(small.count == 2)
        #expect(small.allSatisfy { $0.isPhoneFriendly })
        let large = NativeMLX.offeredOptions(isPhone: true, memoryGB: 11.5)
        #expect(large.contains { $0.repoId == "mlx-community/Qwen3.5-4B-4bit" })
        #expect(large.contains { $0.repoId == "mlx-community/gemma-4-e2b-it-4bit" })
        #expect(!large.contains { $0.minMemoryGB >= 16 })
    }

    @Test func testMacMemoryGatesLargeModels() {
        let small = NativeMLX.offeredOptions(isPhone: false, memoryGB: 16)
        #expect(small.contains { $0.repoId == "mlx-community/Qwen3.5-9B-4bit" })
        #expect(!small.contains { $0.minMemoryGB >= 48 })
        let large = NativeMLX.offeredOptions(isPhone: false, memoryGB: 47.5)
        #expect(large.contains { $0.repoId == "mlx-community/Qwen3.8-27B-4bit" })
        #expect(large.contains { $0.repoId == "mlx-community/Qwen3.6-35B-A3B-4bit" })
    }

    @Test func testCurrentLabelRemoteProviderNilModelShowsDefaultPlaceholder() {
        let ai = AISettings(provider: "claude-subscription", model: nil)
        #expect(ModelCatalog.currentLabel(ai) == "Default model")
        #expect(ModelCatalog.currentID(ai) == nil)
    }

    @Test func testCurrentLabelRemoteProviderUsesStoredModel() {
        let ai = AISettings(provider: "openai", model: "gpt-4o-mini")
        #expect(ModelCatalog.currentLabel(ai) == "gpt-4o-mini")
        #expect(ModelCatalog.currentID(ai) == "gpt-4o-mini")
    }

    // MARK: - hasChatOverride

    @Test func testHasChatOverrideFalseByDefault() {
        let ai = AISettings(provider: "claude-subscription", model: "claude-sonnet-5")
        #expect(ModelCatalog.hasChatOverride(ai) == false)
    }

    @Test func testHasChatOverrideTrueWhenChatModelSet() {
        var ai = AISettings(provider: "claude-subscription", model: "claude-sonnet-5")
        ai.chatModel = "claude-haiku-4-5"
        #expect(ModelCatalog.hasChatOverride(ai) == true)
    }

    @Test func testHasChatOverrideTrueWhenChatProviderSetToDifferentProvider() {
        var ai = AISettings(provider: "claude-subscription", model: "claude-sonnet-5")
        ai.chatProvider = "mlx"
        #expect(ModelCatalog.hasChatOverride(ai) == true)
    }

    @Test func testHasChatOverrideFalseWhenChatProviderIsSame() {
        var ai = AISettings(provider: "claude-subscription", model: "claude-sonnet-5")
        ai.chatProvider = "same"
        #expect(ModelCatalog.hasChatOverride(ai) == false)
    }
}
