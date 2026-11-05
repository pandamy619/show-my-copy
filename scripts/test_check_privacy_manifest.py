#!/usr/bin/env python3
"""Canary tests for scripts/check_privacy_manifest.py: prove that each check can actually fail.

Run with `make security-selftest`. Works on Linux and macOS. Each test copies the project file, the targets'
folders and the manifests into a temporary directory and changes the copy.
"""

from __future__ import annotations

import os
import plistlib
import shutil
import sys
import tempfile
import textwrap
import unittest

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
sys.dont_write_bytecode = True  # keep scripts/ free of __pycache__

import check_privacy_manifest as checker  # noqa: E402

COPIED = ["ShowMyCopy.xcodeproj", "ShowMyCopy", "ShowMyCopyControl", "ShowMyCopyTests"]
APP_MANIFEST = "ShowMyCopy/PrivacyInfo.xcprivacy"
EXTENSION_MANIFEST = "ShowMyCopyControl/PrivacyInfo.xcprivacy"
PBXPROJ = "ShowMyCopy.xcodeproj/project.pbxproj"


def manifest(types=None, **overrides) -> dict:
    """The app's manifest as it should be, with `types` as NSPrivacyAccessedAPITypes and overrides applied."""
    if types is None:
        types = [
            {"NSPrivacyAccessedAPIType": checker.USER_DEFAULTS, "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]},
            {"NSPrivacyAccessedAPIType": checker.FILE_TIMESTAMP,
             "NSPrivacyAccessedAPITypeReasons": ["C617.1", "3B52.1"]},
        ]
    value = {
        "NSPrivacyTracking": False,
        "NSPrivacyTrackingDomains": [],
        "NSPrivacyCollectedDataTypes": [],
        "NSPrivacyAccessedAPITypes": types,
    }
    value.update(overrides)
    return value


class Fixture:
    def __init__(self) -> None:
        self.root = tempfile.mkdtemp(prefix="privacy-selftest-")
        for name in COPIED:
            shutil.copytree(os.path.join(REPO, name), os.path.join(self.root, name))

    def path(self, relative: str) -> str:
        return os.path.join(self.root, relative)

    def write(self, relative: str, text: str) -> None:
        os.makedirs(os.path.dirname(self.path(relative)), exist_ok=True)
        with open(self.path(relative), "w", encoding="utf-8") as handle:
            handle.write(textwrap.dedent(text))

    def write_manifest(self, relative: str, value: object, fmt=plistlib.FMT_XML) -> None:
        with open(self.path(relative), "wb") as handle:
            plistlib.dump(value, handle, fmt=fmt)

    def replace(self, relative: str, old: str, new: str) -> None:
        with open(self.path(relative), encoding="utf-8") as handle:
            text = handle.read()
        if old not in text:
            raise AssertionError("fixture text not found in %s: %r" % (relative, old))
        with open(self.path(relative), "w", encoding="utf-8") as handle:
            handle.write(text.replace(old, new, 1))

    def errors(self, app=None):
        return checker.run_checks(self.root, app)

    def cleanup(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)


class CheckerTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)

    def assertFails(self, needle: str, app=None) -> None:
        errors = self.fixture.errors(app)
        self.assertTrue(any(needle in error for error in errors), "expected %r in %r" % (needle, errors))

    def assertPasses(self, app=None) -> None:
        self.assertEqual(self.fixture.errors(app), [])


class RealRepositoryTests(unittest.TestCase):
    def test_repository_passes(self) -> None:
        self.assertEqual(checker.run_checks(REPO), [])

    def test_app_manifest_is_the_expected_one(self) -> None:
        with open(os.path.join(REPO, APP_MANIFEST), "rb") as handle:
            self.assertEqual(plistlib.load(handle), manifest())

    def test_extension_has_no_manifest_while_it_uses_no_category(self) -> None:
        self.assertFalse(os.path.exists(os.path.join(REPO, EXTENSION_MANIFEST)))


