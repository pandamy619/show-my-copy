#!/usr/bin/env python3
"""Security checks for Show My Copy.

    scripts/check_security.py            project settings, entitlements files and sources
    scripts/check_security.py path/App   also everything that was actually signed into a built app

Runs with the python3 that ships with the Xcode command line tools (3.9), so no newer syntax.
Every check fails closed: anything the checker cannot read or does not understand is an error.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
from typing import Dict, List, Optional, Tuple

PROJECT = "ShowMyCopy.xcodeproj"

# --------------------------------------------------------------------------------------------
# Allowlists. This is the ONE place to extend what the app may do. Adding an entry here is a
# security decision: explain it in the PR and in SECURITY.md.
# --------------------------------------------------------------------------------------------

# Every entitlement a signed app, extension, XPC service or entitlements file may carry, with
# the exact value it must have. Anything else is an error. To allow e.g. user-selected read-only
# files, add: "com.apple.security.files.user-selected.read-only": True
ENTITLEMENT_ALLOWLIST: Dict[str, object] = {
    "com.apple.security.app-sandbox": True,
}

# Build settings that grant file or resource access (ENABLE_*_ACCESS*, ENABLE_USER_SELECTED_FILES)
# and the value they may have. Empty: the app needs no such access.
# Example: {"ENABLE_USER_SELECTED_FILES": "readonly"}
ACCESS_SETTING_ALLOWLIST: Dict[str, str] = {}

# --------------------------------------------------------------------------------------------

SANDBOX_KEY = "com.apple.security.app-sandbox"
TEST_PRODUCT_TYPES = {
    "com.apple.product-type.bundle.unit-test",
    "com.apple.product-type.bundle.ui-testing",
}
# Code that is loaded into a sandboxed process and inherits its sandbox; it is not sandboxed itself.
LIBRARY_PRODUCT_TYPES = {
    "com.apple.product-type.framework",
    "com.apple.product-type.framework.static",
    "com.apple.product-type.library.static",
    "com.apple.product-type.library.dynamic",
}
APPLICATION_PRODUCT_TYPE = "com.apple.product-type.application"
# Configurations in which Xcode itself may resolve ENABLE_HARDENED_RUNTIME to NO even though the
# project file sets YES. Observed with Xcode 26: `xcodebuild -showBuildSettings` for Debug reports
# "ENABLE_DEBUG_DYLIB" : "YES" and "ENABLE_HARDENED_RUNTIME" : "NO" (debug builds load a debug
# dylib for previews and debugging). These are local development builds; the shipped Release app
# is still checked for the hardened runtime flag in its code signature by `make security`.
# Only the xcodebuild cross-check uses this; the project file must still say YES everywhere.
XCODE_DEBUG_CONFIGURATIONS = {"Debug"}
DISABLED_VALUES = {"", "NO", "none", "None"}
ACCESS_SETTING = re.compile(r"^ENABLE_[A-Z0-9_]*ACCESS[A-Z0-9_]*$|^ENABLE_USER_SELECTED_FILES$")

# Source scan. Boundaries are spelled out instead of \b so the meaning is the same everywhere.
_B = r"(?<![A-Za-z0-9_])"
_E = r"(?![A-Za-z0-9_])"
SOURCE_PATTERNS: List[Tuple[str, str]] = [
    # Network access.
    (_B + r"(URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|NWPathMonitor|NWBrowser"
     r"|CFSocket|CFStream|WKWebView|SFSafariViewController|getaddrinfo)" + _E, "network API"),
    (_B + r"import\s+(Network|WebKit|SafariServices|CFNetwork)" + _E, "network module import"),
    # Handing data to another process, app or the system (which may send it anywhere).
    (r"NSWorkspace\s*\.\s*shared\s*\.\s*open", "NSWorkspace.shared.open"),
    (_B + r"(openApplication|openURL|NSSharingService\w*|ShareLink|NSXPCConnection|CSSearchableIndex"
     r"|NSUserActivity)" + _E, "external hand-off API"),
    (_B + r"Link\s*\(", "SwiftUI Link"),
    (_B + r"(Process\s*\(|Process\s*\.\s*run|NSTask|NSAppleScript|posix_spawn|system\s*\()", "process execution"),
    # Loading from a URL (may be remote): Data(contentsOf:), String(contentsOf:), contentsOf: URL(...).
    (r"(?<![A-Za-z0-9_.])[A-Z][A-Za-z0-9_]*\s*\(\s*contentsOf\s*:", "initializer reading contentsOf: a URL"),
    (r"\.init\s*\(\s*contentsOf\s*:|contentsOf\s*:\s*URL" + _E, "reading contentsOf: a URL"),
]
SKIP_DIRS = {".git", "build", ".build", "DerivedData"}


# ------------------------------------------------------------------ entitlements


def check_entitlements(ents: object, where: str, require_sandbox: bool) -> List[str]:
    """Compare an entitlement dictionary against the exact allowlist."""
    if not isinstance(ents, dict):
        return ["%s: entitlements are not a dictionary" % where]
    errors = []
    for key in sorted(ents):
        value = ents[key]
        if key not in ENTITLEMENT_ALLOWLIST:
            errors.append("%s: entitlement %s is not allowed" % (where, key))
        elif not _same_value(value, ENTITLEMENT_ALLOWLIST[key]):
            errors.append("%s: entitlement %s must be %r, found %r" % (where, key, ENTITLEMENT_ALLOWLIST[key], value))
    if require_sandbox and ents.get(SANDBOX_KEY) is not True:
        errors.append("%s: %s must be boolean true" % (where, SANDBOX_KEY))
    return errors


def _same_value(actual: object, expected: object) -> bool:
    # bool is a subclass of int in Python: 1 must not count as true.
    return type(actual) is type(expected) and actual == expected


def check_entitlements_file(path: str, where: str) -> List[str]:
    try:
        with open(path, "rb") as handle:
            ents = plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        return ["%s: cannot read entitlements file %s (%s)" % (where, path, error)]
    return check_entitlements(ents, where, require_sandbox=False)


# ------------------------------------------------------------------ project.pbxproj


class PbxprojError(Exception):
    pass


_TOKEN = re.compile(
    r'\s+|/\*.*?\*/|//[^\n]*|"((?:[^"\\]|\\.)*)"|([{}();,=])|([^\s{}();,="]+)', re.S
)


def parse_pbxproj(text: str) -> dict:
    """Parse the old-style (OpenStep) property list that Xcode uses for project.pbxproj."""
    tokens = []
    pos = 0
    while pos < len(text):
        match = _TOKEN.match(text, pos)
        if match is None:
            raise PbxprojError("unexpected character at offset %d" % pos)
        pos = match.end()
        if match.group(1) is not None:
            tokens.append(("str", _unescape(match.group(1))))
        elif match.group(2) is not None:
            tokens.append(("sym", match.group(2)))
        elif match.group(3) is not None:
            tokens.append(("str", match.group(3)))
    value, index = _parse_value(tokens, 0)
    if index != len(tokens):
        raise PbxprojError("trailing tokens")
    if not isinstance(value, dict):
        raise PbxprojError("top level is not a dictionary")
    return value


def _unescape(raw: str) -> str:
    return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), raw)


def _parse_value(tokens: list, index: int):
    if index >= len(tokens):
        raise PbxprojError("unexpected end of file")
    kind, value = tokens[index]
    if kind == "str":
        return value, index + 1
    if value == "{":
        result = {}
        index += 1
        while True:
            if index >= len(tokens):
                raise PbxprojError("unterminated dictionary")
            if tokens[index] == ("sym", "}"):
                return result, index + 1
            key, index = _parse_value(tokens, index)
            if not isinstance(key, str) or tokens[index:index + 1] != [("sym", "=")]:
                raise PbxprojError("bad dictionary entry near %r" % (key,))
            item, index = _parse_value(tokens, index + 1)
            if tokens[index:index + 1] != [("sym", ";")]:
                raise PbxprojError("missing ';' after %r" % (key,))
            if key in result:
                # A duplicate key could hide a setting from one reader but not the other.
                raise PbxprojError("duplicate key %r" % (key,))
            result[key] = item
            index += 1
    if value == "(":
        result_list = []
        index += 1
        while True:
            if index >= len(tokens):
                raise PbxprojError("unterminated list")
            if tokens[index] == ("sym", ")"):
                return result_list, index + 1
            item, index = _parse_value(tokens, index)
            result_list.append(item)
            if tokens[index:index + 1] == [("sym", ",")]:
                index += 1
            elif tokens[index:index + 1] != [("sym", ")")]:
                raise PbxprojError("missing ',' in list")
    raise PbxprojError("unexpected %r" % (value,))


def _object(objects: dict, ref: object, isa: Optional[str], what: str) -> dict:
    obj = objects.get(ref) if isinstance(ref, str) else None
    if not isinstance(obj, dict) or (isa is not None and obj.get("isa") != isa):
        raise PbxprojError("%s %r is missing or not a %s" % (what, ref, isa))
    return obj


def _configurations(objects: dict, list_ref: object, what: str) -> Dict[str, dict]:
    config_list = _object(objects, list_ref, "XCConfigurationList", what + " configuration list")
    result = {}
    for ref in config_list.get("buildConfigurations", []):
        config = _object(objects, ref, "XCBuildConfiguration", what + " configuration")
        name = config.get("name")
        settings = config.get("buildSettings", {})
        if not isinstance(name, str) or not isinstance(settings, dict):
            raise PbxprojError("%s configuration %r is malformed" % (what, ref))
        if "baseConfigurationReference" in config:
            # Settings in an .xcconfig file are invisible here; fail closed rather than miss them.
            raise PbxprojError(
                "%s configuration %s uses an .xcconfig file, which this checker does not read" % (what, name)
            )
        result[name] = settings
    if not result:
        raise PbxprojError("%s has no build configurations" % what)
    return result


def _flatten(value: object) -> str:
    if isinstance(value, list):
        return " ".join(_flatten(item) for item in value)
    return value if isinstance(value, str) else repr(value)


def project_targets(root: str) -> Tuple[List[Tuple[str, str, Dict[str, Dict[str, str]]]], dict]:
    """Return [(target name, product type, {configuration: merged settings})] and all objects."""
    path = os.path.join(root, PROJECT, "project.pbxproj")
    with open(path, encoding="utf-8") as handle:
        data = parse_pbxproj(handle.read())
    objects = data.get("objects")
    if not isinstance(objects, dict):
        raise PbxprojError("no objects")
    project = _object(objects, data.get("rootObject"), "PBXProject", "root object")
    project_configs = _configurations(objects, project.get("buildConfigurationList"), "project")
    targets = []
    for ref in project.get("targets", []):
        target = _object(objects, ref, None, "target")
        name = target.get("name", ref)
        product_type = target.get("productType", "")
        configs = _configurations(objects, target.get("buildConfigurationList"), "target %s" % name)
        merged = {}
        for config_name, settings in configs.items():
            # Target settings override project settings of the same configuration.
            combined = dict(project_configs.get(config_name, {}))
            combined.update(settings)
            merged[config_name] = {key: _flatten(value) for key, value in combined.items()}
        targets.append((name, product_type, merged))
    # Targets that are not listed in the project are still built by nothing, but flag them anyway.
    listed = set(project.get("targets", []))
    for ref, obj in objects.items():
        if isinstance(obj, dict) and obj.get("isa", "").endswith("Target") and ref not in listed:
            raise PbxprojError("target %r is not listed in the project" % (obj.get("name", ref),))
    return targets, objects


def check_target_settings(
    root: str,
    target: str,
    product_type: str,
    config: str,
    settings: Dict[str, str],
    require_hardened_runtime: bool = True,
) -> List[str]:
    """Apply the per-target rules to one configuration's settings.

    Conditional variants (KEY[sdk=...]) are checked like the plain key, so they cannot override it.
    require_hardened_runtime is False only for Xcode-resolved settings of XCODE_DEBUG_CONFIGURATIONS.
    """
    where = "target %s (%s)" % (target, config)
    if product_type in TEST_PRODUCT_TYPES:
        return []  # Test bundles are never shipped; they run inside the test host.
    by_key: Dict[str, List[str]] = {}
    for key, value in settings.items():
        by_key.setdefault(key.split("[", 1)[0], []).append(value)

    def values(key: str) -> List[str]:
        return by_key.get(key, [])

    errors = []
    sandboxed = product_type not in LIBRARY_PRODUCT_TYPES
    if sandboxed:
        required = ["ENABLE_APP_SANDBOX"]
        if require_hardened_runtime:
            required.append("ENABLE_HARDENED_RUNTIME")
        for key in required:
            if not values(key) or any(value != "YES" for value in values(key)):
                errors.append("%s: %s must be YES" % (where, key))
    for key in ("ENABLE_INCOMING_NETWORK_CONNECTIONS", "ENABLE_OUTGOING_NETWORK_CONNECTIONS"):
        if any(value == "YES" for value in values(key)):
            errors.append("%s: %s must not be YES" % (where, key))
        if product_type == APPLICATION_PRODUCT_TYPE and (
            not values(key) or any(value != "NO" for value in values(key))
        ):
            errors.append("%s: %s must be explicitly NO" % (where, key))
    for key, found in sorted(by_key.items()):
        if key.startswith("RUNTIME_EXCEPTION_") and any(value != "NO" and value != "" for value in found):
            errors.append("%s: %s weakens the hardened runtime" % (where, key))
        if ACCESS_SETTING.match(key):
            for value in found:
                if value not in DISABLED_VALUES and ACCESS_SETTING_ALLOWLIST.get(key) != value:
                    errors.append("%s: %s = %s grants access that is not allowlisted" % (where, key, value))
    for value in values("OTHER_CODE_SIGN_FLAGS"):
        if "--entitlements" in value:
            errors.append("%s: OTHER_CODE_SIGN_FLAGS must not pass --entitlements" % where)
    for value in values("CODE_SIGN_ENTITLEMENTS"):
        if value:
            errors.extend(_check_entitlements_setting(root, where, value))
    return errors


def _check_entitlements_setting(root: str, where: str, value: str) -> List[str]:
    path = re.sub(r"^\$[({](SRCROOT|PROJECT_DIR|SOURCE_ROOT)[)}]/?", "", value)
    if "$" in path:
        return ["%s: CODE_SIGN_ENTITLEMENTS = %s cannot be resolved" % (where, value)]
    if not os.path.isabs(path):
        path = os.path.join(root, path)
    return check_entitlements_file(path, "%s CODE_SIGN_ENTITLEMENTS" % where)


def check_packages(objects: dict) -> List[str]:
    errors = []
    for ref, obj in sorted(objects.items()):
        if isinstance(obj, dict) and obj.get("isa") == "XCRemoteSwiftPackageReference":
            requirement = obj.get("requirement")
            kind = requirement.get("kind") if isinstance(requirement, dict) else None
            if kind != "exactVersion":
                errors.append(
                    "package %s must use an exact version, found %s" % (obj.get("repositoryURL", ref), kind)
                )
    return errors


def check_project(root: str, use_xcodebuild: bool) -> List[str]:
    try:
        targets, objects = project_targets(root)
    except (OSError, UnicodeDecodeError, PbxprojError) as error:
        return ["cannot check %s/project.pbxproj: %s" % (PROJECT, error)]
    if not targets:
        return ["%s has no targets" % PROJECT]
    errors = []
    for name, product_type, configs in targets:
        for config, settings in sorted(configs.items()):
            errors.extend(check_target_settings(root, name, product_type, config, settings))
    errors.extend(check_packages(objects))
    if use_xcodebuild:
        # Second opinion from Xcode itself: resolved settings, including defaults and .xcconfig files.
        config_names = sorted({config for _, _, configs in targets for config in configs})
        for name, _, _ in targets:
            for config in config_names:
                errors.extend(_check_with_xcodebuild(root, name, config))
    return errors


def _check_with_xcodebuild(root: str, target: str, config: str) -> List[str]:
    command = [
        "xcodebuild", "-showBuildSettings", "-json", "-project", PROJECT, "-target", target,
        "-configuration", config,
    ]
    try:
        result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=600)
        entries = json.loads(result.stdout) if result.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        return ["xcodebuild -showBuildSettings failed for %s (%s): %s" % (target, config, error)]
    if not isinstance(entries, list) or not entries:
        return ["xcodebuild -showBuildSettings failed for %s (%s): %s" % (target, config, result.stderr.strip())]
    # Xcode may turn the hardened runtime off for debug builds; see XCODE_DEBUG_CONFIGURATIONS.
    require_hardened_runtime = config not in XCODE_DEBUG_CONFIGURATIONS
    errors = []
    for entry in entries:
        settings = entry.get("buildSettings", {}) if isinstance(entry, dict) else {}
        product_type = settings.get("PRODUCT_TYPE", "")
        if not product_type:
            errors.append("xcodebuild reported no PRODUCT_TYPE for %s (%s)" % (target, config))
        settings = {key: _flatten(value) for key, value in settings.items()}
        for error in check_target_settings(
            root, target, product_type, config, settings, require_hardened_runtime=require_hardened_runtime
        ):
            errors.append("xcodebuild: " + error)
    return errors


# ------------------------------------------------------------------ files in the repository


def _walk(root: str):
    for directory, subdirs, files in os.walk(root):
        subdirs[:] = sorted(d for d in subdirs if d not in SKIP_DIRS)
        for name in sorted(files):
            yield os.path.join(directory, name)


def check_entitlement_files(root: str) -> List[str]:
    errors = []
    for path in _walk(root):
        if path.endswith(".entitlements"):
            errors.extend(check_entitlements_file(path, os.path.relpath(path, root)))
    return errors


def check_sources(root: str) -> List[str]:
    errors = []
    compiled = [(re.compile(pattern), label) for pattern, label in SOURCE_PATTERNS]
    for path in _walk(root):
        if not path.endswith(".swift"):
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        except (OSError, UnicodeDecodeError) as error:
            errors.append("cannot read %s: %s" % (path, error))
            continue
        for number, line in enumerate(lines, 1):
            for regex, label in compiled:
                if regex.search(line):
                    errors.append("%s:%d: %s: %s" % (os.path.relpath(path, root), number, label, line.strip()))
    return errors


# ------------------------------------------------------------------ signed app


def _codesign(args: List[str]) -> subprocess.CompletedProcess:
    return subprocess.run(["codesign"] + args, capture_output=True, timeout=300)


def _signed_entitlements(path: str) -> Tuple[Optional[dict], Optional[str]]:
    result = _codesign(["-d", "--entitlements", "-", "--xml", path])
    if result.returncode != 0:
        return None, result.stderr.decode(errors="replace").strip()
    if not result.stdout.strip():
        return {}, None
    try:
        ents = plistlib.loads(result.stdout)
    except Exception as error:  # plistlib raises several unrelated types on garbage input
        return None, "unreadable entitlements (%s)" % error
    if not isinstance(ents, dict):
        return None, "entitlements are not a dictionary"
    return ents, None


def _has_hardened_runtime(path: str) -> bool:
    result = _codesign(["-d", "--verbose=2", path])
    output = (result.stdout + result.stderr).decode(errors="replace")
    flags = re.search(r"^CodeDirectory .*flags=0x[0-9a-f]+\(([^)]*)\)", output, re.M)
    return result.returncode == 0 and flags is not None and "runtime" in flags.group(1).split(",")


def nested_code(app: str) -> List[Tuple[str, str]]:
    """Every nested piece of code to check: (path, kind) with kind 'sandboxed' or 'library'."""
    found = []
    for directory, subdirs, files in os.walk(app):
        for name in sorted(subdirs):
            if name.endswith((".appex", ".xpc", ".app")):
                found.append((os.path.join(directory, name), "sandboxed"))
            elif name.endswith(".framework"):
                found.append((os.path.join(directory, name), "library"))
        for name in sorted(files):
            if name.endswith(".dylib"):
                found.append((os.path.join(directory, name), "library"))
        subdirs.sort()
    return found


def check_signed_app(app: str) -> List[str]:
    if shutil.which("codesign") is None:
        return ["codesign not found; the signed app can only be checked on macOS"]
    if not os.path.isdir(app):
        return ["%s is not an app bundle" % app]
    errors = []
    verify = _codesign(["--verify", "--strict", "--deep", "--verbose=2", app])
    if verify.returncode != 0:
        details = verify.stderr.decode(errors="replace").strip()
        errors.append("%s fails codesign --verify --strict --deep: %s" % (app, details))
    for path, kind in [(app, "sandboxed")] + nested_code(app):
        where = os.path.relpath(path, os.path.dirname(os.path.abspath(app)))
        ents, problem = _signed_entitlements(path)
        if ents is None:
            errors.append("%s: cannot read signed entitlements: %s" % (where, problem))
            continue
        if kind == "library":
            if ents:
                errors.append(
                    "%s: libraries and frameworks must not carry entitlements, found %s" % (where, sorted(ents))
                )
            continue
        errors.extend(check_entitlements(ents, where, require_sandbox=True))
        if not _has_hardened_runtime(path):
            errors.append("%s: hardened runtime flag is not set" % where)
    return errors


# ------------------------------------------------------------------ entry point


def run_checks(root: str, app: Optional[str] = None, use_xcodebuild: Optional[bool] = None) -> List[str]:
    if use_xcodebuild is None:
        use_xcodebuild = shutil.which("xcodebuild") is not None
    errors = check_project(root, use_xcodebuild)
    errors += check_entitlement_files(root)
    errors += check_sources(root)
    if app is not None:
        errors += check_signed_app(app)
    return errors


def main(argv: List[str]) -> int:
    if len(argv) > 1 or (argv and argv[0].startswith("-")):
        print("usage: check_security.py [path/to/App.app]", file=sys.stderr)
        return 2
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    app = os.path.abspath(argv[0]) if argv else None
    errors = run_checks(root, app)
    for error in errors:
        print("error: " + error, file=sys.stderr)
    if errors:
        return 1
    print("security checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
