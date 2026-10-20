import AppKit

@MainActor
protocol PasteboardReading {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType] { get }
    func string() -> String?
}

@MainActor
final class SystemPasteboard: PasteboardReading {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    var types: [NSPasteboard.PasteboardType] {
        pasteboard.types ?? []
    }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }
}
