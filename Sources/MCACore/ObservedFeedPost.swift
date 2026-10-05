import Foundation

/// Conservative OCR evidence: only an author block with one explicitly labelled
/// metric qualifies. Bare icon counts and body-text mentions are not view metrics.
public struct ObservedFeedPost: Sendable, Equatable {
    public let author: String
    public let body: String
    public let displayedViews: String
    public let views: Double
    public let url: String?
    public var viewports: [Int]

    public static func extract(viewports: [String], minimumViews: Double) -> [ObservedFeedPost] {
        var result: [ObservedFeedPost] = []
        for (viewport, text) in viewports.enumerated() {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            let starts = lines.indices.filter { lines[$0].range(of: #"^@[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil }
            for (ordinal, start) in starts.enumerated() {
                let end = ordinal + 1 < starts.count ? starts[ordinal + 1] : lines.count
                let block = Array(lines[(start + 1)..<end])
                let metrics = block.enumerated().compactMap { index, line -> (Int, Double, String)? in
                    guard let count = parseViews(line) else { return nil }
                    return (index, count, line)
                }
                guard metrics.count == 1, let metric = metrics.first, metric.1 >= minimumViews else { continue }
                let body = block[..<metric.0].filter { !$0.isEmpty }.joined(separator: "\n")
                guard !body.isEmpty else { continue }
                let url = block.compactMap { line in
                    line.range(of: #"https?://(?:www\.)?(?:x\.com|twitter\.com)/[A-Za-z0-9_]+/status/[0-9]+"#, options: .regularExpression).map { String(line[$0]) }
                }.first
                let author = lines[start]
                if let index = result.firstIndex(where: { post in
                    if let url, let previous = post.url { return url == previous }
                    return post.author == author && post.body == body
                }) {
                    if !result[index].viewports.contains(viewport) { result[index].viewports.append(viewport) }
                } else {
                    result.append(ObservedFeedPost(author: author, body: body, displayedViews: metric.2,
                        views: metric.1, url: url, viewports: [viewport]))
                }
            }
        }
        return result
    }

    public static func parseViews(_ line: String) -> Double? {
        let pattern = #"^([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)\s*([kKmM万千]?)\s*(?:views?|ビュー|表示|閲覧|조회(?:수)?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let numberRange = Range(match.range(at: 1), in: line),
              let unitRange = Range(match.range(at: 2), in: line),
              let number = Double(line[numberRange].replacingOccurrences(of: ",", with: "")) else { return nil }
        let unit = String(line[unitRange]).lowercased()
        let multiplier: Double = unit == "m" ? 1_000_000 : unit == "万" ? 10_000 : (unit == "k" || unit == "千") ? 1_000 : 1
        let value = number * multiplier
        return value.isFinite ? value : nil
    }
}
