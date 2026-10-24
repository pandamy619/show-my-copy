import Foundation
import Observation

/// How long a saved password stays in the history.
enum PasswordLifetime: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case tenMinutes = 600
    case oneHour = 3600

    static let `default` = PasswordLifetime.tenMinutes

    var id: Int { rawValue }

    var timeInterval: TimeInterval { TimeInterval(rawValue) }
}

/// What the clipboard monitor does with passwords: items with a password marker and items copied from a known
/// password manager.
struct PasswordPolicy: Equatable, Sendable {
    /// When false, passwords are not recorded. When true, they are recorded concealed and removed after `lifetime`.
    var savesPasswords: Bool
    var lifetime: TimeInterval

    static let `default` = PasswordPolicy(savesPasswords: false, lifetime: PasswordLifetime.default.timeInterval)
}

/// Stores the password choices in UserDefaults and applies them to the clipboard history.
@MainActor
@Observable
final class PasswordSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let history: any HistoryStore
    @ObservationIgnored private let now: @MainActor () -> Date

    /// Off by default. Turning it off removes every saved password from the history at once, and a damaged copy of
    /// the history, which may hold passwords too.
    var savesPasswords: Bool {
        didSet {
            guard savesPasswords != oldValue else {
                return
            }
            defaults.set(savesPasswords, forKey: SettingsKey.savePasswords)
            if !savesPasswords {
                history.removeConcealed()
                (history as? any KeepsDamagedHistory)?.deleteDamagedHistory()
            }
        }
    }

    /// A shorter lifetime also applies to passwords already in the history. A longer one applies to new ones.
    var lifetime: PasswordLifetime {
        didSet {
            guard lifetime != oldValue else {
                return
            }
            defaults.set(lifetime.rawValue, forKey: SettingsKey.passwordLifetime)
            history.limitExpiry(to: now() + lifetime.timeInterval)
        }
    }

    init(
        history: any HistoryStore,
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.history = history
        self.defaults = defaults
        self.now = now
        savesPasswords = Self.storedSavesPasswords(in: defaults)
        let storedLifetime = (defaults.object(forKey: SettingsKey.passwordLifetime) as? Int)
            .flatMap(PasswordLifetime.init(rawValue:))
        lifetime = storedLifetime ?? .default
    }

    /// The saved Save passwords choice, off when nothing valid is saved. Read before the history is loaded, so
    /// loading deletes saved passwords without opening them when saving them is off.
    nonisolated static func storedSavesPasswords(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: SettingsKey.savePasswords) as? Bool ?? false
    }

    var policy: PasswordPolicy {
        PasswordPolicy(savesPasswords: savesPasswords, lifetime: lifetime.timeInterval)
    }
}
