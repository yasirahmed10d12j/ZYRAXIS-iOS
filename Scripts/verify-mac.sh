#!/bin/sh
# verify-mac.sh — read-only Mac/Xcode readiness check for ZYRAXIS-iOS.
# Fails fast with a useful message. Installs nothing, changes nothing,
# touches no signing credentials. Run from the project root:
#   chmod +x Scripts/*.sh
#   ./Scripts/verify-mac.sh
set -u

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/ZYRAXIS-iOS.xcodeproj"
SCHEME="ZYRAXIS-iOS"

fail() { echo "verify-mac: FAIL — $1" >&2; exit 1; }

# 1. macOS detected
[ "$(uname)" = "Darwin" ] || fail "not macOS (uname: $(uname)). This script runs on a Mac."
echo "verify-mac: [1/10] macOS detected"

# 2. Xcode installed
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found. Install Xcode from the App Store."
echo "verify-mac: [2/10] Xcode installed ($(xcodebuild -version | head -n 1))"

# 3. xcode-select configured
xcode-select -p >/dev/null 2>&1 || fail "xcode-select has no developer directory. Run: sudo xcode-select --reset"
echo "verify-mac: [3/10] xcode-select configured ($(xcode-select -p))"

# 4. xcodebuild available (covered above, verify it runs)
xcodebuild -version >/dev/null 2>&1 || fail "xcodebuild does not run."
echo "verify-mac: [4/10] xcodebuild runs"

# 5. project exists
[ -d "$PROJECT" ] || fail "project not found at $PROJECT"
[ -f "$PROJECT/project.pbxproj" ] || fail "project.pbxproj missing."
echo "verify-mac: [5/10] project exists"

# 6. scheme exists (shared scheme travels with the folder)
[ -f "$PROJECT/xcshareddata/xcschemes/$SCHEME.xcscheme" ] || fail "shared scheme $SCHEME.xcscheme missing."
echo "verify-mac: [6/10] shared scheme exists"

# 7. iOS SDK exists
xcodebuild -showsdks 2>/dev/null | grep -q "iphoneos" || fail "no iphoneos SDK listed by xcodebuild -showsdks."
echo "verify-mac: [7/10] iOS SDK present"

# 8. project can be inspected (proves the pbxproj parses)
xcodebuild -list -project "$PROJECT" >/dev/null 2>&1 || fail "xcodebuild -list failed: project.pbxproj does not parse."
xcodebuild -list -project "$PROJECT" 2>/dev/null | grep -q "$SCHEME" || fail "scheme $SCHEME not listed by xcodebuild -list."
echo "verify-mac: [8/10] project parses; scheme listed"

# 9. signing configuration exists (automatic; team is selected in Xcode, never bundled)
grep -q "CODE_SIGN_STYLE = Automatic" "$PROJECT/project.pbxproj" || fail "automatic signing not configured in project.pbxproj."
echo "verify-mac: [9/10] automatic signing configured (select your Team in Xcode)"

# 10. no Windows runtime paths in Swift source or build config
if grep -rn --include='*.swift' --include='*.xcconfig' --include='*.plist' -E 'D:\\|C:\\' "$PROJECT_DIR/ZYRAXIS" "$PROJECT_DIR/Config" 2>/dev/null | grep -q .; then
  fail "Windows path found in runtime source/config."
fi
echo "verify-mac: [10/10] no Windows paths in source/config"

echo "verify-mac: ALL CHECKS PASSED"