class ManifestPresenceTests(CheckerTestCase):
    def test_fixture_passes(self) -> None:
        self.assertPasses()

    def test_missing_app_manifest_fails(self) -> None:
        os.remove(self.fixture.path(APP_MANIFEST))
        self.assertFails("target ShowMyCopy has no PrivacyInfo.xcprivacy")

    def test_manifest_excluded_from_the_app_target_fails(self) -> None:
        self.fixture.replace(
            PBXPROJ,
            "\t\tAA0000000000000000000006 /* ShowMyCopy */ = {\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
            "\t\t\texceptions = (\n",
            "\t\tAA0000000000000000000006 /* ShowMyCopy */ = {\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
            "\t\t\texceptions = (\n\t\t\t\tFF0000000000000000000001,\n",
        )
        self.fixture.replace(
            PBXPROJ,
            "/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */\n",
            "/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */\n"
            "\t\tFF0000000000000000000001 = {\n\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n"
            "\t\t\tmembershipExceptions = (\n\t\t\t\tPrivacyInfo.xcprivacy,\n\t\t\t);\n"
            "\t\t\ttarget = AA0000000000000000000008;\n\t\t};\n",
        )
        self.assertFails("target ShowMyCopy has no PrivacyInfo.xcprivacy")

    def test_two_manifests_in_one_target_fail(self) -> None:
        shutil.copy(self.fixture.path(APP_MANIFEST), self.fixture.path("ShowMyCopy/App/PrivacyInfo.xcprivacy"))
        self.assertFails("builds 2 privacy manifests")

    def test_files_listed_in_a_resources_phase_fail_closed(self) -> None:
        self.fixture.replace(
            PBXPROJ,
            "\t\tAA000000000000000000000C /* Resources */ = {\n\t\t\tisa = PBXResourcesBuildPhase;\n"
            "\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n",
            "\t\tAA000000000000000000000C /* Resources */ = {\n\t\t\tisa = PBXResourcesBuildPhase;\n"
            "\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\tFF0000000000000000000002,\n",
        )
        self.assertFails("this check reads only synchronized folders")

    def test_unreadable_project_fails(self) -> None:
        self.fixture.write(PBXPROJ, "{ objects = ")
        self.assertFails("cannot read")


