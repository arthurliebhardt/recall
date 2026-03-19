#!/bin/bash
set -euo pipefail

APP_NAME="${APP_NAME:-recall}"
REPO="${REPO:-arthurliebhardt/recall}"
BUNDLE_ID="${BUNDLE_ID:-com.summarizecontent.app}"

LEGACY_SUPPORT_DIR="${LEGACY_SUPPORT_DIR:-$HOME/Library/Application Support}"
SANDBOX_SUPPORT_DIR="${SANDBOX_SUPPORT_DIR:-$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support}"

LEGACY_STORE_PATH="$LEGACY_SUPPORT_DIR/default.store"
SANDBOX_STORE_PATH="$SANDBOX_SUPPORT_DIR/default.store"
LEGACY_AUDIO_DIR="$LEGACY_SUPPORT_DIR/AudioFiles"
SANDBOX_AUDIO_DIR="$SANDBOX_SUPPORT_DIR/AudioFiles"

sqlite_scalar() {
    local database_path="$1"
    local query="$2"

    if ! command -v sqlite3 >/dev/null 2>&1; then
        return 1
    fi

    sqlite3 "$database_path" "$query" 2>/dev/null
}

sqlite_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

database_record_count() {
    local database_path="$1"
    sqlite_scalar "$database_path" "SELECT COUNT(*) FROM ZTRANSCRIPTIONRECORD;"
}

database_is_empty() {
    local database_path="$1"
    local count

    count=$(database_record_count "$database_path") || return 1
    [ "${count:-0}" -eq 0 ]
}

directory_file_count() {
    local directory_path="$1"

    if [ ! -d "$directory_path" ]; then
        echo 0
        return
    fi

    find "$directory_path" -type f | wc -l | tr -d ' '
}

database_filename_list() {
    local database_path="$1"
    local output_path="$2"

    sqlite3 "$database_path" \
        "SELECT ZFILENAME FROM ZTRANSCRIPTIONRECORD WHERE ZFILENAME IS NOT NULL ORDER BY ZFILENAME;" \
        2>/dev/null | sort -u > "$output_path"
}

database_is_strict_subset_of() {
    local candidate_db="$1"
    local reference_db="$2"
    local candidate_list="$WORK_DIR/candidate-filenames.txt"
    local reference_list="$WORK_DIR/reference-filenames.txt"
    local candidate_count
    local reference_count

    database_filename_list "$candidate_db" "$candidate_list" || return 1
    database_filename_list "$reference_db" "$reference_list" || return 1

    if [ ! -s "$candidate_list" ]; then
        return 1
    fi

    if comm -23 "$candidate_list" "$reference_list" | grep -q .; then
        return 1
    fi

    candidate_count=$(wc -l < "$candidate_list" | tr -d ' ')
    reference_count=$(wc -l < "$reference_list" | tr -d ' ')

    [ "${reference_count:-0}" -gt "${candidate_count:-0}" ]
}

rewrite_audio_paths_in_database() {
    local database_path="$1"
    local legacy_prefix
    local sandbox_prefix

    if [ ! -f "$database_path" ] || ! command -v sqlite3 >/dev/null 2>&1; then
        return
    fi

    legacy_prefix=$(sqlite_escape "$LEGACY_AUDIO_DIR")
    sandbox_prefix=$(sqlite_escape "$SANDBOX_AUDIO_DIR")

    sqlite3 "$database_path" <<SQL >/dev/null 2>&1 || true
UPDATE ZTRANSCRIPTIONRECORD
SET ZLOCALAUDIOPATH = REPLACE(ZLOCALAUDIOPATH, '$legacy_prefix', '$sandbox_prefix')
WHERE ZLOCALAUDIOPATH LIKE '$legacy_prefix%';
SQL
}

copy_store_artifacts() {
    local source_store_path="$1"
    local destination_store_path="$2"
    local destination_dir
    local suffix

    destination_dir=$(dirname "$destination_store_path")
    mkdir -p "$destination_dir"

    for suffix in "" "-wal" "-shm"; do
        if [ -f "${source_store_path}${suffix}" ]; then
            ditto "${source_store_path}${suffix}" "${destination_store_path}${suffix}"
        fi
    done
}

copy_audio_directory() {
    local source_audio_dir="$1"
    local destination_audio_dir="$2"

    if [ ! -d "$source_audio_dir" ]; then
        return
    fi

    rm -rf "$destination_audio_dir"
    ditto "$source_audio_dir" "$destination_audio_dir"
}

backup_and_clear_sandbox_data() {
    local backup_dir
    local suffix

    backup_dir="$HOME/Library/Application Support/${APP_NAME}-sandbox-backup-$(date +%Y%m%d-%H%M%S)"

    if [ ! -f "$SANDBOX_STORE_PATH" ] && [ ! -f "${SANDBOX_STORE_PATH}-wal" ] && [ ! -f "${SANDBOX_STORE_PATH}-shm" ] && [ ! -d "$SANDBOX_AUDIO_DIR" ]; then
        mkdir -p "$SANDBOX_SUPPORT_DIR"
        return
    fi

    echo "Backing up current sandbox data to $backup_dir"
    mkdir -p "$backup_dir"

    for suffix in "" "-wal" "-shm"; do
        if [ -f "${SANDBOX_STORE_PATH}${suffix}" ]; then
            mv "${SANDBOX_STORE_PATH}${suffix}" "$backup_dir/$(basename "$SANDBOX_STORE_PATH")${suffix}"
        fi
    done

    if [ -d "$SANDBOX_AUDIO_DIR" ]; then
        mv "$SANDBOX_AUDIO_DIR" "$backup_dir/AudioFiles"
    fi

    mkdir -p "$SANDBOX_SUPPORT_DIR"
}

