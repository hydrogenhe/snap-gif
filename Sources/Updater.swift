import AppKit
import CryptoKit

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let digest: String?
    }

    let tag_name: String
    let assets: [Asset]
    var version: String { String(tag_name.dropFirst()) }
}

enum UpdateError: LocalizedError {
    case missingCLI, commandFailed, invalidRelease, invalidArchive, cannotInstall

    var errorDescription: String? {
        switch self {
        case .missingCLI: return "请安装 GitHub CLI，并运行 gh auth login 登录可访问仓库的账号。"
        case .commandFailed: return "GitHub 请求失败。请检查网络，以及 gh auth status 是否显示已登录。"
        case .invalidRelease: return "这个版本没有适用于本机的更新包。"
        case .invalidArchive: return "更新包校验失败，已停止安装。"
        case .cannotInstall: return "当前 App 所在目录不可写。请先把 App 移到「应用程序」或自己的可写目录。"
        }
    }
}

struct ReleaseUpdater {
    static let repository = "hydrogenhe/snap-gif"
    static let assetName: String = {
        #if arch(arm64)
        return "snap-gif-macOS-arm64.zip"
        #else
        return "snap-gif-macOS-x86_64.zip"
        #endif
    }()

    private let gh: URL
    private let app: URL
    private let identifier: String
    private let currentVersion: String

    init(bundle: Bundle = .main) throws {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw UpdateError.missingCLI
        }
        gh = URL(fileURLWithPath: path)
        app = bundle.bundleURL.resolvingSymlinksInPath()
        identifier = bundle.bundleIdentifier ?? ""
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    func latest() throws -> GitHubRelease? {
        let json = try run(gh, ["api", "--hostname", "github.com", "repos/\(Self.repository)/releases/latest"])
        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        guard let newer = versionParts(release.version), let current = versionParts(currentVersion),
              release.tag_name.hasPrefix("v") else { throw UpdateError.invalidRelease }
        guard current.lexicographicallyPrecedes(newer) else { return nil }
        guard release.assets.contains(where: { $0.name == Self.assetName }) else { throw UpdateError.invalidRelease }
        return release
    }

    func install(_ release: GitHubRelease) throws {
        guard let asset = release.assets.first(where: { $0.name == Self.assetName }),
              let expected = asset.digest, expected.hasPrefix("sha256:") else {
            throw UpdateError.invalidArchive
        }
        let manager = FileManager.default
        let parent = app.deletingLastPathComponent()
        guard manager.isWritableFile(atPath: parent.path), app.pathExtension == "app" else {
            throw UpdateError.cannotInstall
        }
        let temp = parent.appendingPathComponent(".snap-gif-update-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temp) }

        let archive = temp.appendingPathComponent("update.zip")
        _ = try run(gh, ["release", "download", release.tag_name, "--repo", Self.repository,
                         "--pattern", Self.assetName, "--output", archive.path])
        let digest = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
        let actual = "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.invalidArchive }

        _ = try run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, temp.path])
        let staged = temp.appendingPathComponent("snap-gif.app", isDirectory: true)
        guard let bundle = Bundle(url: staged), bundle.bundleIdentifier == identifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version else {
            throw UpdateError.invalidArchive
        }
        _ = try run(URL(fileURLWithPath: "/usr/bin/codesign"),
                    ["--verify", "--strict", "--deep", "-R", "=identifier \"\(identifier)\"", staged.path])
        _ = try manager.replaceItemAt(app, withItemAt: staged, backupItemName: nil,
                                      options: [.usingNewMetadataOnly])
    }

    func relaunchAfterExit() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\"",
                           "snap-gif-relaunch", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try child.run()
    }

    private func versionParts(_ raw: String) -> [Int]? {
        let fields = raw.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int($0) }
        guard fields.count == 3, numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }),
              numbers.map(String.init).joined(separator: ".") == raw else { return nil }
        return numbers
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Finder launches without a shell. Inherit the Keychain login through gh itself.
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"
        ]) { _, value in value }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.commandFailed }
        return result
    }
}
