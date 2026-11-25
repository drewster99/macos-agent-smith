#!/usr/bin/env bash
set -Eeuo pipefail

# Automated release builder for Agent Smith.
#
# Default behavior:
#   - bumps patch version (MARKETING_VERSION) and build number (CURRENT_PROJECT_VERSION)
#   - builds Release app with xcodebuild, signed with a Developer ID Application certificate
#     and the hardened runtime (both required for notarization)
#   - notarizes and staples the app, then creates a drag-to-Applications DMG
#   - signs, notarizes, staples, and verifies the DMG
#   - commits version bump, tags it, pushes to GitHub, creates/verifies GitHub release
#
# Examples:
#   ./release.sh                         # 1.0.0 -> 1.0.1, build 3 -> 4, publish
#   ./release.sh --version 1.0.0         # hold the version, still bump the build (first release)
#   ./release.sh --dry-run               # local visual/build test only; skips signing/notarization/publish
#   ./release.sh --notarize-dry-run      # dry-run, but still sign/notarize/staple app + DMG
#   ./release.sh --skip-github           # full signed/notarized local release; no commit/tag/push/release
#   ./release.sh --yes                   # skip confirmation prompt before publishing
#
# Signing/notarization configuration (one of the notarization auth methods is required
# for non-dry-run releases):
#   SIGNING_IDENTITY="Developer ID Application: ..." ./release.sh
#   NOTARY_PROFILE="agent-smith" ./release.sh
#   NOTARY_KEY=/path/AuthKey_ABC123.p8 NOTARY_KEY_ID=ABC123 NOTARY_ISSUER=UUID ./release.sh

APP_NAME="AgentSmith"
DISPLAY_NAME="Agent Smith"
REPO_SLUG="drewster99/macos-agent-smith"
PROJECT_REL="AgentSmith/AgentSmith.xcodeproj"
PROJECT_FILE="${PROJECT_REL}/project.pbxproj"
SCHEME="AgentSmith"
CONFIGURATION="Release"
BUNDLE_IDENTIFIER="com.nuclearcyborg.AgentSmith"
TEAM_ID="P8MA38JTXY"
ENTITLEMENTS_SOURCE="AgentSmith/AgentSmith/AgentSmith.entitlements"
# Entitlements the shipped app must actually carry. Agent Smith drives other apps via Apple
# Events and stores provider API keys in the Keychain; if a signing change silently drops
# either one, both features fail at runtime on the tester's machine and nowhere else. Checked
# against the signed binary rather than the .entitlements source for that reason.
REQUIRED_ENTITLEMENTS=(
  "com.apple.security.automation.apple-events"
  "keychain-access-groups"
)
# The Developer ID provisioning profile to embed. Empty means: find the one for this app among
# the profiles Xcode has downloaded (see find_provisioning_profile).
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}"
PROVISIONING_PROFILE_DIRS=(
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  "$HOME/Library/MobileDevice/Provisioning Profiles"
)
DMG_ICON_SIZE=128
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
# The shared Nuclear Cyborg notarytool keychain profile, already stored on this machine and
# used by the other NCC release scripts. Overridable, but defaulted so a release never stalls
# hunting for the name.
NOTARY_PROFILE="${NOTARY_PROFILE:-${NOTARYTOOL_PROFILE:-ncc-cli-notarytool}}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
NOTARIZATION_TIMEOUT="${NOTARIZATION_TIMEOUT:-30m}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

OVERRIDE_VERSION=""
SKIP_GITHUB=0
DRY_RUN=0
YES=0
KEEP_WORK=0
NOTARIZE_DRY_RUN=0
SKIP_SIGNING_AND_NOTARIZATION=0
SHOULD_SIGN_AND_NOTARIZE=1
NOTARY_ARGS=()

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --version X.Y.Z   Manually set release version instead of auto-incrementing patch.
                    Useful for minor/major bumps; build number still increments.
  --skip-github     Build the complete signed/notarized DMG after bumping version, but do
                    not commit/tag/push/create a GitHub release.
  --dry-run         Build and create a DMG using the current project version without modifying
                    project files or touching git/GitHub. By default this skips signing and
                    notarization so visual/build tests do not require Apple credentials.
  --notarize-dry-run
                    With --dry-run, still run the full Developer ID signing, app notarization,
                    app stapling, DMG signing, DMG notarization, and DMG stapling workflow.
  --skip-signing-and-notarization
                    Local testing escape hatch only. Allowed with --dry-run or --skip-github;
                    never allowed for a published GitHub release.
  --signing-identity NAME
                    Developer ID Application signing identity. Defaults to SIGNING_IDENTITY,
                    or auto-detects when exactly one Developer ID Application identity exists.
  --provisioning-profile PATH
                    Developer ID provisioning profile (.provisionprofile) to embed in the app.
                    Defaults to PROVISIONING_PROFILE, or the unexpired Developer ID profile for
                    ${BUNDLE_IDENTIFIER} that Xcode has downloaded. Xcode creates one when
                    an archive is exported for Direct Distribution.
  --notary-profile NAME
                    notarytool keychain profile name. Defaults to NOTARY_PROFILE or
                    NOTARYTOOL_PROFILE. Alternative auth: NOTARY_KEY (path to .p8)/
                    NOTARY_KEY_ID/NOTARY_ISSUER. (No env-var password path — secrets
                    must not ride in the environment.)
  --notarization-timeout DURATION
                    notarytool --wait timeout (default: ${NOTARIZATION_TIMEOUT}; examples: 30m, 1h).
  --yes             Do not prompt for confirmation before publishing to GitHub.
  --keep-work       Keep temporary DMG staging files for inspection/debugging.
  -h, --help        Show this help.

