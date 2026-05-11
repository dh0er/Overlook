#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Overlook"
BUNDLE_IDS=("com.overlook.app" "com.overlook.app.localrelease")
LOCAL_NETWORK_SERVICE="kTCCServiceLocalNetwork"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="$HOME/Library/Application Support/OverlookCleanupBackups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DRY_RUN=0
SKIP_TCC=0

usage() {
  cat <<'USAGE'
Usage: scripts/cleanup-overlook-macos-state.sh [--dry-run] [--skip-tcc]

Fully removes stale macOS state for Overlook:
  - quits Overlook and System Settings
  - resets TCC permissions for old and current bundle IDs
  - removes Overlook rows directly from user/system TCC databases when allowed
  - unregisters and deletes discovered Overlook.app bundles
  - clears preferences, containers, quarantine attributes, and app caches
  - refreshes LaunchServices and restarts cfprefsd/tccd

If TCC database access fails, grant Full Disk Access to the app running this
script, such as Codex, Terminal, iTerm, or VS Code, then run it again.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --skip-tcc)
      SKIP_TCC=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

log() {
  printf '%s\n' "$*"
}

run() {
  log "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

run_optional() {
  log "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@" || true
  fi
}

sql_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

sqlite_for_db() {
  local db="$1"
  shift

  if [[ "$db" == /Library/* && "$EUID" -ne 0 ]]; then
    if [[ -t 0 ]]; then
      sudo sqlite3 -batch "$db" "$@"
    else
      sudo -n sqlite3 -batch "$db" "$@"
    fi
  else
    sqlite3 -batch "$db" "$@"
  fi
}

copy_for_db() {
  local src="$1"
  local dst="$2"

  if [[ "$src" == /Library/* && "$EUID" -ne 0 ]]; then
    if [[ -t 0 ]]; then
      sudo cp -p "$src" "$dst"
      sudo chown "$USER" "$dst" 2>/dev/null || true
    else
      sudo -n cp -p "$src" "$dst"
      sudo -n chown "$USER" "$dst" 2>/dev/null || true
    fi
  else
    cp -p "$src" "$dst"
  fi
}

can_open_tcc_db() {
  local db="$1"
  [[ -f "$db" ]] && sqlite_for_db "$db" "select 1;" >/dev/null 2>&1
}

column_exists() {
  local db="$1"
  local column="$2"

  sqlite_for_db "$db" "pragma table_info(access);" \
    | awk -F'|' -v column="$column" '$2 == column { found = 1 } END { exit(found ? 0 : 1) }'
}

backup_tcc_db() {
  local db="$1"
  local label

  label="$(printf '%s' "$db" | sed 's#^/##; s#[/ ]#_#g')"
  mkdir -p "$BACKUP_DIR"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "+ backup $db -> $BACKUP_DIR/$label"
    return 0
  fi

  copy_for_db "$db" "$BACKUP_DIR/$label"
  [[ -f "$db-wal" ]] && copy_for_db "$db-wal" "$BACKUP_DIR/$label-wal"
  [[ -f "$db-shm" ]] && copy_for_db "$db-shm" "$BACKUP_DIR/$label-shm"
}

tcc_where_clause() {
  local db="$1"
  local bundle_list=""
  local id
  local clause

  for id in "${BUNDLE_IDS[@]}"; do
    if [[ -n "$bundle_list" ]]; then
      bundle_list+=","
    fi
    bundle_list+="$(sql_quote "$id")"
  done

  clause="client in ($bundle_list) or lower(coalesce(client, '')) like '%overlook%'"

  if column_exists "$db" "indirect_object_identifier"; then
    clause="$clause or lower(coalesce(indirect_object_identifier, '')) like '%overlook%'"
  fi

  printf '(%s)' "$clause"
}

select_tcc_rows() {
  local db="$1"
  local where="$2"
  local columns="service, client"

  column_exists "$db" "client_type" && columns="$columns, client_type"
  column_exists "$db" "auth_value" && columns="$columns, auth_value"
  column_exists "$db" "auth_reason" && columns="$columns, auth_reason"
  column_exists "$db" "indirect_object_identifier" && columns="$columns, indirect_object_identifier"

  sqlite_for_db "$db" ".mode tabs" ".headers on" "select $columns from access where $where order by service, client;"
}

cleanup_tcc_db() {
  local db="$1"
  local where
  local changes

  if [[ ! -f "$db" ]]; then
    log "TCC database not found: $db"
    return 0
  fi

  if ! can_open_tcc_db "$db"; then
    log "Cannot open TCC database: $db"
    log "Grant Full Disk Access to the app running this script, then run it again."
    return 1
  fi

  where="$(tcc_where_clause "$db")"

  log "Matching TCC rows in $db:"
  select_tcc_rows "$db" "$where" || true

  backup_tcc_db "$db"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "+ delete from access where $where"
    return 0
  fi

  changes="$(sqlite_for_db "$db" "begin immediate; delete from access where $where; select changes(); commit;")"
  log "Deleted TCC rows from $db: $changes"
}

reset_tcc_by_bundle_id() {
  local id

  if [[ "$SKIP_TCC" -eq 1 ]]; then
    log "Skipping TCC reset by request."
    return 0
  fi

  for id in "${BUNDLE_IDS[@]}"; do
    run_optional tccutil reset All "$id"
    run_optional tccutil reset "$LOCAL_NETWORK_SERVICE" "$id"
  done
}

cleanup_tcc_databases() {
  local db
  local failed=0
  local dbs=(
    "$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    "/Library/Application Support/com.apple.TCC/TCC.db"
  )

  if [[ "$SKIP_TCC" -eq 1 ]]; then
    log "Skipping direct TCC database cleanup by request."
    return 0
  fi

  for db in "${dbs[@]}"; do
    cleanup_tcc_db "$db" || failed=1
  done

  if [[ "$failed" -ne 0 ]]; then
    log "TCC database cleanup was incomplete."
    return 1
  fi
}

quit_apps() {
  local id

  for id in "${BUNDLE_IDS[@]}"; do
    run_optional osascript -e "quit app id \"$id\""
  done

  run_optional osascript -e 'quit app "Overlook"'
  run_optional osascript -e 'quit app "System Settings"'
  run_optional pkill -x "$APP_NAME"
}

cleanup_preferences_and_containers() {
  local id

  for id in "${BUNDLE_IDS[@]}"; do
    run_optional rm -f "$HOME/Library/Preferences/$id.plist"
    run_optional rm -rf "$HOME/Library/Containers/$id"
    run_optional rm -rf "$HOME/Library/Application Scripts/$id"
    run_optional rm -rf "$HOME/Library/Group Containers/$id"
    run_optional rm -rf "$HOME/Library/Saved Application State/$id.savedState"
    run_optional defaults delete "$id"
  done
}

discover_overlook_apps() {
  local output="$1"
  local root
  local roots=(
    "$ROOT_DIR"
    "$ROOT_DIR/build"
    "$HOME/Library/Developer/Xcode/DerivedData"
    "/Applications"
    "$HOME/Applications"
  )

  : > "$output"
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    find "$root" -maxdepth 10 -name "$APP_NAME.app" -type d -print 2>/dev/null >> "$output"
  done
  sort -u "$output" -o "$output"
}

cleanup_app_bundles() {
  local list_file
  local app

  list_file="$(mktemp -t overlook-apps.XXXXXX)"
  discover_overlook_apps "$list_file"

  if [[ ! -s "$list_file" ]]; then
    log "No $APP_NAME.app bundles found in common locations."
    rm -f "$list_file"
    return 0
  fi

  log "Discovered $APP_NAME.app bundles:"
  sed 's/^/  /' "$list_file"

  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    [[ -x "$LSREGISTER" ]] && run_optional "$LSREGISTER" -u "$app"
    run_optional xattr -cr "$app"
    run_optional rm -rf "$app"
  done < "$list_file"

  rm -f "$list_file"
}

refresh_macos_caches() {
  [[ -x "$LSREGISTER" ]] && run_optional "$LSREGISTER" -r -domain local -domain system -domain user
  run_optional killall cfprefsd
  run_optional killall tccd
  run_optional killall lsd
  run_optional killall sharedfilelistd
}

main() {
  log "Cleaning stale macOS state for $APP_NAME."
  [[ "$DRY_RUN" -eq 1 ]] && log "Dry run: no changes will be made."

  quit_apps
  reset_tcc_by_bundle_id
  cleanup_tcc_databases || true
  cleanup_app_bundles
  cleanup_preferences_and_containers
  refresh_macos_caches

  if [[ "$DRY_RUN" -eq 0 ]]; then
    log "Backups, if any, are in: $BACKUP_DIR"
  fi
  log "Cleanup finished. Reopen System Settings to refresh the Local Network list."
}

main "$@"
