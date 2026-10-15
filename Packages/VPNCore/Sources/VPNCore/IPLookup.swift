import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public IP as seen by an IP lookup service.
public struct IPInfo: Equatable, Sendable {
    public let ip: String
    public let countryCode: String?
    public let city: String?
    public let organization: String?

    public init(ip: String, countryCode: String? = nil, city: String? = nil, organization: String? = nil) {
        self.ip = ip
        self.countryCode = countryCode
        self.city = city
        self.organization = organization
    }
}

/// Where the app asks "what is my IP". The user picks one in the settings;
/// requests go only there and only on the user's action or while connecting.
public enum IPService: String, CaseIterable, Codable, Identifiable, Sendable {
    case ipinfo
    case ifconfig

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ipinfo: "ipinfo.io"
        case .ifconfig: "ifconfig.co"
        }
    }

    public var url: URL {
        switch self {
        case .ipinfo: URL(string: "https://ipinfo.io/json")!
        case .ifconfig: URL(string: "https://ifconfig.co/json")!
        }
    }

    public func request(timeout: TimeInterval = 10) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Parses the service's JSON; text fields are length-limited and checked
    /// so that a broken or hostile answer cannot fill the window.
    public func parse(_ data: Data) throws -> IPInfo {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IPLookupError.badResponse
        }
        guard let ip = (object["ip"] as? String).flatMap(IPLookup.cleanIP) else {
            throw IPLookupError.badResponse
        }
        switch self {
        case .ipinfo:
            return IPInfo(
                ip: ip,
                countryCode: IPLookup.cleanCountry(object["country"] as? String),
                city: IPLookup.cleanText(object["city"] as? String),
                organization: IPLookup.cleanOrganization(object["org"] as? String)
            )
        case .ifconfig:
            return IPInfo(
                ip: ip,
                countryCode: IPLookup.cleanCountry(object["country_iso"] as? String),
                city: IPLookup.cleanText(object["city"] as? String),
                organization: IPLookup.cleanText(object["asn_org"] as? String)
            )
        }
    }
}

public enum IPLookupError: Error, Equatable {
    case badResponse
}

public enum IPLookup {
    /// "IP сменился": both lookups succeeded and the addresses differ.
    public static func changed(direct: IPInfo?, vpn: IPInfo?) -> Bool? {
        guard let direct, let vpn else { return nil }
        return direct.ip != vpn.ip
    }

    static func cleanIP(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...45).contains(trimmed.count) else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let isV4 = trimmed.split(separator: ".", omittingEmptySubsequences: false).count == 4
            && !trimmed.contains(":")
        return isV4 || trimmed.contains(":") ? trimmed : nil
    }

    static func cleanCountry(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).uppercased(), value.count == 2,
              value.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        return value
    }

    static func cleanText(_ value: String?) -> String? {
        guard let value else { return nil }
        let filtered = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        let trimmed = filtered.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(60))
    }

    /// ipinfo.io sends "AS64496 Example Hosting": drop the AS number.
    static func cleanOrganization(_ value: String?) -> String? {
        guard let text = cleanText(value) else { return nil }
        if text.hasPrefix("AS"), let space = text.firstIndex(of: " ") {
            let name = text[text.index(after: space)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? text : name
        }
        return text
    }
}
