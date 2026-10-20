#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Package a signed Pulse macOS app for distribution.

Defaults package build/DerivedData/Build/Products/Release/Pulse.app.

Environment variables:
  APP_PATH                         Signed .app to package.
  PRODUCT_NAME                     Release product name. Default: Pulse
  BUNDLE_NAME                      App bundle name inside artifacts. Default: Pulse.app
  CONFIGURATION                    Build configuration used by default APP_PATH. Default: Release
  RELEASE_DIR                      Output directory. Default: build/release
  RELEASE_BASENAME                 Artifact basename. Default: Pulse-<CFBundleShortVersionString>
  CREATE_ZIP                       Create a .zip. Default: 1
  CREATE_DMG                       Create a .dmg. Default: 1
  REQUIRE_DEVELOPER_ID             Require Developer ID Application signing. Default: 1
  DMG_SIGNING_IDENTITY             Optional Developer ID identity for signing the .dmg.
  NOTARIZE                         Submit and staple app, and optionally dmg. Default: 0
  NOTARIZE_DMG                     Notarize/staple .dmg when NOTARIZE=1. Default: CREATE_DMG
  NOTARYTOOL_KEYCHAIN_PROFILE      notarytool keychain profile name.
  APPLE_ID                         Apple ID email for notarytool.
  APPLE_TEAM_ID                    Apple Developer team ID for notarytool.
  APPLE_APP_SPECIFIC_PASSWORD      Apple app-specific password for notarytool.
  PRESERVE_WORK                    Keep temporary packaging work directory. Default: 0

Examples:
  ./scripts/package-release.sh
  APP_PATH=/Applications/Pulse.app CREATE_DMG=0 ./scripts/package-release.sh
  NOTARIZE=1 NOTARYTOOL_KEYCHAIN_PROFILE=pulse-release ./scripts/package-release.sh
  REQUIRE_DEVELOPER_ID=0 APP_PATH=/Applications/Pulse.app ./scripts/package-release.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
PRODUCT_NAME="${PRODUCT_NAME:-Pulse}"
BUNDLE_NAME="${BUNDLE_NAME:-$PRODUCT_NAME.app}"
APP_PATH="${APP_PATH:-$ROOT_DIR/build/DerivedData/Build/Products/$CONFIGURATION/Pulse.app}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/build/release}"
CREATE_ZIP="${CREATE_ZIP:-1}"
CREATE_DMG="${CREATE_DMG:-1}"
REQUIRE_DEVELOPER_ID="${REQUIRE_DEVELOPER_ID:-1}"
NOTARIZE="${NOTARIZE:-0}"
NOTARIZE_DMG="${NOTARIZE_DMG:-$CREATE_DMG}"
PRESERVE_WORK="${PRESERVE_WORK:-0}"
DMG_SIGNING_IDENTITY="${DMG_SIGNING_IDENTITY:-}"
WORK_DIR="${WORK_DIR:-$RELEASE_DIR/.package-work}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

safe_remove_work_dir() {
  local path="$1"
  [[ -n "$path" ]] || fail "refusing to remove an empty work directory path"
  [[ "$path" != "/" ]] || fail "refusing to remove /"
  [[ "$(basename "$path")" == ".package-work" ]] || fail "refusing to remove unexpected work directory: $path"
  rm -rf "$path"
}

