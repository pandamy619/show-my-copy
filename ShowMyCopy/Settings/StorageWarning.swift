/// A history store that can say why the history is not, or not fully, saved. Only the store that saves to disk
/// conforms; a history kept in memory has nothing to report.
@MainActor
protocol ReportsStorageErrors: AnyObject {
    /// Nil while saving works. Views that read it are updated when it changes.
    var storageError: HistoryPersistenceError? { get }
}

/// What Settings → Storage tells the user about a storage problem: a plain message without technical details. The
/// app keeps working in every case.
enum StorageWarning: Equatable, Sendable {
    /// The store on disk could not be opened; the history is lost when the app quits.
    case notSaved
    /// The store on disk could not be read and a new, empty one was started.
    case historyReset
    /// The saved history could not be read.
    case historyNotLoaded
    /// The last change could not be written; the history in memory is complete.
    case changesNotSaved
    /// A password could not be encrypted, so it is kept in memory only.
    case passwordsNotSaved

    init(_ error: HistoryPersistenceError) {
        switch error {
        case .openFailed:
            self = .notSaved
        case .storeReset:
            self = .historyReset
        case .loadFailed:
            self = .historyNotLoaded
        case .saveFailed:
            self = .changesNotSaved
        case .sealFailed:
            self = .passwordsNotSaved
        }
    }
}
