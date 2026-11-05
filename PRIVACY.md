# Privacy policy

<p><a href="PRIVACY.ru.md">Русская версия</a></p>

Show My Copy is a clipboard history app for macOS. This policy covers version 0.1.0 and every later version until this file says otherwise. It was last changed on 5 November 2026; earlier versions are in this file's history on GitHub.

## In short

- **Nothing is collected, sent or shared.** The developer receives no data from the app: no analytics, no crash reports, no usage statistics, no advertising, no accounts.
- **No network.** The app runs in the macOS App Sandbox without network access, so macOS blocks any connection it would try to make. It never connects to the internet or to your local network.
- **Your history stays on your Mac**, in the app's own sandbox folder. It is not synced to iCloud or other devices and is left out of Time Machine backups.
- **Old copies are removed on their own**: after 8 hours by default.
- **Permissions are opt-in.** The app asks for one permission, and only if you turn on pasting into the app you were using.

## What the app stores, where, and for how long

Everything below is stored on your Mac only. "The app's container" is the folder macOS gives the sandboxed app: `~/Library/Containers/com.pandamy619.ShowMyCopy/`.

| What | Where | How long |
|---|---|---|
| **Clipboard history**: copied text (up to 1 MB per copy) and styled text; images (up to 20 MB each) with a thumbnail of at most 256 pixels; for copied files only their path, name and size, never their contents, and for photos and videos a thumbnail of at most 256 pixels; the name and identifier of the app each copy came from; when it was copied. | The app's container: `Data/Library/Application Support/ShowMyCopy/History/` (a database and an image folder). Excluded from Time Machine and other backups. Not encrypted by the app; FileVault protects it while your Mac is off or locked. | Until the first of these removes an entry: the age limit (8 hours by default; 1 hour, 8 hours, 24 hours, 7 days, 30 days or off in Settings → History), the entry limit (50 by default, 10 to 1000), the size limit (1 GB by default; 100 MB, 500 MB, 1 GB or off), deleting the entry (⌘⌫ in the history window) or Clear History. |
| **Pinned entries** (at most 50) | Same as the history. | Until you unpin or delete them, or clear the history with "Also remove pinned entries". The limits do not remove them. |
| **Passwords** | Not stored by default: items that password managers mark as concealed, and anything copied while a known password manager is in front, are skipped. If you turn on Settings → Passwords → Save passwords, they are stored in the history encrypted with AES-256-GCM. | 1 minute, 10 minutes (default) or 1 hour, as you choose; all of them at once when you turn the setting off. |
| **The encryption key for saved passwords** | Your login keychain, as "Show My Copy history key". It is created only when the first password is saved, and never synced to iCloud. | Until you delete it in Keychain Access. The app never deletes it. |
| **A damaged copy of the history**, if the history file ever cannot be opened | The same folder, as `History.store.damaged`. | One week, or until Clear History or turning Save passwords off. |
| **Settings**: the history limits, the password settings, the excluded apps (only each app's identifier and name), the paste setting and whether its one-time note was shown, whether Settings were shown at first launch, how many launches in a row the history could not be opened, and the hotkey. Open at login is kept by macOS, not by the app. | The app's container: `Data/Library/Preferences/com.pandamy619.ShowMyCopy.plist`. | Until you delete the app's container. |
| **Diagnostic messages** about errors, such as "Could not save an image". They never contain what you copied. | The macOS unified log on your Mac. | macOS removes them on its own schedule. They leave your Mac only if you send them yourself, for example in a report to Apple. |

While the app runs it also holds the history in memory. Deleted entries can stay in the free space of the history database and of your disk until they are overwritten; FileVault protects that space too. [SECURITY.md](SECURITY.md) describes all of this in detail.

## What is not collected, sent or shared

Nothing. The app has no network access, contains no analytics, advertising or crash-reporting code, and has no account or sign-in. Nothing you copy, no setting and no usage data is sent to the developer or to anyone else, and nothing is shared or sold.

Some work is done for the app by macOS itself, outside the app's sandbox: macOS QuickLook draws the thumbnails of copied photos and videos (only for files stored on your Mac), and the system clipboard is shared by all apps and, with Handoff on, by macOS with your other Apple devices (Universal Clipboard). A password the app copies back from its history is marked so that it is kept off Universal Clipboard. What macOS does is covered by [Apple's privacy policy](https://www.apple.com/legal/privacy/). If you download the app from the Mac App Store, Apple may collect information about the download under its own policy; the developer only sees what App Store Connect shows to every developer, such as download counts.

## Permissions

| Permission | When it is asked for | What it is used for |
|---|---|---|
| **Post keyboard events** (shown in System Settings → Privacy & Security → Accessibility) | Only when you turn on Settings → General → Paste after choosing an entry. Off by default. | After you choose an entry in the history window, the app copies it and sends one ⌘V key press to the app you were using, so the entry is pasted there. It never reads what you type or what other apps show: it does not use the rest of the Accessibility API and never asks for Input Monitoring. Turning the setting off stops the pasting; to remove the permission, use System Settings → Privacy & Security → Accessibility. |
| **Open at login** (shown in System Settings → General → Login Items) | Only when you turn on Settings → General → Open at login. Off by default. | Opens the app when you log in. Turn it off in the app or in System Settings. |
| **Keychain** | macOS may ask whether Show My Copy may use its key when a password is saved or loaded, if the app's signature changed since the key was made. | Encrypting and decrypting saved passwords. Only with Save passwords on. |
| **Reading an app you choose** | When you use Settings → Excluded apps → Choose an App…. | Reading that app's identifier and name, so copies made in it are never recorded. Nothing else of it is read or kept. |

Files you copy are made readable to the app by macOS until it quits. The app reads only their size and, for up to 4 copied photos or videos, enough to make a thumbnail; it never copies their contents.

## How to delete everything

1. In Settings, below Storage, choose Clear History… and check "Also remove pinned entries". This deletes the whole history from disk, including a damaged copy.
2. Turn off Settings → General → Open at login, and Paste after choosing an entry.
3. In System Settings → Privacy & Security → Accessibility, remove Show My Copy if it is listed.
4. Quit Show My Copy and move it from Applications to the Trash.
5. Delete the folder `~/Library/Containers/com.pandamy619.ShowMyCopy` (in Finder: Go → Go to Folder…). It holds the history, the settings and the hotkey. If there is a folder `~/Library/Containers/com.pandamy619.ShowMyCopy.ShowMyCopyControl`, delete it too: macOS makes it for the Control Center button, which stores nothing in it.
6. If you saved passwords: open Keychain Access, search for "Show My Copy history key" and delete it.

## Children

The app collects no data from anyone, children included.

## Changes to this policy

Changes are published in this file, with the date above. Its full history is in the repository.

## Contact

Questions about privacy: open an issue at <https://github.com/pandamy619/show-my-copy/issues>. Please do not include anything you copied, or passwords. To report a security problem privately, see [SECURITY.md](SECURITY.md).
