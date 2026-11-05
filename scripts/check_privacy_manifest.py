#!/usr/bin/env python3
"""Privacy manifest checks for Show My Copy.

    scripts/check_privacy_manifest.py            the manifests in the repository, against the code of each target
    scripts/check_privacy_manifest.py path/App   also the manifests a built app carries

Apple's rules (cited in AppStore/CHECKLIST.md):
- A privacy manifest (`PrivacyInfo.xcprivacy`) records tracking, collected data and the "required reason" APIs a
  bundle uses. Required reasons are required on iOS, iPadOS, tvOS, visionOS and watchOS; this Mac app declares them
  anyway, so the manifest stays true if Apple extends the rule to macOS.
  https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- "For each executable or dynamic library in an app that uses a required reason API, the bundle that includes the
  executable or dynamic library needs to include a privacy manifest file that reports the API."
  https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- The categories, the APIs in each and the approved reasons:
  https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
- On macOS the manifest goes in `Contents/Resources/`:
  https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk

What this checks:
- The app target has exactly one manifest, and every other shipped target (the Control Center extension) has one
  exactly when its code uses a required reason API category. Which files a target builds is read from the project's
  file-system synchronized folders and their membership exceptions, so a file built into two targets counts for both.
- Each manifest declares no tracking, no tracking domains and no collected data (nothing leaves the Mac), only keys
  Apple documents, and for each category Apple's reason codes for it.
- The categories a manifest declares are exactly those its target's code uses (API_PATTERNS, matched with comments
  and strings removed) and its reviewed packages use (PACKAGES): a new use fails until it is declared, and a
  declaration no code needs fails too.
- APIs that look like required reason APIs but are not on Apple's list (LOOKALIKES) stay in the files they were
  reviewed in.
- With an app: the built app and each extension carry the manifest from the repository, unchanged, in
  `Contents/Resources/`, and an extension without one in the repository carries none.

Runs with the python3 that ships with the Xcode command line tools (3.9). Fails closed: a file, project entry or
build phase it does not understand is an error.
"""

from __future__ import annotations

import os
import plistlib
import re
import sys
from typing import Dict, List, Optional, Set, Tuple

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPTS)
sys.dont_write_bytecode = True  # keep scripts/ free of __pycache__

import check_security  # noqa: E402  (the project file parser and the Swift comment and string stripper)

PROJECT = check_security.PROJECT
MANIFEST = "PrivacyInfo.xcprivacy"
APPLICATION = "com.apple.product-type.application"
APP_EXTENSION = "com.apple.product-type.app-extension"
SHIPPED_PRODUCT_TYPES = {APPLICATION, APP_EXTENSION}

USER_DEFAULTS = "NSPrivacyAccessedAPICategoryUserDefaults"
FILE_TIMESTAMP = "NSPrivacyAccessedAPICategoryFileTimestamp"
SYSTEM_BOOT_TIME = "NSPrivacyAccessedAPICategorySystemBootTime"
DISK_SPACE = "NSPrivacyAccessedAPICategoryDiskSpace"
ACTIVE_KEYBOARDS = "NSPrivacyAccessedAPICategoryActiveKeyboards"

