# Mac App Store: checklist before the first submission

This is for the owner. Everything here that needs no Apple Developer account is already in the repository:

- the privacy manifest (`ShowMyCopy/PrivacyInfo.xcprivacy`), checked by `make lint` and `make security`;
- the privacy policy ([PRIVACY.md](../PRIVACY.md), [PRIVACY.ru.md](../PRIVACY.ru.md));
- the store texts (`AppStore/metadata/en-US`, `AppStore/metadata/ru`, in fastlane `deliver` layout) and the
  [notes for App Review](review-notes.md), whose lengths `make lint` checks (`scripts/check_store_metadata.py`;
  `python3 scripts/check_store_metadata.py --report` prints each length next to its limit).

The rest needs the account, or a decision only the owner can make. Apple's pages were read on 5 November 2026;
look again before you submit, since they change.

## 1. Account and Team ID

- [ ] Enroll in the [Apple Developer Program](https://developer.apple.com/programs/enroll/) (as an individual or an
      organization; an organization needs a D-U-N-S number). The name you enroll with is the seller name on the
      App Store.
- [ ] Note the **Team ID**: developer.apple.com → Account → Membership details. It is a 10-character string; it is
      not a secret, but it does not have to be in the repository (see section 3).
- [ ] In App Store Connect → Business, accept the agreements. The Free Apps agreement is enough for a free app.
- [ ] Decide your **EU trader status** (Digital Services Act). Without it the app is not offered in the EU. A trader
      must publish an address, phone number and email on the product page.
      [Apple: DSA trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements)
- [ ] Make sure the GitHub repository is **public** and its URL is `https://github.com/pandamy619/ShowMyCopy`.
      The support, marketing and privacy URLs in `AppStore/metadata` point there. If the name differs, change
      `REPOSITORY_URL` in `scripts/check_store_metadata.py`, the URL files, the contact links in `PRIVACY*.md` and
      the last line of `review-notes.md`; `make lint` finds any you miss.

## 2. Bundle IDs

The project uses (`PRODUCT_BUNDLE_IDENTIFIER` in `ShowMyCopy.xcodeproj`):

| Target | Bundle ID |
|---|---|
| ShowMyCopy (app) | `com.pandamy619.ShowMyCopy` |
| ShowMyCopyControlExtension (Control Center button) | `com.pandamy619.ShowMyCopy.ShowMyCopyControl` |

- [ ] Register both as explicit App IDs (Certificates, Identifiers & Profiles → Identifiers → App IDs, platform
      macOS), or let Xcode's automatic signing register them. No capability needs to be turned on: the sandbox
      and the user-selected read-only file access are entitlements, not App ID capabilities, and the app uses no
      App Group, iCloud or push. A bundle ID cannot be changed after the first upload, so change it now if you
      want another prefix (also in `HistoryControl.kind`, `KeychainSecretSealer.service` and the paths in
      `PRIVACY*.md`).
- [ ] In App Store Connect → Apps → +, create the macOS app record: name "Show My Copy", primary language
      English (U.S.), the app's bundle ID, an SKU of your choice (for example `showmycopy-mac`).

## 3. Signing: from ad-hoc to your team

Today every target is signed ad-hoc: the project's Debug and Release configurations in `project.pbxproj` set
`CODE_SIGN_IDENTITY = "-"`, the targets use `CODE_SIGN_STYLE = Automatic` and no `DEVELOPMENT_TEAM` is set.
`make build-release` (used by `make security` and CI) also passes `CODE_SIGN_IDENTITY=-` on the command line.

Suggested change, which keeps CI ad-hoc and the Team ID out of the repository:

- [ ] In `ShowMyCopy.xcodeproj` (project → Build Settings, both configurations) delete `CODE_SIGN_IDENTITY = "-"`.
      A value in the project file wins over the `.xcconfig`, so it must go from there.
- [ ] At the end of `Config/Shared.xcconfig` add:

      // Ad-hoc unless Config/Signing.xcconfig.local (ignored by git, see .gitignore) names a team.
      CODE_SIGN_IDENTITY = -
      #include? "Signing.xcconfig.local"