Default publishes a GitHub release and requires a fully signed/notarized/stapled DMG.
Use --dry-run for local unsigned visual/build testing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { echo "ERROR: --version requires X.Y.Z" >&2; exit 2; }
      OVERRIDE_VERSION="$2"
      shift 2
      ;;
    --skip-github)
      SKIP_GITHUB=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      SKIP_GITHUB=1
      shift
      ;;
    --notarize-dry-run)
      DRY_RUN=1
      SKIP_GITHUB=1
      NOTARIZE_DRY_RUN=1
      shift
      ;;
    --skip-signing-and-notarization)
      SKIP_SIGNING_AND_NOTARIZATION=1
      shift
      ;;
    --signing-identity)
      [[ $# -ge 2 ]] || { echo "ERROR: --signing-identity requires a certificate name" >&2; exit 2; }
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --provisioning-profile)
      [[ $# -ge 2 ]] || { echo "ERROR: --provisioning-profile requires a path to a .provisionprofile" >&2; exit 2; }
      PROVISIONING_PROFILE="$2"
      shift 2
      ;;
    --notary-profile)
      [[ $# -ge 2 ]] || { echo "ERROR: --notary-profile requires a notarytool keychain profile name" >&2; exit 2; }
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --notarization-timeout)
      [[ $# -ge 2 ]] || { echo "ERROR: --notarization-timeout requires a duration such as 30m or 1h" >&2; exit 2; }
      NOTARIZATION_TIMEOUT="$2"
      shift 2
      ;;
    --yes)
      YES=1
      shift
      ;;
    --keep-work)
      KEEP_WORK=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
success() { printf '\033[1;32mSUCCESS:\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR:\033[0m %b\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  echo >&2
  echo "ERROR: release.sh failed at line ${line_no} with exit code ${exit_code}." >&2
  echo "Last command: ${BASH_COMMAND}" >&2
  echo >&2
  echo "Useful checks:" >&2
  echo "  - xcodebuild errors are in build/release/logs/xcodebuild-*.log" >&2
  echo "  - GitHub CLI auth: gh auth status" >&2
  echo "  - Existing releases/tags: gh release list --repo ${REPO_SLUG}" >&2
  echo "  - Working tree: git status --short" >&2
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_file() {
  [[ -e "$1" ]] || fail "Required file/path not found: $1"
}

validate_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "Version must be X.Y or X.Y.Z, got: $1"
}

validate_release_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Release version must be semantic patch form X.Y.Z, got: $1"
}

current_setting() {
  local key="$1"
  local value
  value="$(grep -E "^[[:space:]]*${key} = " "$PROJECT_FILE" | head -n 1 | sed -E "s/.*${key} = ([^;]+);/\1/")"
  [[ -n "$value" ]] || fail "Could not read ${key} from ${PROJECT_FILE}"
  printf '%s' "$value"
}

increment_patch() {
  local version="$1"
  validate_version "$version"
  IFS=. read -r major minor patch <<< "$version"
  patch="${patch:-0}"
  printf '%s.%s.%s' "$major" "$minor" "$((patch + 1))"
}

increment_build() {
  local build="$1"
  [[ "$build" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION must be an integer, got: $build"
  printf '%s' "$((build + 1))"
}

# The app target carries these keys once per build configuration (Debug and Release), so the
# count check is what keeps a partial rewrite — one config updated, one missed — from shipping.
replace_project_setting() {
  local key="$1"
  local value="$2"
  local count
  count="$(grep -cE "^[[:space:]]*${key} = " "$PROJECT_FILE" || true)"
  [[ "$count" -gt 0 ]] || fail "No ${key} entries found in ${PROJECT_FILE}"
  /usr/bin/perl -0pi -e "s/${key} = [^;]+;/${key} = ${value};/g" "$PROJECT_FILE"
  local new_count
  new_count="$(grep -cE "^[[:space:]]*${key} = ${value};" "$PROJECT_FILE" || true)"
  [[ "$new_count" -eq "$count" ]] || fail "Expected to update ${count} ${key} entries to ${value}, updated ${new_count}"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

json_value() {
  local json_file="$1"
  local key="$2"
  python3 - "$json_file" "$key" <<'PYJSON'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    data = json.load(fh)
value = data.get(sys.argv[2], "")
print("" if value is None else value)
PYJSON
}

detect_signing_identity() {
  if [[ -n "$SIGNING_IDENTITY" ]]; then
    printf '%s' "$SIGNING_IDENTITY"
    return 0
  fi

  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application:/ {print $2}' | sort -u)"
  local count
  count="$(printf '%s\n' "$identities" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$count" -eq 1 ]]; then
    printf '%s' "$identities"
  elif [[ "$count" -eq 0 ]]; then
    fail "No Developer ID Application signing identity found. Install the certificate in Keychain Access or pass --signing-identity / SIGNING_IDENTITY. Current identities: $(security find-identity -v -p codesigning 2>&1 | tr '\n' '; ')"
  else
    fail "Multiple Developer ID Application identities found; pass --signing-identity or SIGNING_IDENTITY. Candidates: $(printf '%s' "$identities" | tr '\n' '; ')"
  fi
}

init_notary_auth() {
  NOTARY_ARGS=()
  if [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" ]]; then
    # NOTARY_KEY is a PATH to a .p8 file, not the secret itself — no secret rides in the environment.
    NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID")
    [[ -z "$NOTARY_ISSUER" ]] || NOTARY_ARGS+=(--issuer "$NOTARY_ISSUER")
  else
    # No app-specific-password path: passing a secret via an environment variable is disallowed.
    # Use the keychain profile (secret stays in the keychain) or an on-disk API key.
    fail "Notarization credentials are required for signed releases. Configure one of: --notary-profile/NOTARY_PROFILE (recommended; create with: xcrun notarytool store-credentials <profile>), or NOTARY_KEY (path to .p8) + NOTARY_KEY_ID (+ NOTARY_ISSUER)."
  fi
}

validate_notary_credentials() {
  local output status
  log "Validating notarytool credentials before building"
  set +e
  trap - ERR
  output="$(xcrun notarytool history "${NOTARY_ARGS[@]}" --output-format json 2>&1)"
  status=$?
  trap 'on_error $LINENO' ERR
  set -e
  if [[ "$status" -ne 0 ]]; then
    [[ -z "$output" ]] || echo "$output" >&2
    fail "notarytool credential validation failed. Re-run 'xcrun notarytool store-credentials <profile>' or check NOTARY_* environment variables before releasing."
  fi
  success "notarytool credentials validated"
}

run_checked() {
  local description="$1"
  shift
  local output status
  set +e
  trap - ERR
  output="$("$@" 2>&1)"
  status=$?
  trap 'on_error $LINENO' ERR
  set -e
  if [[ "$status" -ne 0 ]]; then
    [[ -z "$output" ]] || echo "$output" >&2
    fail "${description} failed with status ${status}."
  fi
  [[ -z "$output" ]] || echo "$output" >&2
}

# Prints the path of the Developer ID provisioning profile to embed, or fails saying why none
# qualifies. A profile qualifies when it is for exactly this app (team + bundle identifier), is a
# Developer ID profile (provisions all devices), has not expired, and names the certificate we
# sign with — macOS rejects a profile that does not list the signing certificate. With
# PROVISIONING_PROFILE set, only that file is considered, and it must still qualify. Among several
# that qualify, the one that expires last wins.
find_provisioning_profile() {
  local identity_hash
  identity_hash="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -v identity="$SIGNING_IDENTITY" 'index($0, "\"" identity "\"") || $2 == identity {print $2; exit}')"
  [[ -n "$identity_hash" ]] || fail "Could not find the certificate hash of the signing identity '${SIGNING_IDENTITY}'."

  local -a candidates=()
  if [[ -n "$PROVISIONING_PROFILE" ]]; then
    [[ -f "$PROVISIONING_PROFILE" ]] || fail "Provisioning profile not found: $PROVISIONING_PROFILE"
    candidates=("$PROVISIONING_PROFILE")
  else
    local directory profile
    for directory in "${PROVISIONING_PROFILE_DIRS[@]}"; do
      [[ -d "$directory" ]] || continue
      while IFS= read -r profile; do
        candidates+=("$profile")
      done < <(find "$directory" -maxdepth 1 -name "*.provisionprofile")
    done
  fi
  [[ "${#candidates[@]}" -gt 0 ]] || fail "No .provisionprofile files found in: ${PROVISIONING_PROFILE_DIRS[*]}. Export an archive for Direct Distribution in Xcode once (it creates the Developer ID profile), or pass --provisioning-profile."

  local decoded_dir
  decoded_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-smith-profiles.XXXXXX")"
  local index=0 candidate
  for candidate in "${candidates[@]}"; do
    # A profile that will not decode cannot qualify; the selection below reports what it saw.
    security cms -D -i "$candidate" > "$decoded_dir/$index.plist" 2>/dev/null || rm -f "$decoded_dir/$index.plist"
    printf '%s\n' "$candidate" > "$decoded_dir/$index.path"
    index=$((index + 1))
  done

  # The program goes to a file first: bash 3.2 (what macOS ships) misparses a here-document
  # holding an apostrophe when it sits inside a command substitution.
  cat > "$decoded_dir/select.py" <<'PY'
import datetime, hashlib, pathlib, plistlib, sys

decoded_dir, application_identifier, identity_hash = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3].lower()
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
qualifying, rejected = [], []
for path_file in sorted(decoded_dir.glob("*.path")):
    profile_path = path_file.read_text().rstrip("\n")
    plist_file = path_file.with_suffix(".plist")
    if not plist_file.exists():
        rejected.append(f"{profile_path}: could not be decoded")
        continue
    with plist_file.open("rb") as handle:
        profile = plistlib.load(handle)
    if profile.get("Entitlements", {}).get("com.apple.application-identifier") != application_identifier:
        continue  # another app's profile: not worth reporting
    name = profile.get("Name", "(unnamed)")
    if profile.get("ProvisionsAllDevices") is not True:
        rejected.append(f"{profile_path} ({name}): not a Developer ID profile")
    elif profile["ExpirationDate"] <= now:
        rejected.append(f"{profile_path} ({name}): expired {profile['ExpirationDate']}")
    elif identity_hash not in {hashlib.sha1(certificate).hexdigest() for certificate in profile.get("DeveloperCertificates", [])}:
        rejected.append(f"{profile_path} ({name}): does not list the signing certificate")
    else:
        qualifying.append((profile["ExpirationDate"], profile_path))
if not qualifying:
    print(f"No qualifying Developer ID provisioning profile for {application_identifier}.", file=sys.stderr)
    for reason in rejected:
        print(f"  - {reason}", file=sys.stderr)
    sys.exit(1)
print(max(qualifying)[1])
PY
  local selection status
  set +e
  trap - ERR
  selection="$(python3 "$decoded_dir/select.py" "$decoded_dir" "${TEAM_ID}.${BUNDLE_IDENTIFIER}" "$identity_hash")"
  status=$?
  trap 'on_error $LINENO' ERR
  set -e
  rm -rf "$decoded_dir"
  [[ "$status" -eq 0 && -n "$selection" ]] \
    || fail "No usable provisioning profile. Export an archive for Direct Distribution in Xcode once (it creates the Developer ID profile), or pass --provisioning-profile."
  printf '%s' "$selection"
}

# Writes the entitlements codesign is handed: the source file with $(CFBundleIdentifier)
# expanded, plus the two identifiers that tie the app to its provisioning profile. Xcode adds
# those itself when it signs; we sign by hand, so we add them. Without them the profile is not
# matched to the app and macOS kills it at launch for holding `keychain-access-groups`.
resolve_entitlements() {
  local output="$1"
  /usr/bin/sed "s|\$(CFBundleIdentifier)|${BUNDLE_IDENTIFIER}|g" "$ENTITLEMENTS_SOURCE" > "$output"
  run_checked "Adding the application identifier entitlement" \
    /usr/bin/plutil -insert "com\.apple\.application-identifier" -string "${TEAM_ID}.${BUNDLE_IDENTIFIER}" "$output"
  run_checked "Adding the team identifier entitlement" \
    /usr/bin/plutil -insert "com\.apple\.developer\.team-identifier" -string "$TEAM_ID" "$output"
  run_checked "Entitlements plist validation" /usr/bin/plutil -lint "$output"
  grep -q "${TEAM_ID}.${BUNDLE_IDENTIFIER}" "$output" \
    || fail "Resolved entitlements do not contain the team-qualified keychain group '${TEAM_ID}.${BUNDLE_IDENTIFIER}'. Check ${ENTITLEMENTS_SOURCE}."
}

# Signed here rather than by xcodebuild: the build produces an unsigned app and we embed the
# Developer ID provisioning profile and sign it ourselves, with --entitlements.
#
# The profile is REQUIRED. `keychain-access-groups` is a restricted entitlement, and macOS
# honors it only when an embedded profile authorizes it. Until 2026-11-24 this script signed
# without one, on the belief that a keychain group under the team's own prefix needs none. The
# result was signed, notarized, stapled and accepted by Gatekeeper — and killed by the kernel
# at launch ("Code has restricted entitlements… Unsatisfied Entitlements"). verify_app_launches
# exists because none of the other checks can see that.
#
# Inside-out, and explicitly rather than with --deep: nested code must be signed before the
# bundle that contains it, and only the outer app gets the entitlements. The SPM resource
# bundles get none of their own.
sign_app() {
  local app_path="$1"
  local entitlements="$2"
  local provisioning_profile="$3"
  log "Embedding provisioning profile: ${provisioning_profile}"
  # Before signing: the profile is part of what the app's signature seals.
  cp "$provisioning_profile" "$app_path/Contents/embedded.provisionprofile"
  log "Signing nested code, then the app, with: ${SIGNING_IDENTITY}"

  local nested
  while IFS= read -r nested; do
    [[ -n "$nested" ]] || continue
    run_checked "Signing nested $(basename "$nested")" \
      codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$nested"
  done < <(find "$app_path/Contents" -maxdepth 3 \( -name "*.bundle" -o -name "*.framework" -o -name "*.dylib" -o -name "*.app" \))

  run_checked "App code signing" \
    codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$SIGNING_IDENTITY" "$app_path"
}

# Proves the signed app is what notarization requires, independent of how it got signed.
verify_app_signature() {
  local app_path="$1"
  log "Verifying Developer ID signature, hardened runtime, and entitlements"

  run_checked "App signature verification" codesign --verify --deep --strict --verbose=4 "$app_path"

  local details
  details="$(codesign --display --verbose=4 "$app_path" 2>&1)"

  printf '%s' "$details" | grep -q "Authority=Developer ID Application" \
    || fail "App is not signed with a Developer ID Application certificate; notarization will reject it.\n${details}"

  # Hardened runtime shows up as the `runtime` flag on the code signature. Notarization has
  # required it for all new software since February 2020.
  printf '%s' "$details" | grep -qE '^CodeDirectory .*flags=.*runtime' \
    || fail "App is not signed with the hardened runtime (no 'runtime' flag on the code directory); notarization will reject it.\n${details}"

  local entitlements
  entitlements="$(codesign --display --entitlements - --xml "$app_path" 2>/dev/null || true)"
  [[ -n "$entitlements" ]] || fail "Could not read entitlements from the signed app: $app_path"
  local entitlement
  for entitlement in "${REQUIRED_ENTITLEMENTS[@]}"; do
    printf '%s' "$entitlements" | grep -q "$entitlement" \
      || fail "Signed app is missing the required entitlement '${entitlement}'. Check CODE_SIGN_ENTITLEMENTS on the ${SCHEME} target."
  done

  # Presence of the key is not enough: an unresolved $(AppIdentifierPrefix) yields the
  # syntactically valid but useless group ".${BUNDLE_IDENTIFIER}", and the failure would only
  # show up as "cannot read my API keys" on someone else's Mac.
  printf '%s' "$entitlements" | grep -q "${TEAM_ID}.${BUNDLE_IDENTIFIER}" \
    || fail "Keychain access group is not team-qualified — expected '${TEAM_ID}.${BUNDLE_IDENTIFIER}'. An unresolved \$(AppIdentifierPrefix) will silently break Keychain access for provider API keys.\n${entitlements}"

  [[ -s "$app_path/Contents/embedded.provisionprofile" ]] \
    || fail "Signed app has no embedded provisioning profile; macOS will kill it at launch for its restricted entitlements."
  printf '%s' "$entitlements" | grep -q "com.apple.application-identifier" \
    || fail "Signed app is missing 'com.apple.application-identifier', which ties it to its provisioning profile.\n${entitlements}"

  success "Signature, hardened runtime, and entitlements verified: $app_path"
}

# Proves macOS will actually start the app. Signature verification, notarization and Gatekeeper
# all pass on an app the kernel then refuses to load, so this is the only check of that.
#
# The executable is started SUSPENDED and killed before it runs a single instruction: the
# kernel validates the code signature and entitlements while loading it, which is all we are
# asking about. Running the app for real here would start a second Agent Smith against the
# user's live data.
verify_app_launches() {
  local app_path="$1"
  log "Checking that macOS will load the signed app"
  # Written to a file first for the same bash 3.2 reason as in find_provisioning_profile.
  local checker
  checker="$(mktemp "${TMPDIR:-/tmp}/agent-smith-launch-check.XXXXXX")"
  cat > "$checker" <<'PY'
import ctypes, os, signal, sys, time

POSIX_SPAWN_START_SUSPENDED = 0x0080
libc = ctypes.CDLL(None, use_errno=True)
executable = sys.argv[1].encode()
attributes = ctypes.c_void_p()
if libc.posix_spawnattr_init(ctypes.byref(attributes)) != 0:
    sys.exit("posix_spawnattr_init failed")
if libc.posix_spawnattr_setflags(ctypes.byref(attributes), ctypes.c_short(POSIX_SPAWN_START_SUSPENDED)) != 0:
    sys.exit("posix_spawnattr_setflags failed")
pid = ctypes.c_int()
arguments = (ctypes.c_char_p * 2)(executable, None)
environment = (ctypes.c_char_p * 1)(None)
error = libc.posix_spawn(ctypes.byref(pid), executable, None, ctypes.byref(attributes), arguments, environment)
libc.posix_spawnattr_destroy(ctypes.byref(attributes))
if error != 0:
    sys.exit(f"macOS refused to start it: posix_spawn error {error} ({os.strerror(error)})")
# A refused executable is killed within milliseconds; a suspended one stays until we end it.
deadline = time.monotonic() + 3
while time.monotonic() < deadline:
    finished, wait_status = os.waitpid(pid.value, os.WNOHANG)
    if finished:
        sys.exit(f"macOS killed it at launch (wait status {wait_status})")
    time.sleep(0.1)
os.kill(pid.value, signal.SIGKILL)
os.waitpid(pid.value, 0)
PY
  local output status
  set +e
  trap - ERR
  output="$(python3 "$checker" "$app_path/Contents/MacOS/${APP_NAME}" 2>&1)"
  status=$?
  trap 'on_error $LINENO' ERR
  set -e
  rm -f "$checker"
  if [[ "$status" -ne 0 ]]; then
    fail "The signed app will not launch: ${output}\nUsually a restricted entitlement the embedded provisioning profile does not authorize. Look for 'Unsatisfied Entitlements' with: /usr/bin/log show --last 2m --predicate 'sender == \"AppleMobileFileIntegrity\" OR process == \"kernel\"' | grep ${APP_NAME}"
  fi
  success "macOS loads the signed app"
}

create_notarization_zip() {
  local app_path="$1"
  local zip_path="$2"
  rm -f "$zip_path"
  log "Creating notarization ZIP for app"
  run_checked "App ZIP creation" ditto -c -k --keepParent "$app_path" "$zip_path"
  [[ -s "$zip_path" ]] || fail "Notarization ZIP was not created: $zip_path"
}

notarize_artifact() {
  local artifact_path="$1"
  local label="$2"
  local json_path="$3"
  local log_path="${json_path%.json}-log.json"

  log "Submitting ${label} for notarization and waiting up to ${NOTARIZATION_TIMEOUT}"
  rm -f "$json_path" "$log_path"
  set +e
  set +E
  xcrun notarytool submit "$artifact_path" "${NOTARY_ARGS[@]}" --wait --timeout "$NOTARIZATION_TIMEOUT" --output-format json >"$json_path" 2>"${json_path%.json}.stderr"
  local submit_status=$?
  set -E
  set -e
  if [[ "$submit_status" -ne 0 ]]; then
    [[ ! -s "${json_path%.json}.stderr" ]] || cat "${json_path%.json}.stderr" >&2
    [[ ! -s "$json_path" ]] || cat "$json_path" >&2
    fail "Notarization upload/wait failed for ${label}. Check credentials, network access, and Apple notary service status. Output: $json_path"
  fi

  local notary_status submission_id
  notary_status="$(json_value "$json_path" status)"
  submission_id="$(json_value "$json_path" id)"
  if [[ "$notary_status" != "Accepted" ]]; then
    warn "Notarization status for ${label}: ${notary_status:-unknown}"
    if [[ -n "$submission_id" ]]; then
      set +e
      set +E
      xcrun notarytool log "$submission_id" "${NOTARY_ARGS[@]}" --output-format json >"$log_path" 2>"${log_path%.json}.stderr"
      local log_status=$?
      set -E
      set -e
      if [[ "$log_status" -eq 0 && -s "$log_path" ]]; then
        cat "$log_path" >&2
        fail "Notarization rejected ${label}. Review the notary log above and at: $log_path"
      fi
    fi
    fail "Notarization did not accept ${label}. Status: ${notary_status:-unknown}. Submission JSON: $json_path"
  fi
  success "Notarization accepted ${label} (submission ${submission_id})"
}

staple_and_validate() {
  local path="$1"
  local label="$2"
  log "Stapling notarization ticket to ${label}"
  run_checked "Stapling ${label}" xcrun stapler staple "$path"
  run_checked "Stapler validation for ${label}" xcrun stapler validate "$path"
  success "Stapled and validated ${label}"
}

# The one check that answers the question a tester actually asks: will this open by
# double-clicking? Everything above verifies inputs to that; this verifies the outcome.
assess_gatekeeper() {
  local app_path="$1"
  log "Asking Gatekeeper to assess the stapled app"
  run_checked "Gatekeeper assessment" spctl --assess --type exec --verbose=4 "$app_path"
  success "Gatekeeper accepts the app"
}

sign_dmg() {
  local dmg_path="$1"
  log "Signing DMG with Developer ID identity: ${SIGNING_IDENTITY}"
  run_checked "DMG code signing" codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$dmg_path"
  run_checked "DMG signature verification" codesign --verify --verbose=4 "$dmg_path"
  success "Signed and verified DMG: $dmg_path"
}

create_background_png() {
  local output="$1"
  local title="$2"
  /usr/bin/swift - "$output" "$title" <<'SWIFT'
import AppKit
import Foundation

let output = CommandLine.arguments[1]
let title = CommandLine.arguments[2]
let size = NSSize(width: 640, height: 420)
let image = NSImage(size: size)
image.lockFocus()

let rect = NSRect(origin: .zero, size: size)
let bg = NSGradient(starting: NSColor(calibratedWhite: 0.972, alpha: 1),
                    ending: NSColor(calibratedWhite: 0.925, alpha: 1))!
bg.draw(in: rect, angle: 90)

let accent = NSColor(calibratedRed: 0.12, green: 0.53, blue: 0.90, alpha: 1)
let titleColor = NSColor(calibratedWhite: 0.11, alpha: 1)
let subtitleColor = NSColor(calibratedRed: 0.43, green: 0.43, blue: 0.45, alpha: 1)

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
    .foregroundColor: titleColor
]
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(at: NSPoint(x: (size.width - titleSize.width) / 2, y: 350), withAttributes: titleAttrs)

let subtitle = "Drag the app to Applications"
let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: subtitleColor
]
let subtitleSize = subtitle.size(withAttributes: subtitleAttrs)
subtitle.draw(at: NSPoint(x: (size.width - subtitleSize.width) / 2, y: 322), withAttributes: subtitleAttrs)

// Finder draws the app icon, the Applications symlink, and both filename labels on top of this
// background, so nothing is painted at the icon positions. The arrow goes between them.
let path = NSBezierPath()
let arrowStart = NSPoint(x: 250, y: 205)
let arrowEnd = NSPoint(x: 390, y: 205)
let control1 = NSPoint(x: 292, y: 245)
let control2 = NSPoint(x: 348, y: 245)
path.move(to: arrowStart)
path.curve(to: arrowEnd, controlPoint1: control1, controlPoint2: control2)
accent.setStroke()
path.lineWidth = 7
path.lineCapStyle = .round
path.stroke()

// For a cubic Bezier, the tangent at the endpoint is B'(1) = 3 * (P3 - P2).
// Here that vector is (42, -40), so the arrowhead needs to angle down-right rather than horizontally.
let tangent = CGVector(dx: arrowEnd.x - control2.x, dy: arrowEnd.y - control2.y)
let tangentAngle = atan2(tangent.dy, tangent.dx)
let arrowHeadLength: CGFloat = 31
let arrowHeadSpread: CGFloat = CGFloat.pi / 5.0
func arrowHeadPoint(_ sign: CGFloat) -> NSPoint {
    let angle = tangentAngle + CGFloat.pi + sign * arrowHeadSpread
    return NSPoint(x: arrowEnd.x + cos(angle) * arrowHeadLength,
                   y: arrowEnd.y + sin(angle) * arrowHeadLength)
}

let arrow = NSBezierPath()
arrow.move(to: arrowEnd)
arrow.line(to: arrowHeadPoint(1))
arrow.move(to: arrowEnd)
arrow.line(to: arrowHeadPoint(-1))
arrow.lineWidth = 7
arrow.lineCapStyle = .round
accent.setStroke()
arrow.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Could not render DMG background PNG\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
SWIFT
  [[ -s "$output" ]] || fail "Failed to create DMG background image at $output"
}

