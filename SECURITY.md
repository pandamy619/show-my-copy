# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: **Security → Report a vulnerability** in this repository. Do not open a public issue, and do not include real clipboard contents or passwords in the report.

## Supported versions

Only the latest release gets security fixes.

## Security model

- **No network.** The app is sandboxed without network entitlements, so macOS blocks any connection it tries to make. CI verifies the signed entitlements of every release build.
- **Local only.** History is stored in the app container on your Mac and is never sent anywhere.
- **Passwords.** Entries that password managers mark as concealed are saved only if you allow it, encrypted with a key kept in your Keychain, hidden in the UI and deleted after a set time.
- **Minimal permissions.** Accessibility is requested only if you turn on paste into the active app. The app never asks for Input Monitoring.
