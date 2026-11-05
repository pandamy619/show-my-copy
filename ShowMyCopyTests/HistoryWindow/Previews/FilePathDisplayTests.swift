import Foundation
import Testing

@testable import ShowMyCopy

struct FilePathDisplayTests {
    private let display = FilePathDisplay(home: "/Users/anna")

    @Test func folderInTheHomeFolderStartsWithATilde() {
        #expect(display.folder(ofPath: "/Users/anna/Documents/Report.pdf") == "~/Documents")
        #expect(display.folder(ofPath: "/Users/anna/Documents/Work/Plan.key") == "~/Documents/Work")
    }

    @Test func fileRightInTheHomeFolderIsInTilde() {
        #expect(display.folder(ofPath: "/Users/anna/notes.txt") == "~")
    }

    @Test func homeFolderItselfIsInUsers() {
        #expect(display.folder(ofPath: "/Users/anna") == "/Users")
        #expect(display.path("/Users/anna") == "~")
    }

    @Test func anotherUsersFolderWithTheSameStartIsNotAbbreviated() {
        // Matched by whole components: /Users/annabel is not inside /Users/anna.
        #expect(display.folder(ofPath: "/Users/annabel/Desktop/a.txt") == "/Users/annabel/Desktop")
        #expect(display.folder(ofPath: "/Users/Shared/a.txt") == "/Users/Shared")
    }

    @Test func homeWithATrailingSlashIsAbbreviatedAlike() {
        let display = FilePathDisplay(home: "/Users/anna/")
        #expect(display.folder(ofPath: "/Users/anna/Desktop/a.txt") == "~/Desktop")
    }

    @Test func homeOnAnotherVolumeIsAbbreviated() {
        // A home folder moved to another disk, as Users & Groups allows: the user database says where it is.
        let display = FilePathDisplay(home: "/Volumes/Home/anna")
        #expect(display.folder(ofPath: "/Volumes/Home/anna/Movies/clip.mov") == "~/Movies")
    }

    @Test func pathsOutsideTheHomeFolderAreShownInFull() {
        #expect(display.folder(ofPath: "/Applications/Safari.app") == "/Applications")
        #expect(display.folder(ofPath: "/Volumes/Backup/Photos/IMG_0001.HEIC") == "/Volumes/Backup/Photos")
        #expect(display.folder(ofPath: "/net/fileserver/share/report.pdf") == "/net/fileserver/share")
        #expect(display.folder(ofPath: "/Network/Servers/host/a.txt") == "/Network/Servers/host")
    }

    @Test func volumeRootIsInVolumesAndTheStartupDiskHasNoFolder() {
        #expect(display.folder(ofPath: "/Volumes/Backup") == "/Volumes")
        #expect(display.folder(ofPath: "/Volumes/Backup/") == "/Volumes")
        #expect(display.folder(ofPath: "/Applications") == "/")
        #expect(display.folder(ofPath: "/") == nil)
        #expect(display.path("/") == "/")
    }

    @Test func folderURLsWithATrailingSlashShowTheirParent() throws {
        let folder = URL(fileURLWithPath: "/Users/anna/Projects/App/", isDirectory: true)
        #expect(display.folder(of: FileReference(url: folder)) == "~/Projects")
        #expect(display.path(of: FileReference(url: folder)) == "~/Projects/App")
    }

    @Test func dotsAreResolvedByName() {
        #expect(display.folder(ofPath: "/Users/anna/./Documents/../Desktop/a.txt") == "~/Desktop")
    }

    @Test func relativePathsAreNotShown() {
        #expect(display.folder(ofPath: "Documents/a.txt") == nil)
        #expect(display.path("Documents/a.txt") == nil)
    }

    @Test func withoutAHomeNothingIsAbbreviated() {
        let display = FilePathDisplay(home: nil)
        #expect(display.folder(ofPath: "/Users/anna/Documents/a.txt") == "/Users/anna/Documents")
    }

    @Test func rootOrRelativeHomeIsIgnored() {
        // A home of "/" would turn every path into "~/…".
        #expect(FilePathDisplay(home: "/").folder(ofPath: "/Applications/a.app") == "/Applications")
        #expect(FilePathDisplay(home: "anna").folder(ofPath: "/anna/a.txt") == "/anna")
    }

    @Test func iCloudDriveIsShownByName() {
        let cloud = "/Users/anna/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(display.folder(ofPath: "\(cloud)/Projects/Plan.pages") == "iCloud Drive/Projects")
        #expect(display.folder(ofPath: "\(cloud)/Plan.pages") == "iCloud Drive")
        #expect(display.path("\(cloud)/Projects/Plan.pages") == "iCloud Drive/Projects/Plan.pages")
        #expect(display.path(cloud) == "iCloud Drive")
    }

