import Foundation
import CryptoKit

struct UpdateVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ value: String) {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              fields.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = fields.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    var description: String { parts.map(String.init).joined(separator: ".") }
}

struct ReleaseAsset: Decodable {
    let name: String
    let size: Int
    let browser_download_url: String
    var trustedURL: URL? {
        guard let url = URL(string: browser_download_url), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              !encoded.contains("%"), !encoded.split(separator: "/").contains(".."),
              !encoded.split(separator: "/").contains("."),
              encoded.split(separator: "/").count == 6,
              url.path.hasPrefix("/goldenman-kr/tab-d/releases/download/"),
              url.lastPathComponent == name else { return nil }
        return url
    }
}
struct UpdateRelease: Decodable {
    let draft: Bool
    let prerelease: Bool
    let assets: [ReleaseAsset]
    func macUpdate(after current: UpdateVersion) -> (ReleaseAsset, ReleaseAsset, UpdateVersion)? {
        guard !draft, !prerelease,
              let sums = assets.first(where: { $0.name == "SHA256SUMS.txt" && $0.size > 0 && $0.size <= 65536 && $0.trustedURL != nil }) else { return nil }
        let prefix = "Mr-Tab-D-", suffix = "-macOS-arm64.dmg"
        return assets.compactMap { asset -> (ReleaseAsset, ReleaseAsset, UpdateVersion)? in
            guard asset.name.hasPrefix(prefix), asset.name.hasSuffix(suffix), asset.size > 0,
                  asset.size <= 64 * 1024 * 1024, asset.trustedURL != nil,
                  let version = UpdateVersion(String(asset.name.dropFirst(prefix.count).dropLast(suffix.count))),
                  version > current else { return nil }
            return (asset, sums, version)
        }.max { $0.2 < $1.2 }
    }
}

enum UpdateCheckError: LocalizedError {
    case invalidResponse, tooLarge, checksum, downloadSize
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub의 업데이트 응답을 확인하지 못했습니다."
        case .tooLarge: return "업데이트 파일이 허용된 크기를 초과했습니다."
        case .checksum: return "파일 무결성 확인에 실패했습니다. 설치 파일을 열지 않았습니다."
        case .downloadSize: return "설치 파일 크기가 릴리즈 정보와 다릅니다."
        }
    }
}

func verifyUpdateChecksum(_ data: Data, manifest: Data, name: String) throws {
    guard let text = String(data: manifest, encoding: .utf8) else { throw UpdateCheckError.checksum }
    let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, String(fields[1]) == name else { return nil }
        let hex = String(fields[0]).lowercased()
        guard hex.count == 64, hex.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return hex
    }
    guard matches.count == 1,
          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == matches[0] else {
        throw UpdateCheckError.checksum
    }
}
