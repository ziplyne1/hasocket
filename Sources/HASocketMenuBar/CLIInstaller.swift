// Symlinks the hasocket CLI binary bundled inside this .app (see
// scripts/build-app.sh) into ~/.local/bin, so `hasocket` works from a
// terminal without a separate CLI install step.
import Foundation

enum CLIInstallError: LocalizedError {
    case bundledBinaryMissing

    var errorDescription: String? {
        switch self {
        case .bundledBinaryMissing:
            return "hasocket CLI isn't bundled in this app - rebuild with scripts/build-app.sh."
        }
    }
}

enum CLIInstaller {
    static var bundledBinaryURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/hasocket")
    }

    static var symlinkURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/hasocket")
    }

    static var isSymlinkCurrent: Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path) else {
            return false
        }
        return URL(fileURLWithPath: destination).standardizedFileURL == bundledBinaryURL.standardizedFileURL
    }

    @discardableResult
    static func installSymlink() throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundledBinaryURL.path) else {
            throw CLIInstallError.bundledBinaryMissing
        }

        try fm.createDirectory(at: symlinkURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fm.fileExists(atPath: symlinkURL.path) || (try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path)) != nil {
            try fm.removeItem(at: symlinkURL)
        }
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: bundledBinaryURL)
        return symlinkURL
    }
}
