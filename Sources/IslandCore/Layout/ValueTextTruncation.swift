import Foundation

/// Selects a complete, grapheme-safe prefix; measurement uses the display font at its minimum scale.
public enum ValueTextTruncation {
    public static func displayText(_ text: String, availableWidth: Double,
                                   measure: (String) -> Double) -> String {
        let width = availableWidth.isFinite ? max(0, availableWidth) : 0
        func fits(_ value: String) -> Bool {
            let measured = measure(value)
            return measured.isFinite && measured >= 0 && measured <= width
        }
        if text.isEmpty || fits(text) { return text }

        let characters = Array(text)
        // Evaluate whole candidates, including the ellipsis, so proportional fonts and kerning work.
        for cut in stride(from: characters.count - 1, through: 1, by: -1) {
            var end = cut
            if characters[cut].isNumber {
                var fractionStart = cut
                while fractionStart > 0 && characters[fractionStart - 1].isNumber { fractionStart -= 1 }
                if fractionStart >= 2, characters[fractionStart - 1] == ".",
                   characters[fractionStart - 2].isNumber {
                    // The next omitted character is still a fractional digit: omit the entire fraction.
                    end = fractionStart - 1
                }
            }
            while end > 0 && isSeparator(characters[end - 1]) { end -= 1 }
            guard end > 0 else { continue }
            let candidate = String(characters.prefix(end)) + "…"
            if fits(candidate) { return candidate }
        }
        // Keep this fallback even when the available width is narrower than the ellipsis itself.
        return "…"
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || ".,，、·-‐‑‒–—―－．:：;；/／\\_…".contains(character)
    }
}
