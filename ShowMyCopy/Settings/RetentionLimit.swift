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
    /// The age limit, saved in whole seconds, 0 for none. A negative value is not valid.
    static var age: RetentionLimit<HistoryAgeLimit> {
        RetentionLimit(
            key: SettingsKey.historyMaxAge,
            defaultValue: HistoryAgeLimit.default,
            decode: { saved in
                guard saved >= 0 else {
                    return nil
                }
                return saved == 0 ? .off : .after(.seconds(saved))
            },
            encode: { $0.seconds },
            value: { HistoryAgeLimit(maxAge: $0.maxAge) },
            apply: { $1.withMaxAge($0.maxAge) }
        )
    }
}

/// How long entries stay in the history after they were last copied. Pinned entries stay longer.
enum HistoryAgeLimit: Hashable, Sendable {
    case off
    case after(Duration)

    /// Off until Settings offers the age limit.
    static let `default` = HistoryAgeLimit.off

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
