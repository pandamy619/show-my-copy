import Foundation

extension PasteTuning {
    /// What the next paste uses. Debug builds read overrides from the app's defaults on every paste
    /// (`debugOverrides`), so the owner can try other values on the Mac without a rebuild; Release builds always use
    /// `standard` and contain none of the keys (`make security` checks this, `DEBUG_ONLY_STRINGS`).
    @MainActor
    static func current() -> PasteTuning {
        #if DEBUG
            standard.overridden(by: UserDefaults.standard)
        #else
            standard
        #endif
    }
}

#if DEBUG
    extension PasteTuning {
        /// Debug builds only. Each key is optional; a value that is missing or out of range keeps the standard one.
        ///
        ///     defaults write com.pandamy619.ShowMyCopy debug.paste.settleMs -int 300
        ///     defaults write com.pandamy619.ShowMyCopy debug.paste.windowWaitMs -int 400
        ///     defaults write com.pandamy619.ShowMyCopy debug.paste.commandKey -bool NO
        ///     defaults write com.pandamy619.ShowMyCopy debug.paste.text -bool NO
        ///     defaults write com.pandamy619.ShowMyCopy debug.paste.tap annotated   # session, annotated or hid
        ///     defaults delete com.pandamy619.ShowMyCopy debug.paste.settleMs       # back to the standard value
        enum DebugKey {
            static let settleMilliseconds = "debug.paste.settleMs"
            static let windowWaitMilliseconds = "debug.paste.windowWaitMs"
            static let pressesCommandKey = "debug.paste.commandKey"
            static let carriesText = "debug.paste.text"
            static let tap = "debug.paste.tap"
        }

        /// The longest wait an override may ask for, so a typo cannot hold a paste for minutes.
        static let longestDebugWait: Duration = .seconds(2)

        func overridden(by defaults: UserDefaults) -> PasteTuning {
            var tuning = self
            if let settle = Self.milliseconds(defaults, DebugKey.settleMilliseconds) {
                tuning.timing.settleDelay = settle
            }
            if let windowWait = Self.milliseconds(defaults, DebugKey.windowWaitMilliseconds) {
                tuning.timing.longestWaitForWindow = windowWait
            }
            if defaults.object(forKey: DebugKey.pressesCommandKey) != nil {
                tuning.style.pressesCommandKey = defaults.bool(forKey: DebugKey.pressesCommandKey)
            }
            if defaults.object(forKey: DebugKey.carriesText) != nil {
                tuning.style.carriesText = defaults.bool(forKey: DebugKey.carriesText)
            }
            switch defaults.string(forKey: DebugKey.tap) {
            case "session":
                tuning.style.tap = .session
            case "annotated":
                tuning.style.tap = .annotatedSession
            case "hid":
                tuning.style.tap = .hid
            default:
                break
            }
            return tuning
        }

        private static func milliseconds(_ defaults: UserDefaults, _ key: String) -> Duration? {
            guard defaults.object(forKey: key) != nil else {
                return nil
            }
            let duration = Duration.milliseconds(defaults.integer(forKey: key))
            guard duration >= .zero, duration <= longestDebugWait else {
                return nil
            }
            return duration
        }
    }
#endif
