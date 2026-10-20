#!/usr/bin/env bash
# Security checks for Show My Copy.
#   scripts/check_security.sh            project settings and sources
#   scripts/check_security.sh path/App   also the signed entitlements of a built app
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=ShowMyCopy.xcodeproj/project.pbxproj
fail=0
err() { echo "error: $*" >&2; fail=1; }

# App target: sandbox and hardened runtime on, network off.
for key in ENABLE_APP_SANDBOX ENABLE_HARDENED_RUNTIME; do
    [ "$(grep -c "$key = YES;" "$PROJECT")" -ge 2 ] || err "$key must be YES in Debug and Release"
done
for key in ENABLE_INCOMING_NETWORK_CONNECTIONS ENABLE_OUTGOING_NETWORK_CONNECTIONS; do
    grep -q "$key = YES;" "$PROJECT" && err "$key must not be YES"
    [ "$(grep -c "$key = NO;" "$PROJECT")" -ge 2 ] || err "$key must be NO in Debug and Release"
done

# Entitlements files must not open the network or weaken the hardened runtime.
FORBIDDEN_ENTITLEMENTS='com\.apple\.security\.network\.|com\.apple\.security\.temporary-exception|com\.apple\.security\.cs\.disable-library-validation|com\.apple\.security\.cs\.allow-unsigned-executable-memory|com\.apple\.security\.cs\.allow-dyld-environment-variables|com\.apple\.security\.get-task-allow'
while IFS= read -r -d '' file; do
    grep -Eq "$FORBIDDEN_ENTITLEMENTS" "$file" && err "$file has a forbidden entitlement"
done < <(find . -name '*.entitlements' -not -path './build/*' -print0)

# Network APIs anywhere in Swift sources (SwiftLint checks this too; this also covers new targets).
if grep -rEn --include='*.swift' \
    '\b(URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|NWPathMonitor|CFSocket|WKWebView)\b|import[[:space:]]+(Network|WebKit|CFNetwork)\b' \
    --exclude-dir=build --exclude-dir=.build . ; then
    err "network API found in sources"
fi

# Third-party dependencies must be pinned to an exact version.
if grep -q 'XCRemoteSwiftPackageReference' "$PROJECT"; then
    grep -A4 'requirement = {' "$PROJECT" | grep -q 'kind = exactVersion' || err "Swift packages must use an exact version"
fi

# Built app: check what was actually signed.
if [ $# -ge 1 ]; then
    app="$1"
    ents="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"
    [ -n "$ents" ] || err "cannot read entitlements of $app"
    grep -q '<key>com.apple.security.app-sandbox</key>' <<<"$ents" || err "$app is not sandboxed"
    grep -Eq "$FORBIDDEN_ENTITLEMENTS" <<<"$ents" && err "$app is signed with a forbidden entitlement"
    codesign -d --verbose=2 "$app" 2>&1 | grep -q 'flags=.*runtime' || err "$app has no hardened runtime"
fi

[ "$fail" -eq 0 ] && echo "security checks passed"
exit "$fail"