# Applies the DMG's Finder presentation (window size, icon view, positions, background).
# This step is timing-sensitive: Finder applies these asynchronously and only persists them to
# the volume's .DS_Store on its own schedule, so we use generous delays, re-assert the window
# bounds (setting the background picture can resize the window), and run a second pass because
# Finder sometimes drops the first one. The caller must still pause before unmounting so the
# .DS_Store is flushed to disk.
run_finder_layout() {
  local volume_name="$1"
  local mount_dir="$2"
  local background_path="$3"
  /usr/bin/osascript <<APPLESCRIPT
try
  set mountedFolder to POSIX file "${mount_dir}" as alias
  delay 2
  tell application "Finder"
    repeat 2 times
      open mountedFolder
      delay 2
      set dmgWindow to Finder window 1
      set current view of dmgWindow to icon view
      set toolbar visible of dmgWindow to false
      set statusbar visible of dmgWindow to false
      set the bounds of dmgWindow to {100, 100, 740, 520}
      set viewOptions to the icon view options of dmgWindow
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to ${DMG_ICON_SIZE}
      set background picture of viewOptions to POSIX file "${background_path}"
      delay 1
      set position of item "${APP_NAME}.app" of mountedFolder to {180, 215}
      set position of item "Applications" of mountedFolder to {460, 215}
      set the bounds of dmgWindow to {100, 100, 740, 520}
      delay 1
      update mountedFolder without registering applications
      delay 2
      close dmgWindow
      delay 1
    end repeat
  end tell
  return "Finder DMG layout applied successfully for ${volume_name}"
on error errMsg number errNum
  return "ERROR applying Finder DMG layout (" & errNum & "): " & errMsg
end try
APPLESCRIPT
}

