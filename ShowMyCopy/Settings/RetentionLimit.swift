import Foundation

/// One of the history limits the user chooses: how its choice is saved in UserDefaults, read back and applied to a
/// `RetentionPolicy`. `HistorySettings` and `LimitDraft` work with any of them, so a new limit is a field in
/// `RetentionPolicy`, one value here and its entry in `all`.
///
/// Every limit is saved as an `Int` under its own key. Nothing saved, or a value that is not valid, means the
/// default, so a later default applies to everyone who never chose; a deliberate choice, also No limit, is saved.
struct RetentionLimit<Value: Equatable & Sendable>: Sendable {
    let key: String
    /// The value when nothing valid is saved.
    let defaultValue: Value
    /// The value an `Int` saved under `key` stands for, or nil when it is not valid.
    let decode: @Sendable (Int) -> Value?
    /// What is saved for `value`.
    let encode: @Sendable (Value) -> Int
    /// The value `policy` has.
    let value: @Sendable (RetentionPolicy) -> Value
    /// `policy` with `value`.
    let apply: @Sendable (Value, RetentionPolicy) -> RetentionPolicy

    /// `value` as the policy holds it, such as an entry limit moved into its range.
    func normalized(_ value: Value) -> Value {
        self.value(apply(value, .default))
    }

    /// The saved choice, or the default when nothing valid is saved.
    func stored(in defaults: UserDefaults) -> Value {
        guard let saved = defaults.object(forKey: key) as? Int, let value = decode(saved) else {
            return defaultValue
        }
        return value
    }

    func save(_ value: Value, in defaults: UserDefaults) {
        defaults.set(encode(value), forKey: key)
    }
}

/// A limit whose value type does not matter to the caller: what loading the saved history needs.
protocol StoredRetentionLimit: Sendable {
    /// `policy` with the choice saved in `defaults`.
    func applyingStoredValue(in defaults: UserDefaults, to policy: RetentionPolicy) -> RetentionPolicy
}

extension RetentionLimit: StoredRetentionLimit {
    func applyingStoredValue(in defaults: UserDefaults, to policy: RetentionPolicy) -> RetentionPolicy {
        apply(stored(in: defaults), policy)
    }
}

/// Every limit the user chooses, applied in this order. Add a new limit here.
enum RetentionLimits {
    static let all: [any StoredRetentionLimit] = [
        RetentionLimit.entries,
        RetentionLimit.size,
        RetentionLimit.age,
    ]

    /// Every saved choice as one policy.
    static func stored(in defaults: UserDefaults) -> RetentionPolicy {
        all.reduce(RetentionPolicy.default) { policy, limit in
            limit.applyingStoredValue(in: defaults, to: policy)
        }
    }
}

extension RetentionLimit where Value == Int {
    /// The most entries kept, within `RetentionPolicy.entryLimitRange`. A saved value outside it is moved into it.
    static var entries: RetentionLimit<Int> {
        RetentionLimit(
            key: SettingsKey.historyLimit,
            defaultValue: RetentionPolicy.defaultEntryLimit,
            decode: { RetentionPolicy.clamped($0) },
            encode: { $0 },
            value: { $0.entryLimit },
            apply: { $1.withEntryLimit($0) }
        )
    }
}

extension RetentionLimit where Value == HistorySizeLimit {
    /// The size limit, as one of the options. 0 is saved for No limit; a negative value is not valid, and other
    /// sizes are moved to an option.
    static var size: RetentionLimit<HistorySizeLimit> {
        RetentionLimit(
            key: SettingsKey.historyByteLimit,
            defaultValue: HistorySizeLimit.default,
            decode: { saved in
                guard saved >= 0 else {
                    return nil
                }
                return saved == 0 ? .noLimit : HistorySizeLimit(byteLimit: saved)
            },
            encode: { $0.rawValue },
            value: { HistorySizeLimit(byteLimit: $0.byteLimit) },
            apply: { $1.withByteLimit($0.byteLimit) }
        )
    }
}

extension RetentionLimit where Value == HistoryAgeLimit {
    /// The age limit, saved in whole seconds, 0 for none, as one of the options. A negative value is not valid, and
    /// other ages are moved to an option.
    static var age: RetentionLimit<HistoryAgeLimit> {
        RetentionLimit(
            key: SettingsKey.historyMaxAge,
            defaultValue: HistoryAgeLimit.default,
            decode: { saved in
                guard saved >= 0 else {
                    return nil
                }
                return saved == 0 ? .off : HistoryAgeLimit.after(.seconds(saved)).offered
            },
            encode: { $0.seconds },
            value: { HistoryAgeLimit(maxAge: $0.maxAge).offered },
            apply: { $1.withMaxAge($0.maxAge) }
        )
    }
}

/// How long entries stay in the history after they were last copied. Pinned entries stay longer.
enum HistoryAgeLimit: Hashable, Sendable {
    case off
    case after(Duration)

    /// 8 hours, for everyone who has not chosen: clipboard history is private, so it is kept no longer than a working
    /// day unless the user asks for longer. A saved choice, Off included, stays.
    static let `default` = HistoryAgeLimit.hours(8)

    /// The age limits offered in Settings, shortest first, then Off.
    static let options: [HistoryAgeLimit] = [.hours(1), .hours(8), .hours(24), .days(7), .days(30), .off]

    /// How Settings names an age limit: in days from a week up, in hours below.
    enum Span: Hashable, Sendable {
        case hours(Int)
        case days(Int)
    }

    static func hours(_ count: Int) -> HistoryAgeLimit {
        .after(.seconds(count * 3600))
    }

    static func days(_ count: Int) -> HistoryAgeLimit {
        hours(count * 24)
    }

    /// The option that stands for this limit: the shortest that keeps entries at least as long, or the longest when
    /// none does, as the size limit does. Off stays off.
    var offered: HistoryAgeLimit {
        guard let maxAge else {
            return .off
        }
        let limited = Self.options.compactMap(\.maxAge)
        guard let option = limited.first(where: { $0 >= maxAge }) ?? limited.last else {
            return self
        }
        return .after(option)
    }

    /// The limit in the units Settings names it in, or nil when off. Whole units only, as the options are.
    var span: Span? {
        guard maxAge != nil else {
            return nil
        }
        let hours = seconds / 3600
        return hours >= 7 * 24 ? .days(hours / 24) : .hours(hours)
    }

    init(maxAge: Duration?) {
        guard let maxAge, maxAge > .zero else {
            self = .off
            return
        }
        self = .after(maxAge)
    }

    /// The age limit for `RetentionPolicy`, or nil for none. An age limit of no time at all is none.
    var maxAge: Duration? {
        switch self {
        case .after(let duration) where duration > .zero:
            duration
        case .off, .after:
            nil
        }
    }

    /// The whole seconds saved for it, 0 when off.
    var seconds: Int {
        maxAge.map { Int(clamping: $0.components.seconds) } ?? 0
    }
}
