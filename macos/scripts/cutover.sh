#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"
shift || true
NATIVE_APP=""
NATIVE_ARCHIVE=""
APPLICATIONS_DIR="/Applications"
DATA_ROOT="$HOME/Library/Application Support/dev.ycode.ycode"
SNAPSHOT_ROOT=""
MODE="formal"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --native-app)
      [[ $# -ge 2 ]] || { echo "--native-app requires a path" >&2; exit 2; }
      NATIVE_APP="$2"; shift 2 ;;
    --native-archive)
      [[ $# -ge 2 ]] || { echo "--native-archive requires a path" >&2; exit 2; }
      NATIVE_ARCHIVE="$2"; shift 2 ;;
    --applications-dir)
      [[ $# -ge 2 ]] || { echo "--applications-dir requires a path" >&2; exit 2; }
      APPLICATIONS_DIR="$2"; shift 2 ;;
    --data-root)
      [[ $# -ge 2 ]] || { echo "--data-root requires a path" >&2; exit 2; }
      DATA_ROOT="$2"; shift 2 ;;
    --snapshot-root)
      [[ $# -ge 2 ]] || { echo "--snapshot-root requires a path" >&2; exit 2; }
      SNAPSHOT_ROOT="$2"; shift 2 ;;
    --rehearsal) MODE="rehearsal"; shift ;;
    --local) MODE="local"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

REHEARSAL=0
if [[ "$MODE" == "rehearsal" ]]; then REHEARSAL=1; fi

ACTIVE_APP="$APPLICATIONS_DIR/YCode.app"
if [[ -z "$SNAPSHOT_ROOT" ]]; then
  SNAPSHOT_ROOT="$DATA_ROOT.cutover-snapshot"
fi
MANIFEST="$SNAPSHOT_ROOT/cutover.env"
VERIFY_CANDIDATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify_release_candidate.sh"

require_stopped() {
  if pgrep -x YCode >/dev/null 2>&1 || pgrep -x YCodeApp >/dev/null 2>&1; then
    echo "close both legacy and native YCode before cutover" >&2
    exit 1
  fi
}

manifest_value() {
  local key="$1"
  /usr/bin/awk -v prefix="$key=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' "$MANIFEST"
}

require_safe_snapshot_location() {
  [[ "$SNAPSHOT_ROOT" != "$DATA_ROOT" && "$SNAPSHOT_ROOT" != "$DATA_ROOT/"* ]] || {
    echo "snapshot root must not be inside the live data root" >&2
    exit 1
  }
}

require_rehearsal_paths() {
  local path
  for path in "$APPLICATIONS_DIR" "$DATA_ROOT" "$SNAPSHOT_ROOT"; do
    case "$path" in
      /tmp/*|/private/tmp/*) ;;
      *) echo "rehearsal paths must stay under /tmp or /private/tmp: $path" >&2; exit 1 ;;
    esac
  done
}

require_manifest_context() {
  [[ "$(manifest_value data_root)" == "$DATA_ROOT" ]] || {
    echo "manifest data root does not match --data-root" >&2
    exit 1
  }
  [[ "$(manifest_value applications_dir)" == "$APPLICATIONS_DIR" ]] || {
    echo "manifest applications directory does not match --applications-dir" >&2
    exit 1
  }
  local manifest_mode
  manifest_mode="$(manifest_value mode)"
  if [[ -z "$manifest_mode" ]]; then
    if [[ "$(manifest_value rehearsal)" == "1" ]]; then manifest_mode="rehearsal"; else manifest_mode="formal"; fi
  fi
  [[ "$manifest_mode" == "$MODE" ]] || {
    echo "manifest mode ($manifest_mode) does not match this invocation ($MODE)" >&2
    exit 1
  }
}

verify_native_candidate() {
  local plist="$NATIVE_APP/Contents/Info.plist"
  local version
  local build
  [[ -f "$plist" ]] || { echo "native app is missing Info.plist" >&2; exit 1; }
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
  case "$MODE" in
    rehearsal)
      /usr/bin/codesign --verify --deep --strict --verbose=2 "$NATIVE_APP"
      [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == "dev.ycode.app" ]] || {
        echo "rehearsal app has the wrong bundle identifier" >&2
        exit 1
      }
      ;;
    local)
      # Local self-use drops only the Developer ID / notarization requirements.
      # Deep signature, universal2, bundle contents and app/ZIP consistency still apply.
      [[ -f "$NATIVE_ARCHIVE" ]] || {
        echo "local adoption requires --native-archive for prepare-grade verification" >&2
        exit 1
      }
      env YCODE_EXPECTED_VERSION="$version" YCODE_EXPECTED_BUILD="$build" \
        "$VERIFY_CANDIDATE" "$NATIVE_APP" "$NATIVE_ARCHIVE" prepare
      ;;
    *)
      [[ -f "$NATIVE_ARCHIVE" ]] || {
        echo "formal activation requires --native-archive for notarized package verification" >&2
        exit 1
      }
      env YCODE_EXPECTED_VERSION="$version" YCODE_EXPECTED_BUILD="$build" \
        "$VERIFY_CANDIDATE" "$NATIVE_APP" "$NATIVE_ARCHIVE" notarized
      ;;
  esac
}

case "$ACTION" in
  prepare)
    require_stopped
    require_safe_snapshot_location
    if [[ "$REHEARSAL" == "1" ]]; then require_rehearsal_paths; fi
    [[ -d "$DATA_ROOT" ]] || { echo "missing data root: $DATA_ROOT" >&2; exit 1; }
    [[ -f "$DATA_ROOT/ycode.db" ]] || { echo "missing database: $DATA_ROOT/ycode.db" >&2; exit 1; }
    [[ ! -e "$SNAPSHOT_ROOT" ]] || { echo "snapshot already exists: $SNAPSHOT_ROOT" >&2; exit 1; }
    mkdir -p "$SNAPSHOT_ROOT"
    /usr/bin/ditto "$DATA_ROOT" "$SNAPSHOT_ROOT/legacy-data"
    /usr/bin/sqlite3 "$DATA_ROOT/ycode.db" ".backup '$SNAPSHOT_ROOT/ycode.db'"
    /usr/bin/sqlite3 "$SNAPSHOT_ROOT/ycode.db" "PRAGMA integrity_check;"
    if [[ -d "$ACTIVE_APP" ]]; then /usr/bin/ditto "$ACTIVE_APP" "$SNAPSHOT_ROOT/YCode Legacy.app"; fi
    {
      echo "state=prepared"
      echo "data_root=$DATA_ROOT"
      echo "applications_dir=$APPLICATIONS_DIR"
      echo "mode=$MODE"
      echo "rehearsal=$REHEARSAL"
      echo "prepared_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$MANIFEST"
    ;;
  activate)
    require_stopped
    require_safe_snapshot_location
    [[ -f "$MANIFEST" ]] || { echo "run prepare first" >&2; exit 1; }
    require_manifest_context
    if [[ "$REHEARSAL" == "1" ]]; then require_rehearsal_paths; fi
    [[ -d "$NATIVE_APP" ]] || { echo "--native-app must point to YCode.app" >&2; exit 1; }
    verify_native_candidate
    MIGRATOR="$NATIVE_APP/Contents/Resources/ycode-migrate"
    [[ -x "$MIGRATOR" ]] || { echo "release app is missing ycode-migrate" >&2; exit 1; }
    [[ -w "$APPLICATIONS_DIR" ]] || { echo "applications directory is not writable: $APPLICATIONS_DIR" >&2; exit 1; }
    [[ -f "$SNAPSHOT_ROOT/legacy-data/config.json" ]] || { echo "snapshot is missing config.json" >&2; exit 1; }
    [[ "$(/usr/bin/sqlite3 "$SNAPSHOT_ROOT/ycode.db" 'PRAGMA integrity_check;')" == "ok" ]] || {
      echo "snapshot database failed integrity_check" >&2
      exit 1
    }
    [[ ! -e "$SNAPSHOT_ROOT/native-before-rollback" ]] || { echo "cutover was already activated" >&2; exit 1; }
    mv "$DATA_ROOT" "$SNAPSHOT_ROOT/legacy-live-root"
    if ! "$MIGRATOR" "$SNAPSHOT_ROOT/ycode.db" "$SNAPSHOT_ROOT/legacy-data/config.json" "$DATA_ROOT"; then
      mv "$SNAPSHOT_ROOT/legacy-live-root" "$DATA_ROOT"
      exit 1
    fi
    if [[ -d "$ACTIVE_APP" ]]; then mv "$ACTIVE_APP" "$SNAPSHOT_ROOT/YCode Legacy Live.app"; fi
    if ! /usr/bin/ditto "$NATIVE_APP" "$ACTIVE_APP"; then
      mv "$DATA_ROOT" "$SNAPSHOT_ROOT/native-failed-activation"
      mv "$SNAPSHOT_ROOT/legacy-live-root" "$DATA_ROOT"
      if [[ -d "$SNAPSHOT_ROOT/YCode Legacy Live.app" ]]; then mv "$SNAPSHOT_ROOT/YCode Legacy Live.app" "$ACTIVE_APP"; fi
      exit 1
    fi
    sed -i '' 's/^state=.*/state=active/' "$MANIFEST"
    ;;
  adopt)
    # Local self-use: the native app already owns the live data root. Do not re-run
    # ycode-migrate over data the native app has been writing; capture a rollback
    # anchor, archive the legacy app and install the candidate in its place.
    [[ "$MODE" == "local" ]] || { echo "adopt is only available with --local" >&2; exit 1; }
    require_stopped
    require_safe_snapshot_location
    [[ -d "$DATA_ROOT" ]] || { echo "missing data root: $DATA_ROOT" >&2; exit 1; }
    [[ -f "$DATA_ROOT/ycode.db" ]] || { echo "missing database: $DATA_ROOT/ycode.db" >&2; exit 1; }
    [[ ! -e "$SNAPSHOT_ROOT" ]] || { echo "snapshot already exists: $SNAPSHOT_ROOT" >&2; exit 1; }
    [[ -d "$NATIVE_APP" ]] || { echo "--native-app must point to YCode.app" >&2; exit 1; }
    verify_native_candidate
    [[ -x "$NATIVE_APP/Contents/Resources/ycode-migrate" ]] || { echo "candidate is missing ycode-migrate" >&2; exit 1; }
    [[ -w "$APPLICATIONS_DIR" ]] || { echo "applications directory is not writable: $APPLICATIONS_DIR" >&2; exit 1; }
    mkdir -p "$SNAPSHOT_ROOT"
    /usr/bin/ditto "$DATA_ROOT" "$SNAPSHOT_ROOT/legacy-data"
    /usr/bin/sqlite3 "$DATA_ROOT/ycode.db" ".backup '$SNAPSHOT_ROOT/ycode.db'"
    [[ "$(/usr/bin/sqlite3 "$SNAPSHOT_ROOT/ycode.db" 'PRAGMA integrity_check;')" == "ok" ]] || {
      echo "adoption snapshot failed integrity_check" >&2
      exit 1
    }
    if [[ -d "$ACTIVE_APP" ]]; then /usr/bin/ditto "$ACTIVE_APP" "$SNAPSHOT_ROOT/YCode Legacy Live.app"; fi
    if ! /usr/bin/ditto "$NATIVE_APP" "$SNAPSHOT_ROOT/staged-YCode.app"; then
      echo "failed to stage the native candidate" >&2
      exit 1
    fi
    if [[ -d "$ACTIVE_APP" ]]; then rm -rf "$ACTIVE_APP"; fi
    if ! mv "$SNAPSHOT_ROOT/staged-YCode.app" "$ACTIVE_APP"; then
      if [[ -d "$SNAPSHOT_ROOT/YCode Legacy Live.app" ]]; then
        /usr/bin/ditto "$SNAPSHOT_ROOT/YCode Legacy Live.app" "$ACTIVE_APP"
      fi
      exit 1
    fi
    {
      echo "state=adopted"
      echo "data_root=$DATA_ROOT"
      echo "applications_dir=$APPLICATIONS_DIR"
      echo "mode=$MODE"
      echo "rehearsal=$REHEARSAL"
      echo "prepared_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$MANIFEST"
    ;;
  rollback)
    require_stopped
    require_safe_snapshot_location
    [[ -f "$MANIFEST" ]] || { echo "missing cutover manifest" >&2; exit 1; }
    require_manifest_context
    if [[ "$REHEARSAL" == "1" ]]; then require_rehearsal_paths; fi
    [[ ! -e "$SNAPSHOT_ROOT/native-before-rollback" ]] || { echo "rollback already performed" >&2; exit 1; }
    if [[ "$(manifest_value state)" == "adopted" ]]; then
      [[ -d "$SNAPSHOT_ROOT/legacy-data" ]] || { echo "no preserved adoption snapshot" >&2; exit 1; }
      mv "$DATA_ROOT" "$SNAPSHOT_ROOT/native-before-rollback"
      /usr/bin/ditto "$SNAPSHOT_ROOT/legacy-data" "$DATA_ROOT"
    else
      [[ -d "$SNAPSHOT_ROOT/legacy-live-root" ]] || { echo "no preserved legacy root" >&2; exit 1; }
      mv "$DATA_ROOT" "$SNAPSHOT_ROOT/native-before-rollback"
      mv "$SNAPSHOT_ROOT/legacy-live-root" "$DATA_ROOT"
    fi
    if [[ -d "$ACTIVE_APP" ]]; then mv "$ACTIVE_APP" "$SNAPSHOT_ROOT/YCode Native Rolled Back.app"; fi
    if [[ -d "$SNAPSHOT_ROOT/YCode Legacy Live.app" ]]; then mv "$SNAPSHOT_ROOT/YCode Legacy Live.app" "$ACTIVE_APP"; fi
    sed -i '' 's/^state=.*/state=rolled_back/' "$MANIFEST"
    ;;
  status)
    if [[ -f "$MANIFEST" ]]; then cat "$MANIFEST"; else echo "state=not_prepared"; fi
    ;;
  *)
    echo "usage: $0 prepare|activate|adopt|rollback|status [--rehearsal|--local] [--native-app path] [--native-archive path] [--applications-dir path] [--data-root path] [--snapshot-root path]" >&2
    exit 2
    ;;
esac
