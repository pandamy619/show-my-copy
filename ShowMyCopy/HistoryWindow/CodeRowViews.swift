import SwiftUI

/// The rows of the Codes section: each account with its code as it is now and how long it stays valid, redrawn
/// every second while the window is open. A click copies the code, like Return on the selected row.
struct CodeRows: View {
    let accounts: [CodeAccount]
    let selectedID: UUID?
    let model: HistoryWindowModel
    /// The row's account and whether ⌥ was held, which does the other of what Return does.
    let onClick: @MainActor (CodeAccount, Bool) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ForEach(accounts) { account in
                CodeRow(account: account, now: context.date, isSelected: account.id == selectedID) { isAlternate in
                    onClick(account, isAlternate)
                }
                .id(account.id)
            }
        }
    }
}

/// One account: its name, the code in groups of three digits, and a ring that empties as the code's time runs out.
struct CodeRow: View {
    let account: CodeAccount
    let now: Date
    let isSelected: Bool
    let onClick: @MainActor (Bool) -> Void

    var body: some View {
        let code = account.code(at: now)
        let remaining = max(0, Int(code.validUntil.timeIntervalSince(now).rounded(.up)))
        let period = max(account.account.period, 1)
        Button {
            onClick(NSEvent.modifierFlags.contains(.option))
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: Self.grouped(code.digits))
                        .font(.title3.monospacedDigit().weight(.medium))
                    Text(verbatim: account.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                CountdownRing(fraction: Double(remaining) / Double(period), seconds: remaining)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(account.displayName), code \(Self.spelled(code.digits))"))
        .accessibilityValue(Text("\(remaining) seconds left"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(Text("Copy the code"))
    }

    /// "123 456" or "1234 5678": easier to read back than six or eight digits in a row.
    static func grouped(_ digits: String) -> String {
        let half = digits.count / 2
        return digits.prefix(half) + " " + digits.dropFirst(half)
    }

    /// The digits one by one, so VoiceOver reads "one two three" rather than a number.
    static func spelled(_ digits: String) -> String {
        digits.map(String.init).joined(separator: " ")
    }
}

/// A ring that shows how much of the code's time is left, with the seconds inside.
private struct CountdownRing: View {
    let fraction: Double
    let seconds: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(
                    seconds <= 5 ? Color.red : Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text(verbatim: String(seconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}
