import Testing
@testable import IslandCore

private func fitValue(_ text: String, width: Double) -> String {
    ValueTextTruncation.displayText(text, availableWidth: width) { Double($0.count) }
}

@Test func valueTextTruncationPreservesCompleteTextIncludingSeparators() {
    for value in ["¥12345678.90", "¥123456.78", "余额 👩🏽‍💻", "ending.,，、·- ", ""] {
        #expect(fitValue(value, width: Double(value.count)) == value)
    }
}

@Test func valueTextTruncationUsesMeasurementAtMinimumScale() {
    let value = "¥123456.78"
    let result = ValueTextTruncation.displayText(value, availableWidth: 7.5) {
        Double($0.count) * ValueTextWingLayout.minimumScale
    }
    #expect(result == value)
}

@Test func valueTextTruncationNeverKeepsPartialDecimalDigits() {
    for (value, width, expected) in [
        ("¥12345678.90", 11.0, "¥12345678…"),
        ("¥12345678.90", 10.0, "¥12345678…"),
        ("¥12345678.90", 8.0, "¥123456…"),
        ("¥123456.78", 9.0, "¥123456…"),
        ("¥123456.78", 8.0, "¥123456…"),
        ("¥123456.78", 7.0, "¥12345…"),
        ("¥123456.78 USD", 11.0, "¥123456.78…"),
        ("12.34567", 7.0, "12…"),
        ("余额１２.３４", 6.0, "余额１２…")
    ] {
        #expect(fitValue(value, width: width) == expected)
    }
}

@Test func valueTextTruncationRemovesTrailingSeparatorsBeforeEllipsis() {
    for separator in [".", ",", "，", "、", "·", "-", " ", "\t", "\n", "\u{00a0}", "—", "．"] {
        #expect(fitValue("AB" + separator + "XYZ", width: 4) == "AB…")
    }
    #expect(fitValue("AB.,，、·- \t", width: 4) == "AB…")
    #expect(fitValue(" ,.-XYZ", width: 3) == "…")
}

@Test func valueTextTruncationKeepsLongestNonNumericPrefix() {
    #expect(fitValue("abcdefgh", width: 5) == "abcd…")
    #expect(fitValue("alpha.beta", width: 8) == "alpha.b…")
    #expect(fitValue("abc.12345", width: 7) == "abc.12…")
}

@Test func valueTextTruncationKeepsWholeGraphemeClusters() {
    #expect(fitValue("余额可用", width: 3) == "余额…")
    #expect(fitValue("甲👨‍👩‍👧‍👦乙🇨🇳丁", width: 4) == "甲👨‍👩‍👧‍👦乙…")
    #expect(fitValue("e\u{301}👩🏽‍💻余额", width: 3) == "e\u{301}👩🏽‍💻…")
    #expect(fitValue("🇨🇳🇸🇬🇯🇵", width: 2) == "🇨🇳…")
}

@Test func valueTextTruncationHandlesExtremelyNarrowWidths() {
    for width in [0.0, 0.5, 1, 1.9, -1, .nan, .infinity] {
        #expect(fitValue("¥123456.78", width: width) == "…")
        #expect(fitValue("👩🏽‍💻余额", width: width) == "…")
    }
    #expect(fitValue("A", width: 0) == "…")
    #expect(fitValue("A", width: 1) == "A")
    #expect(fitValue("", width: 0) == "")
    #expect(fitValue("-, ", width: 2) == "…")
}

@Test func valueTextTruncationMeasuresEntireCandidateIncludingEllipsis() {
    let result = ValueTextTruncation.displayText("WiiiZ", availableWidth: 8) { value in
        value.reduce(0.0) { sum, character in
            sum + (character == "W" ? 4 : character == "Z" ? 3 : character == "…" ? 2 : 1)
        }
    }
    #expect(result == "Wii…")
}