# Apple's approved reasons for each category (the NSPrivacyAccessedAPIType page above). A manifest may declare only
# these, and never the ones reserved for third-party SDKs: every target here is the app's own code.
REASONS: Dict[str, Set[str]] = {
    FILE_TIMESTAMP: {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    SYSTEM_BOOT_TIME: {"35F9.1", "8FFB.1", "3D61.1"},
    DISK_SPACE: {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    ACTIVE_KEYBOARDS: {"3EC4.1", "54BD.1"},
    USER_DEFAULTS: {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}
SDK_ONLY_REASONS = {"0A2A.1", "C56D.1"}

# The top-level keys of a privacy manifest (privacy-manifest-files above). The three below must say that the app
# tracks nobody and collects nothing: nothing it reads leaves the Mac.
MANIFEST_KEYS = {
    "NSPrivacyTracking",
    "NSPrivacyTrackingDomains",
    "NSPrivacyCollectedDataTypes",
    "NSPrivacyAccessedAPITypes",
}
REQUIRED_VALUES: Dict[str, object] = {
    "NSPrivacyTracking": False,
    "NSPrivacyTrackingDomains": [],
    "NSPrivacyCollectedDataTypes": [],
}
API_TYPE_KEYS = {"NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"}

_B = check_security._B
_E = check_security._E


def _name(name: str) -> str:
    return _B + re.escape(name) + _E


def _call(name: str) -> str:
    """A call with arguments: `stat(path, &info)`, not `stat()`, which in Swift only makes an empty C struct."""
    return _B + re.escape(name) + r"\s*\((?!\s*\))"


# Every API of Apple's list, as it is written in Swift, with its category. An API in two categories (getattrlist)
# is listed twice. Entries marked "added" are not on Apple's list but return the same data, so they count too.
# Matched in the code with comments and string literals blanked out.
API_PATTERNS: List[Tuple[str, str, str]] = [
    # File timestamp APIs.
    (_name("creationDate"), FILE_TIMESTAMP, "creationDate"),
    (_name("modificationDate"), FILE_TIMESTAMP, "modificationDate"),
    (_name("fileModificationDate"), FILE_TIMESTAMP, "fileModificationDate"),
    (_name("contentModificationDateKey"), FILE_TIMESTAMP, "contentModificationDateKey"),
    (_name("creationDateKey"), FILE_TIMESTAMP, "creationDateKey"),
    (_name("getattrlist"), FILE_TIMESTAMP, "getattrlist"),
    (_name("getattrlistbulk"), FILE_TIMESTAMP, "getattrlistbulk"),
    (_name("fgetattrlist"), FILE_TIMESTAMP, "fgetattrlist"),
    (_call("stat"), FILE_TIMESTAMP, "stat"),
    (_call("fstat"), FILE_TIMESTAMP, "fstat"),
    (_call("fstatat"), FILE_TIMESTAMP, "fstatat"),
    (_call("lstat"), FILE_TIMESTAMP, "lstat"),
    (_name("getattrlistat"), FILE_TIMESTAMP, "getattrlistat"),
    # Added: FileManager's attributes include creationDate and modificationDate; the resource value of the key.
    (_name("attributesOfItem"), FILE_TIMESTAMP, "attributesOfItem (added)"),
    (_name("contentModificationDate"), FILE_TIMESTAMP, "contentModificationDate (added)"),
    # System boot time APIs.
    (_name("systemUptime"), SYSTEM_BOOT_TIME, "systemUptime"),
    (_name("mach_absolute_time"), SYSTEM_BOOT_TIME, "mach_absolute_time"),
    # Added: the boot time itself, through sysctl.
    (_name("KERN_BOOTTIME"), SYSTEM_BOOT_TIME, "KERN_BOOTTIME (added)"),
    # Disk space APIs.
    (_name("volumeAvailableCapacityKey"), DISK_SPACE, "volumeAvailableCapacityKey"),
    (_name("volumeAvailableCapacityForImportantUsageKey"), DISK_SPACE, "volumeAvailableCapacityForImportantUsageKey"),
    (_name("volumeAvailableCapacityForOpportunisticUsageKey"), DISK_SPACE,
     "volumeAvailableCapacityForOpportunisticUsageKey"),
    (_name("volumeTotalCapacityKey"), DISK_SPACE, "volumeTotalCapacityKey"),
    (_name("systemFreeSize"), DISK_SPACE, "systemFreeSize"),
    (_name("systemSize"), DISK_SPACE, "systemSize"),
    (_call("statfs"), DISK_SPACE, "statfs"),
    (_call("statvfs"), DISK_SPACE, "statvfs"),
    (_call("fstatfs"), DISK_SPACE, "fstatfs"),
    (_call("fstatvfs"), DISK_SPACE, "fstatvfs"),
    (_name("getattrlist"), DISK_SPACE, "getattrlist"),
    (_name("fgetattrlist"), DISK_SPACE, "fgetattrlist"),
    (_name("getattrlistat"), DISK_SPACE, "getattrlistat"),
    # Added: FileManager's file system attributes (systemSize, systemFreeSize), and the free and total block counts
    # of the statfs structures that getfsstat fills (see LOOKALIKES).
    (_name("attributesOfFileSystem"), DISK_SPACE, "attributesOfFileSystem (added)"),
    (_B + r"f_(bavail|bfree|blocks|bsize|iosize)" + _E, DISK_SPACE, "statfs block counts (added)"),
    # Active keyboard APIs.
    (_name("activeInputModes"), ACTIVE_KEYBOARDS, "activeInputModes"),
    # User defaults APIs. Added: the Objective-C name, SwiftUI's wrapper and the C API of the same store.
    (_name("UserDefaults"), USER_DEFAULTS, "UserDefaults"),
    (_name("NSUserDefaults"), USER_DEFAULTS, "NSUserDefaults (added)"),
    (_name("NSUserDefaultsController"), USER_DEFAULTS, "NSUserDefaultsController (added)"),
    (_name("AppStorage"), USER_DEFAULTS, "AppStorage (added)"),
    (_B + r"CFPreferences\w*", USER_DEFAULTS, "CFPreferences (added)"),
]

# APIs that are close to a category but not on Apple's list, reviewed in the files listed: anywhere else they fail
# until they are reviewed again. Each entry says why it needs no declaration.
LOOKALIKES: List[Tuple[str, str, Set[str], str]] = [
    (
        _name("getfsstat"),
        "getfsstat",
        {"ShowMyCopy/History/SystemMountedVolumes.swift"},
        "lists mounted volumes; it fills statfs structures, but the app reads only the mount point, the file system "
        "type and MNT_LOCAL, never free or total space (reading those matches the disk space category). Apple lists "
        "statfs, statvfs, fstatfs and fstatvfs, not getfsstat.",
    ),
    (
        _B + r"TIS[A-Z]\w*",
        "Text Input Sources",
        {"ShowMyCopy/Platform/Paste/SystemPasteKeystrokes.swift"},
        "reads the current keyboard layout to find the key that types V for the optional paste. Apple's active "
        "keyboards category lists only UIKit's activeInputModes, the list of enabled keyboards.",
    ),
]

# Swift packages the app links, reviewed for required reason APIs at the pinned version: their code is linked into
# the app's executable, so the app's manifest reports it. KeyboardShortcuts ships no privacy manifest of its own.
# A new package or another version fails until it is reviewed and entered here.
PACKAGES: Dict[str, Tuple[str, Set[str], str]] = {
    "KeyboardShortcuts": (
        "3.1.0",
        {USER_DEFAULTS},
        "keeps the shortcut in UserDefaults.standard under keys that start with KeyboardShortcuts_ (CA92.1); its "
        "Text Input Sources call is a LOOKALIKES case; no other required reason API",
    ),
}

SOURCE_SUFFIXES = (".swift",)
# Code the scan cannot read: a target that builds one of these fails until the scan learns the language.
UNSCANNED_CODE_SUFFIXES = (".m", ".mm", ".c", ".cc", ".cpp", ".h", ".hpp", ".s", ".metal")


class CheckError(Exception):
    pass


# ------------------------------------------------------------------ the project


def _objects(root: str) -> Tuple[dict, dict]:
    path = os.path.join(root, PROJECT, "project.pbxproj")
    try:
        with open(path, encoding="utf-8") as handle:
            data = check_security.parse_pbxproj(handle.read())
    except (OSError, UnicodeDecodeError, check_security.PbxprojError) as error:
        raise CheckError("cannot read %s: %s" % (path, error))
    objects = data.get("objects")
    if not isinstance(objects, dict):
        raise CheckError("%s has no objects" % path)
    project = objects.get(data.get("rootObject"))
    if not isinstance(project, dict) or project.get("isa") != "PBXProject":
        raise CheckError("%s has no project object" % path)
    return objects, project


def _get(objects: dict, ref: object, isa: str, what: str) -> dict:
    obj = objects.get(ref) if isinstance(ref, str) else None
    if not isinstance(obj, dict) or obj.get("isa") != isa:
        raise CheckError("%s %r is missing or not a %s" % (what, ref, isa))
    return obj


def _files_under(root: str, folder: str) -> List[str]:
    """Every file in `folder` (relative to root), relative to root with / separators."""
    found = []
    base = os.path.join(root, folder)
    if not os.path.isdir(base):
        raise CheckError("synchronized folder %s does not exist" % folder)
    for directory, subdirs, files in os.walk(base):
        subdirs[:] = sorted(d for d in subdirs if d not in check_security.SKIP_DIRS)
        for name in sorted(files):
            found.append(os.path.relpath(os.path.join(directory, name), root).replace(os.sep, "/"))
    return found


def _matches(relative: str, exceptions: List[str]) -> bool:
    """Whether a path inside a synchronized folder is one of its exceptions: the file itself or a folder above it."""
    return any(relative == item or relative.startswith(item.rstrip("/") + "/") for item in exceptions)


def target_files(root: str) -> List[Tuple[str, str, List[str], List[str]]]:
    """[(target name, product type, files it builds, package products)] for every shipped target.

    A target builds the files of its own synchronized folders, minus their membership exceptions for it, plus the
    membership exceptions for it in other targets' synchronized folders."""
    objects, project = _objects(root)
    groups: Dict[str, dict] = {
        ref: obj for ref, obj in objects.items()
        if isinstance(obj, dict) and obj.get("isa") == "PBXFileSystemSynchronizedRootGroup"
    }

    def exceptions_for(group: dict, target_ref: str) -> List[str]:
        items: List[str] = []
        for ref in group.get("exceptions", []):
            exception = objects.get(ref)
            if not isinstance(exception, dict):
                raise CheckError("exception set %r is missing" % (ref,))
            if exception.get("isa") != "PBXFileSystemSynchronizedBuildFileExceptionSet":
                raise CheckError("exception %r of folder %s is a %s, which this check does not understand"
                                 % (ref, group.get("path"), exception.get("isa")))
            if exception.get("target") == target_ref:
                members = exception.get("membershipExceptions", [])
                if not isinstance(members, list) or not all(isinstance(item, str) for item in members):
                    raise CheckError("membership exceptions %r are not a list of paths" % (ref,))
                items.extend(members)
        return items

    result = []
    for target_ref in project.get("targets", []):
        target = _get(objects, target_ref, "PBXNativeTarget", "target")
        name = target.get("name", target_ref)
        product_type = target.get("productType", "")
        if product_type not in SHIPPED_PRODUCT_TYPES:
            if product_type in check_security.TEST_PRODUCT_TYPES:
                continue  # never shipped
            raise CheckError("target %s is a %s, which this check does not know" % (name, product_type))
        for phase_ref in target.get("buildPhases", []):
            phase = objects.get(phase_ref)
            if not isinstance(phase, dict):
                raise CheckError("build phase %r of %s is missing" % (phase_ref, name))
            if phase.get("isa") in ("PBXSourcesBuildPhase", "PBXResourcesBuildPhase") and phase.get("files"):
                raise CheckError("target %s lists files in its %s; this check reads only synchronized folders"
                                 % (name, phase.get("isa")))
        own = target.get("fileSystemSynchronizedGroups", [])
        files: List[str] = []
        for group_ref, group in sorted(groups.items()):
            folder = group.get("path")
            if not isinstance(folder, str):
                raise CheckError("synchronized folder %r has no path" % (group_ref,))
            excepted = exceptions_for(group, target_ref)
            for path in _files_under(root, folder):
                inside = path[len(folder) + 1:]
                if group_ref in own:
                    if not _matches(inside, excepted):
                        files.append(path)
                elif _matches(inside, excepted):
                    files.append(path)
        packages = []
        for ref in target.get("packageProductDependencies", []):
            product = _get(objects, ref, "XCSwiftPackageProductDependency", "package product of %s" % name)
            packages.append(product.get("productName", ref))
        result.append((name, product_type, sorted(set(files)), packages))
    if not any(product_type == APPLICATION for _, product_type, _, _ in result):
        raise CheckError("the project has no app target")
    return result


def package_versions(root: str) -> Dict[str, str]:
    """{product name: exact pinned version} of the packages in the project."""
    objects, _ = _objects(root)
    versions: Dict[str, str] = {}
    for obj in objects.values():
        if isinstance(obj, dict) and obj.get("isa") == "XCSwiftPackageProductDependency":
            package = objects.get(obj.get("package"))
            requirement = package.get("requirement") if isinstance(package, dict) else None
            if isinstance(requirement, dict) and requirement.get("kind") == "exactVersion":
                versions[obj.get("productName", "")] = str(requirement.get("version"))
    return versions


# ------------------------------------------------------------------ the code


def scan(text: str, where: str) -> Tuple[List[Tuple[str, int, str]], List[Tuple[int, str]]]:
    """([(category, line, API)], [(line, lookalike)]) of one Swift file."""
    try:
        _, bare = check_security._swift_code(text, strict=False)
    except ValueError as error:
        raise CheckError("%s: cannot scan: %s" % (where, error))

    def line(offset: int) -> int:
        return text.count("\n", 0, offset) + 1

    uses = []
    for pattern, category, api in API_PATTERNS:
        for match in re.finditer(pattern, bare):
            uses.append((category, line(match.start()), api))
    lookalikes = []
    for pattern, label, files, _ in LOOKALIKES:
        if where in files:
            continue
        for match in re.finditer(pattern, bare):
            lookalikes.append((line(match.start()), label))
    return sorted(set(uses)), sorted(set(lookalikes))


def used_categories(root: str, files: List[str], packages: List[str],
                    versions: Dict[str, str]) -> Tuple[Dict[str, List[str]], List[str]]:
    """({category: [where it is used]}, errors) for the files and packages of one target."""
    used: Dict[str, List[str]] = {}
    errors: List[str] = []
    for path in files:
        if path.endswith(UNSCANNED_CODE_SUFFIXES):
            errors.append("%s: only Swift is scanned for required reason APIs; teach this check the language" % path)
            continue
        if not path.endswith(SOURCE_SUFFIXES):
            continue
        try:
            with open(os.path.join(root, path), encoding="utf-8") as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError) as error:
            errors.append("cannot read %s: %s" % (path, error))
            continue
        try:
            uses, lookalikes = scan(text, path)
        except CheckError as error:
            errors.append(str(error))
            continue
        for category, number, api in uses:
            used.setdefault(category, []).append("%s:%d (%s)" % (path, number, api))
        for number, label in lookalikes:
            errors.append("%s:%d: %s outside the files it was reviewed in (LOOKALIKES); review it and add the file"
                          % (path, number, label))
    for package in packages:
        reviewed = PACKAGES.get(package)
        if reviewed is None:
            errors.append("package %s is not reviewed for required reason APIs (PACKAGES)" % package)
            continue
        version, categories, _ = reviewed
        if versions.get(package) != version:
            errors.append("package %s is pinned to %s but was reviewed for required reason APIs at %s (PACKAGES)"
                          % (package, versions.get(package), version))
        for category in sorted(categories):
            used.setdefault(category, []).append("package %s %s" % (package, version))
    return used, errors


# ------------------------------------------------------------------ the manifest


def read_manifest(path: str, where: str) -> Tuple[Optional[dict], List[str]]:
    try:
        with open(path, "rb") as handle:
            manifest = plistlib.load(handle)
    except Exception as error:  # plistlib raises several unrelated types on garbage input
        return None, ["%s: cannot read: %s" % (where, error)]
    if not isinstance(manifest, dict):
        return None, ["%s: is not a dictionary" % where]
    return manifest, []


def check_manifest(manifest: dict, where: str) -> Tuple[Dict[str, List[str]], List[str]]:
    """({declared category: reasons}, errors) of a parsed manifest."""
    errors = []
    for key in sorted(set(manifest) - MANIFEST_KEYS):
        errors.append("%s: unexpected key %s (App Store Connect rejects unexpected keys)" % (where, key))
    for key, expected in REQUIRED_VALUES.items():
        value = manifest.get(key)
        if type(value) is not type(expected) or value != expected:
            errors.append("%s: %s must be %r: nothing the app reads leaves the Mac, found %r"
                          % (where, key, expected, value))
    declared: Dict[str, List[str]] = {}
    types = manifest.get("NSPrivacyAccessedAPITypes")
    if not isinstance(types, list):
        errors.append("%s: NSPrivacyAccessedAPITypes must be an array" % where)
        return declared, errors
    for index, entry in enumerate(types):
        label = "%s: NSPrivacyAccessedAPITypes[%d]" % (where, index)
        if not isinstance(entry, dict):
            errors.append("%s is not a dictionary" % label)
            continue
        for key in sorted(set(entry) - API_TYPE_KEYS):
            errors.append("%s: unexpected key %s" % (label, key))
        category = entry.get("NSPrivacyAccessedAPIType")
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
        if category not in REASONS:
            errors.append("%s: unknown category %r" % (label, category))
            continue
        if category in declared:
            errors.append("%s: %s is declared twice" % (label, category))
            continue
        if not isinstance(reasons, list) or not reasons or not all(isinstance(r, str) for r in reasons):
            errors.append("%s: %s needs a non-empty array of reason codes" % (label, category))
            continue
        if len(set(reasons)) != len(reasons):
            errors.append("%s: %s lists a reason twice" % (label, category))
        for reason in reasons:
            if reason not in REASONS[category]:
                errors.append("%s: %s is not a reason Apple lists for %s" % (label, reason, category))
            elif reason in SDK_ONLY_REASONS:
                errors.append("%s: %s may be declared only by third-party SDKs" % (label, reason))
        declared[category] = list(reasons)
    return declared, errors


def _places(places: List[str]) -> str:
    shown = "; ".join(places[:3])
    return shown if len(places) <= 3 else "%s and %d more" % (shown, len(places) - 3)


def check_repository(root: str) -> List[str]:
    try:
        targets = target_files(root)
        versions = package_versions(root)
    except CheckError as error:
        return [str(error)]
    errors: List[str] = []
    for name, product_type, files, packages in targets:
        used, scan_errors = used_categories(root, files, packages, versions)
        errors.extend(scan_errors)
        manifests = [path for path in files if os.path.basename(path) == MANIFEST]
        is_app = product_type == APPLICATION
        if len(manifests) > 1:
            errors.append("target %s builds %d privacy manifests (%s); Xcode copies them to the same place"
                          % (name, len(manifests), ", ".join(manifests)))
            continue
        if not manifests:
            if is_app:
                errors.append("target %s has no %s in its folder" % (name, MANIFEST))
            for category in sorted(used):
                errors.append("target %s uses %s (%s) but has no %s"
                              % (name, category, _places(used[category]), MANIFEST))
            continue
        manifest, read_errors = read_manifest(os.path.join(root, manifests[0]), manifests[0])
        errors.extend(read_errors)
        if manifest is None:
            continue
        declared, manifest_errors = check_manifest(manifest, manifests[0])
        errors.extend(manifest_errors)
        for category in sorted(set(used) - set(declared)):
            errors.append("%s: target %s uses %s but does not declare it: %s"
                          % (manifests[0], name, category, _places(used[category])))
        for category in sorted(set(declared) - set(used)):
            errors.append("%s: declares %s, which no code of target %s uses; remove it"
                          % (manifests[0], category, name))
    return errors


# ------------------------------------------------------------------ the built app


def _same_manifest(built: str, source: str, where: str) -> List[str]:
    built_manifest, errors = read_manifest(built, where)
    source_manifest, source_errors = read_manifest(source, os.path.basename(os.path.dirname(source)))
    errors += source_errors
    if built_manifest is not None and source_manifest is not None and built_manifest != source_manifest:
        errors.append("%s differs from the manifest in the repository" % where)
    return errors


def check_built_app(root: str, app: str) -> List[str]:
    if not os.path.isdir(os.path.join(app, "Contents")):
        return ["%s is not a macOS app bundle" % app]
    try:
        targets = target_files(root)
    except CheckError as error:
        return [str(error)]
    sources = {}
    for name, product_type, files, _ in targets:
        manifests = [path for path in files if os.path.basename(path) == MANIFEST]
        sources[name] = (product_type, os.path.join(root, manifests[0]) if len(manifests) == 1 else None)
    errors = []
    app_sources = [source for product_type, source in sources.values() if product_type == APPLICATION]
    built = os.path.join(app, "Contents", "Resources", MANIFEST)
    where = os.path.join(os.path.basename(app), "Contents", "Resources", MANIFEST)
    if not os.path.isfile(built):
        errors.append("%s is missing" % where)
    elif len(app_sources) == 1 and app_sources[0] is not None:
        errors += _same_manifest(built, app_sources[0], where)
    if os.path.exists(os.path.join(app, "Contents", MANIFEST)):
        errors.append("%s/Contents/%s: a Mac app keeps its manifest in Contents/Resources"
                      % (os.path.basename(app), MANIFEST))
    plugins = os.path.join(app, "Contents", "PlugIns")
    for name in sorted(os.listdir(plugins)) if os.path.isdir(plugins) else []:
        if not name.endswith(".appex"):
            continue
        target = name[: -len(".appex")]
        where = os.path.join(os.path.basename(app), "Contents", "PlugIns", name, "Contents", "Resources", MANIFEST)
        built = os.path.join(plugins, name, "Contents", "Resources", MANIFEST)
        if target not in sources or sources[target][0] != APP_EXTENSION:
            errors.append("%s: no extension target %s in the project" % (name, target))
            continue
        source = sources[target][1]
        if source is None:
            if os.path.exists(built):
                errors.append("%s exists, but target %s has no manifest in the repository" % (where, target))
        elif not os.path.isfile(built):
            errors.append("%s is missing" % where)
        else:
            errors += _same_manifest(built, source, where)
    return errors


# ------------------------------------------------------------------ entry point


def run_checks(root: str, app: Optional[str] = None) -> List[str]:
    errors = check_repository(root)
    if app is not None:
        errors += check_built_app(root, app)
    return errors


def main(argv: List[str]) -> int:
    if len(argv) > 1 or (argv and argv[0].startswith("-")):
        print("usage: check_privacy_manifest.py [path/to/App.app]", file=sys.stderr)
        return 2
    root = os.path.dirname(SCRIPTS)
    app = os.path.abspath(argv[0]) if argv else None
    errors = run_checks(root, app)
    for error in errors:
        print("error: " + error, file=sys.stderr)
    if errors:
        return 1
    print("privacy manifest checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
