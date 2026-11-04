#!/usr/bin/env python3
"""Security checks for Show My Copy.

    scripts/check_security.py            project settings (with their .xcconfig files), entitlements files and
                                         sources
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

# The one file that may call NSWorkspace.shared.open (see SECURITY.md): it opens System Settings at Privacy &
# Security -> Accessibility for the paste setting. Keep in sync with `excluded` of no_external_handoff in
# .swiftlint.yml. The file may only open fixed SETTINGS_PANE_SCHEME addresses written as plain string literals, in
# exactly the form `URL(string: "<literal>").map { NSWorkspace.shared.open($0) }`, and takes no parameters
# (check_settings_pane). Every other file still fails on NSWorkspace.shared.open.
SETTINGS_PANE_FILE = "ShowMyCopy/Platform/Settings/SystemSettingsPane.swift"
SETTINGS_PANE_SCHEME = "x-apple.systempreferences:"

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
# The only pattern SETTINGS_PANE_FILE is exempt from; check_settings_pane checks that file instead.
HANDOFF_LABEL = "NSWorkspace.shared.open"
SOURCE_PATTERNS: List[Tuple[str, str]] = [
    # Network access.
    (_B + r"(URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|NWPathMonitor|NWBrowser"
     r"|CFSocket|CFStream|WKWebView|SFSafariViewController|getaddrinfo)" + _E, "network API"),
    (_B + r"import\s+(Network|WebKit|SafariServices|CFNetwork)" + _E, "network module import"),
    # Handing data to another process, app or the system (which may send it anywhere).
    (r"NSWorkspace\s*\.\s*shared\s*\.\s*open", HANDOFF_LABEL),
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


def _configurations(objects: dict, list_ref: object, what: str, root: str) -> Dict[str, Tuple[dict, dict]]:
    """Return {configuration: (settings of its .xcconfig file or {}, settings in the project file)}."""
    config_list = _object(objects, list_ref, "XCConfigurationList", what + " configuration list")
    result = {}
    for ref in config_list.get("buildConfigurations", []):
        config = _object(objects, ref, "XCBuildConfiguration", what + " configuration")
        name = config.get("name")
        settings = config.get("buildSettings", {})
        if not isinstance(name, str) or not isinstance(settings, dict):
            raise PbxprojError("%s configuration %r is malformed" % (what, ref))
        base = {}
        if "baseConfigurationReference" in config:
            where = "%s configuration %s" % (what, name)
            path = _file_reference_path(objects, config["baseConfigurationReference"], root, where)
            base = read_xcconfig(path, root)
        result[name] = (base, settings)
    if not result:
        raise PbxprojError("%s has no build configurations" % what)
    return result


def _file_reference_path(objects: dict, ref: object, root: str, where: str) -> str:
    """The path of a file the project refers to, through the groups that hold it. Fails on anything unusual."""
    _object(objects, ref, "PBXFileReference", where + " base configuration")
    parents = {}
    for key, obj in objects.items():
        if isinstance(obj, dict) and obj.get("isa") == "PBXGroup":
            for child in obj.get("children", []):
                if child in parents:
                    raise PbxprojError("%r is in more than one group" % (child,))
                parents[child] = key
    chain = []
    current = ref
    while True:
        obj = objects.get(current)
        if not isinstance(obj, dict) or current in chain:
            raise PbxprojError("%s: cannot follow the groups of %r" % (where, ref))
        chain.append(current)
        tree = obj.get("sourceTree")
        if tree == "SOURCE_ROOT" or (tree == "<group>" and current not in parents):
            # The main group, or a path from the project folder.
            break
        if tree != "<group>":
            raise PbxprojError("%s: file %r is relative to %r, which this checker does not resolve" % (where, ref, tree))
        current = parents[current]
    parts = [objects[item].get("path", "") for item in reversed(chain)]
    for part in parts:
        if not isinstance(part, str) or "$" in part or os.path.isabs(part):
            raise PbxprojError("%s: cannot resolve the path %r" % (where, part))
    return os.path.join(root, *[part for part in parts if part])


_XCCONFIG_SETTING = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])*)\s*=\s*(.*?)\s*;?$")
_XCCONFIG_INCLUDE = re.compile(r'^#include(\??)\s*"([^"]*)"$')


def read_xcconfig(path: str, root: str, including: Tuple[str, ...] = ()) -> Dict[str, str]:
    """Read the settings of an .xcconfig file and the files it includes, later lines winning, as Xcode does.

    Fails on anything it does not understand: an unreadable file, a line that is not a setting, an include
    that is missing or cycles, and includes outside the repository or through build settings.
    """
    real = os.path.realpath(path)
    shown = os.path.relpath(path, root)
    if real in including:
        raise PbxprojError("%s includes itself" % shown)
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except (OSError, UnicodeDecodeError) as error:
        raise PbxprojError("cannot read %s: %s" % (shown, error))
    settings: Dict[str, str] = {}
    for number, raw in enumerate(lines, 1):
        # Xcode ends every line at //, also inside a value.
        line = raw.split("//", 1)[0].strip()
        if not line:
            continue
        include = _XCCONFIG_INCLUDE.match(line)
        if include:
            target = include.group(2)
            target_path = os.path.normpath(os.path.join(os.path.dirname(path), target))
            if "$" in target or target.startswith("<") or os.path.isabs(target) or not os.path.realpath(
                target_path
            ).startswith(os.path.realpath(root) + os.sep):
                raise PbxprojError("%s:%d: cannot follow the include of %r" % (shown, number, target))
            if include.group(1) and not os.path.exists(target_path):
                continue
            settings.update(read_xcconfig(target_path, root, including + (real,)))
            continue
        setting = _XCCONFIG_SETTING.match(line)
        if setting is None:
            raise PbxprojError("%s:%d: cannot parse %r" % (shown, number, line))
        settings[setting.group(1)] = setting.group(2)
    return settings


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
    project_configs = _configurations(objects, project.get("buildConfigurationList"), "project", root)
    targets = []
    for ref in project.get("targets", []):
        target = _object(objects, ref, None, "target")
        name = target.get("name", ref)
        product_type = target.get("productType", "")
        configs = _configurations(objects, target.get("buildConfigurationList"), "target %s" % name, root)
        merged = {}
        for config_name, (target_base, target_settings) in configs.items():
            # Xcode's order, lowest first: the project's .xcconfig, the project, the target's .xcconfig, the target.
            project_base, project_settings = project_configs.get(config_name, ({}, {}))
            combined: Dict[str, object] = {}
            for layer in (project_base, project_settings, target_base, target_settings):
                combined.update(layer)
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
        if any("$" in value for value in values(key)):
            errors.append("%s: %s uses a build setting variable, which this checker does not resolve" % (where, key))
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
                text = handle.read()
        except (OSError, UnicodeDecodeError) as error:
            errors.append("cannot read %s: %s" % (path, error))
            continue
        where = os.path.relpath(path, root).replace(os.sep, "/")
        is_pane = where == SETTINGS_PANE_FILE
        for number, line in enumerate(text.splitlines(), 1):
            for regex, label in compiled:
                if is_pane and label == HANDOFF_LABEL:
                    continue
                if regex.search(line):
                    errors.append("%s:%d: %s: %s" % (where, number, label, line.strip()))
        if is_pane:
            errors.extend(check_settings_pane(text, where))
    return errors


# The only way SETTINGS_PANE_FILE may open something: a URL made from a plain string literal, opened at once. `$0` is
# the URL just made; it cannot name anything else. Matched in the code without comments.
_PANE_OPEN = re.compile(
    r'URL\s*\(\s*string\s*:\s*"([^"\\\n]*)"\s*\)\s*\.\s*map\s*\{\s*'
    r"NSWorkspace\s*\.\s*shared\s*\.\s*open\s*\(\s*\$0\s*\)\s*\}"
)
# Matched in the code without comments and string literals.
_PANE_PARAMETERS = re.compile(
    _B + r"(func\s+[^\s(<]+\s*(<[^>{]*>)?|init\s*[?!]?)\s*\((?!\s*\))|" + _B + r"subscript" + _E
)
_PANE_FORBIDDEN: List[Tuple[str, str]] = [
    (_B + r"NSWorkspace" + _E, "NSWorkspace may be used here only as URL(string: \"%s...\").map "
     "{ NSWorkspace.shared.open($0) }" % SETTINGS_PANE_SCHEME),
    (_B + r"URL" + _E, "opens a URL that is not a literal: every URL here must be URL(string: \"<literal>\") "
     "opened at once"),
    (r"\.\s*open\w*\s*\(", "opens something other than a fixed System Settings address"),
    (_B + r"LS[A-Z][A-Za-z]*" + _E, "Launch Services call"),
    (_B + r"(NSAppleEventDescriptor|NSAppleEventManager|AESend\w*)" + _E, "Apple event"),
    (_B + r"(NSPasteboard|UIPasteboard|Pasteboard\w*|Clipboard\w*)" + _E, "clipboard data"),
]


def _swift_code(text: str) -> Tuple[str, str]:
    """`text` with comments blanked out, and the same with the contents of string literals blanked out too, so
    positions stay the same. Fails on what it cannot follow: raw and multi-line strings, unclosed strings or
    comments."""
    code, bare = list(text), list(text)

    def blank(chars: list, start: int, end: int) -> None:
        for index in range(start, end):
            if chars[index] != "\n":
                chars[index] = " "

    def line(index: int) -> int:
        return text.count("\n", 0, index) + 1

    interpolations: List[int] = []  # open parentheses inside each \( ... ) the scan is in
    string_start = None
    index = 0
    while index < len(text):
        char = text[index]
        if string_start is not None:
            if text.startswith("\\(", index):
                blank(bare, index, index + 2)
                interpolations.append(0)
                string_start = None
                index += 2
            elif char == "\\":
                blank(bare, index, index + 2)
                index += 2
            elif char == '"':
                string_start = None
                index += 1
            elif char == "\n":
                raise ValueError("line %d: string not closed" % line(string_start))
            else:
                bare[index] = " "
                index += 1
            continue
        if text.startswith("//", index):
            end = text.find("\n", index)
            end = len(text) if end < 0 else end
            blank(code, index, end)
            blank(bare, index, end)
            index = end
        elif text.startswith("/*", index):
            depth, end = 1, index + 2
            while depth and end < len(text):
                if text.startswith("/*", end):
                    depth, end = depth + 1, end + 2
                elif text.startswith("*/", end):
                    depth, end = depth - 1, end + 2
                else:
                    end += 1
            if depth:
                raise ValueError("line %d: comment not closed" % line(index))
            blank(code, index, end)
            blank(bare, index, end)
            index = end
        elif text.startswith('"""', index) or text.startswith('#"', index):
            raise ValueError("line %d: raw and multi-line string literals are not allowed here" % line(index))
        elif char == '"':
            string_start = index
            index += 1
        else:
            if interpolations and char == "(":
                interpolations[-1] += 1
            elif interpolations and char == ")":
                if interpolations[-1] == 0:
                    interpolations.pop()
                    string_start = index  # back in the string the interpolation is part of
                else:
                    interpolations[-1] -= 1
            index += 1
    if string_start is not None or interpolations:
        raise ValueError("string not closed")
    return "".join(code), "".join(bare)


def check_settings_pane(text: str, where: str) -> List[str]:
    """SETTINGS_PANE_FILE may open only fixed System Settings addresses and take nothing from its callers."""
    try:
        code, bare = _swift_code(text)
    except ValueError as error:
        return ["%s: cannot check: %s" % (where, error)]

    def line(index: int) -> int:
        return text.count("\n", 0, index) + 1

    errors = []
    allowed = []
    for match in _PANE_OPEN.finditer(code):
        allowed.append((match.start(), match.end()))
        if not match.group(1).startswith(SETTINGS_PANE_SCHEME):
            errors.append("%s:%d: opens an address that does not start with %s: %s"
                          % (where, line(match.start()), SETTINGS_PANE_SCHEME, match.group(1)))
    for pattern, label in _PANE_FORBIDDEN:
        for match in re.finditer(pattern, bare):
            # Inside an allowed call, only its own `URL` and `NSWorkspace...open(` are fine.
            if any(start <= match.start() < end for start, end in allowed):
                continue
            errors.append("%s:%d: %s" % (where, line(match.start()), label))
    for match in _PANE_PARAMETERS.finditer(bare):
        errors.append(
            "%s:%d: takes parameters; this file must take nothing from its callers" % (where, line(match.start()))
        )
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
