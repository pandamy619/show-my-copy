import SwiftUI

/// Settings → Codes: the accounts, with a button to remove each, and how to add more.
struct CodesSettingsPage: View {
    @Bindable var codes: CodesSettings

    var body: some View {
        Form {
            accountsSection
            addSection
        }
        .formStyle(.grouped)
    }

    private var accountsSection: some View {
        Section("Accounts") {
            if codes.accounts.isEmpty {
                Text("No accounts yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(codes.accounts) { account in
                HStack {
                    Text(verbatim: account.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        Task {
                            await codes.remove(account)
                        }
                    } label: {
                        Label("Remove \(account.displayName)", systemImage: "minus.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Remove \(account.displayName)"))
                }
            }
            if let warning = Self.storageWarning(for: codes.store) {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("The button next to the gear in the history window (or ⌘K) shows the codes.")
                Text("They are hidden each time the window opens.")
                Text("Choosing one copies it. The code leaves the clipboard when its time is up.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addSection: some View {
        Section("Add accounts") {
            TextField("Address or key", text: $codes.draft, prompt: Text("otpauth://… or a key"), axis: .vertical)
                .lineLimit(1...4)
                .fontDesign(.monospaced)
            TextField("Service", text: $codes.draftIssuer, prompt: Text("For a key: GitHub, Google…"))
            TextField("Account", text: $codes.draftName, prompt: Text("For a key: your name or e-mail"))
            HStack {
                Button("Add") {
                    Task {
                        await codes.addDraft()
                    }
                }
                .disabled(codes.isBusy || codes.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Read QR Code from Clipboard") {
                    Task {
                        await codes.importFromClipboard()
                    }
                }
                .disabled(codes.isBusy)
            }
            if let note = codes.note {
                Self.text(for: note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("From Google Authenticator: Transfer accounts → Export accounts, then screenshot the QR code.")
                Text("Copy the screenshot to this Mac and click Read QR Code from Clipboard.")
                Text("The screenshot is then removed from the history and the clipboard.")
                Text("From a service: paste the otpauth:// address or the key shown next to its QR code.")
                Text("Only time-based codes are supported. Secrets are encrypted and kept only on this Mac.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Why the accounts are not saved, or nil while they are.
    static func storageWarning(for store: CodeAccountStore) -> LocalizedStringKey? {
        if store.lastSaveFailed {
            return "The accounts could not be saved. They are kept until the app quits."
        }
        switch store.availability {
        case .loading, .ready:
            return nil
        case .unavailable(.keyLockedOut):
            return "The Keychain is locked: saved accounts are not loaded yet, new ones are kept until the app quits."
        case .unavailable(.keyUnavailable):
            return "The Keychain key is unavailable, so accounts are kept only until the app quits."
        case .unavailable(.damaged):
            return
                "The saved accounts could not be opened and are left alone. New ones are kept until the app quits."
        case .unavailable(.newerFormat):
            return "The accounts were saved by a newer Show My Copy. New ones are kept until the app quits."
        case .unavailable(.unreadable), .unavailable(.accounts):
            return "The saved accounts could not be read. New ones are kept until the app quits."
        }
    }

    static func text(for note: CodesSettings.Note) -> Text {
        switch note {
        case .imported(let summary):
            summaryText(summary)
        case .failed(let failure), .notAnAccount(let failure):
            failureText(failure)
        case .noImage:
            Text("The clipboard holds no image.")
        case .noQRCode:
            Text("No QR code was found in the copied image.")
        }
    }

    private static func summaryText(_ summary: CodeImportSummary) -> Text {
        var parts: [Text] = []
        parts.append(Text("Added \(summary.added) accounts."))
        if summary.duplicates > 0 {
            parts.append(Text("\(summary.duplicates) were in the list already."))
        }
        if !summary.skipped.isEmpty {
            let names = summary.skipped.map { CodeAccount(account: placeholder($0), addedAt: .distantPast).displayName }
            parts.append(
                Text("Not supported: \(names.joined(separator: ", ")) (counter-based or an unknown algorithm)."))
        }
        if let index = summary.batchIndex, let size = summary.batchSize, size > 1 {
            parts.append(Text("This was QR code \(index + 1) of \(size)."))
        }
        if summary.screenshotRemoved {
            parts.append(Text("The screenshot was removed from the history and the clipboard."))
        }
        if summary.screenshotKeptUnsaved {
            parts.append(Text("The screenshot was kept, because the accounts are not saved on this Mac yet."))
        }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: " ") + $1 }
    }

    /// A skipped account's names, for the list of what was not imported.
    private static func placeholder(_ skipped: SkippedAccount) -> OneTimeCodeAccount {
        OneTimeCodeAccount(
            issuer: skipped.issuer, name: skipped.name, secret: Data([0]), algorithm: .sha1, digits: .six,
            period: OneTimeCodeAccount.defaultPeriod)
    }

    private static func failureText(_ failure: CodeImport.Failure) -> Text {
        switch failure {
        case .empty:
            Text("Paste an address or a key first.")
        case .keyNeedsName:
            Text("Add the service or the account name for this key.")
        case .key:
            Text("This is not an otpauth address, an export or a Base32 key.")
        case .address(.unsupportedType), .export:
            Text("Only time-based codes (TOTP) are supported, as in Google Authenticator.")
        case .address:
            Text("This address could not be read. Check that it is complete.")
        }
    }
}