- [ ] On your Mac only, create `Config/Signing.xcconfig.local` (already covered by `*.xcconfig.local` in
      `.gitignore`):

      DEVELOPMENT_TEAM = ABCDE12345
      CODE_SIGN_IDENTITY = Apple Development

- [ ] In `Makefile`, make `build-release` stay ad-hoc on a Mac that has the local file: add
      `DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual` next to `CODE_SIGN_IDENTITY=-`. Check that `make security` still
      passes.
- [ ] Keep `CODE_SIGN_INJECT_BASE_ENTITLEMENTS[config=Release] = NO`, the hardened runtime and the entitlements
      files as they are. Archive with Product → Archive and upload with Organizer → Distribute App → App Store
      Connect. Xcode signs the app with Apple Distribution and the installer package with Mac Installer
      Distribution, and embeds a provisioning profile.
- [ ] After archiving, check the signature of the archived app (see "Checks on your Mac" below). TestFlight needs
      the application identifier from the provisioning profile ("For builds to be eligible for TestFlight, they
      must include application identifiers within the provisioning profiles",
      [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)),
      so the store build carries `com.apple.application-identifier` and `com.apple.developer.team-identifier`.
      It must not carry `com.apple.security.get-task-allow`.

Two consequences to decide on before the first store build:

