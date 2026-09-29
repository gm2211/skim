import Testing
@testable import SkimInferencePolicy

@Test func chatAnswerCleanupStripsRealBuggyReply() {
    // The actual reply from bd skim-p9ol: preamble + bold "Summary:" header
    // in front of a vague, question-ignoring answer.
    let text = "Okay, here's my response:\n\n**Summary:**\n\n3D-printed materials are increasingly being explored utilizing biological components as the primary feedstock."
    let cleaned = ChatAnswerCleanup.clean(text, question: "Making nozzles out of dead things?")
    #expect(cleaned == "3D-printed materials are increasingly being explored utilizing biological components as the primary feedstock.")
}

@Test func chatAnswerCleanupStripsBareOpenerOnSameLine() {
    let cleaned = ChatAnswerCleanup.clean("Sure! The nozzle was 3D-printed from a resin mold.", question: "How was the nozzle made?")
    #expect(cleaned == "The nozzle was 3D-printed from a resin mold.")
}

@Test func chatAnswerCleanupKeepsSummaryHeaderWhenQuestionAsksForOne() {
    let text = "**Summary:**\n\nThe article explains how the mosquito proboscis was used as a nozzle."
    let cleaned = ChatAnswerCleanup.clean(text, question: "Summarize it")
    #expect(cleaned == text)
}

@Test func chatAnswerCleanupAlwaysStripsAnswerHeaderEvenForSummaryQuestion() {
    let text = "**Answer:**\n\nThe mosquito proboscis was used as a 3D-printing nozzle."
    let cleaned = ChatAnswerCleanup.clean(text, question: "Summarize it")
    #expect(cleaned == "The mosquito proboscis was used as a 3D-printing nozzle.")
}

@Test func chatAnswerCleanupRemovesTrailingSignOff() {
    let text = "The nozzle was made from a dead mosquito's proboscis.\n\nLet me know if you have more questions!"
    let cleaned = ChatAnswerCleanup.clean(text, question: "How was the nozzle made?")
    #expect(cleaned == "The nozzle was made from a dead mosquito's proboscis.")
}

@Test func chatAnswerCleanupLeavesLookalikeTextUnchanged() {
    let text = "Okay-rated hotels near the airport include three budget chains."
    #expect(ChatAnswerCleanup.clean(text, question: "Which hotels are okay?") == text)
}

@Test func chatAnswerCleanupPreservesMidTextBold() {
    let text = "The article says the team used **recycled** plastic for the build."
    #expect(ChatAnswerCleanup.clean(text, question: "What material was used?") == text)
}

@Test func chatAnswerCleanupReturnsOriginalWhenOnlyPreambleRemains() {
    let text = "Okay, here's my response:"
    #expect(ChatAnswerCleanup.clean(text, question: "What happened?") == text)
}

@Test func chatAnswerCleanupHandlesCurlyApostrophe() {
    let text = "Okay, here\u{2019}s my response:\n\nThe nozzle was 3D-printed."
    let cleaned = ChatAnswerCleanup.clean(text, question: "How was the nozzle made?")
    #expect(cleaned == "The nozzle was 3D-printed.")
}

@Test func chatAnswerCleanupStripsHereIsMySummaryVariant() {
    let text = "Here's my summary of what happened: the nozzle was 3D-printed from resin."
    let cleaned = ChatAnswerCleanup.clean(text, question: "What material?")
    #expect(cleaned == "the nozzle was 3D-printed from resin.")
}
