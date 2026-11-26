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
    case unavailable, commandFailed, invalidRelease, invalidArchive, cannotInstall

    var errorDescription: String? {
        switch self {
        case .unavailable: return "GitHub 下载暂时不可用，请稍后重试。"
        case .commandFailed: return "无法解包或验证更新的 App。"
        case .invalidRelease: return "这个版本没有适用于本机的更新包。"
        case .invalidArchive: return "更新包校验失败，已停止安装。"
        case .cannotInstall: return "当前 App 所在目录不可写。请先把 App 移到「应用程序」或自己的可写目录。"
        }
    }
}

enum UpdateInstallProgress: Sendable {
    case downloading(received: Int64, expected: Int64)
    case verifying
    case installing
}

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let archive: URL
    private let progress: @Sendable (UpdateInstallProgress) -> Void
    private let completion: CheckedContinuation<URLResponse, Error>
    // URLSession calls the delegate on its serial delegate queue.
    private var result: Result<URLResponse, Error>?

    init(archive: URL, progress: @escaping @Sendable (UpdateInstallProgress) -> Void,
         completion: CheckedContinuation<URLResponse, Error>) {
        self.archive = archive
        self.progress = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(.downloading(received: totalBytesWritten, expected: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        result = Result {
            guard let response = downloadTask.response else { throw UpdateError.unavailable }
            try FileManager.default.moveItem(at: location, to: archive)
            return response
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let error {
            completion.resume(throwing: error)
        } else {
            completion.resume(with: result ?? .failure(UpdateError.unavailable))
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

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()
    private let app: URL
    private let identifier: String
    private let currentVersion: String

    init(bundle: Bundle = .main) {
        app = bundle.bundleURL.resolvingSymlinksInPath()
        identifier = bundle.bundleIdentifier ?? ""
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    func latest() async throws -> GitHubRelease? {
        let url = URL(string: "https://github.com/\(Self.repository)/releases/latest/download/snap-gif-update.json")!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let (json, response) = try await session.data(for: request)
        try requireSuccess(response)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        guard let newer = versionParts(release.version), let current = versionParts(currentVersion),
              release.tag_name.hasPrefix("v") else { throw UpdateError.invalidRelease }
        guard current.lexicographicallyPrecedes(newer) else { return nil }
        guard release.assets.contains(where: { $0.name == Self.assetName }) else { throw UpdateError.invalidRelease }
        return release
    }

    func install(_ release: GitHubRelease,
                 progress: @escaping @Sendable (UpdateInstallProgress) -> Void = { _ in }) async throws {
        guard let asset = release.assets.first(where: { $0.name == Self.assetName }),
              let expected = asset.digest, expected.hasPrefix("sha256:") else {
            throw UpdateError.invalidArchive
        }
        let manager = FileManager.default
        let parent = app.deletingLastPathComponent()
        guard manager.isWritableFile(atPath: parent.path), app.pathExtension == "app" else {
            throw UpdateError.cannotInstall
        }
        let temp = parent.appendingPathComponent(".snap-gif-update-\(UUID().uuidString).noindex", isDirectory: true)
        try manager.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temp) }

        guard release.tag_name.hasPrefix("v"), versionParts(release.version) != nil else {
            throw UpdateError.invalidRelease
        }
        let url = URL(string: "https://github.com/\(Self.repository)/releases/download/\(release.tag_name)/\(Self.assetName)")!
        let archive = temp.appendingPathComponent("update.zip")
        let response = try await withCheckedThrowingContinuation { continuation in
            let delegate = UpdateDownloadDelegate(archive: archive, progress: progress, completion: continuation)
            let downloadSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
            downloadSession.downloadTask(with: url).resume()
        }
        try requireSuccess(response)
        progress(.verifying)
        let digest = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
        let actual = "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.invalidArchive }

        try run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, temp.path])
        let staged = temp.appendingPathComponent("snap-gif.app", isDirectory: true)
        guard let bundle = Bundle(url: staged), bundle.bundleIdentifier == identifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version else {
            throw UpdateError.invalidArchive
        }
        try run(URL(fileURLWithPath: "/usr/bin/codesign"),
                    ["--verify", "--strict", "--deep", "-R", "=identifier \"\(identifier)\"", staged.path])
        progress(.installing)
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

    private func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https" else { throw UpdateError.unavailable }
    }

    private func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.commandFailed }
    }
}