class ManifestContentTests(CheckerTestCase):
    def check_content(self, value: object, needle: str) -> None:
        self.fixture.write_manifest(APP_MANIFEST, value)
        self.assertFails(needle)

    def test_binary_manifest_with_the_same_content_passes(self) -> None:
        self.fixture.write_manifest(APP_MANIFEST, manifest(), fmt=plistlib.FMT_BINARY)
        self.assertPasses()

    def test_garbage_fails(self) -> None:
        self.fixture.write(APP_MANIFEST, "not a plist")
        self.assertFails("cannot read")

    def test_not_a_dictionary_fails(self) -> None:
        self.check_content(["NSPrivacyTracking"], "is not a dictionary")

    def test_tracking_fails(self) -> None:
        self.check_content(manifest(NSPrivacyTracking=True), "NSPrivacyTracking must be False")

    def test_missing_tracking_key_fails(self) -> None:
        value = manifest()
        del value["NSPrivacyTracking"]
        self.check_content(value, "NSPrivacyTracking must be False")

    def test_tracking_domain_fails(self) -> None:
        self.check_content(manifest(NSPrivacyTrackingDomains=["example.com"]), "NSPrivacyTrackingDomains must be")

    def test_collected_data_fails(self) -> None:
        collected = [{"NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeOtherUsageData"}]
        self.check_content(manifest(NSPrivacyCollectedDataTypes=collected), "NSPrivacyCollectedDataTypes must be")

    def test_unexpected_key_fails(self) -> None:
        self.check_content(manifest(NSPrivacyNote="hello"), "unexpected key NSPrivacyNote")

    def test_unexpected_key_in_an_api_type_fails(self) -> None:
        types = manifest()["NSPrivacyAccessedAPITypes"]
        types[0]["NSPrivacyNote"] = "hello"
        self.check_content(manifest(types), "unexpected key NSPrivacyNote")

    def test_api_types_not_an_array_fails(self) -> None:
        self.check_content(manifest(NSPrivacyAccessedAPITypes={}), "must be an array")

    def test_unknown_category_fails(self) -> None:
        types = manifest()["NSPrivacyAccessedAPITypes"] + [
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryClipboard",
             "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]}]
        self.check_content(manifest(types), "unknown category")

    def test_category_declared_twice_fails(self) -> None:
        types = manifest()["NSPrivacyAccessedAPITypes"]
        self.check_content(manifest(types + [types[0]]), "is declared twice")

    def test_empty_reasons_fail(self) -> None:
        types = manifest()["NSPrivacyAccessedAPITypes"]
        types[0]["NSPrivacyAccessedAPITypeReasons"] = []
        self.check_content(manifest(types), "needs a non-empty array")

    def test_reason_of_another_category_fails(self) -> None:
        types = manifest()["NSPrivacyAccessedAPITypes"]
        types[0]["NSPrivacyAccessedAPITypeReasons"] = ["C617.1"]
        self.check_content(manifest(types), "C617.1 is not a reason Apple lists for " + checker.USER_DEFAULTS)

    def test_reason_twice_fails(self) -> None:
        types = manifest()["NSPrivacyAccessedAPITypes"]
        types[0]["NSPrivacyAccessedAPITypeReasons"] = ["CA92.1", "CA92.1"]
        self.check_content(manifest(types), "lists a reason twice")

    def test_sdk_only_reason_fails(self) -> None:
        types = manifest()["NSPrivacyAccessedAPITypes"]
        types[0]["NSPrivacyAccessedAPITypeReasons"] = ["CA92.1", "C56D.1"]
        self.check_content(manifest(types), "C56D.1 may be declared only by third-party SDKs")

    def test_undeclared_category_in_use_fails(self) -> None:
        types = manifest()["NSPrivacyAccessedAPITypes"][:1]
        self.check_content(manifest(types), "uses %s but does not declare it" % checker.FILE_TIMESTAMP)

    def test_declared_category_nobody_uses_fails(self) -> None:
        types = manifest()["NSPrivacyAccessedAPITypes"] + [
            {"NSPrivacyAccessedAPIType": checker.SYSTEM_BOOT_TIME, "NSPrivacyAccessedAPITypeReasons": ["35F9.1"]}]
        self.check_content(manifest(types), "declares %s, which no code" % checker.SYSTEM_BOOT_TIME)


# One use of every API in API_PATTERNS, as Swift would write it. A pattern without a sample fails the test below.
SAMPLES = {
    "creationDate": "let date = attributes[.creationDate]",
    "modificationDate": "let date = attributes[.modificationDate]",
    "fileModificationDate": "let date = document.fileModificationDate",
    "contentModificationDateKey": "let keys: Set<URLResourceKey> = [.contentModificationDateKey]",
    "creationDateKey": "let keys: Set<URLResourceKey> = [.creationDateKey]",
    "getattrlist": "let status = getattrlist(path, &list, &buffer, size, 0)",
    "getattrlistbulk": "let count = getattrlistbulk(fd, &list, &buffer, size, 0)",
    "fgetattrlist": "let status = fgetattrlist(fd, &list, &buffer, size, 0)",
    "stat": "var info = Darwin.stat()\n_ = stat(path, &info)",
    "fstat": "_ = fstat(fd, &info)",
    "fstatat": "_ = fstatat(fd, path, &info, 0)",
    "lstat": "_ = lstat(path, &info)",
    "getattrlistat": "_ = getattrlistat(fd, path, &list, &buffer, size, 0)",
    "attributesOfItem (added)": "let attributes = try FileManager.default.attributesOfItem(atPath: path)",
    "contentModificationDate (added)": "let date = values.contentModificationDate",
    "systemUptime": "let uptime = ProcessInfo.processInfo.systemUptime",
    "mach_absolute_time": "let ticks = mach_absolute_time()",
    "KERN_BOOTTIME (added)": "var mib = [CTL_KERN, KERN_BOOTTIME]",
    "volumeAvailableCapacityKey": "let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey]",
    "volumeAvailableCapacityForImportantUsageKey": "_ = [URLResourceKey.volumeAvailableCapacityForImportantUsageKey]",
    "volumeAvailableCapacityForOpportunisticUsageKey":
        "_ = [URLResourceKey.volumeAvailableCapacityForOpportunisticUsageKey]",
    "volumeTotalCapacityKey": "_ = [URLResourceKey.volumeTotalCapacityKey]",
    "systemFreeSize": "let free = attributes[.systemFreeSize]",
    "systemSize": "let size = attributes[.systemSize]",
    "statfs": "var info = statfs()\n_ = statfs(path, &info)",
    "statvfs": "_ = statvfs(path, &info)",
    "fstatfs": "_ = fstatfs(fd, &info)",
    "fstatvfs": "_ = fstatvfs(fd, &info)",
    "attributesOfFileSystem (added)": "let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)",
    "statfs block counts (added)": "let free = info.f_bavail",
    "activeInputModes": "let modes = UITextInputMode.activeInputModes",
    "UserDefaults": "let value = UserDefaults.standard.bool(forKey: key)",
    "NSUserDefaults (added)": "let defaults = NSUserDefaults.standard",
    "NSUserDefaultsController (added)": "let controller = NSUserDefaultsController.shared",
    "AppStorage (added)": "@AppStorage(\"key\") var value = false",
    "CFPreferences (added)": "let value = CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication)",
}


class ApiPatternTests(unittest.TestCase):
    def categories(self, code: str):
        uses, _ = checker.scan(code + "\n", "Sample.swift")
        return {(category, api) for category, _, api in uses}

    def test_every_pattern_has_a_sample(self) -> None:
        names = {api for _, _, api in checker.API_PATTERNS}
        self.assertEqual(names, set(SAMPLES))

    def test_every_pattern_finds_its_sample(self) -> None:
        for pattern, category, api in checker.API_PATTERNS:
            with self.subTest(api=api):
                self.assertIn((category, api), self.categories(SAMPLES[api]))

    def test_every_category_has_patterns_and_reasons(self) -> None:
        self.assertEqual({category for _, category, _ in checker.API_PATTERNS}, set(checker.REASONS))

    def test_comments_and_strings_do_not_count(self) -> None:
        code = '// UserDefaults.standard\n/* systemUptime */\nlet text = "mach_absolute_time() stat(path, &info)"'
        self.assertEqual(self.categories(code), set())

    def test_empty_c_structs_do_not_count(self) -> None:
        self.assertEqual(self.categories("var info = stat()\nvar volume = statfs( )"), set())

    def test_longer_names_do_not_count(self) -> None:
        self.assertEqual(self.categories("let x = myUserDefaultsKey + statistics(a) + systemUptimeLabel"), set())

    def test_use_across_line_breaks_counts(self) -> None:
        self.assertIn((checker.SYSTEM_BOOT_TIME, "systemUptime"),
                      self.categories("let uptime = ProcessInfo.processInfo\n    .systemUptime"))

    def test_unclosed_string_fails_closed(self) -> None:
        with self.assertRaises(checker.CheckError):
            checker.scan('let text = "never closed\n', "Sample.swift")


class CodeScanTests(CheckerTestCase):
    def test_new_use_of_an_undeclared_category_fails(self) -> None:
        self.fixture.write("ShowMyCopy/App/Uptime.swift", """\
            import Foundation

            let launchedAt = ProcessInfo.processInfo.systemUptime
            """)
        self.assertFails("uses %s but does not declare it: ShowMyCopy/App/Uptime.swift:3 (systemUptime)"
                         % checker.SYSTEM_BOOT_TIME)

    def test_disk_space_read_from_getfsstat_results_fails(self) -> None:
        self.fixture.replace(
            "ShowMyCopy/Platform/Files/SystemMountedVolumes.swift",
            "isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0",
            "isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0 && info.f_bavail > 0",
        )
        self.assertFails("uses %s but does not declare it" % checker.DISK_SPACE)

    def test_tests_are_not_scanned(self) -> None:
        self.fixture.write("ShowMyCopyTests/UptimeTests.swift", "let uptime = ProcessInfo.processInfo.systemUptime\n")
        self.assertPasses()

    def test_objective_c_in_a_target_fails_closed(self) -> None:
        self.fixture.write("ShowMyCopy/App/Helper.m", "int helper(void) { return 0; }\n")
        self.assertFails("only Swift is scanned")

    def test_unscannable_swift_fails_closed(self) -> None:
        self.fixture.write("ShowMyCopy/App/Broken.swift", 'let text = "never closed\n')
        self.assertFails("ShowMyCopy/App/Broken.swift: cannot scan")

    def test_lookalike_outside_its_reviewed_file_fails(self) -> None:
        self.fixture.write("ShowMyCopy/App/Volumes.swift", "import Darwin\n\nlet count = getfsstat(nil, 0, MNT_NOWAIT)\n")
        self.assertFails("ShowMyCopy/App/Volumes.swift:3: getfsstat outside the files it was reviewed in")

    def test_text_input_sources_outside_their_reviewed_file_fails(self) -> None:
        self.fixture.write("ShowMyCopy/App/Layout.swift", "let source = TISCopyCurrentKeyboardInputSource()\n")
        self.assertFails("Text Input Sources outside the files it was reviewed in")


class ExtensionTests(CheckerTestCase):
    def test_extension_code_using_a_category_without_a_manifest_fails(self) -> None:
        self.fixture.write("ShowMyCopyControl/Settings.swift", "let shown = UserDefaults.standard.bool(forKey: \"k\")\n")
        self.assertFails("target ShowMyCopyControlExtension uses %s" % checker.USER_DEFAULTS)

    def test_shared_file_built_into_the_extension_counts_for_it(self) -> None:
        # HistoryRequests.swift is in the app's folder and built into the extension by a membership exception.
        self.fixture.replace(
            "ShowMyCopy/App/HistoryRequests.swift",
            "    private var showsWhenConnected = false\n",
            "    private var showsWhenConnected = UserDefaults.standard.bool(forKey: \"k\")\n",
        )
        self.assertFails("target ShowMyCopyControlExtension uses %s" % checker.USER_DEFAULTS)

    def test_extension_manifest_for_its_category_passes(self) -> None:
        self.fixture.write("ShowMyCopyControl/Settings.swift", "let shown = UserDefaults.standard.bool(forKey: \"k\")\n")
        self.fixture.write_manifest(EXTENSION_MANIFEST, manifest(manifest()["NSPrivacyAccessedAPITypes"][:1]))
        self.assertPasses()

    def test_extension_manifest_declaring_unused_categories_fails(self) -> None:
        self.fixture.write_manifest(EXTENSION_MANIFEST, manifest())
        self.assertFails("which no code of target ShowMyCopyControlExtension uses")

    def test_app_file_not_built_into_the_extension_does_not_count_for_it(self) -> None:
        targets = {name: files for name, _, files, _ in checker.target_files(self.fixture.root)}
        self.assertNotIn(APP_MANIFEST, targets["ShowMyCopyControlExtension"])
        self.assertNotIn("ShowMyCopyControl/Info.plist", targets["ShowMyCopyControlExtension"])
        self.assertIn("ShowMyCopy/App/HistoryRequests.swift", targets["ShowMyCopyControlExtension"])
        self.assertIn(APP_MANIFEST, targets["ShowMyCopy"])


class PackageTests(CheckerTestCase):
    def test_package_at_another_version_fails(self) -> None:
        self.fixture.replace(PBXPROJ, "version = 3.1.0;", "version = 3.2.0;")
        self.assertFails("package KeyboardShortcuts is pinned to 3.2.0 but was reviewed")

    def test_unreviewed_package_fails(self) -> None:
        self.fixture.replace(PBXPROJ, "productName = KeyboardShortcuts;", "productName = HotKeys;")
        self.assertFails("package HotKeys is not reviewed")

    def test_package_categories_count_as_used(self) -> None:
        # Without the app's own use of UserDefaults, KeyboardShortcuts still needs the declaration.
        used, errors = checker.used_categories(self.fixture.root, [], ["KeyboardShortcuts"],
                                               {"KeyboardShortcuts": "3.1.0"})
        self.assertEqual(errors, [])
        self.assertEqual(set(used), {checker.USER_DEFAULTS})


class BuiltAppTests(CheckerTestCase):
    def make_app(self, app_manifest=True, extension_manifest=False) -> str:
        app = os.path.join(self.fixture.root, "build", "ShowMyCopy.app")
        resources = os.path.join(app, "Contents", "Resources")
        extension = os.path.join(app, "Contents", "PlugIns", "ShowMyCopyControlExtension.appex", "Contents",
                                 "Resources")
        os.makedirs(resources)
        os.makedirs(extension)
        if app_manifest:
            shutil.copy(self.fixture.path(APP_MANIFEST), os.path.join(resources, checker.MANIFEST))
        if extension_manifest:
            shutil.copy(self.fixture.path(APP_MANIFEST), os.path.join(extension, checker.MANIFEST))
        return app

    def test_built_app_with_its_manifest_passes(self) -> None:
        self.assertPasses(self.make_app())

    def test_built_app_with_a_binary_copy_passes(self) -> None:
        app = self.make_app(app_manifest=False)
        with open(os.path.join(app, "Contents", "Resources", checker.MANIFEST), "wb") as handle:
            plistlib.dump(manifest(), handle, fmt=plistlib.FMT_BINARY)
        self.assertPasses(app)

    def test_built_app_without_its_manifest_fails(self) -> None:
        self.assertFails("ShowMyCopy.app/Contents/Resources/PrivacyInfo.xcprivacy is missing", self.make_app(False))

    def test_built_manifest_that_differs_fails(self) -> None:
        app = self.make_app(app_manifest=False)
        with open(os.path.join(app, "Contents", "Resources", checker.MANIFEST), "wb") as handle:
            plistlib.dump(manifest(NSPrivacyTracking=True), handle)
        self.assertFails("differs from the manifest in the repository", app)

    def test_manifest_at_the_ios_location_fails(self) -> None:
        app = self.make_app()
        shutil.copy(self.fixture.path(APP_MANIFEST), os.path.join(app, "Contents", checker.MANIFEST))
        self.assertFails("a Mac app keeps its manifest in Contents/Resources", app)

    def test_extension_carrying_a_manifest_the_repository_lacks_fails(self) -> None:
        self.assertFails("but target ShowMyCopyControlExtension has no manifest", self.make_app(extension_manifest=True))

    def test_extension_missing_its_manifest_fails(self) -> None:
        self.fixture.write("ShowMyCopyControl/Settings.swift", "let shown = UserDefaults.standard.bool(forKey: \"k\")\n")
        self.fixture.write_manifest(EXTENSION_MANIFEST, manifest(manifest()["NSPrivacyAccessedAPITypes"][:1]))
        self.assertFails("ShowMyCopyControlExtension.appex/Contents/Resources/PrivacyInfo.xcprivacy is missing",
                         self.make_app())

    def test_unknown_extension_fails(self) -> None:
        app = self.make_app()
        os.makedirs(os.path.join(app, "Contents", "PlugIns", "Other.appex", "Contents"))
        self.assertFails("Other.appex: no extension target Other", app)

    def test_not_an_app_fails(self) -> None:
        self.assertFails("is not a macOS app bundle", os.path.join(self.fixture.root, "missing.app"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
