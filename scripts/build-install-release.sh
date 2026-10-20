#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Pulse.xcodeproj"
SCHEME="${SCHEME:-MacMonitorApp}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"
INSTALL_PATH="${INSTALL_PATH:-/Applications/Pulse.app}"
STAGING_INSTALL="${STAGING_INSTALL:-auto}"
TEAM_ID="${DEVELOPMENT_TEAM:-549A496SHU}"
SIGNING_MODE="${SIGNING_MODE:-managed}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Apple Development: felmon.fekadu@icloud.com (WJX5PBY73S)}"
LAUNCH_AFTER_INSTALL="${LAUNCH_AFTER_INSTALL:-1}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
RELEASE_VERSION="${RELEASE_VERSION:-}"

if [[ "$INSTALL_PATH" != "/" ]]; then
  INSTALL_PATH="${INSTALL_PATH%/}"
fi
if [[ -e "$INSTALL_PATH" ]] && command -v realpath >/dev/null 2>&1; then
  INSTALL_PATH="$(realpath "$INSTALL_PATH")"
fi

if [[ -z "${ENABLE_HARDENED_RUNTIME+x}" ]]; then
  if [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]]; then
    ENABLE_HARDENED_RUNTIME=1
  else
    ENABLE_HARDENED_RUNTIME=0
  fi
fi

if [[ -z "${CODESIGN_TIMESTAMP+x}" ]]; then
  if [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]]; then
    CODESIGN_TIMESTAMP=1
  else
    CODESIGN_TIMESTAMP=none
  fi
fi

APP_ENTITLEMENTS="$ROOT_DIR/Sources/MacMonitorApp.entitlements"
EXTENSION_ENTITLEMENTS="$ROOT_DIR/Sources/MacMonitorWidgetExtension.entitlements"
BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Pulse.app"
BUILT_EXTENSION="$BUILT_APP/Contents/PlugIns/MacMonitorWidgetExtension.appex"
INSTALLED_APP_EXECUTABLE="$INSTALL_PATH/Contents/MacOS/Pulse"
LEGACY_INSTALLED_APP_EXECUTABLE="$INSTALL_PATH/Contents/MacOS/MacMonitorApp"
INSTALLED_EXTENSION="$INSTALL_PATH/Contents/PlugIns/MacMonitorWidgetExtension.appex"
INSTALLED_EXTENSION_EXECUTABLE="$INSTALLED_EXTENSION/Contents/MacOS/MacMonitorWidgetExtension"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
APP_GROUP_ID="group.com.macmonitor.widget.shared"
WIDGET_BUNDLE_ID="com.macmonitor.widget.extension"
WIDGET_KIND="MacMonitorWidget"
CHRONO_ROOT="$HOME/Library/Containers/$WIDGET_BUNDLE_ID/Data/SystemData/com.apple.chrono"
IS_LIVE_INSTALL=0
case "$STAGING_INSTALL" in
  0)
    IS_LIVE_INSTALL=1
    ;;
  1)
    ;;
  auto)
    REGISTERED_AT_INSTALL_PATH="$(pluginkit -m -A -D -v -i "$WIDGET_BUNDLE_ID" 2>/dev/null || true)"
    if [[ "$INSTALL_PATH" == "/Applications/Pulse.app" ||
          "$LAUNCH_AFTER_INSTALL" == "1" ||
          "$REGISTERED_AT_INSTALL_PATH" == *"$INSTALLED_EXTENSION"* ]]; then
      IS_LIVE_INSTALL=1
    fi
    ;;
  *)
    printf 'error: STAGING_INSTALL must be auto, 0, or 1, got %s.\n' "$STAGING_INSTALL" >&2
    exit 1
    ;;
esac

if [[ "$STAGING_INSTALL" == "1" && "$LAUNCH_AFTER_INSTALL" == "1" ]]; then
  printf 'error: STAGING_INSTALL=1 cannot be combined with LAUNCH_AFTER_INSTALL=1.\n' >&2
  exit 1