    @Test func otherCloudFoldersKeepTheirPath() {
        // Only iCloud Drive's own folder has a name that needs no lookup; app folders and other providers do not.
        #expect(
            display.folder(ofPath: "/Users/anna/Library/Mobile Documents/iCloud~com~apple~Pages/Documents/a.pages")
                == "~/Library/Mobile Documents/iCloud~com~apple~Pages/Documents")
        #expect(
            display.folder(ofPath: "/Users/anna/Library/CloudStorage/Dropbox/Work/a.txt")
                == "~/Library/CloudStorage/Dropbox/Work")
    }

    @Test func iCloudDriveOfAnotherUserIsNotRenamed() {
        #expect(
            display.folder(ofPath: "/Users/boris/Library/Mobile Documents/com~apple~CloudDocs/a.txt")
                == "/Users/boris/Library/Mobile Documents/com~apple~CloudDocs")
    }

    @Test func controlAndDirectionCharactersAreRemoved() {
        // A folder name with a right-to-left override would show the rest of the path backwards.
        let path = "/Users/anna/evil\u{202E}txt.exe/line\nbreak\u{0007}/a.txt"
        #expect(display.folder(ofPath: path) == "~/eviltxt.exe/line break")
    }

    @Test func veryLongPathsAreCutInTheMiddle() throws {
        let long = String(repeating: "a", count: 3_000)
        let shown = try #require(display.folder(ofPath: "/Volumes/Disk/\(long)/end/file.txt"))
        #expect(shown.count == FilePathDisplay.maximumLength)
        #expect(shown.hasPrefix("/Volumes/Disk/aaa"))
        #expect(shown.hasSuffix("aaa/end"))
        #expect(shown.contains(EntryPreview.ellipsis))
    }

    @Test func pathsUpToTheLimitAreKeptWhole() throws {
        let path = "/" + String(repeating: "b", count: FilePathDisplay.maximumLength - 1)
        #expect(display.path(path) == path)
    }

    @Test func fewFilesAreAllListed() {
        let files = ["/Users/anna/a.txt", "/Users/anna/b.txt"].map(file)
        #expect(display.list(of: files) == FilePathDisplay.FileList(paths: ["~/a.txt", "~/b.txt"], more: 0))
    }

    @Test func oneMoreFileIsListedInsteadOfAndOneMore() {
        let files = (1...4).map { file("/Users/anna/\($0).txt") }
        let list = display.list(of: files)
        #expect(list.paths == ["~/1.txt", "~/2.txt", "~/3.txt", "~/4.txt"])
        #expect(list.more == 0)
    }

    @Test func manyFilesListTheFirstFewAndCountTheRest() {
        let files = (1...10).map { file("/Volumes/Backup/\($0).jpg") }
        let list = display.list(of: files)
        #expect(list.paths == ["/Volumes/Backup/1.jpg", "/Volumes/Backup/2.jpg", "/Volumes/Backup/3.jpg"])
        #expect(list.more == 7)
    }

    @Test func noFilesListNothing() {
        #expect(display.list(of: []) == FilePathDisplay.FileList(paths: [], more: 0))
    }

    private func file(_ path: String) -> FileReference {
        FileReference(url: URL(fileURLWithPath: path))
    }
}

struct UserHomeTests {
    @Test func homeIsTheUsersOwnFolderNotTheSandboxContainer() throws {
        let home = try #require(UserHome.path)
        #expect(home.hasPrefix("/"))
        // In the sandbox NSHomeDirectory() is the app's container, inside the real home folder.
        #expect(!home.contains("/Library/Containers/"))
        if NSHomeDirectory().contains("/Library/Containers/") {
            #expect(NSHomeDirectory().hasPrefix(home + "/"))
        }
    }

    @Test func unknownUserHasNoHome() {
        #expect(UserHome.folder(ofUser: 3_999_999_999) == nil)
    }
}

struct FilePreviewItemFolderTests {
    @Test func previewItemShowsTheFolderOfItsFile() {
        let item = FilePreviewItem(id: 0, file: FileReference(url: URL(fileURLWithPath: "/Volumes/Backup/a.jpg")))
        #expect(item.folder == "/Volumes/Backup")
    }

    @Test func previewItemAbbreviatesTheRealHomeFolder() throws {
        let home = try #require(UserHome.path)
        let item = FilePreviewItem(id: 0, file: FileReference(url: URL(fileURLWithPath: home + "/Documents/a.txt")))
        #expect(item.folder == "~/Documents")
    }
}
