#!/usr/bin/env python3
"""Canary tests for scripts/check_security.py: prove that each check can actually fail.

Run with `make security-selftest`. Works on Linux and macOS. Fixture projects are built in a
temporary directory from the real project file; the signed-app checks use a fake `codesign`
put first on PATH for the duration of one test, so check_security.py itself has no test hook.
"""

from __future__ import annotations

import os
import plistlib
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
CONFIG = "\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n"
APP_DEBUG = "AA0000000000000000000016 /* Debug */ = {" + CONFIG
APP_RELEASE = "AA0000000000000000000017 /* Release */ = {" + CONFIG
TESTS_DEBUG = "AA0000000000000000000019 /* Debug */ = {" + CONFIG
TESTS_RELEASE = "AA000000000000000000001A /* Release */ = {" + CONFIG

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


def plist(ents: dict) -> bytes:
    return plistlib.dumps(ents)


SANDBOX_ONLY = {"com.apple.security.app-sandbox": True}


class Fixture:
    """A throwaway copy of the parts of the repo the checker reads."""

    def __init__(self, base: str) -> None:
        self.root = os.path.join(base, "repo")
        os.makedirs(os.path.join(self.root, check_security.PROJECT))
        os.makedirs(os.path.join(self.root, "ShowMyCopy"))
        with open(PBXPROJ, encoding="utf-8") as handle:
            self.pbxproj = handle.read()
        self.save()

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
        self.fixture.replace("ENABLE_APP_SANDBOX = YES;", "ENABLE_APP_SANDBOX = NO;", count=2)
        for anchor in (TESTS_DEBUG, TESTS_RELEASE):
            self.fixture.replace(anchor, anchor + "\t\t\t\tENABLE_APP_SANDBOX = YES;\n")
        self.assertEqual(self.fixture.pbxproj.count("ENABLE_APP_SANDBOX = YES;"), 2)
        self.assertFailsWith(self.fixture.errors(), "target ShowMyCopy (Release): ENABLE_APP_SANDBOX must be YES")

    def test_sandbox_only_in_one_configuration(self) -> None:
        # The first occurrence is the app's Debug configuration; Release stays YES.
        self.fixture.pbxproj = self.fixture.pbxproj.replace(
            "ENABLE_APP_SANDBOX = YES;", "ENABLE_APP_SANDBOX = NO;", 1
        )
        self.fixture.save()
        self.assertFailsWith(self.fixture.errors(), "target ShowMyCopy (Debug): ENABLE_APP_SANDBOX must be YES")

    def test_conditional_setting_cannot_override_sandbox(self) -> None:
        self.fixture.add_app_setting('"ENABLE_APP_SANDBOX[sdk=macosx*]" = NO;')
        self.assertFailsWith(self.fixture.errors(), "ENABLE_APP_SANDBOX must be YES")

    def test_missing_hardened_runtime(self) -> None:
        self.fixture.replace("ENABLE_HARDENED_RUNTIME = YES;", "ENABLE_HARDENED_RUNTIME = NO;", count=2)
        self.assertFailsWith(self.fixture.errors(), "ENABLE_HARDENED_RUNTIME must be YES")

    def test_outgoing_network(self) -> None:
        self.fixture.replace(
            "ENABLE_OUTGOING_NETWORK_CONNECTIONS = NO;", "ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES;", count=2
        )
        self.assertFailsWith(self.fixture.errors(), "ENABLE_OUTGOING_NETWORK_CONNECTIONS must not be YES")

    def test_network_setting_must_be_explicit_for_app(self) -> None:
        self.fixture.replace("\t\t\t\tENABLE_INCOMING_NETWORK_CONNECTIONS = NO;\n", "", count=2)
        self.assertFailsWith(self.fixture.errors(), "ENABLE_INCOMING_NETWORK_CONNECTIONS must be explicitly NO")

    def test_runtime_exception(self) -> None:
        self.fixture.add_app_setting("RUNTIME_EXCEPTION_ALLOW_JIT = YES;")
        self.assertFailsWith(self.fixture.errors(), "RUNTIME_EXCEPTION_ALLOW_JIT weakens the hardened runtime")

    def test_resource_access(self) -> None:
        self.fixture.add_app_setting("ENABLE_RESOURCE_ACCESS_CAMERA = YES;")
        self.assertFailsWith(self.fixture.errors(), "ENABLE_RESOURCE_ACCESS_CAMERA = YES grants access")

    def test_file_access(self) -> None:
        self.fixture.add_app_setting("ENABLE_USER_SELECTED_FILES = readwrite;")
        self.assertFailsWith(self.fixture.errors(), "ENABLE_USER_SELECTED_FILES = readwrite grants access")

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
        self.fixture.write("ShowMyCopy/App.entitlements", plist(SANDBOX_ONLY))
        self.fixture.add_app_setting("CODE_SIGN_ENTITLEMENTS = ShowMyCopy/App.entitlements;")
        self.assertEqual(self.fixture.errors(), [])

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

    def test_xcconfig_is_rejected(self) -> None:
        self.fixture.replace(APP_RELEASE, APP_RELEASE.replace(
            "isa = XCBuildConfiguration;", "isa = XCBuildConfiguration;\n\t\t\tbaseConfigurationReference = CC01;"
        ))
        self.assertFailsWith(self.fixture.errors(), "uses an .xcconfig file")

    def test_unparseable_project(self) -> None:
        self.fixture.pbxproj = self.fixture.pbxproj.replace("ENABLE_APP_SANDBOX = YES;", "ENABLE_APP_SANDBOX = YES", 1)
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

    def test_without_codesign(self) -> None:
        old = os.environ.get("PATH", "")
        os.environ["PATH"] = os.path.join(self.tmp, "empty")
        try:
            errors = check_security.check_signed_app(self.app)
        finally:
            os.environ["PATH"] = old
        self.assertFailsWith(errors, "codesign not found")


class RealRepositoryTests(unittest.TestCase):
    def test_real_repository_passes(self) -> None:
        # Exactly what `make lint` runs, including the xcodebuild cross-check when Xcode is present.
        result = subprocess.run(
            ["bash", os.path.join(SCRIPTS, "check_security.sh")], capture_output=True, text=True, timeout=1800
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("security checks passed", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
