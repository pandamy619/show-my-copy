#!/usr/bin/env python3
"""Canary tests for scripts/check_security.py: prove that each check can actually fail.

Run with `make security-selftest`. Works on Linux and macOS. Fixture projects are built in a
temporary directory from the real project file; the signed-app and resolved-settings checks use
a fake `codesign` or `xcodebuild` put first on PATH for the duration of one test, so
check_security.py itself has no test hook.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import contextmanager

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
sys.dont_write_bytecode = True  # keep scripts/ free of __pycache__

import check_security  # noqa: E402

PBXPROJ = os.path.join(REPO, check_security.PROJECT, "project.pbxproj")
SHARED = "Config/Shared.xcconfig"
TESTS = "Config/Tests.xcconfig"
CONFIG = "\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n"
APP_DEBUG = "AA0000000000000000000016 /* Debug */ = {" + CONFIG
APP_RELEASE = "AA0000000000000000000017 /* Release */ = {" + CONFIG

FAKE_CODESIGN = r'''#!/usr/bin/env python3
# Fake codesign for the self-test. Reads the answers from files next to the code it is asked about.
import os, sys
args = sys.argv[1:]
path = args[-1]
meta = path + ".fake" if os.path.isfile(path) else os.path.join(path, "_fake")
def has(name):
    return os.path.exists(os.path.join(meta, name))
if "--verify" in args:
    sys.exit(1 if has("verify-fails") else 0)
if "--entitlements" in args:
    ents = os.path.join(meta, "entitlements.plist")
    if os.path.exists(ents):
        with open(ents, "rb") as handle:
            sys.stdout.buffer.write(handle.read())
    sys.exit(0)
if "-d" in args:
    flags = "0x2(adhoc)" if has("no-runtime") else "0x10002(adhoc,runtime)"
    sys.stderr.write("Executable=%s\nCodeDirectory v=20500 size=1 flags=%s hashes=1+1\n" % (path, flags))
    sys.exit(0)
sys.exit(2)
'''

FAKE_XCODEBUILD = r'''#!/usr/bin/env python3
# Fake xcodebuild for the self-test: answers -showBuildSettings -json from settings/<target>/<config>.json.
import os, sys
args = sys.argv[1:]
target = args[args.index("-target") + 1]
config = args[args.index("-configuration") + 1]
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "settings", target, config + ".json")
if "-showBuildSettings" not in args or "-json" not in args or not os.path.exists(path):
    sys.stderr.write("fake xcodebuild: no answer for %s\\n" % args)
    sys.exit(1)
with open(path) as handle:
    sys.stdout.write(handle.read())
'''


def plist(ents: dict) -> bytes:
    return plistlib.dumps(ents)


SANDBOX_ONLY = {"com.apple.security.app-sandbox": True}
READ_ONLY = "com.apple.security.files.user-selected.read-only"
READ_WRITE = "com.apple.security.files.user-selected.read-write"
# What the app is signed with: Settings -> Excluded apps picks an app with an open panel.
APP_ENTITLEMENTS = dict(SANDBOX_ONLY, **{READ_ONLY: True})
APP_FILE = "Config/ShowMyCopy.entitlements"
WIDGET_FILE = "Config/ShowMyCopyControl.entitlements"
WIDGET = "ShowMyCopyControlExtension"
WIDGET_XCCONFIG = "Config/Widget.xcconfig"
APP_READ_ONLY_SETTING = "ENABLE_USER_SELECTED_FILES = readonly;"
DEBUG_MARKER = "com.pandamy619.ShowMyCopy.debug.quitForNewerDebugBuild"
# A key Debug builds read to tune pasting; DEBUG_ONLY_STRINGS has its prefix.
PASTE_DEBUG_KEY = "debug.paste.settleMs"
# Where each DEBUG_ONLY_STRINGS string is used in the app.
DEBUG_ONLY_STRING_FILES = {
    DEBUG_MARKER: "ShowMyCopy/App/AppDelegate.swift",
    "debug.paste.": "ShowMyCopy/Paste/PasteDebugTuning.swift",
}


class Fixture:
    """A throwaway copy of the parts of the repo the checker reads."""

    def __init__(self, base: str) -> None:
        self.root = os.path.join(base, "repo")
        os.makedirs(os.path.join(self.root, check_security.PROJECT))
        os.makedirs(os.path.join(self.root, "ShowMyCopy"))
        with open(PBXPROJ, encoding="utf-8") as handle:
            # Tests that need an entitlements file add their own CODE_SIGN_ENTITLEMENTS line.
            self.pbxproj = re.sub(r"\t+CODE_SIGN_ENTITLEMENTS = [^\n]*\n", "", handle.read())
        self.save()
        # Every xcconfig the project uses, such as one per target, so the fixture project reads like the real one.
        for name in sorted(os.listdir(os.path.join(REPO, "Config"))):
            if name.endswith(".xcconfig"):
                with open(os.path.join(REPO, "Config", name), encoding="utf-8") as handle:
                    self.write("Config/" + name, handle.read())

    def read(self, relative: str) -> str:
        with open(os.path.join(self.root, relative), encoding="utf-8") as handle:
            return handle.read()

    def edit(self, relative: str, old: str, new: str) -> None:
        text = self.read(relative)
        assert text.count(old) == 1, "fixture anchor %r found %d times in %s" % (old, text.count(old), relative)
        self.write(relative, text.replace(old, new))

    def save(self) -> None:
        with open(os.path.join(self.root, check_security.PROJECT, "project.pbxproj"), "w", encoding="utf-8") as out:
            out.write(self.pbxproj)

    def replace(self, old: str, new: str, count: int = 1) -> None:
        assert self.pbxproj.count(old) == count, "fixture anchor %r found %d times" % (old, self.pbxproj.count(old))
        self.pbxproj = self.pbxproj.replace(old, new)
        self.save()

    def add_app_setting(self, line: str) -> None:
        for anchor in (APP_DEBUG, APP_RELEASE):
            self.replace(anchor, anchor + "\t\t\t\t" + line + "\n")

    def write(self, relative: str, content) -> str:
        path = os.path.join(self.root, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as out:
            out.write(content.encode() if isinstance(content, str) else content)
        return path

    def errors(self) -> list:
        return check_security.run_checks(self.root, use_xcodebuild=False)


class CheckerTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp(prefix="check-security-")
        self.addCleanup(shutil.rmtree, self.tmp)
        self.fixture = Fixture(self.tmp)

    def assertFailsWith(self, errors: list, fragment: str) -> None:
        self.assertTrue(errors, "checker passed but should have failed with %r" % fragment)
        self.assertTrue(
            any(fragment in error for error in errors),
            "expected an error containing %r, got:\n%s" % (fragment, "\n".join(errors)),
        )


class ProjectFixtureTests(CheckerTestCase):
    def test_unmodified_fixture_passes(self) -> None:
        self.assertEqual(self.fixture.errors(), [])

    def test_app_without_sandbox_is_not_hidden_by_another_target(self) -> None:
        self.fixture.edit(SHARED, "ENABLE_APP_SANDBOX = YES", "ENABLE_APP_SANDBOX = NO")
        self.fixture.edit(TESTS, "ENABLE_APP_SANDBOX = NO", "ENABLE_APP_SANDBOX = YES")
        self.assertFailsWith(self.fixture.errors(), "target ShowMyCopy (Release): ENABLE_APP_SANDBOX must be YES")

    def test_sandbox_only_in_one_configuration(self) -> None:
        # The target's own setting overrides the shared file; Release stays YES.
        self.fixture.replace(APP_DEBUG, APP_DEBUG + "\t\t\t\tENABLE_APP_SANDBOX = NO;\n")
        errors = self.fixture.errors()
        self.assertFailsWith(errors, "target ShowMyCopy (Debug): ENABLE_APP_SANDBOX must be YES")
        self.assertFalse(any("(Release)" in error for error in errors), errors)

    def test_conditional_setting_cannot_override_sandbox(self) -> None:
        self.fixture.add_app_setting('"ENABLE_APP_SANDBOX[sdk=macosx*]" = NO;')
        self.assertFailsWith(self.fixture.errors(), "ENABLE_APP_SANDBOX must be YES")

    def test_missing_hardened_runtime(self) -> None:
        self.fixture.edit(SHARED, "ENABLE_HARDENED_RUNTIME = YES", "ENABLE_HARDENED_RUNTIME = NO")
        self.assertFailsWith(self.fixture.errors(), "ENABLE_HARDENED_RUNTIME must be YES")

    def test_outgoing_network(self) -> None:
        self.fixture.edit(
            SHARED, "ENABLE_OUTGOING_NETWORK_CONNECTIONS = NO", "ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES"
        )
        self.assertFailsWith(self.fixture.errors(), "ENABLE_OUTGOING_NETWORK_CONNECTIONS must not be YES")

    def test_network_setting_must_be_explicit_for_app(self) -> None:
        self.fixture.edit(SHARED, "ENABLE_INCOMING_NETWORK_CONNECTIONS = NO\n", "")
        self.assertFailsWith(self.fixture.errors(), "ENABLE_INCOMING_NETWORK_CONNECTIONS must be explicitly NO")

    def test_network_setting_through_a_variable_is_not_trusted(self) -> None:
        # An extension need not say NO, but a value the checker cannot resolve might be YES.
        self.fixture.replace(
            'productType = "com.apple.product-type.bundle.unit-test";',
            'productType = "com.apple.product-type.app-extension";',
        )
        self.fixture.edit(TESTS, "ENABLE_APP_SANDBOX = NO", "ENABLE_APP_SANDBOX = YES")
        self.fixture.edit(TESTS, "ENABLE_HARDENED_RUNTIME = NO", "ENABLE_HARDENED_RUNTIME = YES")
        self.assertEqual(self.fixture.errors(), [])
        self.fixture.edit(TESTS, "ENABLE_HARDENED_RUNTIME = YES", "ENABLE_HARDENED_RUNTIME = YES\n"
                          "ENABLE_OUTGOING_NETWORK_CONNECTIONS = $(NETWORK)")
        self.assertFailsWith(
            self.fixture.errors(),
            "target ShowMyCopyTests (Debug): ENABLE_OUTGOING_NETWORK_CONNECTIONS uses a build setting variable",
        )

    # .xcconfig files

    def test_shared_settings_apply_to_every_target(self) -> None:
        targets, _ = check_security.project_targets(self.fixture.root)
        for name, _, configs in targets:
            for config, settings in configs.items():
                with self.subTest(target=name, config=config):
                    self.assertEqual(settings.get("SWIFT_VERSION"), "6.0")
                    self.assertEqual(settings.get("SWIFT_STRICT_CONCURRENCY"), "complete")
                    self.assertEqual(settings.get("SWIFT_TREAT_WARNINGS_AS_ERRORS"), "YES")
                    # The Control Center widget needs macOS 26 (Config/Widget.xcconfig); everything else runs on 15.
                    widget = name == "ShowMyCopyControlExtension"
                    self.assertEqual(settings.get("MACOSX_DEPLOYMENT_TARGET"), "26.0" if widget else "15.0")
                    self.assertEqual(settings.get("ENABLE_OUTGOING_NETWORK_CONNECTIONS"), "NO")
                    # Only the test bundle runs outside the sandbox (Config/Tests.xcconfig).
                    self.assertEqual(settings.get("ENABLE_APP_SANDBOX"), "NO" if name == "ShowMyCopyTests" else "YES")

    def test_target_xcconfig_overrides_the_project_xcconfig(self) -> None:
        # The tests' file turns the sandbox off; the same line in the app's settings is caught.
        self.fixture.replace(APP_RELEASE, APP_RELEASE.replace(
            "isa = XCBuildConfiguration;",
            "isa = XCBuildConfiguration;\n\t\t\tbaseConfigurationReference = AA000000000000000000001C;",
        ))
        self.assertFailsWith(self.fixture.errors(), "target ShowMyCopy (Release): ENABLE_APP_SANDBOX must be YES")

    def test_included_xcconfig_is_read(self) -> None:
        self.fixture.write("Config/Network.xcconfig", "ENABLE_INCOMING_NETWORK_CONNECTIONS = YES // inbound\n")
        self.fixture.edit(
            SHARED, "ENABLE_OUTGOING_NETWORK_CONNECTIONS = NO",
            'ENABLE_OUTGOING_NETWORK_CONNECTIONS = NO\n#include "Network.xcconfig"',
        )
        self.assertFailsWith(self.fixture.errors(), "ENABLE_INCOMING_NETWORK_CONNECTIONS must not be YES")

    def test_conditional_setting_in_xcconfig_cannot_override_sandbox(self) -> None:
        self.fixture.edit(
            SHARED, "ENABLE_APP_SANDBOX = YES", "ENABLE_APP_SANDBOX = YES\nENABLE_APP_SANDBOX[sdk=macosx*] = NO;"
        )
        self.assertFailsWith(self.fixture.errors(), "target ShowMyCopy (Debug): ENABLE_APP_SANDBOX must be YES")

    def test_missing_include_fails(self) -> None:
        self.fixture.edit(SHARED, "MACOSX_DEPLOYMENT_TARGET", '#include "Missing.xcconfig"\nMACOSX_DEPLOYMENT_TARGET')
        self.assertFailsWith(self.fixture.errors(), "cannot read Config/Missing.xcconfig")

    def test_optional_missing_include_is_skipped(self) -> None:
        self.fixture.edit(SHARED, "MACOSX_DEPLOYMENT_TARGET", '#include? "Local.xcconfig"\nMACOSX_DEPLOYMENT_TARGET')
        self.assertEqual(self.fixture.errors(), [])

    def test_include_from_outside_the_repository_fails(self) -> None:
        for target in ("../../outside.xcconfig", "/etc/outside.xcconfig", "<DEVELOPER_DIR>/x.xcconfig", "$(X).xcconfig"):
            with self.subTest(target):
                self.fixture.write(SHARED, '#include "%s"\n' % target)
                self.assertFailsWith(self.fixture.errors(), "cannot follow the include")

    def test_include_cycle_fails(self) -> None:
        self.fixture.write("Config/Loop.xcconfig", '#include "Shared.xcconfig"\n')
        self.fixture.edit(SHARED, "MACOSX_DEPLOYMENT_TARGET", '#include "Loop.xcconfig"\nMACOSX_DEPLOYMENT_TARGET')
        self.assertFailsWith(self.fixture.errors(), "includes itself")

    def test_unparseable_xcconfig_line_fails(self) -> None:
        self.fixture.edit(SHARED, "MACOSX_DEPLOYMENT_TARGET = 15.0", "MACOSX_DEPLOYMENT_TARGET 15.0")
        self.assertFailsWith(self.fixture.errors(), "Config/Shared.xcconfig:")

    def test_missing_xcconfig_file_fails(self) -> None:
        os.remove(os.path.join(self.fixture.root, SHARED))
        self.assertFailsWith(self.fixture.errors(), "cannot read Config/Shared.xcconfig")

    def test_runtime_exception(self) -> None:
        self.fixture.add_app_setting("RUNTIME_EXCEPTION_ALLOW_JIT = YES;")
        self.assertFailsWith(self.fixture.errors(), "RUNTIME_EXCEPTION_ALLOW_JIT weakens the hardened runtime")

    def test_resource_access(self) -> None:
        self.fixture.add_app_setting("ENABLE_RESOURCE_ACCESS_CAMERA = YES;")
        self.assertFailsWith(self.fixture.errors(), "ENABLE_RESOURCE_ACCESS_CAMERA = YES grants access")

    def test_file_access(self) -> None:
        self.fixture.replace(APP_READ_ONLY_SETTING, "ENABLE_USER_SELECTED_FILES = readwrite;", count=2)
        self.assertFailsWith(self.fixture.errors(), "ENABLE_USER_SELECTED_FILES = readwrite grants access")

    def test_conditional_read_write_cannot_hide_behind_read_only(self) -> None:
        conditional = "ENABLE_USER_SELECTED_FILES[config=Debug] = readwrite\n"
        self.fixture.edit(SHARED, "SWIFT_VERSION = 6.0\n", "SWIFT_VERSION = 6.0\n" + conditional)
        self.assertFailsWith(
            self.fixture.errors(), "target ShowMyCopy (Debug): ENABLE_USER_SELECTED_FILES = readwrite grants access"
        )

    def test_read_only_setting_in_the_widget_fails(self) -> None:
        self.fixture.edit(WIDGET_XCCONFIG, "MACOSX_DEPLOYMENT_TARGET = 26.0\n",
                          "MACOSX_DEPLOYMENT_TARGET = 26.0\nENABLE_USER_SELECTED_FILES = readonly\n")
        self.assertFailsWith(
            self.fixture.errors(), "target %s (Release): ENABLE_USER_SELECTED_FILES = readonly grants access" % WIDGET
        )

    def test_read_only_setting_for_every_target_fails_in_the_widget(self) -> None:
        self.fixture.edit(SHARED, "SWIFT_VERSION = 6.0\n", "SWIFT_VERSION = 6.0\n" + APP_READ_ONLY_SETTING[:-1] + "\n")
        errors = self.fixture.errors()
        self.assertFailsWith(errors, "target %s (Debug): ENABLE_USER_SELECTED_FILES = readonly grants access" % WIDGET)
        self.assertFalse([error for error in errors if "target ShowMyCopy (" in error], errors)

    def test_other_code_sign_flags_entitlements(self) -> None:
        self.fixture.add_app_setting('OTHER_CODE_SIGN_FLAGS = ("--entitlements", "x.plist");')
        self.assertFailsWith(self.fixture.errors(), "OTHER_CODE_SIGN_FLAGS must not pass --entitlements")

    def test_code_sign_entitlements_with_sandbox_false(self) -> None:
        self.fixture.write("ShowMyCopy/App.entitlements", plist({"com.apple.security.app-sandbox": False}))
        self.fixture.add_app_setting("CODE_SIGN_ENTITLEMENTS = ShowMyCopy/App.entitlements;")
        self.assertFailsWith(self.fixture.errors(), "entitlement com.apple.security.app-sandbox must be True")

    def test_code_sign_entitlements_with_allow_jit(self) -> None:
        self.fixture.write(
            "ShowMyCopy/App.entitlements", plist(dict(SANDBOX_ONLY, **{"com.apple.security.cs.allow-jit": True}))
        )
        self.fixture.add_app_setting('CODE_SIGN_ENTITLEMENTS = "$(SRCROOT)/ShowMyCopy/App.entitlements";')
        errors = self.fixture.errors()
        self.assertFailsWith(errors, "CODE_SIGN_ENTITLEMENTS: entitlement com.apple.security.cs.allow-jit")

    def test_code_sign_entitlements_missing_file(self) -> None:
        self.fixture.add_app_setting("CODE_SIGN_ENTITLEMENTS = ShowMyCopy/Missing.entitlements;")
        self.assertFailsWith(self.fixture.errors(), "cannot read entitlements file")

    def test_allowed_entitlements_file_passes(self) -> None:
        # The app's own file with user-selected read-only files, and the build setting that says the same.
        self.fixture.write(APP_FILE, plist(APP_ENTITLEMENTS))
        self.fixture.add_app_setting("CODE_SIGN_ENTITLEMENTS = %s;" % APP_FILE)
        self.assertIn(APP_READ_ONLY_SETTING, self.fixture.pbxproj)
        self.assertEqual(self.fixture.errors(), [])

    def test_app_read_only_must_be_exactly_true(self) -> None:
        self.fixture.add_app_setting("CODE_SIGN_ENTITLEMENTS = %s;" % APP_FILE)
        for value in (False, 1, "true", "YES"):
            with self.subTest(value=value):
                self.fixture.write(APP_FILE, plist(dict(SANDBOX_ONLY, **{READ_ONLY: value})))
                self.assertFailsWith(self.fixture.errors(), "entitlement %s must be True" % READ_ONLY)

    def test_app_read_write_fails(self) -> None:
        self.fixture.add_app_setting("CODE_SIGN_ENTITLEMENTS = %s;" % APP_FILE)
        for ents in (dict(SANDBOX_ONLY, **{READ_WRITE: True}), dict(APP_ENTITLEMENTS, **{READ_WRITE: True})):
            with self.subTest(ents=sorted(ents)):
                self.fixture.write(APP_FILE, plist(ents))
                self.assertFailsWith(
                    self.fixture.errors(), "CODE_SIGN_ENTITLEMENTS: entitlement %s is not allowed" % READ_WRITE
                )

    def test_app_read_only_without_the_build_setting_fails(self) -> None:
        self.fixture.replace("\t\t\t\t" + APP_READ_ONLY_SETTING + "\n", "", count=2)
        self.fixture.write(APP_FILE, plist(APP_ENTITLEMENTS))
        self.fixture.add_app_setting("CODE_SIGN_ENTITLEMENTS = %s;" % APP_FILE)
        self.assertFailsWith(
            self.fixture.errors(),
            "ENABLE_USER_SELECTED_FILES = (not set) and %s in %s disagree" % (READ_ONLY, APP_FILE),
        )

    def test_build_setting_without_the_app_read_only_entitlement_fails(self) -> None:
        self.fixture.write(APP_FILE, plist(SANDBOX_ONLY))
        self.fixture.add_app_setting("CODE_SIGN_ENTITLEMENTS = %s;" % APP_FILE)
        self.assertFailsWith(
            self.fixture.errors(), "ENABLE_USER_SELECTED_FILES = readonly and %s in %s disagree" % (READ_ONLY, APP_FILE)
        )

    def test_read_only_build_setting_through_a_variable_is_not_trusted(self) -> None:
        self.fixture.replace(APP_READ_ONLY_SETTING, 'ENABLE_USER_SELECTED_FILES = "$(FILES)";', count=2)
        self.fixture.write(APP_FILE, plist(APP_ENTITLEMENTS))
        self.fixture.add_app_setting("CODE_SIGN_ENTITLEMENTS = %s;" % APP_FILE)
        errors = self.fixture.errors()
        self.assertFailsWith(errors, "ENABLE_USER_SELECTED_FILES uses a build setting variable")
        self.assertFailsWith(errors, "ENABLE_USER_SELECTED_FILES = $(FILES) grants access")

    def test_app_read_only_in_another_file_fails(self) -> None:
        self.fixture.write("ShowMyCopy/App.entitlements", plist(APP_ENTITLEMENTS))
        self.fixture.add_app_setting("CODE_SIGN_ENTITLEMENTS = ShowMyCopy/App.entitlements;")
        errors = self.fixture.errors()
        self.assertFailsWith(errors, "CODE_SIGN_ENTITLEMENTS: entitlement %s is not allowed (only the app" % READ_ONLY)
        self.assertFailsWith(errors, "ShowMyCopy/App.entitlements: entitlement %s is not allowed" % READ_ONLY)

    def test_read_only_in_the_widget_file_fails(self) -> None:
        self.fixture.write(WIDGET_FILE, plist(APP_ENTITLEMENTS))
        self.assertFailsWith(
            self.fixture.errors(), "%s: entitlement %s is not allowed (only the app" % (WIDGET_FILE, READ_ONLY)
        )

    def test_widget_signed_with_the_app_file_fails(self) -> None:
        self.fixture.write(APP_FILE, plist(APP_ENTITLEMENTS))
        self.fixture.edit(WIDGET_XCCONFIG, "MACOSX_DEPLOYMENT_TARGET = 26.0\n",
                          "MACOSX_DEPLOYMENT_TARGET = 26.0\nCODE_SIGN_ENTITLEMENTS = %s\n" % APP_FILE)
        self.assertFailsWith(
            self.fixture.errors(),
            "target %s (Release) CODE_SIGN_ENTITLEMENTS: entitlement %s is not allowed" % (WIDGET, READ_ONLY),
        )

    def test_stray_entitlements_file(self) -> None:
        self.fixture.write(
            "Helper/Helper.entitlements",
            plist(dict(SANDBOX_ONLY, **{"com.apple.security.files.downloads.read-write": True})),
        )
        self.assertFailsWith(self.fixture.errors(), "entitlement com.apple.security.files.downloads.read-write")

    def test_package_up_to_next_major_next_to_exact(self) -> None:
        extra = textwrap.dedent(
            """\
            \t\tBB00000000000000000000A1 /* XCRemoteSwiftPackageReference "Other" */ = {
            \t\t\tisa = XCRemoteSwiftPackageReference;
            \t\t\trepositoryURL = "https://example.com/other";
            \t\t\trequirement = {
            \t\t\t\tkind = upToNextMajorVersion;
            \t\t\t\tminimumVersion = 1.0.0;
            \t\t\t};
            \t\t};
            """
        )
        anchor = "/* End XCRemoteSwiftPackageReference section */"
        self.fixture.replace(anchor, extra + anchor)
        self.assertIn("kind = exactVersion;", self.fixture.pbxproj)
        self.assertFailsWith(self.fixture.errors(), "https://example.com/other must use an exact version")

    def test_unknown_xcconfig_reference_fails(self) -> None:
        self.fixture.replace(APP_RELEASE, APP_RELEASE.replace(
            "isa = XCBuildConfiguration;", "isa = XCBuildConfiguration;\n\t\t\tbaseConfigurationReference = CC01;"
        ))
        self.assertFailsWith(self.fixture.errors(), "'CC01' is missing or not a PBXFileReference")

    def test_xcconfig_relative_to_an_unknown_place_fails(self) -> None:
        self.fixture.replace(
            'path = Shared.xcconfig; sourceTree = "<group>";', "path = Shared.xcconfig; sourceTree = SDKROOT;"
        )
        self.assertFailsWith(self.fixture.errors(), "which this checker does not resolve")

    def test_unparseable_project(self) -> None:
        self.fixture.pbxproj = self.fixture.pbxproj.replace("ENABLE_PREVIEWS = YES;", "ENABLE_PREVIEWS = YES", 1)
        self.fixture.save()
        self.assertFailsWith(self.fixture.errors(), "cannot check")

    def test_unsandboxed_extension_target(self) -> None:
        # A second shippable target: same rules as the app, minus the explicit-NO network rule.
        self.fixture.replace(
            'productType = "com.apple.product-type.bundle.unit-test";',
            'productType = "com.apple.product-type.app-extension";',
        )
        self.assertFailsWith(self.fixture.errors(), "target ShowMyCopyTests (Debug): ENABLE_APP_SANDBOX must be YES")


class SourceScanTests(CheckerTestCase):
    BAD = {
        "URLSession": "let session = URLSession.shared",
        "NSWorkspace.shared.open": "NSWorkspace.shared.open(url)",
        "openApplication": "NSWorkspace.shared.openApplication(at: url, configuration: config)",
        "openURL": "@Environment(\\.openURL) private var openURL",
        "Link": 'Link("Help", destination: url)',
        "ShareLink": "ShareLink(item: text)",
        "NSSharingService": "let picker = NSSharingServicePicker(items: [text])",
        "Process(": "let task = Process()",
        "Process.run": "try Process.run(url, arguments: [])",
        "NSXPCConnection": "let connection = NSXPCConnection(serviceName: name)",
        "Data(contentsOf:)": "let data = try Data(contentsOf: url)",
        "contentsOf: URL": "let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)",
        "CSSearchableIndex": "CSSearchableIndex.default().indexSearchableItems(items)",
        "NSUserActivity": "let activity = NSUserActivity(activityType: type)",
        "WKWebView": "let view = WKWebView()",
        "import Network": "import Network",
    }
    GOOD = textwrap.dedent(
        """\
        import AppKit

        let isTest = ProcessInfo.processInfo.environment["X"] != nil
        let app = NSWorkspace.shared.frontmostApplication
        let center = NSWorkspace.shared.notificationCenter
        var items: [Int] = []
        items.append(contentsOf: [1, 2])
        let link = NavigationLink("Settings") { EmptyView() }
        let sessionCount = 1
        """
    )

    def test_each_exfiltration_route_is_caught(self) -> None:
        for name, line in self.BAD.items():
            with self.subTest(name):
                path = self.fixture.write("ShowMyCopy/Bad.swift", "import AppKit\n" + line + "\n")
                self.assertFailsWith(self.fixture.errors(), "ShowMyCopy/Bad.swift:2:")
                os.remove(path)

    def test_scan_covers_new_folders(self) -> None:
        self.fixture.write("NewTarget/Sources/Uploader.swift", "let session = URLSession.shared\n")
        self.assertFailsWith(self.fixture.errors(), "NewTarget/Sources/Uploader.swift:1: network API")

    def test_lookalikes_pass(self) -> None:
        self.fixture.write("ShowMyCopy/Good.swift", self.GOOD)
        self.assertEqual(self.fixture.errors(), [])

    def test_unreadable_file_fails(self) -> None:
        self.fixture.write("ShowMyCopy/Bad.swift", 'let text = "not closed\nlet session = 1\n')
        self.assertFailsWith(self.fixture.errors(), "ShowMyCopy/Bad.swift: cannot scan: line 1: string not closed")


class WorkspaceAndOpenTests(CheckerTestCase):
    """NSWorkspace only through its read-only members, `open...` only by the app's own names, across line breaks."""

    WORKSPACE = "NSWorkspace beyond its read-only members"
    OPEN = "open call that is not in OPEN_ALLOWLIST"
    # name: (code, line of the error, label). The code starts at line 2, after `import AppKit`.
    BAD = {
        "workspace kept in a variable": ("let w = NSWorkspace.shared; w.open(url)", 2, WORKSPACE),
        "workspace passed around": (
            "func show(_ url: URL) { hand(NSWorkspace.shared, url) }\n"
            "func hand(_ w: NSWorkspace, _ url: URL) { _ = w.open(url) }",
            2, WORKSPACE,
        ),
        "workspace as a parameter type": (
            "func show(_ url: URL) { hand(NSWorkspace.shared, url) }\n"
            "func hand(_ w: NSWorkspace, _ url: URL) { _ = w.open(url) }",
            3, WORKSPACE,
        ),
        "split across lines": ("_ = NSWorkspace.shared\n    .open(url)", 2, WORKSPACE),
        "split with a comment": ("_ = NSWorkspace // the shared one\n    .shared /* then */ .open(url)", 2, WORKSPACE),
        "injected workspace": (
            "final class Opener {\n"
            "    private let workspace: NSWorkspace\n"
            "    init(workspace: NSWorkspace) { self.workspace = workspace }\n"
            "    func show(_ url: URL) { _ = workspace.open(url) }\n"
            "}",
            3, WORKSPACE,
        ),
        "workspace made, not shared": ("_ = NSWorkspace().open(url)", 2, WORKSPACE),
        "openApplication on a stored workspace": (
            "let workspace = NSWorkspace.shared\n"
            "workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())",
            3, WORKSPACE,
        ),
        "other workspace call": ("NSWorkspace.shared.activateFileViewerSelecting([url])", 2, WORKSPACE),
        "allowed member's name on another receiver": ("_ = NSWorkspace.shared\n    .open(url).icon", 2, WORKSPACE),
        "workspace in a type alias": ("typealias Shell = NSWorkspace", 2, WORKSPACE),
        "workspace in a key path": ("let path = \\NSWorkspace.shared", 2, WORKSPACE),
        "workspace extended": ("extension NSWorkspace: Opening {}", 2, WORKSPACE),
        "workspace in an interpolation": ('let text = "\\(NSWorkspace.shared.open(url))"', 2, WORKSPACE),
        "workspace in a multi-line string's interpolation": (
            'let text = """\n    \\(NSWorkspace.shared.open(url))\n    """', 3, WORKSPACE,
        ),
        "open call of another type": (
            "NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }", 2, OPEN,
        ),
        "open call split across lines": ("documents\n    .openDocument(withContentsOf: url, display: true)", 3, OPEN),
        "open member without a call": ("urls.forEach(documents.openUntitledDocumentAndDisplay)", 2, OPEN),
        "open call in backticks": ("documents.`openDocument`(url)", 2, OPEN),
        "free open call": ("openFile(path)", 2, OPEN),
        "free open call with a trailing closure": ("openThing { url }", 2, OPEN),
        "open environment value": ("@Environment(\\.openWindow) private var openWindow", 2, OPEN),
        "qualified call on another receiver": ("Other.openSystemSettingsLoginItems()", 2, OPEN),
        "qualified call through a nested name": ("Kit.SMAppService.openSystemSettingsLoginItems()", 2, OPEN),
        "initializer split across lines": (
            "let data = try Data(\n    contentsOf: url\n)", 2, "initializer reading contentsOf: a URL",
        ),
        "process split across lines": ("try Process\n    .run(url, arguments: [])", 2, "process execution"),
        "import split across lines": ("import\n    Network", 2, "network module import"),
        "Launch Services": ("LSOpenCFURLRef(url as CFURL, nil)", 2, "Launch Services call"),
        "Apple event": ("let event = NSAppleEventDescriptor(eventClass: 1, eventID: 2, target: nil, "
                        "returnID: 0, transactionID: 0)", 2, "Apple event"),
        "Services menu": ("NSPerformService(name, pasteboard)", 2, "external hand-off API"),
        "class by name": ('let type = NSClassFromString("NSWork" + "space")', 2, "dynamic lookup"),
        "method by name": ('_ = object.perform(Selector(("open" + ":")), with: url)', 2, "dynamic lookup"),
        "symbol by name": ('let symbol = dlsym(handle, "LSOpenCFURLRef")', 2, "dynamic lookup"),
    }
    GOOD = textwrap.dedent(
        """\
        import AppKit
        import ServiceManagement

        // NSWorkspace.shared.open(url), NSWorkspace().open(url) and `x.openFile(path)` in a comment.
        /* let w = NSWorkspace.shared
           w.open(url) */
        let text = "NSWorkspace.shared.open(url) openURL(x)"
        let raw = #"NSWorkspace.shared.open("\\(url)")"#
        let lines = \"""
            NSWorkspace.shared
                .openApplication(at: url)
            \"""
        let apps = NSWorkspace.shared.runningApplications
        let front = NSWorkspace
            .shared
            .frontmostApplication
        let center = NSWorkspace.shared.notificationCenter
        let note = NSWorkspace.didWakeNotification
        let icon = NSWorkspace.shared.icon(forFile: path)
        let typeIcon = NSWorkspace.shared.icon(for: .applicationBundle)
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        let label = "\\(NSWorkspace.shared.runningApplications.count) apps"
        let plain = try sealer.open(sealed)
        let decrypted = try AES.GCM.open(box, using: key)
        let descriptor = Darwin.open(path, O_RDONLY)
        let store = try opener.openStore(url)
        SMAppService.openSystemSettingsLoginItems()
        SMAppService
            .openSystemSettingsLoginItems()
        func openLater(_ value: Int) {}
        open class Base {}
        let gate = Gate(open: true)
        let opened = true
        func openingTwiceChangesNothing() {}
        let panel = NSOpenPanel()
        let handle = try FileHandle(forReadingFrom: url)
        let result = sqlite3_open(path, &database)
        let action = #selector(Base.description)
        """
    )

    def test_each_bypass_is_caught(self) -> None:
        for name, (code, line, label) in self.BAD.items():
            with self.subTest(name):
                path = self.fixture.write("ShowMyCopy/Bad.swift", "import AppKit\n" + code + "\n")
                self.assertFailsWith(self.fixture.errors(), "ShowMyCopy/Bad.swift:%d: %s" % (line, label))
                os.remove(path)

    def test_also_in_tests_and_new_folders(self) -> None:
        for relative in ("ShowMyCopyTests/Settings/OpenTests.swift", "NewTarget/Opener.swift"):
            with self.subTest(relative):
                path = self.fixture.write(relative, "let w = NSWorkspace.shared\n")
                self.assertFailsWith(self.fixture.errors(), "%s:1: %s" % (relative, self.WORKSPACE))
                os.remove(path)

    def test_read_only_members_and_lookalikes_pass(self) -> None:
        self.fixture.write("ShowMyCopy/Good.swift", self.GOOD)
        self.assertEqual(self.fixture.errors(), [])

    def test_every_allowlisted_name_passes(self) -> None:
        code = ["import AppKit"]
        code += ["_ = NSWorkspace.shared.%s" % member for member in sorted(check_security.NSWORKSPACE_READ_ONLY)]
        code += ["_ = x.%s()" % name for name in sorted(check_security.OPEN_ALLOWLIST)]
        code += ["%s.%s()" % pair for pair in sorted(check_security.OPEN_QUALIFIED_ALLOWLIST)]
        self.fixture.write("ShowMyCopy/Good.swift", "\n".join(code) + "\n")
        self.assertEqual(self.fixture.errors(), [])