plist_value() {
  local key="$1"
  local plist="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

verify_app_signature() {
  local app_path="$1"
  if ! codesign --verify --deep --strict --verbose=2 "$app_path"; then
    cat >&2 <<EOF
error: codesign verification failed for $app_path.

For a public release, rebuild with a trusted Developer ID Application
certificate before packaging. Example:

  DEVELOPMENT_TEAM="TEAMID1234" \\
  SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" \\
  INSTALL_PATH="\$PWD/build/release/Pulse.app" \\
  LAUNCH_AFTER_INSTALL=0 \\
  STAGING_INSTALL=1 SIGNING_MODE=manual ./scripts/build-install-release.sh
EOF
    exit 1
  fi

  if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
    local authorities
    authorities="$(codesign -dv --verbose=4 "$app_path" 2>&1 | awk -F= '/^Authority=/ {print $2}')"
    if ! printf '%s\n' "$authorities" | grep -q '^Developer ID Application:'; then
      cat >&2 <<EOF
error: $app_path is not signed with a Developer ID Application identity.

Observed signing authorities:
$(printf '%s\n' "$authorities" | sed 's/^/  /')

Public macOS releases should be signed with Developer ID before packaging and
notarization. Rebuild with an installed Developer ID Application certificate:

  DEVELOPMENT_TEAM="TEAMID1234" \\
  SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" \\
  INSTALL_PATH="\$PWD/build/release/Pulse.app" \\
  LAUNCH_AFTER_INSTALL=0 \\
  STAGING_INSTALL=1 SIGNING_MODE=manual ./scripts/build-install-release.sh

For a local development artifact only, rerun with REQUIRE_DEVELOPER_ID=0.
EOF
      exit 1
    fi
  fi
}

build_notary_args() {
  NOTARY_ARGS=()
  if [[ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE")
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
  else
    cat >&2 <<'EOF'
error: NOTARIZE=1 requires notarytool credentials.

Use a stored notarytool profile:
  xcrun notarytool store-credentials pulse-release \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD"
  NOTARIZE=1 NOTARYTOOL_KEYCHAIN_PROFILE=pulse-release ./scripts/package-release.sh

Or pass credentials directly:
  NOTARIZE=1 \
  APPLE_ID="you@example.com" \
  APPLE_TEAM_ID="TEAMID1234" \
  APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
  ./scripts/package-release.sh
EOF
    exit 1
  fi
}

submit_for_notarization() {
  local target="$1"
  local submit_target="$target"
  local result_json

  mkdir -p "$WORK_DIR/notary"
  if [[ -d "$target" ]]; then
    submit_target="$WORK_DIR/notary/$(basename "${target%.*}")-notary.zip"
    rm -f "$submit_target"
    ditto -c -k --keepParent "$target" "$submit_target"
  fi

  printf 'Submitting %s for notarization...\n' "$(basename "$target")"
  result_json="$WORK_DIR/notary/$(basename "${target%.*}")-notary-result.json"
  if ! xcrun notarytool submit "$submit_target" --wait --output-format json "${NOTARY_ARGS[@]}" > "$result_json"; then
    cat "$result_json" >&2
    fail "notarization submission failed for $target"
  fi

  local submission_id
  local status
  submission_id="$(plutil -extract id raw -o - "$result_json" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - "$result_json" 2>/dev/null || true)"
  [[ -n "$submission_id" ]] && printf 'Submission ID: %s\n' "$submission_id"
  printf 'Notarization status: %s\n' "${status:-unknown}"
  if [[ "$status" != "Accepted" ]]; then
    cat "$result_json" >&2
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" "${NOTARY_ARGS[@]}" >&2 || true
    fi
    fail "notarization failed for $target"
  fi

  printf 'Stapling notarization ticket to %s...\n' "$(basename "$target")"
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
}

APP_PATH="$(absolute_path "$APP_PATH")"
RELEASE_DIR="$(absolute_path "$RELEASE_DIR")"
WORK_DIR="$(absolute_path "$WORK_DIR")"

require_tool codesign
require_tool ditto
require_tool shasum
if [[ "$CREATE_DMG" == "1" ]]; then
  require_tool hdiutil
fi
if [[ "$NOTARIZE" == "1" ]]; then
  REQUIRE_DEVELOPER_ID=1
  require_tool xcrun
  require_tool plutil
  build_notary_args
fi

[[ -d "$APP_PATH" ]] || fail "APP_PATH does not exist or is not a directory: $APP_PATH"
[[ -f "$APP_PATH/Contents/Info.plist" ]] || fail "APP_PATH is missing Contents/Info.plist: $APP_PATH"

APP_VERSION="$(plist_value CFBundleShortVersionString "$APP_PATH/Contents/Info.plist")"
APP_BUILD="$(plist_value CFBundleVersion "$APP_PATH/Contents/Info.plist")"
APP_BUNDLE_ID="$(plist_value CFBundleIdentifier "$APP_PATH/Contents/Info.plist")"
APP_VERSION="${APP_VERSION:-unversioned}"
APP_BUILD="${APP_BUILD:-unknown}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-unknown.bundle.id}"
SAFE_VERSION="$(printf '%s' "$APP_VERSION" | tr '/ :' '---')"
RELEASE_BASENAME="${RELEASE_BASENAME:-$PRODUCT_NAME-$SAFE_VERSION}"

printf 'Packaging %s %s (%s) from %s\n' "$PRODUCT_NAME" "$APP_VERSION" "$APP_BUILD" "$APP_PATH"
printf 'Bundle identifier: %s\n' "$APP_BUNDLE_ID"
printf 'Require Developer ID: %s\n' "$REQUIRE_DEVELOPER_ID"
printf 'Verifying source app signature...\n'
verify_app_signature "$APP_PATH"

mkdir -p "$RELEASE_DIR"
safe_remove_work_dir "$WORK_DIR"
mkdir -p "$WORK_DIR/stage"

STAGE_DIR="$WORK_DIR/stage"
STAGED_APP="$STAGE_DIR/$BUNDLE_NAME"
ditto "$APP_PATH" "$STAGED_APP"

printf 'Verifying staged app signature...\n'
verify_app_signature "$STAGED_APP"

if [[ "$NOTARIZE" == "1" ]]; then
  submit_for_notarization "$STAGED_APP"
fi

ARTIFACTS=()

if [[ "$CREATE_ZIP" == "1" ]]; then
  ZIP_PATH="$RELEASE_DIR/$RELEASE_BASENAME.zip"
  rm -f "$ZIP_PATH"
  printf 'Creating zip: %s\n' "$ZIP_PATH"
  (cd "$STAGE_DIR" && ditto -c -k --sequesterRsrc --keepParent "$BUNDLE_NAME" "$ZIP_PATH")
  ARTIFACTS+=("$ZIP_PATH")
fi

if [[ "$CREATE_DMG" == "1" ]]; then
  DMG_STAGING_DIR="$WORK_DIR/dmg"
  DMG_PATH="$RELEASE_DIR/$RELEASE_BASENAME.dmg"
  mkdir -p "$DMG_STAGING_DIR"
  ditto "$STAGED_APP" "$DMG_STAGING_DIR/$BUNDLE_NAME"
  ln -s /Applications "$DMG_STAGING_DIR/Applications"
  rm -f "$DMG_PATH"
  printf 'Creating dmg: %s\n' "$DMG_PATH"
  hdiutil create -volname "$PRODUCT_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH"

  if [[ -n "$DMG_SIGNING_IDENTITY" ]]; then
    printf 'Signing dmg with: %s\n' "$DMG_SIGNING_IDENTITY"
    codesign --force --sign "$DMG_SIGNING_IDENTITY" --timestamp "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
  elif [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
    cat >&2 <<'EOF'
warning: DMG_SIGNING_IDENTITY is not set, so the DMG will not have a
disk-image code signature. The app inside can still be Developer ID signed,
notarized, and stapled. For a public DMG release, pass a local Developer ID
Application identity with DMG_SIGNING_IDENTITY.
EOF
  fi

  if [[ "$NOTARIZE" == "1" && "$NOTARIZE_DMG" == "1" ]]; then
    submit_for_notarization "$DMG_PATH"
  fi

  ARTIFACTS+=("$DMG_PATH")
fi

if [[ "${#ARTIFACTS[@]}" -eq 0 ]]; then
  fail "no artifacts were requested; set CREATE_ZIP=1 and/or CREATE_DMG=1"
fi

CHECKSUM_PATH="$RELEASE_DIR/$RELEASE_BASENAME-SHA256SUMS.txt"
rm -f "$CHECKSUM_PATH"
for artifact in "${ARTIFACTS[@]}"; do
  (cd "$RELEASE_DIR" && shasum -a 256 "$(basename "$artifact")") >> "$CHECKSUM_PATH"
done
ARTIFACTS+=("$CHECKSUM_PATH")

if [[ "$PRESERVE_WORK" != "1" ]]; then
  safe_remove_work_dir "$WORK_DIR"
else
  printf 'Preserved work directory: %s\n' "$WORK_DIR"
fi

printf 'Release artifacts:\n'
for artifact in "${ARTIFACTS[@]}"; do
  printf '  %s\n' "$artifact"
done