- [ ] **`make security` rejects a store-signed app**: `ENTITLEMENT_ALLOWLIST` in `scripts/check_security.py` allows
      only the sandbox entitlement (and the app's user-selected read-only files). Either keep running `make
      security` on the ad-hoc build only, or add the two identifier entitlements to the allowlist for the signed
      build, with a SECURITY.md entry and self-test cases (a security decision, GUIDELINES.md section 2).
- [ ] **The password key moves to another keychain.** `KeychainSymmetricKeyStore` tries the data protection
      keychain first. Today that fails with `errSecMissingEntitlement`, because an ad-hoc app has no application
      identifier, and the key is kept in the login keychain (SECURITY.md, "Where the encryption key is kept"). A
      store-signed app has the application identifier, so it will create its key in the data protection keychain
      (`WhenUnlockedThisDeviceOnly`, never synced, no prompt). Passwords saved by a non-store build on the same Mac
      then cannot be decrypted and are deleted (the history itself stays). Test this in TestFlight, then update
      SECURITY.md, PRIVACY*.md ("Your login keychain") and the README in the same change.

## 4. Version

- [ ] `MARKETING_VERSION` is `0.1.0` in `Config/Shared.xcconfig` (one value for the app and the extension, which
      must match). Leave it until you decide; for the store release set it to `1.0` (or `1.0.0`), and update
      the "0.1.0" in README.md, README.ru.md, SECURITY.md, CHANGELOG.md and PRIVACY*.md with it.
- [ ] `CURRENT_PROJECT_VERSION` (`1`) is the build number: raise it for every upload, since App Store Connect
      takes each build number of a version only once.
- [ ] "What's New" (`release_notes.txt`) is not shown for the first version of an app; the draft is for the
      next one ([platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)).

## 5. App icon

What `ShowMyCopy/Assets.xcassets/AppIcon.appiconset` holds now (checked: every file is a PNG of the size its
slot needs, 8-bit RGBA):

| Slot | 1x | 2x |
|---|---|---|
| 16 pt | `icon_16.png` 16×16 | `icon_32.png` 32×32 |
| 32 pt | `icon_32.png` 32×32 | `icon_64.png` 64×64 |
| 128 pt | `icon_128.png` 128×128 | `icon_256.png` 256×256 |
| 256 pt | `icon_256.png` 256×256 | `icon_512.png` 512×512 |
| 512 pt | `icon_512.png` 512×512 | `icon_1024.png` 1024×1024 |

- [x] All ten macOS slots are filled, including the 1024×1024 image App Store Connect takes the store icon from.
- [ ] Optional: on macOS 26 apps can provide an Icon Composer (`.icon`) file for the new light, dark and tinted
      appearances; without one macOS 26 shows the image above. Not required for submission.
- [ ] After a Release build, check that the icon made it in (see "Checks on your Mac").

## 6. Screenshots

[Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications):
Mac screenshots are required, 16:10, one of **1280×800, 1440×900, 2560×1600 or 2880×1800** pixels, 1 to 10 per
language, `.png`, `.jpg` or `.jpeg`.

- [ ] Take them on a display set to a 16:10 mode, such as 1440×900 "looks like" on a Retina display (2880×1800
      pixels), or crop and scale them to one of the four sizes. Use a plain desktop and a tidy menu bar.
- [ ] Use made-up content only: no real clipboard data, names, paths or passwords.
- [ ] Suggested set, in English and in Russian (set the app's language in System Settings → General → Language &
      Region → Applications):
  1. The history window over a document, with text, an image and copied files in the list, the source app
     visible.
  2. Search narrowing the list.
  3. The preview (→) of an image or of styled text.
  4. Pinned entries in their section.
  5. Settings → History and Storage: the age limit (8 hours), entry and size limits, and "saved on this Mac only".
  6. Settings → Passwords and Excluded apps.
  7. On macOS 26: the Clipboard History button in Control Center.
- [ ] Do not show the Accessibility permission alert in the screenshots; it is optional and off by default.

## 7. Texts and URLs in App Store Connect

- [ ] Copy each field from `AppStore/metadata/<locale>/<field>.txt`: name, subtitle, promotional text,
      description, keywords, support URL, marketing URL, and the privacy policy URL (App Information, per
      language). Limits, from
      [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
      and [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information):
      name 2–30 characters, subtitle 30, promotional text 170, description 4000, keywords 100 **bytes** (Russian
      letters take 2 bytes each), What's New 4000, App Review notes 4000 bytes.
- [ ] The support URL is the GitHub issues page. Apple says it "must lead to actual contact information (legal
      address, email address, telephone number), as may be required by local law". Decide whether a GitHub page
      is enough where you sell, or add contact details to the README.
- [ ] Copy `AppStore/review-notes.md` into App Review Information → Notes, and fill in the contact name, email and
      phone there (the phone with + and country code). It says that the paste feature can be left out of the
      store build if App Review objects to it: that needs a build setting that removes the feature (code that
      does not exist yet). Plan the time for it.
- [ ] Copyright: for example "2026 pandamy619".

## 8. App Privacy (the privacy "nutrition label")

- [ ] App Store Connect → App Privacy → Get Started → "No, we do not collect data from this app". This matches the
      privacy manifest (`NSPrivacyCollectedDataTypes` empty, `NSPrivacyTracking` false): Apple counts data as
      collected only when it is transmitted off the device, and nothing leaves the Mac.
      [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [ ] Xcode → Organizer → the archive → Generate Privacy Report: it should list no collected data.

## 9. Export compliance (encryption)

What the app does: it encrypts saved passwords on the Mac with AES-256-GCM from CryptoKit, Apple's framework, so
they are not stored in plain text. The key stays in the Keychain. Nothing is sent anywhere, the app has no
network access, and it implements no cryptographic algorithm of its own.

What Apple says ([Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations),
[ITSAppUsesNonExemptEncryption](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption),
[Overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)):

- "Crypto functionality within Apple's operating system" is encryption in the sense of the questions: the answer
  to "Does your app use encryption?" is **yes**, not no.
- "Typically, the use of encryption that's built into the operating system ... is exempt from export documentation
  upload requirements, whereas the use of proprietary encryption is not."
- Set `ITSAppUsesNonExemptEncryption` to `NO` "if your app ... only uses forms of encryption that are exempt from
  export compliance requirements"; then App Store Connect stops asking at every upload.
- "If your app uses exempt forms of encryption, you might alternatively be required to submit a year-end
  self-classification report to the U.S. government."
- France controls the import of encryption apps; "The main items of control for France are Secure Storage, Secure
  Communications, and Security Anti-Virus applications."

Suggested answers, which are the owner's legal decision (Apple: "you're responsible for all liabilities associated
with misinterpretation of export regulations or claiming exemption inaccurately"):

- [ ] Uses encryption: yes. Proprietary or non-standard algorithms: no. Standard algorithms instead of, or in
      addition to, Apple's operating system: no (only CryptoKit). With these answers App Store Connect should say
      that no documentation is required.
- [ ] Then add `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` to the app target (both configurations) so the
      questions are not asked for every build. Not done in the repository: it is a legal statement for you to make.
- [ ] Check whether you need the annual self-classification report (BIS), and whether France's rules apply: the
      app's purpose is clipboard history, not secure storage, and password saving is optional and off by default.
      If in doubt, leave France out of the first release (Pricing and Availability).

## 10. Age rating and category

- [ ] Age rating questionnaire
      ([values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions)):
      every content descriptor "None"; no parental controls or age assurance; no unrestricted web access, no
      user-generated content (what you copy is never shown to anyone else), no messaging or chat, no advertising.
      Expect the lowest rating, 4+.
- [ ] Category: primary **Utilities**, which matches `LSApplicationCategoryType = public.app-category.utilities` in
      the app's Info.plist ("For macOS apps ... The primary category you set in App Store Connect should match the
      category you set in Xcode",
      [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)).
      Secondary: Productivity, if you want one.
- [ ] Price: free. Availability: see section 9 about France and section 1 about the EU.

## 11. TestFlight for Mac

- [ ] Archive (Xcode 26), upload, and wait for processing. Answer the export compliance questions for the build if
      the Info.plist key is not set.
- [ ] Internal testing: add yourself (and up to 100 App Store Connect users) to an internal group; no review needed.
      External testers need a Beta App Review; fill in the beta app description and a feedback email.
- [ ] Install TestFlight from the Mac App Store and install the build. Builds expire after 90 days.
- [ ] Test on macOS 15 and macOS 26, with a new user account (no earlier build, no data):
  - first launch shows Settings; ⌥⌘V opens the history; copies of text, styled text, images and files appear;
  - restart the Mac: the history is still there; the age limit removes old entries;
  - Paste after choosing an entry: macOS asks once, the entry is pasted into TextEdit, ⌥Enter only copies;
  - Open at login: listed in System Settings → General → Login Items and opens the app at login;
  - Save passwords: copy from a password manager, quit, relaunch; the password comes back and expires; check in
    Keychain Access where the key went (section 3);
  - Control Center button on macOS 26;
  - Clear History removes everything (Settings → Storage shows 0 and the container folder has no images left);
  - watch for any alert about the app reading the clipboard: Apple has said that macOS may come to ask the user
    before an app reads the pasteboard without a user action. If such an alert appears, describe it in the review
    notes and the description.

## Checks on your Mac

Run in the repository after `make security` (Release, ad-hoc) and again on the archived store build:

```sh
APP=build/Build/Products/Release/ShowMyCopy.app   # or: the .app inside the .xcarchive's Products/Applications

# The privacy manifest is in the app, unchanged, and not in the extension (also run by `make security`).
python3 -I scripts/check_privacy_manifest.py "$APP"
ls "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
plutil -lint "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
ls "$APP/Contents/PlugIns/ShowMyCopyControlExtension.appex/Contents/Resources/"   # no PrivacyInfo.xcprivacy

# The icon.
plutil -extract CFBundleIconName raw "$APP/Contents/Info.plist"   # AppIcon
ls "$APP/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/Assets.car"

# Category and version.
plutil -extract LSApplicationCategoryType raw "$APP/Contents/Info.plist"   # public.app-category.utilities
plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist"
plutil -extract CFBundleShortVersionString raw \
  "$APP/Contents/PlugIns/ShowMyCopyControlExtension.appex/Contents/Info.plist"   # the same

# Entitlements: the ad-hoc build has only the sandbox (and the app's user-selected read-only files); the store
# build adds com.apple.application-identifier and com.apple.developer.team-identifier, never get-task-allow.
codesign -d --entitlements - --xml "$APP" | plutil -p -
codesign -d --entitlements - --xml "$APP/Contents/PlugIns/ShowMyCopyControlExtension.appex" | plutil -p -

# Store build only: the provisioning profile is embedded.
ls "$APP/Contents/embedded.provisionprofile"
```

Xcode → Organizer → Archives → Generate Privacy Report should show the app's manifest with the categories in the
table below and no collected data.

## Required reason APIs: what the app uses

Apple asks for these reasons on iOS, iPadOS, tvOS, visionOS and watchOS
([Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)); the
Mac app declares them anyway, so the manifest is true if Apple extends the rule. Categories and reason codes are
from [NSPrivacyAccessedAPIType](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
`make lint` keeps this in step with the code (`scripts/check_privacy_manifest.py`).

| API | Where | Category | Reason |
|---|---|---|---|
| `UserDefaults` (settings, excluded apps, first-launch flag, failed-open count) | `ShowMyCopy/Settings/*`, `App/FirstLaunch.swift`, `History/Persistence/HistoryStoreOpener.swift` and others | UserDefaults | `CA92.1`: read and write information only the app itself can access |
| `UserDefaults.standard` (the hotkey) | KeyboardShortcuts 3.1.0, linked into the app; it ships no privacy manifest | UserDefaults | `CA92.1` |
| `FileManager.attributesOfItem` → `.size` of saved images and of the history files | `History/Blobs/FileBlobStore.swift`, `History/Persistence/StoreFiles.swift` | File timestamp (counted although only the size is read: the call returns the dates too) | `C617.1`: metadata of files in the app container |
| `attributesOfItem(...)[.modificationDate]`, `setAttributes([.modificationDate: ...])` of the damaged copy | `History/Persistence/HistoryStoreOpener.swift` | File timestamp | `C617.1` |
| `FileManager.attributesOfItem` → size and type of copied files | `History/FileSizeReader.swift` | File timestamp | `3B52.1`: metadata of files the user gave the app access to (macOS grants it for files the user copies) |
| `stat` → `st_flags` (dataless placeholder) of copied photos and videos | `Platform/Files/QuickLookFileThumbnailMaker.swift` | File timestamp | `3B52.1` |
| `getfsstat` (mount point, file system type, local flag) | `Platform/Files/SystemMountedVolumes.swift` | Not on Apple's list (statfs, statvfs, fstatfs, fstatvfs are); no free or total space is read, so no disk space reason applies | none |
| Text Input Sources (`TISCopyCurrentASCIICapableKeyboardLayoutInputSource`) | `Platform/Paste/SystemPasteKeystrokes.swift`, also in KeyboardShortcuts | Not on Apple's list (active keyboards lists only UIKit's `activeInputModes`) | none |
| System boot time (`systemUptime`, `mach_absolute_time`) | not used; `ContinuousClock` is read inside Apple's Swift runtime | — | none |
| Disk space (`volumeAvailableCapacity*Key`, `systemFreeSize`, `statfs`, ...) | not used | — | none |

The Control Center extension builds `ShowMyCopyControl/*.swift`, `App/HistoryRequests.swift` and
`Platform/Intents/OpenHistoryIntent.swift`, none of which uses a listed API, so it needs no manifest of its own:
"For each executable or dynamic library in an app that uses a required reason API, the bundle that includes the
executable or dynamic library needs to include a privacy manifest file"
([Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)).
`make lint` fails if it starts using one without a manifest in `ShowMyCopyControl/`.

The manifest sits in the `ShowMyCopy` folder, which the project syncs with the app target (Xcode 16+
file-system synchronized folder). Xcode puts files of a synchronized folder that it does not compile into the
target's Copy Bundle Resources phase, as it does with `Localizable.xcstrings` and `Assets.xcassets` there, so no
project file entry is needed; on macOS it lands in `Contents/Resources/`, where Apple expects it
([Adding a privacy manifest](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)).
The extension builds only the two files named in its membership exception from that folder, so the manifest does
not end up in it. `make security` checks both on the built app.
