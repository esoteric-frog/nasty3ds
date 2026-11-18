import Testing
@testable import Nasty3DSKit

@Test func theScreensShareOneWindowByDefault() {
    #expect(ScreenLayout.resolve(gameRuns: true, phoneHasLower: false, wantsSplit: false) == .oneWindow)
}

@Test func theUserCanSplitTheScreensWhenNoPhoneIsInUse() {
    #expect(ScreenLayout.resolve(gameRuns: true, phoneHasLower: false, wantsSplit: true) == .twoWindows)
}

@Test func thePhoneTakesTheLowerScreenEvenWhenTheUserAskedForTwoWindows() {
    #expect(ScreenLayout.resolve(gameRuns: true, phoneHasLower: true, wantsSplit: true) == .topOnly)
    #expect(ScreenLayout.resolve(gameRuns: true, phoneHasLower: true, wantsSplit: false) == .topOnly)
}

@Test func theLibraryKeepsOneWindowWhenNoGameRuns() {
    #expect(ScreenLayout.resolve(gameRuns: false, phoneHasLower: false, wantsSplit: true) == .oneWindow)
    #expect(ScreenLayout.resolve(gameRuns: false, phoneHasLower: true, wantsSplit: true) == .oneWindow)
}