fi

if [[ "$SIGNING_MODE" != "managed" && "$SIGNING_MODE" != "manual" ]]; then
  printf 'error: SIGNING_MODE must be managed or manual, got %s.\n' "$SIGNING_MODE" >&2
  exit 1
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER=2
  if [[ -f "$INSTALL_PATH/Contents/Info.plist" ]]; then
    INSTALLED_BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$INSTALL_PATH/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$INSTALLED_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
      BUILD_NUMBER=$((INSTALLED_BUILD_NUMBER + 1))
    fi
  fi
fi

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  printf 'error: BUILD_NUMBER must be a positive integer, got %s.\n' "$BUILD_NUMBER" >&2
  exit 1
fi

if [[ -z "$RELEASE_VERSION" ]]; then
  RELEASE_VERSION="1.0.$BUILD_NUMBER"
fi

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'error: RELEASE_VERSION must contain three numeric components, got %s.\n' "$RELEASE_VERSION" >&2
  exit 1
fi

process_ids_for_executable() {
  local executable="$1"
  local pid
  local command

  while read -r pid command; do
    if [[ "$command" == "$executable" ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(ps -axo pid=,comm=)
}

terminate_process_at_path() {
  local executable="$1"
  local label="$2"
  local pids=""

  pids="$(process_ids_for_executable "$executable")"
  if [[ -z "$pids" ]]; then
    return
  fi

  printf 'Stopping %s process(es): %s\n' "$label" "$(printf '%s' "$pids" | tr '\n' ' ')"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
  done <<< "$pids"

  for _ in {1..50}; do
    if [[ -z "$(process_ids_for_executable "$executable")" ]]; then
      return
    fi
    sleep 0.1
  done

  pids="$(process_ids_for_executable "$executable")"
  printf '%s did not stop cleanly; forcing it to exit.\n' "$label"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
  done <<< "$pids"
}

registered_widget_paths() {
  pluginkit -m -A -D -v -i "$WIDGET_BUNDLE_ID" 2>/dev/null \
    | sed -nE $'s|^.*\t(/.*)$|\\1|p'
}

unregister_widget_copies_except() {
  local keep_path="${1:-}"
  local registered_path

  while IFS= read -r registered_path; do
    [[ -z "$registered_path" || "$registered_path" == "$keep_path" ]] && continue
    printf 'Unregistering duplicate widget at %s...\n' "$registered_path"
    pluginkit -r "$registered_path" >/dev/null 2>&1 || true
  done < <(registered_widget_paths)
}

reset_pulse_widget_cache() {
  local area
  local cache_path

  printf 'Resetting Pulse WidgetKit render caches...\n'
  killall MacMonitorWidgetExtension >/dev/null 2>&1 || true
  killall NotificationCenter >/dev/null 2>&1 || true
  killall chronod >/dev/null 2>&1 || true

  for area in snapshots timelines placeholders; do
    cache_path="$CHRONO_ROOT/$area/$WIDGET_KIND"
    if [[ -d "$cache_path" ]]; then
      # The widget container is privacy-protected; a shell without App Data
      # access can't clear it. The cache is only an optimization (chronod was
      # restarted above and the build number changed), so warn and continue
      # instead of aborting a half-finished install.
      /bin/rm -rf "$cache_path" 2>/dev/null \
        || printf 'warning: could not clear %s (no App Data access); continuing.\n' "$cache_path" >&2
    fi
  done
}

verify_managed_bundle() {
  local bundle_path="$1"
  local bundle_id="$2"
  local profile_path="$bundle_path/Contents/embedded.provisionprofile"
  local entitlements
  local profile_entitlements

  if [[ ! -f "$profile_path" ]]; then
    printf 'error: managed build is missing %s.\n' "$profile_path" >&2
    exit 1
  fi

  entitlements="$(codesign -d --entitlements :- "$bundle_path" 2>/dev/null)"
  if ! grep -Fq "<string>$TEAM_ID.$bundle_id</string>" <<< "$entitlements"; then
    printf 'error: %s is missing the expected application identifier for team %s.\n' \
      "$bundle_path" "$TEAM_ID" >&2
    exit 1
  fi

  if ! grep -Fq '<string>group.com.macmonitor.widget.shared</string>' <<< "$entitlements"; then
    printf 'error: %s is missing the Pulse App Group entitlement.\n' "$bundle_path" >&2
    exit 1
  fi

  profile_entitlements="$(security cms -D -i "$profile_path" 2>/dev/null \
    | plutil -extract Entitlements xml1 -o - - 2>/dev/null || true)"
  if ! grep -Fq "<string>$TEAM_ID.$bundle_id</string>" <<< "$profile_entitlements"; then
    printf 'error: the provisioning profile for %s does not authorize team %s.\n' \
      "$bundle_path" "$TEAM_ID" >&2
    exit 1
  fi

  if ! grep -Fq "<string>$APP_GROUP_ID</string>" <<< "$profile_entitlements"; then
    printf 'warning: the provisioning profile for %s does not authorize App Group %s; Pulse will use local settings and live widget samples.\n' \
      "$bundle_path" "$APP_GROUP_ID" >&2
  fi
}

CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$CODESIGN_TIMESTAMP" == "none" || "$CODESIGN_TIMESTAMP" == "0" ]]; then
  CODESIGN_ARGS+=(--timestamp=none)
else
  CODESIGN_ARGS+=(--timestamp)
fi
if [[ "$ENABLE_HARDENED_RUNTIME" == "1" ]]; then
  CODESIGN_ARGS+=(--options runtime)
fi

printf 'Using signing identity: %s\n' "$SIGNING_IDENTITY"
printf 'Signing mode: %s\n' "$SIGNING_MODE"
printf 'Apple team ID: %s\n' "$TEAM_ID"
printf 'Build number: %s\n' "$BUILD_NUMBER"
printf 'Release version: %s\n' "$RELEASE_VERSION"
printf 'Hardened runtime: %s\n' "$ENABLE_HARDENED_RUNTIME"
printf 'Codesign timestamp: %s\n' "$CODESIGN_TIMESTAMP"
if [[ "$SIGNING_MODE" == "manual" ]] && \
   ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
  printf 'error: signing identity was not found in the keychain.\n' >&2
  printf 'Set SIGNING_IDENTITY to an installed codesigning identity, or install the Apple Development certificate for team %s.\n' "$TEAM_ID" >&2
  exit 1
fi

if [[ "$SIGNING_MODE" == "managed" ]]; then
  printf 'Building %s %s with Xcode-managed signing...\n' "$SCHEME" "$CONFIGURATION"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MARKETING_VERSION="$RELEASE_VERSION" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGNING_ALLOWED=YES \
    -allowProvisioningUpdates \
    build
else
  printf 'Building %s %s without Xcode-managed signing...\n' "$SCHEME" "$CONFIGURATION"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MARKETING_VERSION="$RELEASE_VERSION" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGNING_ALLOWED=NO \
    build

  printf 'Signing widget extension...\n'
  codesign "${CODESIGN_ARGS[@]}" \
    --entitlements "$EXTENSION_ENTITLEMENTS" \
    "$BUILT_EXTENSION"

  printf 'Signing app...\n'
  codesign "${CODESIGN_ARGS[@]}" \
    --entitlements "$APP_ENTITLEMENTS" \
    "$BUILT_APP"
fi

printf 'Verifying signed build...\n'
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
if [[ "$SIGNING_MODE" == "managed" ]]; then
  verify_managed_bundle "$BUILT_APP" "com.macmonitor.widget"
  verify_managed_bundle "$BUILT_EXTENSION" "$WIDGET_BUNDLE_ID"
fi

if [[ "$IS_LIVE_INSTALL" == "0" ]]; then
  printf 'Removing transient build-product registrations for the staging install.\n'
  pluginkit -r "$BUILT_EXTENSION" >/dev/null 2>&1 || true
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
  fi
fi

HAD_EXISTING_WIDGET_TIMELINE=0
if [[ "$IS_LIVE_INSTALL" == "1" ]]; then
  printf 'Quitting existing Pulse instance if it is running...\n'
  osascript -e 'tell application id "com.macmonitor.widget" to quit' >/dev/null 2>&1 || true
  terminate_process_at_path "$INSTALLED_APP_EXECUTABLE" "Pulse app"
  terminate_process_at_path "$LEGACY_INSTALLED_APP_EXECUTABLE" "legacy Pulse app"

  if find "$CHRONO_ROOT/timelines/$WIDGET_KIND" \
    -type f -name '*.chrono-timeline' -print -quit 2>/dev/null | grep -q .; then
    HAD_EXISTING_WIDGET_TIMELINE=1
  fi

  unregister_widget_copies_except
  if [[ -d "$INSTALLED_EXTENSION" ]]; then
    printf 'Unregistering the installed widget extension before replacement...\n'
    pluginkit -r "$INSTALLED_EXTENSION" >/dev/null 2>&1 || true
  fi
  terminate_process_at_path "$INSTALLED_EXTENSION_EXECUTABLE" "Pulse widget"
  reset_pulse_widget_cache
else
  printf 'Preserving the running Pulse app and widget state for this staging install.\n'
fi

printf 'Installing to %s...\n' "$INSTALL_PATH"
mkdir -p "$(dirname "$INSTALL_PATH")"
rsync -a --delete "$BUILT_APP/" "$INSTALL_PATH/"
touch "$INSTALL_PATH"

if [[ "$IS_LIVE_INSTALL" == "1" ]]; then
  printf 'Registering the installed Pulse app and widget extension...\n'
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f -R -trusted "$INSTALL_PATH"
  fi
  pluginkit -a "$INSTALLED_EXTENSION"
  terminate_process_at_path "$INSTALLED_EXTENSION_EXECUTABLE" "Pulse widget"
  unregister_widget_copies_except "$INSTALLED_EXTENSION"
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
  fi
else
  printf 'Leaving LaunchServices, PluginKit, and WidgetKit state unchanged.\n'
fi

printf 'Verifying installed app...\n'
codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"
codesign -d --entitlements :- "$INSTALL_PATH" >/dev/null
codesign -d --entitlements :- "$INSTALL_PATH/Contents/PlugIns/MacMonitorWidgetExtension.appex" >/dev/null

if [[ "$SIGNING_MODE" == "managed" ]]; then
  verify_managed_bundle "$INSTALL_PATH" "com.macmonitor.widget"
  verify_managed_bundle "$INSTALLED_EXTENSION" "$WIDGET_BUNDLE_ID"
fi

INSTALLED_APP_BUILD="$(plutil -extract CFBundleVersion raw -o - "$INSTALL_PATH/Contents/Info.plist")"
INSTALLED_WIDGET_BUILD="$(plutil -extract CFBundleVersion raw -o - "$INSTALLED_EXTENSION/Contents/Info.plist")"
if [[ "$INSTALLED_APP_BUILD" != "$BUILD_NUMBER" || "$INSTALLED_WIDGET_BUILD" != "$BUILD_NUMBER" ]]; then
  printf 'error: installed build numbers do not match requested build %s (app=%s, widget=%s).\n' \
    "$BUILD_NUMBER" "$INSTALLED_APP_BUILD" "$INSTALLED_WIDGET_BUILD" >&2
  exit 1
fi

INSTALLED_APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INSTALL_PATH/Contents/Info.plist")"
INSTALLED_WIDGET_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INSTALLED_EXTENSION/Contents/Info.plist")"
if [[ "$INSTALLED_APP_VERSION" != "$RELEASE_VERSION" || "$INSTALLED_WIDGET_VERSION" != "$RELEASE_VERSION" ]]; then
  printf 'error: installed versions do not match requested version %s (app=%s, widget=%s).\n' \
    "$RELEASE_VERSION" "$INSTALLED_APP_VERSION" "$INSTALLED_WIDGET_VERSION" >&2
  exit 1
fi

BUILT_WIDGET_HASH="$(shasum -a 256 "$BUILT_EXTENSION/Contents/MacOS/MacMonitorWidgetExtension" | awk '{print $1}')"
INSTALLED_WIDGET_HASH="$(shasum -a 256 "$INSTALLED_EXTENSION_EXECUTABLE" | awk '{print $1}')"
if [[ "$BUILT_WIDGET_HASH" != "$INSTALLED_WIDGET_HASH" ]]; then
  printf 'error: installed widget binary does not match the newly built extension.\n' >&2
  exit 1
fi

if [[ "$LAUNCH_AFTER_INSTALL" == "1" ]]; then
  printf 'Launching Pulse...\n'
  open "$INSTALL_PATH"

  APP_PID=""
  for _ in {1..50}; do
    APP_PID="$(process_ids_for_executable "$INSTALLED_APP_EXECUTABLE")"
    if [[ -n "$APP_PID" ]]; then
      break
    fi
    sleep 0.2
  done

  if [[ -z "$APP_PID" ]]; then
    printf 'error: the newly installed Pulse app did not launch from %s.\n' \
      "$INSTALLED_APP_EXECUTABLE" >&2
    exit 1
  fi

  REGISTERED_WIDGETS=""
  for _ in {1..50}; do
    REGISTERED_WIDGETS="$(pluginkit -m -v -i com.macmonitor.widget.extension 2>/dev/null || true)"
    if grep -Fq "$INSTALLED_EXTENSION" <<< "$REGISTERED_WIDGETS"; then
      break
    fi
    sleep 0.2
  done

  if ! grep -Fq "$INSTALLED_EXTENSION" <<< "$REGISTERED_WIDGETS"; then
    printf 'error: PluginKit did not register the installed widget extension at %s after launch.\n' \
      "$INSTALLED_EXTENSION" >&2
    exit 1
  fi

  REGISTERED_COUNT="$(registered_widget_paths | wc -l | tr -d ' ')"
  if [[ "$REGISTERED_COUNT" != "1" ]]; then
    printf 'error: expected one registered Pulse widget, found %s.\n' "$REGISTERED_COUNT" >&2
    registered_widget_paths >&2
    exit 1
  fi

  FRESH_TIMELINE=""
  if [[ "$HAD_EXISTING_WIDGET_TIMELINE" == "1" ]]; then
    for _ in {1..100}; do
      FRESH_TIMELINE="$(find "$CHRONO_ROOT/timelines/$WIDGET_KIND" \
        -type f -name '*.chrono-timeline' -print -quit 2>/dev/null || true)"
      if [[ -n "$FRESH_TIMELINE" ]]; then
        break
      fi
      sleep 0.2
    done
  fi

  if [[ -z "$FRESH_TIMELINE" && "$HAD_EXISTING_WIDGET_TIMELINE" == "1" ]]; then
    printf 'warning: WidgetKit has not regenerated the Pulse timeline yet; macOS may be throttling the refresh.\n' >&2
  elif [[ -z "$FRESH_TIMELINE" ]]; then
    printf 'warning: no Pulse widget timeline exists yet; add the widget to let WidgetKit create one.\n' >&2
  fi
else
  printf 'Skipping launch because LAUNCH_AFTER_INSTALL=%s.\n' "$LAUNCH_AFTER_INSTALL"
  if [[ "$IS_LIVE_INSTALL" == "1" ]]; then
    printf 'Pulse is registered but was not launched.\n'
  else
    printf 'The staging app was verified without changing the active Pulse installation.\n'
  fi
fi

printf 'Done.\n'