class XcodebuildTests(CheckerTestCase):
    """The resolved-settings cross-check, fed by a fake xcodebuild put first on PATH."""

    def setUp(self) -> None:
        super().setUp()
        self.bin = os.path.join(self.tmp, "xcodebuild-bin")
        os.makedirs(self.bin)
        xcodebuild = os.path.join(self.bin, "xcodebuild")
        with open(xcodebuild, "w") as out:
            out.write(FAKE_XCODEBUILD)
        os.chmod(xcodebuild, os.stat(xcodebuild).st_mode | stat.S_IXUSR)
        # Start from what the fixture project declares, as Xcode would resolve it.
        targets, _ = check_security.project_targets(self.fixture.root)
        self.settings = {}
        for name, product_type, configs in targets:
            for config, settings in configs.items():
                resolved = dict(settings, PRODUCT_TYPE=product_type)
                if config == "Debug":
                    resolved["ENABLE_DEBUG_DYLIB"] = "YES"
                self.settings[(name, config)] = resolved

    def resolve(self, config: str, key: str, value: str) -> None:
        self.settings[("ShowMyCopy", config)][key] = value

    def errors(self) -> list:
        for (target, config), settings in self.settings.items():
            path = os.path.join(self.bin, "settings", target, config + ".json")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as out:
                json.dump([{"target": target, "buildSettings": settings}], out)
        old = os.environ.get("PATH", "")
        os.environ["PATH"] = self.bin + os.pathsep + old
        try:
            return check_security.run_checks(self.fixture.root, use_xcodebuild=True)
        finally:
            os.environ["PATH"] = old

    def test_resolved_settings_pass(self) -> None:
        self.assertEqual(self.errors(), [])

    def test_debug_hardened_runtime_resolved_to_no_passes(self) -> None:
        # What Xcode 26 reports for the Debug configuration of the app.
        self.resolve("Debug", "ENABLE_HARDENED_RUNTIME", "NO")
        self.assertEqual(self.errors(), [])

    def test_release_hardened_runtime_resolved_to_no(self) -> None:
        self.resolve("Release", "ENABLE_HARDENED_RUNTIME", "NO")
        self.assertFailsWith(
            self.errors(), "xcodebuild: target ShowMyCopy (Release): ENABLE_HARDENED_RUNTIME must be YES"
        )

    def test_debug_sandbox_resolved_to_no(self) -> None:
        self.resolve("Debug", "ENABLE_HARDENED_RUNTIME", "NO")
        self.resolve("Debug", "ENABLE_APP_SANDBOX", "NO")
        self.assertFailsWith(self.errors(), "xcodebuild: target ShowMyCopy (Debug): ENABLE_APP_SANDBOX must be YES")

    def test_debug_network_resolved_to_yes(self) -> None:
        self.resolve("Debug", "ENABLE_HARDENED_RUNTIME", "NO")
        self.resolve("Debug", "ENABLE_OUTGOING_NETWORK_CONNECTIONS", "YES")
        self.assertFailsWith(
            self.errors(), "xcodebuild: target ShowMyCopy (Debug): ENABLE_OUTGOING_NETWORK_CONNECTIONS must not be YES"
        )

    def test_widget_read_only_resolved(self) -> None:
        self.settings[(WIDGET, "Release")]["ENABLE_USER_SELECTED_FILES"] = "readonly"
        self.assertFailsWith(
            self.errors(),
            "xcodebuild: target %s (Release): ENABLE_USER_SELECTED_FILES = readonly grants access" % WIDGET,
        )

    def test_app_read_write_resolved(self) -> None:
        self.assertEqual(self.settings[("ShowMyCopy", "Release")]["ENABLE_USER_SELECTED_FILES"], "readonly")
        self.resolve("Release", "ENABLE_USER_SELECTED_FILES", "readwrite")
        self.assertFailsWith(
            self.errors(),
            "xcodebuild: target ShowMyCopy (Release): ENABLE_USER_SELECTED_FILES = readwrite grants access",
        )

    def test_project_file_debug_hardened_runtime_no_still_fails(self) -> None:
        # The project must still declare YES everywhere; only Xcode's own resolution may say NO.
        self.fixture.replace(APP_DEBUG, APP_DEBUG + "\t\t\t\tENABLE_HARDENED_RUNTIME = NO;\n")
        errors = self.errors()
        self.assertIn("target ShowMyCopy (Debug): ENABLE_HARDENED_RUNTIME must be YES", errors)


