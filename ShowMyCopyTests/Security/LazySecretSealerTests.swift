import Foundation
import Synchronization
import Testing

@testable import ShowMyCopy

/// Makes sealers and counts how often it was asked to, from any thread.
final class SealerFactorySpy: Sendable {
    private let count = Mutex(0)
    private let fails: Bool

    init(fails: Bool = false) {
        self.fails = fails
    }

    var calls: Int {
        count.withLock { $0 }
    }

    func make() throws -> any SecretSealing {
        count.withLock { $0 += 1 }
        if fails {
            throw SecretSealingError.keyUnavailable(.accessDenied)
        }
        return FakeSecretSealer()
    }

    func makeLazySealer() -> LazySecretSealer {
        LazySecretSealer { [self] in try make() }
    }
}

struct LazySecretSealerTests {
    @Test func doesNotCreateTheSealerUntilItIsUsed() {
        let factory = SealerFactorySpy()
        _ = factory.makeLazySealer()
        #expect(factory.calls == 0)
    }

    @Test func createsTheSealerOnFirstUseAndKeepsIt() throws {
        let factory = SealerFactorySpy()
        let sealer = factory.makeLazySealer()

        let sealed = try sealer.seal(Data("hunter2".utf8))
        #expect(factory.calls == 1)
        #expect(sealed != Data("hunter2".utf8))
        #expect(try sealer.open(sealed) == Data("hunter2".utf8))
        _ = try sealer.seal(Data("again".utf8))
        #expect(factory.calls == 1)
    }

    @Test func openingFirstAlsoCreatesTheSealer() throws {
        let factory = SealerFactorySpy()
        let sealer = factory.makeLazySealer()
        let sealed = try FakeSecretSealer().seal(Data("hunter2".utf8))

        #expect(try sealer.open(sealed) == Data("hunter2".utf8))
        #expect(factory.calls == 1)
    }

    @Test func remembersAFailureForTheRestOfTheSession() {
        let factory = SealerFactorySpy(fails: true)
        let sealer = factory.makeLazySealer()

        #expect(throws: SecretSealingError.keyUnavailable(.accessDenied)) {
            try sealer.seal(Data("a".utf8))
        }
        #expect(throws: SecretSealingError.keyUnavailable(.accessDenied)) {
            try sealer.open(Data("b".utf8))
        }
        #expect(throws: SecretSealingError.keyUnavailable(.accessDenied)) {
            try sealer.seal(Data("c".utf8))
        }
        #expect(factory.calls == 1)
    }

    @Test func concurrentFirstUseCreatesTheSealerOnce() async throws {
        let factory = SealerFactorySpy()
        let sealer = factory.makeLazySealer()

        let opened = try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0..<64 {
                group.addTask {
                    try sealer.open(try sealer.seal(Data("item \(index)".utf8)))
                }
            }
            var results: [Data] = []
            for try await data in group {
                results.append(data)
            }
            return results
        }

        #expect(opened.count == 64)
        #expect(factory.calls == 1)
    }
}
