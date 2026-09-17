import Testing
@testable import IslandCore

@Test func valueTextWingKeepsFullSizeWhenItFits() {
    let fit = ValueTextWingLayout(measuredTextWidth: 40, availableWidth: 64, iconWidth: 14, spacing: 5)
    #expect(fit.showsIcon && fit.fontScale == 1 && !fit.truncates)
}

@Test func valueTextWingShrinksBeforeGivingUpItsIcon() {
    let fit = ValueTextWingLayout(measuredTextWidth: 50, availableWidth: 64, iconWidth: 14, spacing: 5)
    #expect(fit.showsIcon && fit.fontScale == 0.9 && !fit.truncates)
    let boundary = ValueTextWingLayout(measuredTextWidth: 60, availableWidth: 64, iconWidth: 14, spacing: 5)
    #expect(boundary.showsIcon && boundary.fontScale == 0.75 && !boundary.truncates)
}

@Test func valueTextWingDropsIconBeforeTruncatingOrShrinkingBelowMinimum() {
    let fit = ValueTextWingLayout(measuredTextWidth: 80, availableWidth: 64, iconWidth: 14, spacing: 5)
    #expect(!fit.showsIcon && fit.fontScale == 0.8 && !fit.truncates)
    #expect(fit.textWidth == 64)
}

@Test func valueTextWingTruncatesOnlyAfterUsingAllSpaceAtMinimumScale() {
    let fit = ValueTextWingLayout(measuredTextWidth: 100, availableWidth: 64, iconWidth: 14, spacing: 5)
    #expect(!fit.showsIcon && fit.fontScale == 0.75 && fit.truncates)
    #expect(fit.textWidth == 64)
}

@Test func valueTextWingWithoutAnIconKeepsItsEntireWidth() {
    let fit = ValueTextWingLayout(measuredTextWidth: 80, availableWidth: 64, iconWidth: 14, spacing: 5, hasIcon: false)
    #expect(!fit.showsIcon && fit.fontScale == 0.8 && !fit.truncates)
    #expect(fit.textWidth == 64)
}

@Test func customSourceStatusUsesUserAddedLabelAndExistingDisabledRules() {
    let source = CustomSource(name: "余额", command: "echo 62")
    for enabled in [true, false] {
        let custom = ProviderState(descriptor: source.descriptor, detection: .init(installed: [source.id: true]),
                                   override: enabled, latestClaudeModel: nil)
        let builtin = ProviderState(descriptor: ProviderRegistry.descriptor(for: .claude),
                                    detection: .init(installed: [.claude: true]), override: enabled, latestClaudeModel: nil)
        #expect(custom.statusLabel == "自定义" && builtin.statusLabel == "已检测到")
        #expect(custom.enabled == builtin.enabled && custom.quotaAvailable == builtin.quotaAvailable)
        #expect(custom.quotaReason == builtin.quotaReason)
    }
}
