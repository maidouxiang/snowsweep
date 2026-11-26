import Foundation

/// 联网核验只查 Apple 的公开软件目录，且只发送应用自己的 Bundle ID。
/// 不上传文件路径、文件名、哈希、目录列表，也不把“查不到”当成“可以删”。
public enum AppReleaseFreshness: String, Sendable, Equatable {
    case active
    case aging
    case stale
    case unknown

    public var chineseName: String {
        switch self {
        case .active: return "仍在更新"
        case .aging: return "更新变慢"
        case .stale: return "很久没更新"
        case .unknown: return "没有日期"
        }
    }

    public var note: String {
        switch self {
        case .active:
            return "公开目录显示两年内有版本更新；这只是活跃度，不代表本机残留一定能删。"
        case .aging:
            return "公开目录显示最近一次更新在两到三年之间；可以核对，但不要只凭这一点删除。"
        case .stale:
            return "公开目录显示超过三年没有更新；可能停更，也可能转成了别的发行渠道。仍要结合本地宿主与文件证据。"
        case .unknown:
            return "公开目录没有给出可靠更新时间；请继续看本地签名、收据和宿主关系。"
        }
    }

    public static func classify(lastRelease: Date?, now: Date = Date()) -> AppReleaseFreshness {
        guard let lastRelease else { return .unknown }
        let days = now.timeIntervalSince(lastRelease) / 86_400
        if days < 0 { return .unknown }
        if days <= 730 { return .active }
        if days <= 1_095 { return .aging }
        return .stale
    }
}

public struct OnlineAppVerification: Sendable, Equatable {
    public let bundleID: String
    public let found: Bool
    public let appName: String?
    public let sellerName: String?
    public let version: String?
    public let lastRelease: Date?
    public let storeURL: String?
    public let freshness: AppReleaseFreshness

    public init(bundleID: String, found: Bool, appName: String? = nil,
                sellerName: String? = nil, version: String? = nil,
                lastRelease: Date? = nil, storeURL: String? = nil,
                freshness: AppReleaseFreshness = .unknown) {
        self.bundleID = bundleID
        self.found = found
        self.appName = appName
        self.sellerName = sellerName
        self.version = version
        self.lastRelease = lastRelease
        self.storeURL = storeURL
        self.freshness = freshness
    }

    public var summary: String {
        guard found else {
            return "Apple 公开目录里没有这条记录。它可能不是 App Store 软件，也可能已经下架；这不能证明文件没用。"
        }
        let name = appName ?? bundleID
        let versionText = version.map { " · 当前版本 \($0)" } ?? ""
        let dateText = lastRelease.map { " · 最近更新 \($0.formatted(date: .numeric, time: .omitted))" } ?? ""
        return "\(name)\(versionText)\(dateText) · \(freshness.chineseName)"
    }
}

public enum OnlineVerificationError: Error, LocalizedError, Equatable {
    case invalidBundleID
    case network(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .invalidBundleID:
            return "这条记录没有可核验的 Bundle ID"
        case let .network(reason):
            return "联网核验没有完成：\(reason)。本地证据仍然可用，未上传任何文件信息。"
        case .badResponse:
            return "公开目录返回了无法识别的结果；本次核验不改变任何判定。"
        }
    }
}

public struct OnlineAppVerifier: Sendable {
    public init() {}

    public static func lookupURL(bundleID: String, country: String = "cn") -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "entity", value: "macSoftware"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "1")
        ]
        return components?.url
    }

    public func verify(bundleID: String, country: String = "cn",
                       session: URLSession = .shared) async throws -> OnlineAppVerification {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 180,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }),
              let url = Self.lookupURL(bundleID: trimmed, country: country) else {
            throw OnlineVerificationError.invalidBundleID
        }

        let data: Data
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            throw OnlineVerificationError.network(error.localizedDescription)
        }
        guard let response = try? JSONDecoder().decode(AppStoreLookupResponse.self, from: data),
              response.resultCount >= 0 else {
            throw OnlineVerificationError.badResponse
        }
        guard let item = response.results.first else {
            return OnlineAppVerification(bundleID: trimmed, found: false)
        }
        let release = Self.parseDate(item.currentVersionReleaseDate) ?? Self.parseDate(item.releaseDate)
        return OnlineAppVerification(
            bundleID: trimmed,
            found: true,
            appName: item.trackName,
            sellerName: item.sellerName,
            version: item.version,
            lastRelease: release,
            storeURL: item.trackViewUrl,
            freshness: AppReleaseFreshness.classify(lastRelease: release)
        )
    }

    static func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.dateFormat = "yyyy-MM-dd"
        return plain.date(from: text)
    }
}

private struct AppStoreLookupResponse: Decodable {
    let resultCount: Int
    let results: [AppStoreItem]
}

private struct AppStoreItem: Decodable {
    let trackName: String?
    let sellerName: String?
    let version: String?
    let currentVersionReleaseDate: String?
    let releaseDate: String?
    let trackViewUrl: String?
}
