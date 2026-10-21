# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: **Security → Report a vulnerability** in this repository. Do not open a public issue, and do not include real clipboard contents or passwords in the report.

## Supported versions

There are no releases yet. Security fixes go to the `main` branch; once releases exist, only the latest one will get them.

## Security model

### Today (0.1)

- **No network.** The app is sandboxed without network entitlements, so macOS blocks any connection it tries to make. CI builds the Release configuration with ad-hoc signing and checks its signed entitlements (`make security`).
- **Memory only.** History is kept in memory and is lost when you quit the app. Nothing is written to disk or sent anywhere.
- **Marked passwords are skipped.** Items that apps mark as concealed, transient or auto-generated (see [nspasteboard.org](http://nspasteboard.org)), and items with the older markers some password managers use, are never stored.
- **Minimal permissions.** The app asks for no permissions: no Accessibility, no Input Monitoring.
- **No secrets in logs.** Clipboard contents are never logged.

### Known limitations

- **Unmarked passwords are kept.** A password copied without a marker — for example from some browser extensions or a text file — is kept like any other text. We are working on this.
- **Screen sharing.** The history window uses the standard macOS opt-out from screen sharing, screenshots and screen recordings. Some newer capture methods (ScreenCaptureKit on recent macOS versions) may still capture it.

### Planned

- History saved on disk in the app container, so it survives a restart.
- Concealed items saved only if you allow it, encrypted with a key kept in your Keychain, hidden in the UI and deleted after a set time.
- Paste into the active app. Accessibility will be requested only if you turn this on.
- Releases, with CI checking the signed entitlements of every release build.
