import AppKit
import Foundation

/// Detects and repairs "collapsed" ASR output where SentencePiece word
/// boundaries (▁) were lost, fusing entire phrases into a single run.
///
/// This typically happens when the TDT decoder encounters emails, URLs,
/// or technical terms and switches into sub-word-only mode for the entire
/// utterance, producing output like "Iwanttousemyemail@example.com".
///
/// Uses dynamic-programming word segmentation against a dictionary of
/// common English words to re-insert spaces.
enum CollapsedRunRepair {

    /// Minimum length of a whitespace-free run before we attempt repair.
    /// The 70% coverage gate in `bestSegmentation` is the real false-positive
    /// guard — single compound words like "notification" stay below it — so
    /// this bound is kept low to catch short ASR clumps like "asaprodesigner".
    private static let minRunLength = 10

    /// Minimum length of a letter-only fragment to attempt segmentation.
    private static let minFragmentLength = 6

    /// Minimum fraction of a fragment that must be covered by real words for
    /// the segmentation to be accepted. Collapsed-run repair is allowed to
    /// recover fused phrases, but must not invent internal spaces inside a
    /// single unfamiliar word.
    private static let minCoverage: Double = 0.95

    /// Longest dictionary word we check (bounds the inner DP loop).
    private static let maxWordLength = 12

    /// Email addresses are especially prone to losing whitespace around the
    /// domain separator, e.g. `mail@example. com`.
    private static let emailAddressPattern = try! NSRegularExpression(
        pattern: #"\b[A-Z0-9._%+\-]+\s*@\s*[A-Z0-9\-]+(?:\s*\.\s*[A-Z0-9\-]+)+\b"#,
        options: [.caseInsensitive]
    )

    // MARK: - Public

    static func repair(_ text: String) -> String {
        var result = text

        if text.count >= minRunLength {
            let runs = collapsedRuns(in: text)
            if !runs.isEmpty {
                for run in runs.reversed() {
                    let runText = String(result[run])
                    if let fixed = segmentCollapsedRun(runText) {
                        result.replaceSubrange(run, with: fixed)
                    }
                }
            }
        }

        return repairEmailAddressWhitespace(in: result)
    }

    // MARK: - Run detection

    /// Finds ranges of non-whitespace characters >= `minRunLength`.
    private static func collapsedRuns(in text: String) -> [Range<String.Index>] {
        var runs: [Range<String.Index>] = []
        var runStart: String.Index?
        var runLength = 0

        for idx in text.indices {
            if text[idx].isWhitespace {
                if let start = runStart, runLength >= minRunLength {
                    runs.append(start..<idx)
                }
                runStart = nil
                runLength = 0
            } else {
                if runStart == nil { runStart = idx }
                runLength += 1
            }
        }
        if let start = runStart, runLength >= minRunLength {
            runs.append(start..<text.endIndex)
        }
        return runs
    }

    // MARK: - Segmentation

    /// Splits a collapsed run into letter-only fragments and non-letter
    /// separators, segments the long letter fragments, and reassembles.
    private static func segmentCollapsedRun(_ run: String) -> String? {
        var fragments: [(text: String, isLetters: Bool)] = []
        var current = ""
        var currentIsLetters: Bool?

        for ch in run {
            let isLetter = ch.isLetter
            if let prev = currentIsLetters, isLetter != prev {
                fragments.append((current, prev))
                current = String(ch)
                currentIsLetters = isLetter
            } else {
                current.append(ch)
                currentIsLetters = isLetter
            }
        }
        if !current.isEmpty, let isLetters = currentIsLetters {
            fragments.append((current, isLetters))
        }

        var anyChanged = false
        var output: [String] = []

        for fragment in fragments {
            if fragment.isLetters,
               fragment.text.count >= minFragmentLength,
               isSegmentationCandidate(fragment.text),
               !isProtectedWholeWord(fragment.text) {
                let chars = Array(fragment.text)
                let (words, coveredCharacterCount) = bestSegmentation(chars)
                let coverage = Double(coveredCharacterCount) / Double(chars.count)
                if isAcceptableCollapsedPhrase(words, coverage: coverage) {
                    output.append(words.joined(separator: " "))
                    anyChanged = true
                    continue
                }
            }
            output.append(fragment.text)
        }

        return anyChanged ? output.joined() : nil
    }

