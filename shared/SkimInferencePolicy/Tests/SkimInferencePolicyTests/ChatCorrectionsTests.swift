import Testing
@testable import SkimInferencePolicy

private let earlier: [String?] = [nil, "The excerpt covers SnapStart and Aurora DSQL [1]. It also mentions double NAT."]

@Test func chatCorrectionStrikesWrongWordsInEarlierReply() {
    let answer = "Yes, the 100x figure is from your quote.\n\n<correction><was>covers SnapStart and Aurora DSQL</was><now>does not cover SnapStart or Aurora DSQL</now></correction>"
    let result = ChatCorrections.apply(to: earlier, answer: answer)
    #expect(result.corrected == 1)
    #expect(result.earlier[1] == "The excerpt ~~covers SnapStart and Aurora DSQL~~ **[updated]:** does not cover SnapStart or Aurora DSQL [1]. It also mentions double NAT.")
    #expect(result.earlier[0] == nil)
    #expect(result.answer == "Yes, the 100x figure is from your quote.")
}

@Test func chatCorrectionMatchesAcrossSpacingAndCase() {
    let result = ChatCorrections.apply(to: earlier, answer: "<correction><was>also  mentions\ndouble nat</was><now>does not mention double NAT</now></correction>")
    #expect(result.earlier[1]?.contains("~~also mentions double NAT~~ **[updated]:** does not mention double NAT") == true)
    #expect(result.answer == ChatCorrections.onlyCorrectionsNote)
}

@Test func chatCorrectionThatMatchesNothingStaysInAnswer() {
    let result = ChatCorrections.apply(to: earlier, answer: "Here is more.\n<correction><was>never said this</was><now>right</now></correction>")
    #expect(result.corrected == 0)
    #expect(result.earlier == earlier)
    #expect(result.answer == "~~never said this~~ **[updated]:** right\n\nHere is more.")
}

@Test func chatAnswerWithoutCorrectionsIsUntouched() {
    let result = ChatCorrections.apply(to: earlier, answer: "Plain [2] answer.")
    #expect(result.answer == "Plain [2] answer.")
    #expect(result.corrected == 0)
}
