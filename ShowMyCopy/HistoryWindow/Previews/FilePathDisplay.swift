import Foundation

/// Where a copied file is, as the history window shows it: "~/Documents", "iCloud Drive/Projects",
/// "/Volumes/Backup". Worked out from the path saved with the entry alone, as text: nothing here looks at the file
/// system, so a path on a network volume, under `/net` or on a disk that is gone is shown at once, like any other.
struct FilePathDisplay: Sendable {
    /// The user's real home folder (`UserHome`), shortened to "~".
    static let current = FilePathDisplay(home: UserHome.path)

    /// What Finder calls iCloud Drive's folder. A product name, not translated.
    static let iCloudDriveName = "iCloud Drive"
    /// Where iCloud Drive keeps its files in the home folder. Folders of apps beside it and other cloud providers
    /// (`~/Library/CloudStorage`) are shown by their path: their names in Finder would need a lookup.
    static let iCloudDriveFolder = ["Library", "Mobile Documents", "com~apple~CloudDocs"]
    /// The longest path shown, in characters, as long as macOS paths get (`PATH_MAX`). Another app can put a far
    /// longer file URL on the clipboard; such a path is cut in the middle.
    static let maximumLength = 1_024
    /// How many paths the hover text of a files row lists before "and N more".
    static let listedFileCount = 3

    /// The paths of the first files of an entry and how many more there are.
    struct FileList: Equatable, Sendable {
        let paths: [String]
        let more: Int
    }

    /// The home folder's components, or nil when there is no usable home folder: then nothing is shortened.
    private let home: [String]?

    /// `home`: an absolute path. Nil, "/" or a relative path shortens nothing.
    init(home: String?) {
        let components = home.flatMap(CopiedPaths.normalizedComponents(of:))
        self.home = components?.isEmpty == false ? components : nil
    }

    /// The folder that holds the file, shown under its name in the preview.
    func folder(of file: FileReference) -> String? {
        folder(ofPath: file.path)
    }

    /// The folder that holds `path`, or nil for "/" and for a path that is not absolute.
    func folder(ofPath path: String) -> String? {
        guard let components = CopiedPaths.normalizedComponents(of: path), !components.isEmpty else {
            return nil
        }
        return shown(components.dropLast())
    }

    /// The whole path of the file, as its row shows it on hover.
    func path(of file: FileReference) -> String? {
        path(file.path)
    }

    /// The whole of `path`, or nil for a path that is not absolute.
    func path(_ path: String) -> String? {
        CopiedPaths.normalizedComponents(of: path).map { shown($0[...]) }
    }

    /// The paths of the first `listedFileCount` files and how many are left. One file more than that is listed
    /// instead of "and 1 more", which would take the same room.
    func list(of files: [FileReference]) -> FileList {
        let listed = files.count <= Self.listedFileCount + 1 ? files.count : Self.listedFileCount
        let paths = files.prefix(listed).map { path(of: $0) ?? Self.shortened(Self.sanitized($0.path)) }
        return FileList(paths: paths, more: files.count - listed)
    }

    private func shown(_ components: ArraySlice<String>) -> String {
        let text: String
        if let home, components.starts(with: home) {
            let inHome = components.dropFirst(home.count)
            if inHome.starts(with: Self.iCloudDriveFolder) {
                text = ([Self.iCloudDriveName] + inHome.dropFirst(Self.iCloudDriveFolder.count).map(Self.sanitized))
                    .joined(separator: "/")
            } else {
                text = (["~"] + inHome.map(Self.sanitized)).joined(separator: "/")
            }
        } else {
            text = "/" + components.map(Self.sanitized).joined(separator: "/")
        }
        return Self.shortened(text)
    }

    /// A path component without control and bidirectional formatting characters, which could make the path look
    /// like another, and with line breaks and tabs as spaces, so it stays on one line.
    static func sanitized(_ component: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in component.unicodeScalars {
            if EntryPreview.isLineBreak(scalar) || scalar == "\t" {
                scalars.append(" ")
            } else if !EntryPreview.isRemoved(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// `text` cut in the middle to `maximumLength` characters, keeping its start and its end.
    private static func shortened(_ text: String) -> String {
        guard text.count > maximumLength else {
            return text
        }
        let kept = maximumLength - EntryPreview.ellipsis.count
        let head = kept / 2
        return String(text.prefix(head)) + EntryPreview.ellipsis + String(text.suffix(kept - head))
    }
}

/// The user's home folder, such as "/Users/anna", for shortening paths to "~".
///
/// In the sandbox `NSHomeDirectory()`, `FileManager.homeDirectoryForCurrentUser` and `~` in `NSString` paths are
/// the app's container (`~/Library/Containers/<app>/Data`), not the folder the user knows. The user database
/// (`getpwuid_r`) says where the real one is, also when it was moved to another disk, without touching the file
/// system and without an entitlement. Read once, the first time a path is shown.
enum UserHome {
    static let path: String? = folder(ofUser: getuid())

    /// The home folder the user database lists for `uid`, or nil when it has none or cannot be read.
    static func folder(ofUser uid: uid_t) -> String? {
        let suggested = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        var buffer = [CChar](repeating: 0, count: suggested > 0 ? suggested : 16_384)
        return buffer.withUnsafeMutableBufferPointer { storage -> String? in
            var record = passwd()
            var found: UnsafeMutablePointer<passwd>?
            guard let base = storage.baseAddress, getpwuid_r(uid, &record, base, storage.count, &found) == 0,
                found != nil, let directory = record.pw_dir
            else {
                return nil
            }
            let path = String(cString: directory)
            return path.hasPrefix("/") ? path : nil
        }
    }
}