make_dmg() {
  local app_path="$1"
  local version="$2"
  local dist_dir="$ROOT_DIR/build/release/dist"
  local work_dir="$ROOT_DIR/build/release/dmg-work"
  local volume_name="${DISPLAY_NAME} ${version}"
  local dmg_name="${APP_NAME}-${version}.dmg"
  local rw_dmg="$work_dir/${APP_NAME}-${version}-rw.dmg"
  local final_dmg="$dist_dir/$dmg_name"

  rm -rf "$work_dir"
  mkdir -p "$work_dir/staging/.background" "$dist_dir"
  rm -f "$final_dmg" "$rw_dmg"

  log "Preparing DMG staging area"
  ditto "$app_path" "$work_dir/staging/${APP_NAME}.app"
  ln -s /Applications "$work_dir/staging/Applications"
  create_background_png "$work_dir/staging/.background/background.png" "$DISPLAY_NAME"

  local size_mb
  size_mb="$(( $(du -sm "$work_dir/staging" | awk '{print $1}') + 80 ))"

  if [[ -d "/Volumes/${volume_name}" ]]; then
    warn "Detaching stale volume left mounted from a previous run: /Volumes/${volume_name}"
    hdiutil detach "/Volumes/${volume_name}" -force >/dev/null 2>&1 || true
  fi

  log "Creating writable DMG (${size_mb} MB)"
  hdiutil create -volname "$volume_name" -srcfolder "$work_dir/staging" -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${size_mb}m" "$rw_dmg" >/dev/null

  log "Mounting DMG to apply Finder presentation"
  local attach_output mount_dir device
  attach_output="$(hdiutil attach -readwrite -noverify -noautoopen "$rw_dmg")"
  mount_dir="$(printf '%s\n' "$attach_output" | awk '/\/Volumes\// {print substr($0, index($0,"/Volumes/")); exit}')"
  device="$(printf '%s\n' "$attach_output" | awk '/^\/dev\// {print $1; exit}')"
  [[ -n "$mount_dir" && -d "$mount_dir" ]] || fail "Could not determine DMG mount point. hdiutil output: $attach_output"
  [[ -n "$device" ]] || fail "Could not determine DMG device. hdiutil output: $attach_output"

  local layout_output
  set +e
  layout_output="$(run_finder_layout "$volume_name" "$mount_dir" "$mount_dir/.background/background.png")"
  local layout_status=$?
  echo "$layout_output" >&2
  # Give Finder time to flush the volume's .DS_Store to disk before we unmount.
  sleep 3
  sync
  # Finder may briefly keep the volume busy after closing its window; retry the detach.
  local detach_status=1 attempt
  for attempt in 1 2 3 4 5; do
    if hdiutil detach "$device" >/dev/null 2>&1; then detach_status=0; break; fi
    sleep 2
  done
  if [[ "$detach_status" -ne 0 ]]; then
    hdiutil detach "$device" -force >/dev/null 2>&1 && detach_status=0
  fi
  set -e
  [[ "$detach_status" -eq 0 ]] || fail "Could not detach temporary DMG device ${device} after retries"
  [[ "$layout_status" -eq 0 ]] || fail "Finder DMG layout command failed with status ${layout_status}"
  [[ "$layout_output" != ERROR* ]] || fail "$layout_output"

  log "Converting DMG to compressed read-only image"
  hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$final_dmg" >/dev/null
  hdiutil verify "$final_dmg" >/dev/null

  if [[ "$KEEP_WORK" -eq 0 ]]; then
    rm -rf "$work_dir"
  else
    warn "Keeping DMG work directory: $work_dir"
  fi

  [[ -s "$final_dmg" ]] || fail "Final DMG was not created: $final_dmg"
  printf '%s' "$final_dmg"
}