replace_sandbox_data_with_legacy_copy() {
    echo "Restoring legacy app data into the sandbox container..."
    backup_and_clear_sandbox_data
    copy_store_artifacts "$LEGACY_STORE_PATH" "$SANDBOX_STORE_PATH"
    copy_audio_directory "$LEGACY_AUDIO_DIR" "$SANDBOX_AUDIO_DIR"
    rewrite_audio_paths_in_database "$SANDBOX_STORE_PATH"
}

migrate_existing_data_if_needed() {
    local legacy_record_count=0
    local sandbox_record_count=0
    local legacy_audio_count=0
    local sandbox_audio_count=0

    if [ -f "$LEGACY_STORE_PATH" ]; then
        legacy_record_count=$(database_record_count "$LEGACY_STORE_PATH" || echo 0)
    fi

    if [ -f "$SANDBOX_STORE_PATH" ]; then
        sandbox_record_count=$(database_record_count "$SANDBOX_STORE_PATH" || echo 0)
    fi

    legacy_audio_count=$(directory_file_count "$LEGACY_AUDIO_DIR")
    sandbox_audio_count=$(directory_file_count "$SANDBOX_AUDIO_DIR")

    if [ ! -f "$LEGACY_STORE_PATH" ] && [ "${legacy_audio_count:-0}" -eq 0 ]; then
        if [ -f "$SANDBOX_STORE_PATH" ] || [ "${sandbox_audio_count:-0}" -gt 0 ]; then
            echo "Preserving existing app data in $SANDBOX_SUPPORT_DIR"
        fi
        return
    fi

    if [ ! -f "$SANDBOX_STORE_PATH" ]; then
        replace_sandbox_data_with_legacy_copy
        return
    fi

    if database_is_empty "$SANDBOX_STORE_PATH" && { [ "${legacy_record_count:-0}" -gt 0 ] || [ "${legacy_audio_count:-0}" -gt 0 ]; }; then
        replace_sandbox_data_with_legacy_copy
        return
    fi

    if [ "${legacy_record_count:-0}" -gt "${sandbox_record_count:-0}" ] && database_is_strict_subset_of "$SANDBOX_STORE_PATH" "$LEGACY_STORE_PATH"; then
        replace_sandbox_data_with_legacy_copy
        return
    fi

    echo "Preserving existing app data in $SANDBOX_SUPPORT_DIR"
}

download_latest_zip() {
    local api_url="https://api.github.com/repos/$REPO/releases/latest"
    local latest_url

    if command -v gh >/dev/null 2>&1; then
        if gh release download --repo "$REPO" --pattern 'recall-v*-macos.zip' --dir "$WORK_DIR" --clobber >/dev/null 2>&1; then
            ZIP_PATH=$(find "$WORK_DIR" -maxdepth 1 -type f -name 'recall-v*-macos.zip' | head -n 1)
            if [ -n "${ZIP_PATH:-}" ]; then
                echo "Downloaded latest release via GitHub CLI."
                return
            fi
        fi
    fi

    latest_url=$(
        curl -fsSL "$api_url" |
            grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' |
            sed -E 's/.*"([^"]+)"/\1/' |
            grep -E '/recall-v[^/]*-macos\.zip$' |
            head -n 1
    )

    if [ -z "$latest_url" ]; then
        latest_url=$(
            curl -fsSL "$api_url" |
                grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' |
                sed -E 's/.*"([^"]+)"/\1/' |
                grep -E '\.zip$' |
                head -n 1
        )
    fi

    if [ -z "$latest_url" ]; then
        echo "Error: could not determine the latest release zip from GitHub."
        echo "Attach a macOS zip asset to the latest release or pass a local zip path to this script."
        exit 1
    fi

    ZIP_PATH="$WORK_DIR/$(basename "$latest_url")"
    echo "Downloading latest release: $latest_url"
    curl -fL "$latest_url" -o "$ZIP_PATH"
}

determine_install_dir() {
    if [ -n "${INSTALL_DIR:-}" ]; then
        mkdir -p "$INSTALL_DIR"
        return
    fi

    if [ -w "/Applications" ]; then
        INSTALL_DIR="/Applications"
    else
        INSTALL_DIR="$HOME/Applications"
        mkdir -p "$INSTALL_DIR"
    fi
}

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/recall-install.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

ZIP_PATH="${1:-}"

if [ -n "$ZIP_PATH" ]; then
    if [ ! -f "$ZIP_PATH" ]; then
        echo "Error: zip file not found: $ZIP_PATH"
        exit 1
    fi
else
    download_latest_zip
fi

echo "Found $ZIP_PATH"
echo "Installing $APP_NAME..."

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "Error: please quit $APP_NAME before installing."
    exit 1
fi

EXTRACT_DIR="$WORK_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ZIP_PATH" "$EXTRACT_DIR"

APP_PATH="$EXTRACT_DIR/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: extracted archive did not contain $APP_NAME.app"
    exit 1
fi

xattr -rd com.apple.quarantine "$APP_PATH" 2>/dev/null || true

determine_install_dir

if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    echo "Removing existing $APP_NAME from $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
fi

migrate_existing_data_if_needed

mv "$APP_PATH" "$INSTALL_DIR/"
echo "✓ $APP_NAME installed to $INSTALL_DIR"
echo "  Open it from your Applications folder or Spotlight."
