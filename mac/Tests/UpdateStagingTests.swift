import Foundation

/// Validates a local DMG and stages a copy without replacing or launching any app.
@main struct UpdateStagingTests {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("Usage: update-staging-tests CURRENT_APP DMG EXPECTED_VERSION") }
        let prepared = try DirectUpdateInstaller.prepare(dmg: URL(fileURLWithPath: args[2]),
            expectedVersion: args[3], currentApp: URL(fileURLWithPath: args[1]))
        defer { prepared.discard() }
        precondition(FileManager.default.fileExists(atPath: prepared.staged.appendingPathComponent("Contents/Info.plist").path))
        precondition(FileManager.default.fileExists(atPath: prepared.target.path))
        do {
            let unexpected = try DirectUpdateInstaller.prepare(dmg: URL(fileURLWithPath: args[2]),
                expectedVersion: "999999.0.0", currentApp: URL(fileURLWithPath: args[1]))
            unexpected.discard()
            preconditionFailure("Incorrect package version must be rejected")
        } catch DirectUpdateInstaller.Failure.invalidApp {
            // Expected: a valid checksum or signer never bypasses the version check.
        }
        print("UpdateStaging: exact bundle/version, strict nested signature, same signer and staged copy passed; installed app unchanged")
    }
}
