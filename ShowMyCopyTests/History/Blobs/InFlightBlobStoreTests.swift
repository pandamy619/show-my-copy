import Foundation
import Testing

@testable import ShowMyCopy

struct InFlightBlobStoreTests {
    private let base = InMemoryBlobStore()
    private let blobs: InFlightBlobStore

    init() {
        blobs = InFlightBlobStore(base: base)
    }

    @Test func writesReadsAndDeletesLikeItsBase() throws {
        let id = try blobs.write(Data([1, 2]))
        #expect(try blobs.read(id) == Data([1, 2]))
        #expect(blobs.size(of: id) == 2)
        #expect(try blobs.allIDs() == [id])
        try blobs.delete([id])
        #expect(base.allIDs().isEmpty)
    }

    @Test func heldBlobIsNotDeletedUntilItsWorkReleasesIt() throws {
        let reservation = blobs.reservation()
        let id = reservation.newID()
        try blobs.write(Data([1]), as: id)

        try blobs.delete([id])
        #expect(base.contains(id))
        // The deletion was put off: the work gives the blob back to be deleted unless an entry uses it.
        #expect(reservation.release() == [id])
        try blobs.delete([id])
        #expect(!base.contains(id))
    }

    @Test func sweepDoesNotSeeHeldBlobs() throws {
        let settled = try blobs.write(Data([1]))
        let reservation = blobs.reservation()
        let inFlight = reservation.newID()
        try blobs.write(Data([2]), as: inFlight)
        #expect(try blobs.allIDs() == [settled])
        _ = reservation.release()
        #expect(try blobs.allIDs() == [settled, inFlight])
    }

    @Test func existingBlobHeldByWorkIsGivenBackOnlyWhenItsDeletionWasPutOff() throws {
        let kept = try blobs.write(Data([1]))
        let removed = try blobs.write(Data([2]))
        let reservation = blobs.reservation()
        reservation.hold([kept, removed])
        try blobs.delete([removed])

        #expect(reservation.release() == [removed])
        #expect(base.allIDs() == [kept, removed])
    }

    @Test func blobHeldByTwoWorksIsGivenBackByTheLastOne() throws {
        let id = try blobs.write(Data([1]))
        let first = blobs.reservation()
        let second = blobs.reservation()
        first.hold([id])
        second.hold([id])
        try blobs.delete([id])

        #expect(first.release().isEmpty)
        #expect(base.contains(id))
        #expect(second.release() == [id])
    }

    @Test func releasingTwiceGivesNothingBack() {
        let reservation = blobs.reservation()
        _ = reservation.newID()
        #expect(reservation.release().count == 1)
        #expect(reservation.release().isEmpty)
    }
}