confirm_publish() {
  [[ "$YES" -eq 1 ]] && return 0
  cat <<EOF

About to publish GitHub release:
  Repository: ${REPO_SLUG}
  Version:    ${NEW_VERSION}
  Tag:        ${TAG}
  DMG:        ${DMG_PATH}
  Signing:    Developer ID signed, hardened runtime, notarized, and stapled app + DMG

This will commit the version bump, push main + tag, and create a public GitHub release.
EOF
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || fail "Publish cancelled by user. Local DMG remains at: ${DMG_PATH}"
}

release_notes() {
  local version="$1"
  local previous_tag
  previous_tag="$(git tag --list 'v*' --sort=-v:refname | grep -v "^v${version}$" | head -n 1 || true)"
  {
    echo "Release ${version} of ${DISPLAY_NAME}."
    echo
    echo "## Install"
    echo "1. Download the DMG asset below."
    echo "2. Open it and drag ${DISPLAY_NAME} to Applications."
    echo "3. Launch the app from Applications."
    echo
    echo "Requires macOS 26.2 or later. The app is Developer ID signed and notarized by Apple."
    echo
    echo "## Changes"
    if [[ -n "$previous_tag" ]]; then
      git log --pretty='- %s (%h)' "${previous_tag}..HEAD"
    else
      git log --pretty='- %s (%h)' --max-count=20
    fi
  } > "$ROOT_DIR/build/release/RELEASE_NOTES_${version}.md"
  printf '%s' "$ROOT_DIR/build/release/RELEASE_NOTES_${version}.md"
}

