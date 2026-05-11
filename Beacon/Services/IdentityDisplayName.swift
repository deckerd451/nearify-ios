import Foundation

enum IdentityDisplayName {
    static let fallback = "Nearify Member"

    static func primaryName(
        displayName: String? = nil,
        fullName: String? = nil,
        name: String? = nil,
        contactDisplayName: String? = nil,
        email: String? = nil,
        debugSource: String? = nil
    ) -> String {
        for candidate in [displayName, fullName, name] {
            if let normalized = nonEmailName(candidate) { return normalized }
        }

        if let contact = nonEmailName(contactDisplayName) { return contact }

        let rawEmail = [displayName, fullName, name, email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: isEmailLike)

        if let rawEmail, let humanized = humanizedEmailLocalPart(from: rawEmail) {
            #if DEBUG
            if let debugSource {
                print("[IdentityDisplay] replaced email fallback raw=\(rawEmail) display=\(humanized) source=\(debugSource)")
            } else {
                print("[IdentityDisplay] replaced email fallback raw=\(rawEmail) display=\(humanized)")
            }
            #endif
            return humanized
        }

        return fallback
    }

    static func nonEmailName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard !isEmailLike(value) else { return nil }
        return value
    }

    static func isEmailLike(_ raw: String) -> Bool {
        raw.contains("@")
    }

    static func humanizedEmailLocalPart(from rawEmailOrName: String) -> String? {
        let trimmed = rawEmailOrName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let localPart = trimmed.split(separator: "@").first.map(String.init) ?? ""
        guard !localPart.isEmpty else { return nil }

        var token = localPart
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "[._-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\d{4,}$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !token.isEmpty else { return nil }
        guard token.count >= 4 else { return nil }

        let parts = token.split(separator: " ").map(String.init)
        if parts.count == 1, let one = parts.first {
            let hasVowel = one.range(of: "[aeiou]", options: .regularExpression) != nil
            let longDigitRun = one.range(of: "\\d{3,}", options: .regularExpression) != nil
            if !hasVowel || longDigitRun { return nil }
        }

        token = parts.prefix(3).map {
            let lower = $0.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")

        return token.isEmpty ? nil : token
    }
}
