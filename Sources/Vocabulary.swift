import Foundation

/// User-editable dictionary (~/Library/Application Support/Diktafon/slovnik.txt):
/// - plain lines are terms passed to Whisper as a hint (initial prompt),
/// - `wrong => right` lines are replacements applied to the transcript afterwards.
struct Vocabulary {
    static let url = Paths.support.appendingPathComponent("slovnik.txt")

    var terms: [String] = []
    var replacements: [(pattern: NSRegularExpression, replacement: String)] = []

    /// Hint for Whisper, or nil when there are no terms.
    var prompt: String? {
        terms.isEmpty ? nil : "Slovník: " + terms.joined(separator: ", ") + "."
    }

    /// Reads the file (creating it with defaults on first use).
    static func load() -> Vocabulary {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try? defaultContents.write(to: url, atomically: true, encoding: .utf8)
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Vocabulary(parsing: text)
    }

    init(parsing text: String) {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let arrow = line.range(of: "=>") {
                let wrong = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !wrong.isEmpty else { continue }
                // Whole words only, case-insensitive.
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: wrong) + "(?![\\p{L}\\p{N}])"
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    replacements.append((regex, NSRegularExpression.escapedTemplate(for: right)))
                }
            } else {
                terms.append(line)
            }
        }
    }

    func apply(to text: String) -> String {
        replacements.reduce(text) { result, rule in
            rule.pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                  withTemplate: rule.replacement)
        }
    }

    static let defaultContents = """
    # Slovník Diktafónu
    # Po uložení platí hneď pri ďalšom diktovaní (appku netreba reštartovať).
    #
    # 1) Slová a názvy, ktoré má model poznať a písať presne takto.
    #    Každé na samostatnom riadku.
    Claude
    Claude Code
    Anthropic
    GitHub
    commit
    pull request
    merge
    branch
    deploy
    feedback
    Slack

    # 2) Opravy: čo model napíše zle => ako to má byť.
    #    Nahrádzajú sa celé slová, na veľkých/malých písmenách nezáleží.
    Cloud Code => Claude Code
    Clod Code => Claude Code
    Klód kód => Claude Code
    Kód kód => Claude Code
    Klód => Claude
    """
}