class SignedAppTests(CheckerTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        codesign = os.path.join(self.bin, "codesign")
        with open(codesign, "w") as out:
            out.write(FAKE_CODESIGN)
        os.chmod(codesign, os.stat(codesign).st_mode | stat.S_IXUSR)
        self.app = os.path.join(self.tmp, "ShowMyCopy.app")
        self.bundle(self.app, SANDBOX_ONLY)
        self.executable = self.nested("MacOS/ShowMyCopy")
        os.makedirs(os.path.dirname(self.executable))
        with open(self.executable, "wb") as out:
            out.write(b"\xcf\xfa\xed\xfecom.pandamy619.ShowMyCopy.anotherCopyStarted\x00")

    def bundle(self, path: str, ents, *markers: str) -> None:
        meta = path + ".fake" if path.endswith(".dylib") else os.path.join(path, "_fake")
        if path.endswith(".dylib"):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "wb").close()
        os.makedirs(meta, exist_ok=True)
        if ents is not None:
            with open(os.path.join(meta, "entitlements.plist"), "wb") as out:
                out.write(plist(ents))
        for marker in markers:
            open(os.path.join(meta, marker), "w").close()

    @contextmanager
    def fake_codesign(self):
        old = os.environ.get("PATH", "")
        os.environ["PATH"] = self.bin + os.pathsep + old
        try:
            yield
        finally:
            os.environ["PATH"] = old

    def errors(self) -> list:
        with self.fake_codesign():
            return check_security.check_signed_app(self.app)

    def nested(self, relative: str) -> str:
        return os.path.join(self.app, "Contents", relative)

    def test_clean_app_passes(self) -> None:
        self.bundle(self.nested("PlugIns/Share.appex"), SANDBOX_ONLY)
        self.bundle(self.nested("Frameworks/KeyboardShortcuts.framework"), None)
        self.bundle(self.nested("Frameworks/libFoo.dylib"), None)
        self.assertEqual(self.errors(), [])

    def test_app_with_read_only_passes(self) -> None:
        self.bundle(self.app, APP_ENTITLEMENTS)
        self.bundle(self.nested("PlugIns/Share.appex"), SANDBOX_ONLY)
        self.assertEqual(self.errors(), [])

    def test_app_read_only_must_be_exactly_true(self) -> None:
        for value in (False, 1, "true"):
            with self.subTest(value=value):
                self.bundle(self.app, dict(SANDBOX_ONLY, **{READ_ONLY: value}))
                self.assertFailsWith(self.errors(), "entitlement %s must be True" % READ_ONLY)

    def test_app_read_write_next_to_read_only_fails(self) -> None:
        self.bundle(self.app, dict(APP_ENTITLEMENTS, **{READ_WRITE: True}))
        self.assertFailsWith(self.errors(), "entitlement %s is not allowed" % READ_WRITE)

    def test_embedded_code_with_read_only_fails(self) -> None:
        for relative in ("PlugIns/Share.appex", "XPCServices/Helper.xpc", "Library/LoginItems/Helper.app"):
            with self.subTest(relative):
                self.bundle(self.app, APP_ENTITLEMENTS)
                self.bundle(self.nested(relative), APP_ENTITLEMENTS)
                errors = self.errors()
                self.assertFailsWith(errors, "%s: entitlement %s is not allowed (only the app" % (relative, READ_ONLY))
                self.assertEqual(len(errors), 1, errors)
                shutil.rmtree(self.nested(relative))

    def test_sandbox_false(self) -> None:
        self.bundle(self.app, {"com.apple.security.app-sandbox": False})
        self.assertFailsWith(self.errors(), "app-sandbox must be boolean true")

    def test_sandbox_not_boolean(self) -> None:
        self.bundle(self.app, {"com.apple.security.app-sandbox": 1})
        self.assertFailsWith(self.errors(), "app-sandbox must be boolean true")

    def test_sandbox_missing(self) -> None:
        self.bundle(self.app, {})
        self.assertFailsWith(self.errors(), "app-sandbox must be boolean true")

    def test_allow_jit(self) -> None:
        self.bundle(self.app, dict(SANDBOX_ONLY, **{"com.apple.security.cs.allow-jit": True}))
        self.assertFailsWith(self.errors(), "entitlement com.apple.security.cs.allow-jit is not allowed")

    def test_other_weakening_entitlements(self) -> None:
        for key in (
            "com.apple.security.cs.disable-executable-page-protection",
            "com.apple.security.cs.debugger",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.automation.apple-events",
            "com.apple.security.device.camera",
            "com.apple.security.personal-information.addressbook",
            "com.apple.security.inherit",
            "com.apple.security.network.client",
        ):
            with self.subTest(key):
                self.bundle(self.app, dict(SANDBOX_ONLY, **{key: True}))
                self.assertFailsWith(self.errors(), "entitlement %s is not allowed" % key)

    def test_no_hardened_runtime(self) -> None:
        self.bundle(self.app, SANDBOX_ONLY, "no-runtime")
        self.assertFailsWith(self.errors(), "hardened runtime flag is not set")

    def test_verify_fails(self) -> None:
        self.bundle(self.app, SANDBOX_ONLY, "verify-fails")
        self.assertFailsWith(self.errors(), "fails codesign --verify --strict --deep")

    def test_unsandboxed_extension(self) -> None:
        self.bundle(self.nested("PlugIns/Share.appex"), {})
        self.assertFailsWith(self.errors(), "PlugIns/Share.appex: com.apple.security.app-sandbox must be boolean true")

    def test_xpc_service_with_network(self) -> None:
        self.bundle(
            self.nested("XPCServices/Helper.xpc"), dict(SANDBOX_ONLY, **{"com.apple.security.network.client": True})
        )
        self.assertFailsWith(self.errors(), "Helper.xpc: entitlement com.apple.security.network.client")

    def test_framework_with_entitlements(self) -> None:
        self.bundle(self.nested("Frameworks/Evil.framework"), SANDBOX_ONLY)
        self.assertFailsWith(self.errors(), "Evil.framework: libraries and frameworks must not carry entitlements")

    def test_dylib_with_entitlements(self) -> None:
        self.bundle(self.nested("Frameworks/libEvil.dylib"), {"com.apple.security.get-task-allow": True})
        self.assertFailsWith(self.errors(), "libEvil.dylib: libraries and frameworks must not carry entitlements")

    def test_debug_only_string_in_the_executable_fails(self) -> None:
        with open(self.executable, "ab") as out:
            out.write(DEBUG_MARKER.encode() + b"\x00")
        self.assertFailsWith(self.errors(), "MacOS/ShowMyCopy: contains the Debug-only string %r" % DEBUG_MARKER)

    def test_paste_debug_key_in_the_executable_fails(self) -> None:
        with open(self.executable, "ab") as out:
            out.write(b"\x00" + PASTE_DEBUG_KEY.encode() + b"\x00")
        self.assertFailsWith(self.errors(), "MacOS/ShowMyCopy: contains the Debug-only string 'debug.paste.'")

    def test_debug_only_string_in_nested_code_fails(self) -> None:
        for relative in ("MacOS/ShowMyCopy.debug.dylib", "PlugIns/Share.appex/Contents/MacOS/Share"):
            with self.subTest(relative):
                path = self.nested(relative)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "wb") as out:
                    out.write(b"\x00" + DEBUG_MARKER.encode())
                if relative.startswith("PlugIns"):
                    self.bundle(self.nested("PlugIns/Share.appex"), SANDBOX_ONLY)
                self.assertFailsWith(self.errors(), "%s: contains the Debug-only string" % relative)
                os.remove(path)

    def test_unreadable_file_in_the_app_fails(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("root reads every file")
        os.chmod(self.executable, 0)
        self.addCleanup(os.chmod, self.executable, stat.S_IRUSR | stat.S_IWUSR)
        self.assertFailsWith(self.errors(), "MacOS/ShowMyCopy: cannot read")

    def test_without_codesign(self) -> None:
        old = os.environ.get("PATH", "")
        os.environ["PATH"] = os.path.join(self.tmp, "empty")
        try:
            errors = check_security.check_signed_app(self.app)
        finally:
            os.environ["PATH"] = old
        self.assertFailsWith(errors, "codesign not found")


class DebugOnlyStringTests(CheckerTestCase):
    """DEBUG_ONLY_STRINGS appear in app sources only in an `#if DEBUG` branch."""

    FILE = "ShowMyCopy/App/AppDelegate.swift"

    def errors_for(self, code: str, relative: str = FILE) -> list:
        self.fixture.write(relative, textwrap.dedent(code))
        return self.fixture.errors()

    def test_in_a_debug_branch_passes(self) -> None:
        cases = {
            "plain": """\
                #if DEBUG
                    let name = "%s"
                #else
                    let name: String? = nil
                #endif
                """,
            "nested": """\
                #if DEBUG
                    #if os(macOS)
                        let name = "%s"
                    #else
                        let name = "%s"
                    #endif
                #endif
                """,
            "elseif": """\
                #if os(iOS)
                    let name = ""
                #elseif DEBUG
                    let name = "%s"
                #endif
                """,
        }
        for name, code in cases.items():
            with self.subTest(name):
                self.assertEqual(self.errors_for(code.replace("%s", DEBUG_MARKER)), [])

    def test_outside_a_debug_branch_fails(self) -> None:
        cases = {
            "no condition": 'let name = "%s"\n',
            "else": '#if DEBUG\nlet a = 1\n#else\nlet name = "%s"\n#endif\n',
            "not debug": '#if !DEBUG\nlet name = "%s"\n#endif\n',
            "another condition": '#if os(macOS)\nlet name = "%s"\n#endif\n',
            "debug and more": '#if DEBUG && os(macOS)\nlet name = "%s"\n#endif\n',
            "after the branch": '#if DEBUG\nlet a = 1\n#endif\nlet name = "%s"\n',
            "elseif after debug": '#if DEBUG\nlet a = 1\n#elseif os(macOS)\nlet name = "%s"\n#endif\n',
            "debug in a comment": '#if os(macOS) // DEBUG\nlet name = "%s"\n#endif\n',
        }
        for name, code in cases.items():
            with self.subTest(name):
                self.assertFailsWith(
                    self.errors_for(code.replace("%s", DEBUG_MARKER)),
                    "%s:%d: Debug-only string" % (self.FILE, code.count("\n", 0, code.index("%s")) + 1),
                )

    def test_paste_debug_keys_only_in_a_debug_branch(self) -> None:
        relative = "ShowMyCopy/Paste/PasteDebugTuning.swift"
        inside = '#if DEBUG\n    static let settle = "%s"\n#endif\n' % PASTE_DEBUG_KEY
        self.assertEqual(self.errors_for(inside, relative), [])
        cases = {
            "no condition": 'static let settle = "%s"\n',
            "else": '#if DEBUG\nlet a = 1\n#else\nstatic let settle = "%s"\n#endif\n',
            "another key": 'let tap = "debug.paste.tap"\n',
        }
        for name, code in cases.items():
            with self.subTest(name):
                self.assertFailsWith(
                    self.errors_for(code.replace("%s", PASTE_DEBUG_KEY), relative),
                    "Debug-only string 'debug.paste.' outside an #if DEBUG branch",
                )

    def test_in_any_app_folder_and_the_extension_fails(self) -> None:
        for relative in ("ShowMyCopy/New/Thing.swift", "ShowMyCopyControl/Control.swift"):
            with self.subTest(relative):
                self.assertFailsWith(self.errors_for('let name = "%s"\n' % DEBUG_MARKER, relative), relative)
                os.remove(os.path.join(self.fixture.root, relative))

    def test_unbalanced_conditions_fail(self) -> None:
        self.assertFailsWith(self.errors_for('#endif\nlet name = "%s"\n' % DEBUG_MARKER), "#endif without #if")

    def test_in_a_comment_or_in_tests_passes(self) -> None:
        self.assertEqual(self.errors_for("// %s\nlet a = 1\n" % DEBUG_MARKER), [])
        self.assertEqual(self.errors_for('let name = "%s"\n' % DEBUG_MARKER, "ShowMyCopyTests/App/T.swift"), [])


class SettingsPaneTests(CheckerTestCase):
    """The one file that may open something: fixed System Settings addresses, and nothing else."""

    PANE = check_security.SETTINGS_PANE_FILE
    CURRENT = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    LEGACY = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    NOT_SETTINGS = "opens an address that does not start with x-apple.systempreferences:"
    NOT_LITERAL = "opens a URL that is not a literal"
    ONLY_WORKSPACE = "NSWorkspace may be used here only as"
    GOOD = textwrap.dedent(
        """\
        import AppKit

        /// Opens Privacy & Security → Accessibility with NSWorkspace, never a URL(string: "https://x") or .open(x).
        @MainActor
        final class SystemSettingsPane: AccessibilitySettingsOpening {
            func openAccessibilityList() {
                let opened: Bool
                if #available(macOS 26, *) {
                    opened = Self.showCurrentPane() || Self.showLegacyPane()
                } else {
                    opened = Self.showLegacyPane() || Self.showCurrentPane()
                }
                if !opened {
                    AppLogger.app.error("System Settings could not be opened")
                }
            }

            /* Both addresses are literals. */
            private static func showCurrentPane() -> Bool {
                URL(string: "%s")
                    .map { NSWorkspace.shared.open($0) } ?? false
            }

            private static func showLegacyPane() -> Bool {
                URL(
                    string: "%s"
                ).map {
                    NSWorkspace.shared.open($0)
                } ?? false
            }
        }
        // Not code: URL(string: "https://x").map { NSWorkspace.shared.open($0) }
        """
    ) % (CURRENT, LEGACY)

    def write(self, content: str, relative: str = PANE) -> None:
        self.fixture.write(relative, content)

    def changed(self, old: str, new: str) -> str:
        self.assertEqual(self.GOOD.count(old), 1, old)
        return self.GOOD.replace(old, new)

    def test_allowed_file_passes(self) -> None:
        self.write(self.GOOD)
        self.assertEqual(self.fixture.errors(), [])

    def test_same_code_in_another_file_fails(self) -> None:
        for relative in (
            "ShowMyCopy/Settings/OtherPane.swift",
            "ShowMyCopy/Platform/Settings/SystemSettingsPane.swift",
            "Other/ShowMyCopy/Settings/SystemSettingsPane.swift",
            "ShowMyCopy/Settings/SystemSettingsPane.swift.swift",
        ):
            with self.subTest(relative):
                path = self.fixture.write(relative, self.GOOD)
                self.assertFailsWith(self.fixture.errors(), relative + ":21: NSWorkspace beyond its read-only members")
                os.remove(path)

    def test_http_url_fails(self) -> None:
        for address in ("https://example.com/collect", "file:///etc/passwd", "X-APPLE.SYSTEMPREFERENCES:x",
                        " x-apple.systempreferences:x", "x-apple.systempreferences"):
            with self.subTest(address):
                self.write(self.changed(self.CURRENT, address))
                self.assertFailsWith(self.fixture.errors(), self.PANE + ":20: " + self.NOT_SETTINGS)

    def test_interpolated_or_built_url_fails(self) -> None:
        for address in (
            '"%s&q=\\(text)"' % self.CURRENT,
            '"%s" + text' % self.CURRENT,
            '"\\(base)"',
            '"%s\\u{3F}x"' % self.CURRENT,
        ):
            with self.subTest(address):
                self.write(self.changed('"%s"' % self.CURRENT, address))
                self.assertFailsWith(self.fixture.errors(), self.PANE + ":20: " + self.NOT_LITERAL)

    def test_url_from_a_variable_fails(self) -> None:
        cases = {
            "variable": ('URL(string: "%s")' % self.CURRENT, "URL(string: address)", ":20: " + self.NOT_LITERAL),
            "constant": ('URL(string: "%s")' % self.CURRENT, "URL(string: Self.address)", ":20: " + self.NOT_LITERAL),
            "made another way": (
                'URL(string: "%s")' % self.CURRENT, "URL(fileURLWithPath: path) as URL?", ":20: " + self.NOT_LITERAL
            ),
            "changed afterwards": (
                'URL(string: "%s")\n' % self.CURRENT,
                'URL(string: "%s")?\n            .appendingPathComponent(text)\n' % self.CURRENT,
                ":20: " + self.NOT_LITERAL,
            ),
            "bound name": (
                'URL(string: "%s")\n            .map { NSWorkspace.shared.open($0) } ?? false' % self.CURRENT,
                'guard let url = URL(string: "%s") else { return false }\n'
                "        return NSWorkspace.shared.open(url)" % self.CURRENT,
                ":21: " + self.ONLY_WORKSPACE,
            ),
            "other value": (
                "NSWorkspace.shared.open($0) } ?? false", "NSWorkspace.shared.open(userURL) } ?? false",
                ":21: " + self.ONLY_WORKSPACE,
            ),
            "raw string": ('"%s"' % self.CURRENT, '#"%s"#' % self.CURRENT, ": cannot check"),
        }
        for name, (old, new, fragment) in cases.items():
            with self.subTest(name):
                self.write(self.changed(old, new))
                self.assertFailsWith(self.fixture.errors(), self.PANE + fragment)

    def test_other_hand_off_api_fails(self) -> None:
        before = "let opened: Bool"
        cases = {
            "openURL": (
                "final class SystemSettingsPane: AccessibilitySettingsOpening {\n",
                "final class SystemSettingsPane: AccessibilitySettingsOpening {\n"
                "    @Environment(\\.openURL) private var openURL\n",
                ":6: external hand-off API",
            ),
            "other NSWorkspace call": (
                "if !opened {", 'if !NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") {',
                ":13: " + self.ONLY_WORKSPACE,
            ),
            "NSWorkspace kept aside": (
                before, "let workspace = NSWorkspace.shared\n        " + before, ":7: " + self.ONLY_WORKSPACE
            ),
            "open with options": (
                "NSWorkspace.shared.open($0) } ?? false",
                "NSWorkspace.shared.open([$0], withApplicationAt: app, configuration: c) } ?? false",
                ":21: " + self.ONLY_WORKSPACE,
            ),
            "other object": (
                before, "_ = SharedFiles.current.openFile(path)\n        " + before,
                ":7: opens something other than a fixed System Settings address",
            ),
            "Launch Services": (before, "LSOpenCFURLRef(address, nil)\n        " + before, ":7: Launch Services"),
            "clipboard": (
                before, "let text = NSPasteboard.general.string(forType: .string)\n        " + before,
                ":7: clipboard data",
            ),
        }
        for name, (old, new, fragment) in cases.items():
            with self.subTest(name):
                self.write(self.changed(old, new))
                self.assertFailsWith(self.fixture.errors(), self.PANE + fragment)

    def test_parameters_fail(self) -> None:
        for old, new in (
            ("func openAccessibilityList() {", "func openAccessibilityList(_ address: String) {"),
            ("private static func showCurrentPane() -> Bool {", "private static func showCurrentPane(\n"
             "        text: String\n    ) -> Bool {"),
            ("let opened: Bool", "init(text: String) {}\n        let opened: Bool"),
        ):
            with self.subTest(new):
                self.write(self.changed(old, new))
                self.assertFailsWith(self.fixture.errors(), "takes parameters")

    def test_unreadable_code_fails(self) -> None:
        for old, new in (("/* Both addresses are literals. */", "/* not closed"),
                         ('error("System Settings could not be opened")', 'error("not closed)')):
            with self.subTest(new):
                self.write(self.changed(old, new))
                self.assertFailsWith(self.fixture.errors(), self.PANE + ": cannot check")


class RealRepositoryTests(unittest.TestCase):
    def test_debug_only_strings_are_in_the_app(self) -> None:
        # Keeps DEBUG_ONLY_STRINGS in step with the code: a renamed string would no longer be looked for.
        self.assertEqual(set(check_security.DEBUG_ONLY_STRINGS), set(DEBUG_ONLY_STRING_FILES))
        for marker, relative in DEBUG_ONLY_STRING_FILES.items():
            with self.subTest(marker):
                with open(os.path.join(REPO, relative), encoding="utf-8") as handle:
                    self.assertIn('"%s' % marker, handle.read())

    def test_configured_files_exist(self) -> None:
        # A moved or renamed file would leave its check pointing at nothing: the pane's stricter check and the
        # app's entitlements would no longer be looked at where the code now is.
        for relative in (check_security.SETTINGS_PANE_FILE, check_security.APP_ENTITLEMENTS_FILE):
            with self.subTest(relative):
                self.assertTrue(os.path.isfile(os.path.join(REPO, relative)), relative)

    def test_swiftlint_excludes_exactly_the_settings_pane(self) -> None:
        # The SwiftLint mirror of SETTINGS_PANE_FILE (no_external_handoff `excluded`) names the same file and no
        # other, so a move cannot leave the early warning off for some other file or on for the pane.
        with open(os.path.join(REPO, ".swiftlint.yml"), encoding="utf-8") as handle:
            config = handle.read()
        rule = config[config.index("\n  no_external_handoff:\n"):]
        found = re.search(r"^    excluded: '([^']*)'$", rule, re.M)
        self.assertIsNotNone(found, "no_external_handoff has no excluded path")
        assert found is not None
        excluded = re.compile(found.group(1))
        matching = []
        for folder, _, names in os.walk(REPO):
            for name in names:
                relative = os.path.relpath(os.path.join(folder, name), REPO).replace(os.sep, "/")
                if name.endswith(".swift") and excluded.search(relative):
                    matching.append(relative)
        self.assertEqual(matching, [check_security.SETTINGS_PANE_FILE])

    def test_real_repository_passes(self) -> None:
        # Exactly what `make lint` runs, including the xcodebuild cross-check when Xcode is present.
        result = subprocess.run(
            ["bash", os.path.join(SCRIPTS, "check_security.sh")], capture_output=True, text=True, timeout=1800
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("security checks passed", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