    private static func isAcceptableCollapsedPhrase(_ words: [String], coverage: Double) -> Bool {
        guard coverage >= minCoverage else { return false }
        guard words.count >= 3 else { return false }

        var cache: [String: Int] = [:]
        let lowercased = words.map { $0.lowercased() }
        for (index, word) in lowercased.enumerated() {
            guard segmentationWordScore(word, cache: &cache) > 0 else {
                return false
            }

            if word.count == 1 {
                if word == "a" {
                    continue
                }
                if word == "i", index == 0 {
                    continue
                }
                return false
            }
        }

        // Real collapsed phrases usually contain at least two substantial
        // words. Single words with productive suffixes otherwise look like
        // plausible phrases: `production` -> `product i on`,
        // `visualization` -> `visual iz at i on`.
        if let first = lowercased.first,
           first.count >= 5,
           lowercased.dropFirst().allSatisfy({ $0.count <= 3 }) {
            return false
        }

        var trailingShortWordCount = 0
        for word in lowercased.reversed() {
            guard word.count <= 2 else { break }
            trailingShortWordCount += 1
        }
        if trailingShortWordCount > 0,
           !isAcceptableTrailingShortPhrase(lowercased, trailingShortWordCount: trailingShortWordCount) {
            return false
        }

        return true
    }

    private static func isAcceptableTrailingShortPhrase(
        _ words: [String],
        trailingShortWordCount: Int
    ) -> Bool {
        guard trailingShortWordCount <= 2,
              trailingShortWordCount < words.count
        else {
            return false
        }

        let tail = words.suffix(trailingShortWordCount)
        guard tail.allSatisfy({ trailingShortFunctionWords.contains($0) }) else {
            return false
        }

        let core = words.dropLast(trailingShortWordCount)
        return core.contains { $0.count >= 4 }
    }

    private static func isProtectedWholeWord(_ fragment: String) -> Bool {
        let normalized = fragment.lowercased()
        if protectedWholeWords.contains(normalized) || commonWords.contains(normalized) {
            return true
        }

        if isAcceptedSystemWord(normalized) {
            return !looksLikeCollapsedPronounPhrase(normalized)
        }

        return false
    }

    private static func looksLikeCollapsedPronounPhrase(_ normalized: String) -> Bool {
        guard normalized.count >= minRunLength else {
            return false
        }

        for pronoun in collapsedPhraseSubjectPronouns
            where normalized.hasPrefix(pronoun)
            && normalized.count > pronoun.count + minFragmentLength {
            let rest = String(normalized.dropFirst(pronoun.count))
            let chars = Array(rest)
            let (tailWords, coveredCharacterCount) = bestSegmentation(chars)
            guard coveredCharacterCount == chars.count else {
                continue
            }
            if isAcceptableCollapsedPhrase([pronoun] + tailWords, coverage: 1) {
                return true
            }
        }

        return false
    }

    /// Skip mixed-case identifiers like `WorkspaceSyncEngine` so we don't
    /// "repair" deliberate technical terms the user dictated as one token.
    private static func isSegmentationCandidate(_ fragment: String) -> Bool {
        let uppercaseIndices = fragment.indices.filter { fragment[$0].isUppercase }
        guard !uppercaseIndices.isEmpty else { return true }
        guard uppercaseIndices.count == 1, uppercaseIndices[0] == fragment.startIndex else {
            return false
        }
        let next = fragment.index(after: fragment.startIndex)
        return fragment[next...].allSatisfy { !$0.isUppercase }
    }

    private static func repairEmailAddressWhitespace(in text: String) -> String {
        let matches = emailAddressPattern.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let candidate = String(result[range])
            let fixed = candidate
                .replacingOccurrences(
                    of: #"\s*@\s*"#,
                    with: "@",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"\s*\.\s*"#,
                    with: ".",
                    options: .regularExpression
                )
            result.replaceSubrange(range, with: fixed)
        }