log "Checking prerequisites"
require_cmd git
require_cmd xcodebuild
require_cmd hdiutil
require_cmd osascript
require_cmd swift
require_cmd perl
require_cmd awk
require_cmd ditto
require_cmd lipo
require_file "$PROJECT_FILE"
require_file "$ENTITLEMENTS_SOURCE"

if [[ "$SKIP_GITHUB" -eq 0 ]]; then
  require_cmd gh
  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run: gh auth login"
fi

if [[ "$DRY_RUN" -eq 1 && "$NOTARIZE_DRY_RUN" -eq 0 ]]; then
  SHOULD_SIGN_AND_NOTARIZE=0
fi
if [[ "$SKIP_SIGNING_AND_NOTARIZATION" -eq 1 ]]; then
  SHOULD_SIGN_AND_NOTARIZE=0
fi
if [[ "$SHOULD_SIGN_AND_NOTARIZE" -eq 0 && "$SKIP_GITHUB" -eq 0 ]]; then
  fail "Published releases must be signed, notarized, and stapled. Do not use --skip-signing-and-notarization for GitHub publishing."
fi

if [[ "$SHOULD_SIGN_AND_NOTARIZE" -eq 1 ]]; then
  require_cmd codesign
  require_cmd xcrun
  require_cmd security
  require_cmd spctl
  require_cmd python3
  SIGNING_IDENTITY="$(detect_signing_identity)"
  # Resolved up front so a missing or expired profile stops the release before the build.
  PROVISIONING_PROFILE="$(find_provisioning_profile)"
  init_notary_auth
  validate_notary_credentials
  success "Signing/notarization enabled with identity: ${SIGNING_IDENTITY}"
  success "Provisioning profile: ${PROVISIONING_PROFILE}"
