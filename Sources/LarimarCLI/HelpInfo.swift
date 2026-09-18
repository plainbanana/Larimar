import Foundation

/// A help screen rendered as structured JSON instead of a wall of text.
struct HelpInfo: Encodable {
    var overview: String?
    var usage: String?
    var arguments: [Entry]?
    var options: [Entry]?
    var subcommands: [Entry]?
    /// The raw help screen, used when it does not follow the layout below.
    var lines: [String]?

    struct Entry: Encodable {
        let name: String
        let abstract: String?
    }
}

/// Turns the help screen ArgumentParser renders into ``HelpInfo``.
///
/// ArgumentParser has no API for the help text other than the rendered screen,
/// so this reads its layout: `OVERVIEW:` and `USAGE:` prefixes, `SECTION:`
/// headers, entries indented by two spaces with the description in a second
/// column, and continuation lines indented to that column.
enum HelpParser {
    private enum Section {
        case none
        case overview
        case usage
        case entries(WritableKeyPath<HelpInfo, [HelpInfo.Entry]?>)
    }

    static func parse(_ text: String) -> HelpInfo {
        var info = HelpInfo()
        var section = Section.none

        for line in text.components(separatedBy: "\n") {
            if line.isEmpty {
                section = .none
            } else if let overview = line.dropPrefix("OVERVIEW: ") {
                info.overview = overview
                section = .overview
            } else if let usage = line.dropPrefix("USAGE: ") {
                info.usage = usage
                section = .usage
            } else if let keyPath = sectionKeyPath(header: line) {
                section = .entries(keyPath)
            } else {
                append(line, to: &section, of: &info)
            }
        }

        if info.overview == nil && info.usage == nil && info.options == nil {
            return HelpInfo(lines: text.components(separatedBy: "\n"))
        }
        return info
    }

    /// Section headers are unindented, all caps and end with a colon.
    private static func sectionKeyPath(header: String) -> WritableKeyPath<HelpInfo, [HelpInfo.Entry]?>? {
        guard header.hasSuffix(":"), header == header.uppercased() else { return nil }
        switch header {
        case "ARGUMENTS:": return \.arguments
        case "OPTIONS:": return \.options
        case "SUBCOMMANDS:": return \.subcommands
        default: return nil
        }
    }

    private static func append(_ line: String, to section: inout Section, of info: inout HelpInfo) {
        let indent = line.prefix { $0 == " " }.count
        let text = line.trimmingCharacters(in: .whitespaces)

        switch section {
        case .none:
            break
        case .overview:
            info.overview = [info.overview, text].compactMap { $0 }.joined(separator: " ")
        case .usage:
            info.usage = [info.usage, text].compactMap { $0 }.joined(separator: " ")
        case .entries(let keyPath):
            // An entry name is indented by two spaces; anything deeper continues
            // the description of the entry above it.
            if indent > 2, var entries = info[keyPath: keyPath], let last = entries.popLast() {
                let abstract = [last.abstract, text].compactMap { $0 }.joined(separator: " ")
                entries.append(HelpInfo.Entry(name: last.name, abstract: abstract))
                info[keyPath: keyPath] = entries
            } else if let entry = parseEntry(text) {
                info[keyPath: keyPath] = (info[keyPath: keyPath] ?? []) + [entry]
            }
        }
    }

    /// Splits `--all                   Connect all tunnels` into name and abstract.
    /// Returns nil for the trailing notes that close a section.
    private static func parseEntry(_ text: String) -> HelpInfo.Entry? {
        guard let gap = text.range(of: "  ") else {
            return text.hasPrefix("See ") ? nil : HelpInfo.Entry(name: text, abstract: nil)
        }
        return HelpInfo.Entry(
            name: String(text[..<gap.lowerBound]),
            abstract: text[gap.upperBound...].trimmingCharacters(in: .whitespaces)
        )
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
