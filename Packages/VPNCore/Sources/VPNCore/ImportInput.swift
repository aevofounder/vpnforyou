/// Sorts what the user pasted into subscription URLs and servers.
public struct ImportInput: Equatable, Sendable {
    public var subscriptionURLs: [String]
    public var parsed: ParsedSubscription

    public var isEmpty: Bool { subscriptionURLs.isEmpty && parsed.isEmpty && parsed.skipped.isEmpty }

    public init(subscriptionURLs: [String] = [], parsed: ParsedSubscription = ParsedSubscription()) {
        self.subscriptionURLs = subscriptionURLs
        self.parsed = parsed
    }

    /// Lines with http(s) links are subscriptions; everything else is decoded as keys
    /// (share links, base64 list or Xray JSON).
    public static func classify(_ text: String) -> ImportInput {
        var urls: [String] = []
        var rest: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if (lower.hasPrefix("https://") || lower.hasPrefix("http://")), SubscriptionURL.validate(trimmed) != nil {
                if !urls.contains(trimmed) { urls.append(trimmed) }
            } else {
                rest.append(line)
            }
        }

        var input = ImportInput(subscriptionURLs: urls)
        let remaining = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remaining.isEmpty else { return input }
        do {
            input.parsed = try SubscriptionDecoder.decode(text: remaining)
        } catch let error as ImportError {
            input.parsed.skipped.append(SkippedEntry(name: "Вставленный текст", reason: error.message))
        } catch {
            input.parsed.skipped.append(SkippedEntry(name: "Вставленный текст", reason: ImportError.unrecognizedFormat.message))
        }
        return input
    }
}