else
  warn "Signing/notarization is disabled for this local test build. Published releases always require the full workflow."
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ -z "$(git status --porcelain)" ]] || fail "Working tree is not clean. Commit/stash changes first, or use --dry-run.\n$(git status --short)"
fi

OLD_VERSION="$(current_setting MARKETING_VERSION)"
OLD_BUILD="$(current_setting CURRENT_PROJECT_VERSION)"
validate_version "$OLD_VERSION"

if [[ -n "$OVERRIDE_VERSION" ]]; then
  validate_release_version "$OVERRIDE_VERSION"
  NEW_VERSION="$OVERRIDE_VERSION"
else
  NEW_VERSION="$(increment_patch "$OLD_VERSION")"
fi
NEW_BUILD="$(increment_build "$OLD_BUILD")"
TAG="v${NEW_VERSION}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  NEW_VERSION="$OLD_VERSION"
  NEW_BUILD="$OLD_BUILD"
  TAG="v${NEW_VERSION}-dry-run"
  log "Dry run: using existing version ${NEW_VERSION} (${NEW_BUILD}); project files will not be modified"
else
  log "Bumping version: ${OLD_VERSION} (${OLD_BUILD}) -> ${NEW_VERSION} (${NEW_BUILD})"
  replace_project_setting MARKETING_VERSION "$NEW_VERSION"
  replace_project_setting CURRENT_PROJECT_VERSION "$NEW_BUILD"
fi

BUILD_ROOT="$ROOT_DIR/build/release"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
LOG_DIR="$BUILD_ROOT/logs"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
XCODE_LOG="$LOG_DIR/xcodebuild-${TIMESTAMP}.log"
mkdir -p "$LOG_DIR"

# The build never signs; sign_app does, afterwards, after embedding the provisioning profile.
SIGNING_BUILD_SETTINGS=(CODE_SIGNING_ALLOWED=NO)

log "Building ${APP_NAME} Release with xcodebuild"
rm -rf "$DERIVED_DATA"
set +e
xcodebuild \
  -project "$PROJECT_REL" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'generic/platform=macOS' \
  clean build \
  "${SIGNING_BUILD_SETTINGS[@]}" \
  2>&1 | tee "$XCODE_LOG"
XCODE_STATUS=${PIPESTATUS[0]}
set -e
if [[ "$XCODE_STATUS" -ne 0 ]]; then
  fail "xcodebuild failed with status ${XCODE_STATUS}. See log: $XCODE_LOG"
fi

APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
require_file "$APP_PATH/Contents/Info.plist"
[[ -x "$APP_PATH/Contents/MacOS/${APP_NAME}" ]] || fail "Built app executable missing or not executable: $APP_PATH/Contents/MacOS/${APP_NAME}"

