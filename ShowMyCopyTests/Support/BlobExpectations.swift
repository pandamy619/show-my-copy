import Testing

@testable import ShowMyCopy

/// Expects `blobs` to hold exactly the blobs that the entries of `history` use: none missing and none left over.
@MainActor
func expectEveryBlobBelongsToAnEntry(
    of history: any HistoryStore, in blobs: any BlobStore, sourceLocation: SourceLocation = #_sourceLocation
) {
    let used = Set(history.entries.flatMap(\.content.blobIDs))
    #expect(used.allSatisfy { blobs.contains($0) }, sourceLocation: sourceLocation)
    do {
        #expect(try blobs.allIDs() == used, sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}
