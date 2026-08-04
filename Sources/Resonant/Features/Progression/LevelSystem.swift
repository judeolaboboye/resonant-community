import Foundation

/// 11 levels from Rookie to Transcendent, keyed by cumulative word count.
struct LevelSystem {

    struct Level: Equatable {
        let name: String
        let abbreviation: String
        let minWords: Int
        let color: String   // hex
    }

    static let levels: [Level] = [
        Level(name: "Rookie",      abbreviation: "RK",  minWords: 0,          color: "#6B7280"),
        Level(name: "Talker",      abbreviation: "TK",  minWords: 100,        color: "#3B82F6"),
        Level(name: "Chatterbox",  abbreviation: "CB",  minWords: 500,        color: "#06B6D4"),
        Level(name: "Wordsmith",   abbreviation: "WS",  minWords: 1_000,      color: "#10B981"),
        Level(name: "Narrator",    abbreviation: "NR",  minWords: 5_000,      color: "#84CC16"),
        Level(name: "Orator",      abbreviation: "OR",  minWords: 10_000,     color: "#EAB308"),
        Level(name: "Scribe",      abbreviation: "SC",  minWords: 25_000,     color: "#F97316"),
        Level(name: "Voice Master",abbreviation: "VM",  minWords: 50_000,     color: "#EF4444"),
        Level(name: "Legend",      abbreviation: "LG",  minWords: 100_000,    color: "#EC4899"),
        Level(name: "Mythic",      abbreviation: "MT",  minWords: 500_000,    color: "#8B5CF6"),
        Level(name: "Transcendent",abbreviation: "TR",  minWords: 1_000_000,  color: "#F59E0B"),
    ]

    func level(for totalWords: Int) -> Level {
        Self.levels.last(where: { totalWords >= $0.minWords }) ?? Self.levels[0]
    }

    func nextLevel(for totalWords: Int) -> Level? {
        Self.levels.first(where: { totalWords < $0.minWords })
    }

    func progress(for totalWords: Int) -> Double {
        let current = level(for: totalWords)
        guard let next = nextLevel(for: totalWords) else { return 1.0 }
        let range = next.minWords - current.minWords
        let earned = totalWords - current.minWords
        return Double(earned) / Double(range)
    }

    func didLevelUp(before: Int, after: Int) -> Level? {
        let levelBefore = level(for: before)
        let levelAfter  = level(for: after)
        return levelBefore == levelAfter ? nil : levelAfter
    }
}

extension LevelSystem.Level {
    /// HSB hue (0...1) derived from the level's hex color, suitable for the orb renderer.
    var hue: Double {
        let cleaned = color.trimmingCharacters(in: .init(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return 0.6 }

        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0

        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC

        guard delta > 0 else { return 0.6 }

        let segment: Double
        if maxC == r {
            segment = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            segment = (b - r) / delta + 2
        } else {
            segment = (r - g) / delta + 4
        }

        var degrees = segment * 60
        if degrees < 0 { degrees += 360 }
        return degrees / 360
    }
}