BUILT_VERSION="$(plist_value "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)"
BUILT_BUILD="$(plist_value "$APP_PATH/Contents/Info.plist" CFBundleVersion)"
BUILT_BUNDLE_ID="$(plist_value "$APP_PATH/Contents/Info.plist" CFBundleIdentifier)"
[[ "$BUILT_VERSION" == "$NEW_VERSION" ]] || fail "Built app version mismatch: expected ${NEW_VERSION}, got ${BUILT_VERSION}"
[[ "$BUILT_BUILD" == "$NEW_BUILD" ]] || fail "Built app build mismatch: expected ${NEW_BUILD}, got ${BUILT_BUILD}"
[[ "$BUILT_BUNDLE_ID" == "$BUNDLE_IDENTIFIER" ]] || fail "Built app bundle identifier mismatch: expected ${BUNDLE_IDENTIFIER}, got ${BUILT_BUNDLE_ID}"

# Apple Silicon only, deliberately: semantic memory embeds on MLX, which has no Intel
# implementation. An x86_64 slice would let an Intel Mac install and launch the app and then
# fail inside memory retrieval — an arm64-only binary is refused up front by Launch Services,
# which is the honest outcome. ARCHS is set on the app target; this catches it being undone.
BUILT_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/${APP_NAME}")"
[[ "$BUILT_ARCHS" == "arm64" ]] || fail "Built app must be arm64-only, got: ${BUILT_ARCHS}. Check ARCHS on the ${SCHEME} target."
success "Built ${APP_NAME}.app version ${BUILT_VERSION} (${BUILT_BUILD}), arm64"

if [[ "$SHOULD_SIGN_AND_NOTARIZE" -eq 1 ]]; then
  APP_NOTARY_ZIP="$BUILD_ROOT/${APP_NAME}-${NEW_VERSION}-app-notarization.zip"
  APP_NOTARY_JSON="$BUILD_ROOT/notary-${APP_NAME}-${NEW_VERSION}-app.json"
  RESOLVED_ENTITLEMENTS="$BUILD_ROOT/${APP_NAME}-resolved.entitlements"
  resolve_entitlements "$RESOLVED_ENTITLEMENTS"
  sign_app "$APP_PATH" "$RESOLVED_ENTITLEMENTS" "$PROVISIONING_PROFILE"
  verify_app_signature "$APP_PATH"
  # Before notarizing: no point asking Apple to notarize an app that cannot start.
  verify_app_launches "$APP_PATH"
  create_notarization_zip "$APP_PATH" "$APP_NOTARY_ZIP"
  notarize_artifact "$APP_NOTARY_ZIP" "${APP_NAME}.app" "$APP_NOTARY_JSON"
  staple_and_validate "$APP_PATH" "${APP_NAME}.app"
  assess_gatekeeper "$APP_PATH"
  verify_app_launches "$APP_PATH"
fi

log "Creating drag-to-Applications DMG"
DMG_PATH="$(make_dmg "$APP_PATH" "$NEW_VERSION")"
success "Created DMG: $DMG_PATH"

if [[ "$SHOULD_SIGN_AND_NOTARIZE" -eq 1 ]]; then
  DMG_NOTARY_JSON="$BUILD_ROOT/notary-${APP_NAME}-${NEW_VERSION}-dmg.json"
  sign_dmg "$DMG_PATH"
  notarize_artifact "$DMG_PATH" "DMG" "$DMG_NOTARY_JSON"
  staple_and_validate "$DMG_PATH" "DMG"
  run_checked "Final DMG verification" hdiutil verify "$DMG_PATH"
  success "Final DMG is signed, notarized, stapled, and verified: $DMG_PATH"
fi

if [[ "$SKIP_GITHUB" -eq 1 ]]; then
  success "Local release build complete (GitHub publishing skipped)."
  echo "DMG: $DMG_PATH"
  exit 0
fi

if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
  fail "GitHub release ${TAG} already exists. Choose a new --version or delete the existing release."
fi
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  fail "Local tag ${TAG} already exists. Choose a new --version or delete the tag."
fi
if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
  fail "Remote tag ${TAG} already exists on origin. Choose a new --version or delete the remote tag."
fi

confirm_publish

log "Committing version bump"
git add "$PROJECT_FILE"
git commit -m "Release ${NEW_VERSION}"

git tag -a "$TAG" -m "Release ${NEW_VERSION}"

log "Pushing main and tag to GitHub"
git push origin HEAD:main
git push origin "$TAG"

NOTES_FILE="$(release_notes "$NEW_VERSION")"

log "Creating GitHub release and uploading DMG asset"
gh release create "$TAG" "$DMG_PATH" \
  --repo "$REPO_SLUG" \
  --title "${DISPLAY_NAME} ${NEW_VERSION}" \
  --notes-file "$NOTES_FILE"

log "Verifying GitHub release and DMG asset"
RELEASE_JSON="$(gh release view "$TAG" --repo "$REPO_SLUG" --json tagName,url,assets)"
printf '%s' "$RELEASE_JSON" > "$BUILD_ROOT/release-${NEW_VERSION}.json"
printf '%s' "$RELEASE_JSON" | grep -q '"tagName":"'"$TAG"'"' || fail "GitHub release verification failed: tag ${TAG} not found in release JSON"
printf '%s' "$RELEASE_JSON" | grep -q "$(basename "$DMG_PATH")" || fail "GitHub release verification failed: DMG asset missing from release JSON"

ASSET_URL="$(gh release view "$TAG" --repo "$REPO_SLUG" --json assets --jq '.assets[] | select(.name == "'"$(basename "$DMG_PATH")"'") | .url' | head -n 1)"
[[ -n "$ASSET_URL" ]] || fail "GitHub release verification failed: could not read DMG asset URL"

success "Published and verified ${DISPLAY_NAME} ${NEW_VERSION}"
echo "Release: https://github.com/${REPO_SLUG}/releases/tag/${TAG}"
echo "DMG:     $DMG_PATH"
echo "Asset:   $ASSET_URL"
echo
echo "Note: For direct GitHub/public distribution, the numeric CFBundleVersion can increment with each release as done here. A perpetually increasing build number is required for App Store uploads and is also a safe convention outside the App Store."
