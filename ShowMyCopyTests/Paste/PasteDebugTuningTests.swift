import Foundation
import Testing

@testable import ShowMyCopy

#if DEBUG
    /// The overrides Debug builds read so the owner can try other values on the Mac (`PasteTuning.overridden(by:)`).
    /// Release builds have none of this.
    @MainActor
    struct PasteDebugTuningTests {
        private typealias Key = PasteTuning.DebugKey

        @Test func withoutOverridesItIsTheStandardTuning() async throws {
            try await ContainerFactory.withDefaults { defaults in
                #expect(PasteTuning.standard.overridden(by: defaults) == .standard)
            }
        }

        @Test func overridesTheWaitsInMilliseconds() async throws {
            try await ContainerFactory.withDefaults { defaults in
                defaults.set(300, forKey: Key.settleMilliseconds)
                defaults.set("40", forKey: Key.windowWaitMilliseconds)

                let tuning = PasteTuning.standard.overridden(by: defaults)

                #expect(tuning.timing.settleDelay == .milliseconds(300))
                #expect(tuning.timing.longestWaitForWindow == .milliseconds(40))
                #expect(tuning.timing.pollInterval == PasteTiming.standard.pollInterval)
                #expect(tuning.style == .standard)
            }
        }

        @Test func zeroIsAllowedButNotMoreThanTheLongestDebugWait() async throws {
            try await ContainerFactory.withDefaults { defaults in
                defaults.set(0, forKey: Key.settleMilliseconds)
                defaults.set(60_000, forKey: Key.windowWaitMilliseconds)
                #expect(PasteTuning.longestDebugWait == .seconds(2))

                let tuning = PasteTuning.standard.overridden(by: defaults)

                #expect(tuning.timing.settleDelay == .zero)
                #expect(tuning.timing.longestWaitForWindow == PasteTiming.standard.longestWaitForWindow)
            }
        }

        @Test func aNegativeWaitKeepsTheStandardOne() async throws {
            try await ContainerFactory.withDefaults { defaults in
                defaults.set(-5, forKey: Key.settleMilliseconds)
                #expect(PasteTuning.standard.overridden(by: defaults).timing == .standard)
            }
        }

        @Test func overridesHowCommandVIsPosted() async throws {
            try await ContainerFactory.withDefaults { defaults in
                defaults.set(false, forKey: Key.pressesCommandKey)
                defaults.set(false, forKey: Key.carriesText)
                defaults.set("annotated", forKey: Key.tap)

                let style = PasteTuning.standard.overridden(by: defaults).style

                let expected = PastePostingStyle(pressesCommandKey: false, carriesText: false, tap: .annotatedSession)
                #expect(style == expected)
            }
        }

        @Test func readsEveryTap() async throws {
            try await ContainerFactory.withDefaults { defaults in
                let taps: [String: PasteEventTap] = ["session": .session, "annotated": .annotatedSession, "hid": .hid]
                for (name, tap) in taps {
                    defaults.set(name, forKey: Key.tap)
                    #expect(PasteTuning.standard.overridden(by: defaults).style.tap == tap)
                }
                defaults.set("cgSessionEventTap", forKey: Key.tap)
                #expect(PasteTuning.standard.overridden(by: defaults).style.tap == PastePostingStyle.standard.tap)
            }
        }

        /// The keys the owner types in Terminal, as SECURITY.md and the paste check list give them. They share the
        /// prefix `make security` looks for in Release builds (`DEBUG_ONLY_STRINGS`).
        @Test func keysAreTheDocumentedOnes() {
            let keys = [
                Key.settleMilliseconds, Key.windowWaitMilliseconds, Key.pressesCommandKey, Key.carriesText, Key.tap,
            ]
            #expect(
                keys == [
                    "debug.paste.settleMs", "debug.paste.windowWaitMs", "debug.paste.commandKey", "debug.paste.text",
                    "debug.paste.tap",
                ])
            #expect(keys.allSatisfy { $0.hasPrefix("debug.paste.") })
        }
    }
#endif
