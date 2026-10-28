import Foundation
import CryptoKit

@main struct UpdatePolicyTests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); count += 1
        }
        check(UpdateVersion("0.6.10")! > UpdateVersion("0.6.9")!, "Numeric, not lexical comparison")
        check(UpdateVersion("0.6.5")! == UpdateVersion("0.6.5")!, "Same version")
        check(UpdateVersion("0.6.5-beta") == nil, "Reject prerelease filename")
        check(UpdateVersion("0.6") == nil, "Require complete version")
        check(UpdateVersion("0.-6.5") == nil, "Reject negative version")
        func asset(_ name: String, size: Int = 100, prefix: String = "https://github.com/goldenman-kr/tab-d/releases/download/v0.6.5/") -> ReleaseAsset {
            ReleaseAsset(name: name, size: size, browser_download_url: prefix + name)
        }
        let mac = asset("Mr-Tab-D-0.6.5-macOS-arm64.dmg")
        let sums = asset("SHA256SUMS.txt")
        let android = asset("Mr-Tab-D-0.9.0-Android.apk")
        check(UpdateRelease(draft: false, prerelease: false, assets: [mac, sums, android]).macUpdate(after: UpdateVersion("0.6.4")!)?.2 == UpdateVersion("0.6.5"), "Platform asset determines version")
        check(UpdateRelease(draft: false, prerelease: false, assets: [mac, sums]).macUpdate(after: UpdateVersion("0.6.5")!) == nil, "No reinstall")
        check(UpdateRelease(draft: false, prerelease: true, assets: [mac, sums]).macUpdate(after: UpdateVersion("0.6.4")!) == nil, "No prereleases")
        check(UpdateRelease(draft: true, prerelease: false, assets: [mac, sums]).macUpdate(after: UpdateVersion("0.6.4")!) == nil, "No drafts")
        check(UpdateRelease(draft: false, prerelease: false, assets: [mac]).macUpdate(after: UpdateVersion("0.6.4")!) == nil, "Require checksum manifest")
        check(asset(mac.name, prefix: "https://github.com/other/repo/releases/download/v1/").trustedURL == nil, "Only own repo")
        check(asset(mac.name, prefix: "http://github.com/goldenman-kr/tab-d/releases/download/v1/").trustedURL == nil, "HTTPS only")
        check(UpdateRelease(draft: false, prerelease: false, assets: [asset(mac.name, size: 128 * 1024 * 1024), sums]).macUpdate(after: UpdateVersion("0.6.4")!) == nil, "Size bound")
        check(ReleaseAsset(name: mac.name, size: 100, browser_download_url: mac.browser_download_url + "?x=1").trustedURL == nil, "Reject query")
        check(ReleaseAsset(name: mac.name, size: 100, browser_download_url: mac.browser_download_url + "#fragment").trustedURL == nil, "Reject fragment")
        check(asset(mac.name, prefix: "https://github.com/goldenman-kr/tab-d/releases/download/../").trustedURL == nil, "Reject traversal")
        check(asset(mac.name, prefix: "https://github.com/goldenman-kr/tab-d/releases/download/%2e%2e/").trustedURL == nil, "Reject encoded traversal")
        let data = Data("verified update".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try verifyUpdateChecksum(data, manifest: Data("\(hash)  \(mac.name)\n".utf8), name: mac.name)
        count += 1
        for invalid in ["\(hash)  different.dmg\n", "\(String(repeating: "0", count: 64))  \(mac.name)\n", "\(hash)  \(mac.name)\n\(hash)  \(mac.name)\n"] {
            do { try verifyUpdateChecksum(data, manifest: Data(invalid.utf8), name: mac.name); preconditionFailure("Must reject checksum") }
            catch { count += 1 }
        }
        print("UpdatePolicy: \(count) version / platform / origin / checksum checks passed")
    }
}