        return result
    }

    // MARK: - DP word break

    /// Finds the segmentation that maximises the number of characters
    /// explained by dictionary words.  Returns the word list (using
    /// original casing) and the total covered character count.
    private static func bestSegmentation(_ chars: [Character]) -> (words: [String], covered: Int) {
        let n = chars.count
        guard n > 0 else { return ([], 0) }

        let lowerChars = Array(String(chars).lowercased())
        var spellCheckCache: [String: Int] = [:]

        struct Entry {
            var covered: Int = 0
            var score: Int = 0
            var wordStart: Int = -1  // start index of the last matched word, or -1
        }

        var dp = [Entry](repeating: Entry(), count: n + 1)

        for i in 1...n {
            // Default: carry forward without matching a word here
            dp[i].covered = dp[i - 1].covered

            for len in 1...min(i, maxWordLength) {
                let j = i - len
                let candidate = String(lowerChars[j..<i])
                let candidateScore = segmentationWordScore(candidate, cache: &spellCheckCache)
                if candidateScore > 0 {
                    let newCovered = dp[j].covered + len
                    let newScore = dp[j].score + candidateScore
                    if newCovered > dp[i].covered
                        || (newCovered == dp[i].covered && newScore > dp[i].score) {
                        dp[i] = Entry(covered: newCovered, score: newScore, wordStart: j)
                    }
                }
            }
        }

        // Backtrack to find word boundary positions
        var boundaries: [Int] = []
        var pos = n
        while pos > 0 {
            if dp[pos].wordStart >= 0 {
                let start = dp[pos].wordStart
                if start > 0 { boundaries.append(start) }
                pos = start
            } else {
                pos -= 1
            }
        }
        boundaries.sort()

        // Build words from boundary positions (using original chars)
        var words: [String] = []
        var prev = 0
        for b in boundaries {
            words.append(String(chars[prev..<b]))
            prev = b
        }
        words.append(String(chars[prev..<n]))

        return (words, dp[n].covered)
    }

    private static func segmentationWordScore(_ word: String, cache: inout [String: Int]) -> Int {
        if commonWords.contains(word) {
            return word.count * 4
        }
        if isInflectionOfCommonWord(word) {
            return word.count * 4
        }

        // The static word list intentionally stays small to avoid overfitting
        // ASR repairs, but collapsed runs often contain ordinary inflections
        // ("needs") or longer words ("distribute"). Let the system dictionary
        // fill those gaps after the whole-word protection gate has already
        // ruled out normal single words.
        guard word.count >= 3 else {
            return 0
        }

        if let cached = cache[word] {
            return cached
        }

        let score = isAcceptedSystemWord(word) ? word.count * 2 : 0
        cache[word] = score
        return score
    }

    private static func isAcceptedSystemWord(_ word: String) -> Bool {
        SpellCheckSerialization.lock.withLock {
            NSSpellChecker.shared.checkSpelling(
                of: word,
                startingAt: 0
            ).location == NSNotFound
        }
    }

    private static func isInflectionOfCommonWord(_ word: String) -> Bool {
        if word.hasSuffix("s") {
            let base = String(word.dropLast())
            if commonWords.contains(base) {
                return true
            }
        }

        if word.hasSuffix("es") {
            let base = String(word.dropLast(2))
            if commonWords.contains(base) {
                return true
            }
        }

        if word.hasSuffix("ed") {
            let base = String(word.dropLast(2))
            if commonWords.contains(base) || commonWords.contains(base + "e") {
                return true
            }
        }

        if word.hasSuffix("ing") {
            let base = String(word.dropLast(3))
            if commonWords.contains(base) || commonWords.contains(base + "e") {
                return true
            }
        }

        return false
    }

    // MARK: - Dictionary

    // swiftlint:disable:next closure_body_length
    private static let commonWords: Set<String> = {
        var words: Set<String> = []
        let raw = [
            // 1-2 letter
            "a", "i", "am", "an", "as", "at", "be", "by", "do", "go",
            "he", "if", "in", "is", "it", "me", "my", "no", "of", "oh",
            "ok", "on", "or", "so", "to", "up", "us", "we",
            // 3 letter
            "add", "ago", "air", "all", "and", "any", "app", "are", "art",
            "ask", "bad", "big", "bit", "box", "bug", "bus", "but", "buy",
            "can", "car", "cut", "day", "did", "due", "end", "eye", "far",
            "few", "fit", "fix", "fly", "for", "fun", "gap", "get", "god",
            "got", "guy", "had", "has", "her", "him", "his", "hit", "hot",
            "how", "its", "job", "key", "kid", "law", "lay", "led", "let",
            "lie", "log", "lot", "low", "man", "map", "may", "men", "met",
            "mix", "net", "new", "nor", "not", "now", "odd", "off", "oil",
            "old", "one", "our", "out", "own", "pay", "per", "pin", "pop",
            "pro", "put", "ran", "raw", "red", "rid", "row", "run", "sad",
            "sat", "saw", "say", "sea", "set", "she", "sir", "sit", "six",
            "son", "sum", "sun", "tab", "tax", "ten", "the", "tie", "tip",
            "too", "top", "try", "two", "use", "van", "via", "war", "was",
            "way", "web", "who", "why", "win", "won", "yes", "yet", "you",
            // 4 letter
            "able", "also", "area", "auto", "away", "back", "base", "been",
            "best", "bill", "body", "book", "both", "burn", "busy", "call",
            "came", "card", "care", "case", "chat", "city", "clip", "code",
            "cold", "come", "cool", "copy", "core", "cost", "dark", "data",
            "date", "days", "dead", "deal", "deep", "dial", "does", "done",
            "door", "down", "draw", "drop", "drug", "each", "earn", "ease",
            "east", "easy", "edge", "edit", "else", "even", "ever", "face",
            "fact", "fail", "fair", "fall", "fast", "fear", "feed", "feel",
            "fell", "file", "fill", "film", "find", "fine", "fire", "firm",
            "five", "flag", "flat", "flow", "food", "foot", "form", "four",
            "free", "from", "full", "fund", "gain", "game", "gave", "gift",
            "girl", "give", "glad", "goal", "goes", "gold", "gone", "good",
            "grab", "grew", "grow", "guys", "hack", "half", "hand", "hang",
            "hard", "hate", "have", "head", "hear", "heat", "held", "help",
            "here", "hero", "hide", "high", "hill", "hold", "hole", "home",
            "hope", "host", "hour", "huge", "hung", "hurt", "icon", "idea",
            "into", "item", "join", "joke", "jump", "just", "keen", "keep",
            "kept", "kick", "kind", "knew", "know", "lack", "laid", "land",
            "lane", "last", "late", "lead", "left", "lend", "less", "life",
            "lift", "like", "line", "link", "list", "live", "load", "lock",
            "logo", "long", "look", "loop", "lose", "loss", "lost", "love",
            "luck", "made", "mail", "main", "make", "male", "many", "mark",
            "mass", "mean", "meet", "menu", "mild", "mind", "mine", "miss",
            "mode", "mood", "more", "most", "move", "much", "must", "name",
            "near", "neat", "need", "news", "next", "nice", "nine", "node",
            "none", "note", "okay", "once", "only", "onto", "open", "over",
            "pack", "page", "paid", "pain", "pair", "part", "pass", "past",
            "path", "peak", "pick", "plan", "play", "plus", "poem", "poll",
            "pool", "poor", "port", "post", "pour", "pull", "pure", "push",
            "quit", "race", "rain", "rank", "rare", "rate", "read", "real",
            "rely", "rent", "rest", "rich", "ride", "ring", "rise", "risk",
            "road", "rock", "role", "roll", "roof", "room", "root", "rose",
            "rule", "rush", "safe", "said", "sake", "sale", "same", "sand",
            "save", "says", "scan", "seed", "seek", "seem", "seen", "self",
            "sell", "send", "sent", "ship", "shop", "shot", "show", "shut",
            "sick", "side", "sign", "site", "size", "skin", "slip", "slot",
            "slow", "snap", "soft", "sold", "sole", "some", "song", "soon",
            "sort", "soul", "spin", "spot", "star", "stay", "stem", "step",
            "stop", "such", "suit", "sure", "swim", "sync", "tail", "take",
            "tale", "talk", "tall", "tank", "tape", "task", "team", "tear",
            "tech", "tell", "tend", "term", "test", "text", "than", "that",
            "them", "then", "they", "thin", "this", "thus", "till", "time",
            "tiny", "tire", "told", "toll", "tone", "took", "tool", "tops",
            "tour", "town", "trap", "tree", "trim", "trip", "true", "tube",
            "tune", "turn", "type", "ugly", "undo", "unit", "upon", "urge",
            "used", "user", "vary", "vast", "very", "vice", "view", "void",
            "vote", "wage", "wait", "wake", "walk", "wall", "want", "warm",
            "warn", "wash", "wave", "weak", "wear", "week", "well", "went",
            "were", "west", "what", "when", "whom", "wide", "wife", "wild",
            "will", "wind", "wine", "wing", "wire", "wise", "wish", "with",
            "woke", "wood", "word", "wore", "work", "worm", "worn", "wrap",
            "yard", "yeah", "year", "your", "zero", "zone", "zoom",
            // 5 letter
            "about", "above", "adapt", "added", "admit", "adopt", "adult",
            "after", "again", "agent", "agree", "ahead", "alarm", "alert",
            "align", "alive", "allow", "alone", "along", "alter", "among",
            "angel", "anger", "angle", "apart", "apply", "arena", "argue",
            "arise", "aside", "asked", "avoid", "award", "aware", "based",
            "basic", "batch", "began", "begin", "being", "below", "black",
            "blame", "blank", "blend", "blind", "block", "blown", "board",
            "bonus", "boost", "bound", "brain", "brand", "brave", "bread",
            "break", "brief", "bring", "broad", "broke", "brown", "brush",
            "buddy", "build", "built", "bunch", "buyer", "carry", "catch",
            "cause", "chain", "chair", "cheap", "check", "chest", "chief",
            "child", "chunk", "claim", "class", "clean", "clear", "click",
            "climb", "clone", "close", "cloud", "coach", "coast", "comes",
            "could", "count", "court", "cover", "crack", "craft", "crash",
            "crazy", "crowd", "cycle", "daily", "dance", "death", "debug",
            "delay", "depth", "dirty", "doing", "doubt", "draft", "drain",
            "drama", "drawn", "dream", "dress", "drink", "drive", "drove",
            "dying", "eager", "early", "earth", "eight", "elect", "email",
            "empty", "ended", "enemy", "enjoy", "enter", "equal", "error",
            "essay", "event", "every", "exact", "exist", "extra", "faith",
            "fancy", "fatal", "fault", "favor", "feast", "fetch", "fewer",
            "field", "fight", "final", "first", "fixed", "flame", "flash",
            "fleet", "float", "flood", "floor", "fluid", "flush", "focus",
            "force", "forth", "forum", "found", "frame", "fraud", "fresh",
            "front", "fruit", "fully", "funny", "giant", "given", "glass",
            "globe", "going", "grace", "grade", "grain", "grand", "grant",
            "graph", "grasp", "grave", "great", "green", "greet", "gross",
            "group", "grown", "guard", "guess", "guide", "habit", "happy",
            "heard", "heart", "heavy", "hence", "horse", "hotel", "hours",
            "house", "human", "humor", "hurry", "ideal", "image", "imply",
            "inbox", "index", "indie", "inner", "input", "issue", "joint",
            "judge", "juice", "known", "label", "labor", "large", "laser",
            "later", "laugh", "layer", "learn", "lease", "least", "leave",
            "legal", "level", "light", "limit", "lived", "local", "logic",
            "login", "loose", "lover", "lower", "lucky", "lunch", "magic",
            "major", "maker", "match", "maybe", "mayor", "meant", "media",
            "merge", "metal", "might", "minor", "minus", "mixed", "model",
            "money", "month", "moral", "mount", "mouse", "mouth", "moved",
            "movie", "music", "named", "nerve", "never", "newly", "night",
            "noble", "noise", "north", "noted", "novel", "occur", "ocean",
            "offer", "often", "olive", "order", "other", "ought", "outer",
            "owned", "owner", "paint", "panel", "paper", "party", "paste",
            "patch", "pause", "peace", "penny", "phone", "photo", "piece",
            "pilot", "pitch", "pixel", "pizza", "place", "plain", "plane",
            "plant", "plate", "point", "power", "press", "price", "pride",
            "prime", "print", "prior", "prize", "proof", "prove", "proxy",
            "pulse", "queen", "query", "queue", "quick", "quiet", "quite",
            "quote", "radio", "raise", "rally", "range", "rapid", "ratio",
            "reach", "ready", "realm", "rebel", "reign", "relax", "relay",
            "renew", "reply", "reset", "ridge", "right", "rigid", "rival",
            "river", "robot", "rough", "round", "route", "royal", "sadly",
            "saint", "scale", "scene", "scope", "score", "scout", "sense",
            "serve", "setup", "seven", "shade", "shake", "shall", "shame",
            "shape", "share", "sharp", "sheet", "shelf", "shift", "shirt",
            "shock", "shore", "short", "shown", "sight", "since", "sixth",
            "sixty", "skill", "sleep", "slice", "slide", "slope", "small",
            "smart", "smell", "smile", "smoke", "solid", "solve", "sorry",
            "sound", "south", "space", "spare", "spark", "speak", "speed",
            "spell", "spend", "spent", "split", "spoke", "sport", "spray",
            "stack", "staff", "stage", "stain", "stake", "stand", "stare",
            "start", "state", "stays", "steak", "steal", "steam", "steel",
            "steep", "stern", "stick", "still", "stock", "stone", "stood",
            "store", "storm", "story", "strap", "strip", "stuck", "study",
            "stuff", "style", "suite", "super", "surge", "swear", "sweet",
            "swept", "swift", "swing", "table", "taken", "taste", "taxes",
            "teach", "thank", "theft", "their", "theme", "there", "these",
            "thick", "thing", "think", "third", "those", "three", "threw",
            "throw", "thumb", "tight", "timer", "tired", "title", "today",
            "token", "topic", "total", "touch", "tough", "tower", "toxic",
            "trace", "track", "trade", "trail", "train", "trait", "trash",
            "treat", "trend", "trial", "tribe", "trick", "tried", "truly",
            "trunk", "trust", "truth", "twice", "twist", "ultra", "under",
            "union", "unite", "unity", "until", "upper", "upset", "urban",
            "usage", "using", "usual", "utter", "valid", "value", "video",
            "vigor", "vinyl", "viral", "visit", "vital", "vivid", "vocal",
            "voice", "voter", "watch", "water", "weigh", "weird", "whale",
            "wheat", "wheel", "where", "which", "while", "white", "whole",
            "whose", "width", "women", "world", "worry", "worse", "worst",
            "worth", "would", "wound", "write", "wrong", "wrote", "yield",
            "young", "yours", "youth",
            // 6 letter – common words that also prevent false sub-word splits
            "accept", "access", "across", "action", "active", "actual",
            "adding", "adjust", "advice", "afford", "agreed", "almost",
            "always", "amount", "animal", "annual", "answer", "anyway",
            "appear", "around", "arrive", "assume", "attach", "attack",
            "august", "barely", "battle", "became", "become", "before",
            "behind", "belong", "beside", "better", "beyond", "bitter",
            "border", "bother", "bottom", "bounce", "branch", "bright",
            "broken", "browse", "budget", "bundle", "burden", "bureau",
            "button", "called", "camera", "campus", "cancel", "cannot",
            "carbon", "career", "caught", "center", "chance", "change",
            "charge", "chosen", "church", "circle", "client", "closed",
            "closer", "coffee", "column", "combat", "coming", "commit",
            "common", "comply", "config", "corner", "costly", "cotton",
            "county", "couple", "course", "create", "credit", "crisis",
            "custom", "damage", "danger", "debate", "decade", "decent",
            "decide", "defeat", "defend", "define", "degree", "delete",
            "demand", "dental", "depend", "deploy", "derive", "desert",
            "design", "desire", "detail", "detect", "device", "differ",
            "dinner", "direct", "divide", "doctor", "domain", "double",
            "dozens", "driven", "driver", "during", "easily", "eating",
            "editor", "effect", "effort", "eighth", "either", "eleven",
            "empire", "employ", "enable", "ending", "energy", "engage",
            "engine", "enough", "ensure", "entire", "entity", "equals",
            "equity", "escape", "estate", "evolve", "exceed", "except",
            "excuse", "exempt", "expand", "expect", "expert", "export",
            "expose", "extend", "extent", "fabric", "factor", "fairly",
            "family", "farmer", "father", "female", "figure", "filter",
            "finale", "finger", "finish", "flight", "follow", "forced",
            "forest", "forget", "formal", "format", "former", "foster",
            "fourth", "friend", "frozen", "future", "gained", "garden",
            "gather", "gender", "gentle", "gifted", "giving", "global",
            "golden", "govern", "ground", "growth", "guided", "guilty",
            "handle", "happen", "harbor", "hardly", "having", "header",
            "health", "heaven", "height", "helped", "hidden", "highly",
            "honest", "hoping", "hosted", "hunger", "hybrid", "ignore",
            "impact", "import", "impose", "income", "indeed", "indoor",
            "inform", "injury", "inline", "insert", "inside", "insist",
            "intact", "intend", "intent", "invest", "invite", "island",
            "itself", "junior", "launch", "lawyer", "layout", "leader",
            "league", "legend", "length", "lesson", "letter", "likely",
            "linear", "linked", "listen", "little", "lively", "loaded",
            "locate", "locked", "logged", "longer", "lookup", "lovely",
            "mainly", "manage", "manner", "manual", "margin", "marine",
            "marked", "market", "master", "matter", "mature", "medium",
            "member", "memory", "mental", "merely", "method", "middle",
            "mighty", "minute", "mirror", "mobile", "modern", "modest",
            "modify", "module", "moment", "mostly", "motion", "mother",
            "moving", "murder", "muscle", "mutual", "myself", "namely",
            "narrow", "nation", "native", "nature", "nearby", "nearly",
            "needed", "nicely", "nobody", "normal", "notice", "notion",
            "number", "object", "obtain", "occupy", "offset", "online",
            "opened", "oppose", "option", "orange", "origin", "outfit",
            "output", "oxygen", "packed", "palace", "parent", "partly",
            "passed", "patent", "patrol", "paying", "pencil", "people",
            "period", "permit", "person", "phrase", "picked", "planet",
            "player", "please", "pledge", "plenty", "plugin", "pocket",
            "poetry", "poison", "police", "policy", "polite", "portal",
            "posted", "powder", "prayer", "prefer", "prefix", "pretty",
            "prince", "prison", "profit", "prompt", "proper", "propose",
            "proven",
            "public", "purely", "pursue", "pushed", "puzzle", "racial",
            "raised", "random", "rarely", "rather", "rating", "reader",
            "really", "reason", "recall", "recent", "record", "reduce",
            "reform", "refuse", "regard", "regime", "region", "reject",
            "relate", "relief", "remain", "remote", "remove", "rename",
            "render", "rental", "repeat", "report", "rescue", "resign",
            "resist", "resort", "result", "retain", "retire", "return",
            "reveal", "review", "revise", "reward", "rising", "robust",
            "rotate", "ruling", "runner", "sacred", "safely", "safety",
            "salary", "sample", "saving", "saying", "scheme", "school",
            "screen", "script", "scroll", "search", "season", "second",
            "secret", "sector", "secure", "seeing", "select", "seller",
            "sender", "senior", "serial", "series", "server", "settle",
            "severe", "shadow", "shaped", "shared", "shield", "signal",
            "signed", "silent", "silver", "simple", "simply", "single",
            "slight", "slowly", "smooth", "social", "solved", "sought",
            "source", "speech", "spirit", "spoken", "spread", "spring",
            "square", "stable", "status", "steady", "stolen", "stored",
            "strain", "stream", "street", "strict", "strike", "string",
            "strong", "struck", "studio", "submit", "sudden", "suffer",
            "summit", "supply", "surely", "survey", "switch", "symbol",
            "syntax", "system", "tackle", "talent", "target", "taught",
            "tenant", "tender", "thanks", "theory", "thirty", "though",
            "thread", "threat", "thrown", "timber", "toggle", "tongue",
            "toward", "travel", "treaty", "tribal", "trophy", "tunnel",
            "twelve", "twenty", "unable", "unfair", "unique", "united",
            "unless", "unlike", "unlock", "update", "upload", "urgent",
            "useful", "valley", "valued", "vendor", "verbal", "versus",
            "vessel", "victim", "viewer", "virtue", "vision", "visual",
            "volume", "walker", "wander", "warmth", "wealth", "weapon",
            "weekly", "weight", "wholly", "widely", "widget", "window",
            "winner", "winter", "wisdom", "within", "wonder", "wooden",
            "worker", "worthy", "writer", "yearly",
            // 7+ letter – high-frequency words (prevents false sub-word splits)
            "ability", "about", "absence", "account", "achieve", "address",
            "against", "already", "amazing", "another", "anymore", "applied",
            "attempt", "balance", "because", "becomes", "believe", "benefit",
            "between", "billion", "brought", "browser", "building",
            "business", "calendar", "campaign", "capture", "careful",
            "central", "certain", "chapter", "clearly", "combine", "command",
            "comment", "company", "compare", "complex", "concern", "confirm",
            "connect", "contact", "content", "context", "control", "convert",
            "correct", "counter", "country", "created", "current", "customer",
            "database", "deadline", "decision", "declined", "default",
            "deliver", "delivery", "desktop", "develop", "digital",
            "distribute",
            "directly", "discover", "discuss", "display", "document",
            "download", "dropped", "earlier", "economic", "election",
            "element", "employee", "entirely", "envelope", "estimate",
            "evaluate", "eventual", "everyone", "evidence", "exactly",
            "examine", "example", "exchange", "exciting", "exercise",
            "existing", "expected", "explicit", "exposure", "extended",
            "external", "familiar", "favorite", "featured", "feedback",
            "filename", "finally", "finding", "flexible", "floating",
            "followed", "football", "formerly", "forward", "fraction",
            "frequent", "friendly", "frontier", "function", "further",
            "general", "generate", "getting", "governor", "gradient",
            "graphics", "grateful", "greatly", "growing", "guidance",
            "handling", "happened", "headline", "helpful", "herself",
            "himself", "history", "hospital", "however", "hundred",
            "identity", "imagine", "implicit", "important", "improved",
            "incident", "included", "increase", "indicate", "industry",
            "informal", "informed", "initially", "instance", "intended",
            "interest", "internal", "internet", "invested", "involved",
            "isolated", "keyboard", "language", "launched", "learning",
            "leverage", "lifetime", "limiting", "linkedin", "listener",
            "literary", "location", "maintain", "majority", "managing",
            "material", "maximize", "measured", "medicine", "meeting",
            "membrane", "mentioned", "midnight", "military", "millions",
            "minimize", "ministry", "minority", "moderate", "modified",
            "mortgage", "movement", "multiple", "national", "negative",
            "neighbor", "normally", "notebook", "numerous", "observed",
            "obstacle", "obtained", "occasion", "offering", "official",
            "opening", "operated", "opponent", "opposite", "optional",
            "ordering", "ordinary", "organize", "original", "outlined",
            "overcome", "overhead", "overview", "painting", "parallel",
            "password", "patience", "personal", "physical", "pipeline",
            "planning", "platform", "pleasant", "pleasure", "pointing",
            "politics", "position", "positive", "possible", "possibly",
            "powerful", "practice", "precious", "prepared", "presence",
            "preserve", "pressing", "pressure", "previous", "printing",
            "priority", "probably", "problem", "process", "produce",
            "product", "profile", "program", "project", "promise",
            "proposed",
            "promote", "protect", "provide", "publish", "purpose",
            "quality", "quickly", "question", "reaction", "reading",
            "reality", "realize", "receive", "recently", "recovery",
            "reducing", "register", "regional", "relation", "relative",
            "released", "relevant", "reliable", "remained", "remember",
            "removing", "rendered", "repeated", "replaced", "reported",
            "required", "research", "reserved", "resident", "resource",
            "response", "restrain", "restrict", "resulted", "revealed",
            "reviewed", "rotation", "running", "runtime", "schedule",
            "scholars", "sciences", "seasonal", "sections", "security",
            "selected", "sentence", "separate", "sequence", "services",
            "session", "setting", "settings", "several", "sharing",
            "shipping", "shopping", "shortage", "shoulder", "shutdown",
            "similar", "slightly", "snapshot", "social", "software",
            "solution", "somebody", "somewhat", "special", "specific",
            "spending", "standard", "standing", "starting", "straight",
            "strategy", "strength", "strictly", "striking", "strongly",
            "struggle", "students", "studying", "subjects", "suddenly",
            "suitable", "supplied", "supposed", "surprise", "switched",
            "targeted", "teaching", "teammate", "teamwork", "terminal",
            "thinking", "thorough", "thousand", "together", "tomorrow",
            "touching", "tracking", "training", "transfer", "trillion",
            "ultimate", "umbrella", "uncommon", "underway", "universe",
            "unlocked", "uploaded", "username", "valuable", "violence",
            "volatile", "whatever", "whenever", "wherever", "workshop",
            "writing", "written", "yourself",
            // Tech terms common in dictation
            "proton", "gmail", "outlook", "yahoo", "slack", "github",
            "notion", "figma", "cursor", "chrome", "safari", "firefox",
            "docker", "linux", "macos", "apple", "google", "microsoft",
            "windows", "react", "swift", "python", "pixel", "iphone",
            "android", "samsung", "amazon", "netflix", "spotify",
            "youtube", "instagram", "twitter", "whatsapp", "telegram",
            "signal", "bluetooth", "wifi",
        ]
        for w in raw { words.insert(w) }
        return words
    }()

    private static let protectedWholeWords: Set<String> = [
        "cloudflare",
        "diarisation",
        "diarization",
        "everything",
        "standardised",
        "standardized",
        "reprompt",
        "reprompted",
        "reprompting",
        "reprompts",
        "transcript",
        "transcription",
        "transcriptions",
        "transcripts",
        "underneath",
        "visualisation",
        "visualization"
    ]

    private static let trailingShortFunctionWords: Set<String> = [
        "am", "as", "at", "be", "by", "do", "go", "he", "if", "in",
        "is", "it", "me", "my", "of", "on", "or", "so", "to", "up",
        "us", "we"
    ]

    private static let collapsedPhraseSubjectPronouns = [
        "they", "you", "she", "he", "we", "it", "i"
    ]
}
