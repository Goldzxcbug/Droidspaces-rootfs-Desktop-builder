#!/usr/bin/env bash
# Fetch the current TUI release and its shared libraries into a build directory.
set -euo pipefail

readonly REPOSITORY='Goldzxcbug/droidspaces-package'
readonly RELEASE_TAG='Gold-bug-tui'
readonly MANIFEST_NAME='Gold-bug-tui-manifest'
readonly FILES_NAME='Gold-bug-tui-files'
readonly BUNDLE_NAME='Gold-bug-tui.tar.gz'
readonly MANIFEST_LIMIT=1048576
readonly SCRIPT_LIMIT=8388608
readonly BUNDLE_LIMIT=33554432
readonly EXPANDED_LIMIT=67108864
readonly MEMBER_LIMIT=128
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
OUTPUT="$SCRIPT_DIR/../.build/tui"
SOURCE="${DROIDSPACES_TUI_SOURCE:-github}"
CHECK=false
WORK_DIR=''
BACKUP_DIR=''
OLD_MOVED=false
PUBLISHED=false
REVISION=''
BUNDLE_DIGEST=''
BUNDLE_SIZE=''
BOOTSTRAP_DIGEST=''
BOOTSTRAP_SIZE=''
declare -a ASSETS=() DIGESTS=() SIZES=()

die() { printf 'sync-tui: %s\n' "$*" >&2; exit 1; }
argument_error() { printf 'sync-tui: %s\n' "$*" >&2; exit 2; }

usage() {
    cat <<'HELP'
Usage: sync-tui.sh [options]

  --output DIRECTORY  Download directory (default: .build/tui in this repository)
  --source github|cnb Download source (default: DROIDSPACES_TUI_SOURCE or github)
  --check             Verify the existing download directory without networking
  -h, --help          Show this help

Downloads Gold-bug-tui.tar.gz, checks the release and file manifests, SHA-256,
file sizes, archive structure and shell syntax, then replaces the output as a
whole. The output contains the TUI scripts, lib/ and both provenance manifests.

Requires Bash, curl, GNU tar/coreutils, gzip and flock (util-linux).
DROIDSPACES_TUI_DOWNLOAD_BASE overrides the complete release download URL,
for example http://127.0.0.1:8000 for a local release fixture.
HELP
}

require_commands() {
    local command
    for command in "$@"; do
        command -v "$command" >/dev/null 2>&1 || die "missing required command: $command"
    done
}

asset_metadata() {
    case "$1" in
        droidspaces-tui.sh) printf 'tui\t/usr/local/bin/droidspaces-tui' ;;
        droidspaces-gpu.sh) printf 'tui\t/usr/local/bin/droidspaces-gpu' ;;
        droidspaces-video.sh) printf 'tui\t/usr/local/bin/droidspaces-video.sh' ;;
        install-tui.sh) printf 'bootstrap\t-' ;;
        install-mesa.sh|install-hangover-wine.sh|install-winefonts.sh|install-anland-kde.sh|install-anland-gnome.sh|install-anland-next.sh|install-anland-niri.sh|install-anland-hyprland.sh|install-anland-mango.sh|install-anland-denial.sh)
            printf 'installer\t/usr/local/sbin/%s' "${1%.sh}"
            ;;
        lib/*)
            [[ "$1" =~ ^lib/[A-Za-z0-9][A-Za-z0-9_-]*\.sh$ && "$1" != *..* ]] || return 1
            printf 'library\t/usr/local/lib/droidspaces/tui/%s' "${1#lib/}"
            ;;
        *) return 1 ;;
    esac
}

parse_arguments() {
    while (($#)); do
        case "$1" in
            --output|--source)
                (($# >= 2)) && [[ -n "$2" ]] || argument_error "$1 requires a value"
                case "$1" in --output) OUTPUT="$2" ;; --source) SOURCE="$2" ;; esac
                shift 2
                ;;
            --output=*) OUTPUT="${1#*=}"; [[ -n "$OUTPUT" ]] || argument_error '--output requires a value'; shift ;;
            --source=*) SOURCE="${1#*=}"; [[ -n "$SOURCE" ]] || argument_error '--source requires a value'; shift ;;
            --check) CHECK=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) argument_error "unsupported argument: $1" ;;
        esac
    done
    case "$SOURCE" in github|cnb) ;; *) argument_error "unsupported source: $SOURCE" ;; esac
}

cleanup() {
    local failed=false
    if [[ "$OLD_MOVED" == true && "$PUBLISHED" == false ]]; then
        if [[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]]; then
            mv -T -- "$BACKUP_DIR" "$OUTPUT" || failed=true
        else
            failed=true
        fi
        if [[ "$failed" == true ]]; then
            printf 'sync-tui: previous download preserved at %s\n' "$BACKUP_DIR" >&2
            BACKUP_DIR=''
        fi
    fi
    [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
    [[ -z "$BACKUP_DIR" ]] || rm -rf -- "$BACKUP_DIR"
}

check_directory_entries() {
    local directory="$1" path child name
    local -a entries=() libraries=()
    [[ ! -L "$directory" && -d "$directory" ]] || die "not a regular download directory: $directory"
    shopt -s nullglob dotglob
    entries=("$directory"/*)
    for path in "${entries[@]}"; do
        name="${path##*/}"
        if [[ "$name" == lib ]]; then
            [[ -d "$path" && ! -L "$path" ]] || die 'download lib/ is not a regular directory'
            libraries=("$path"/*)
            for child in "${libraries[@]}"; do
                [[ -f "$child" && ! -L "$child" ]] || die "unexpected library entry: ${child##*/}"
                asset_metadata "lib/${child##*/}" >/dev/null || die "unexpected library name: ${child##*/}"
            done
        else
            [[ -f "$path" && ! -L "$path" ]] || die "unexpected non-regular download entry: $name"
            [[ "$name" == "$MANIFEST_NAME" || "$name" == "$FILES_NAME" ]] || asset_metadata "$name" >/dev/null || \
                die "unexpected file in download directory: $name"
        fi
    done
    shopt -u nullglob dotglob
}

parse_manifest() {
    local manifest="$1" kind="${2:-files}" expected_revision="${3:-}"
    local line key value sha size role target asset metadata expected_role expected_target limit name
    local header=false line_number=0 invalid_bytes manifest_size roots=0
    local -A fields=() seen=()
    ASSETS=(); DIGESTS=(); SIZES=()
    [[ -f "$manifest" && ! -L "$manifest" ]] || die 'manifest is missing or not a regular file'
    manifest_size="$(stat -c '%s' -- "$manifest")"
    ((manifest_size > 0 && manifest_size <= MANIFEST_LIMIT)) || die 'manifest exceeds the size limit or is empty'
    invalid_bytes="$(LC_ALL=C tr -d '\11\12\40-\176' < "$manifest" | wc -c)"
    [[ "$invalid_bytes" -eq 0 ]] || die 'manifest contains unsupported bytes'
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        if [[ "$header" == false ]]; then
            if [[ "$line" == $'sha256\tsize\trole\ttarget\tasset' ]]; then
                header=true
                continue
            fi
            [[ "$line" == *=* ]] || die "invalid manifest metadata at line $line_number"
            key="${line%%=*}"; value="${line#*=}"
            case "$key" in format|release_tag|revision|generated_at) ;; *) die "unknown manifest metadata: $key" ;; esac
            [[ -z "${fields[$key]+present}" ]] || die "duplicate manifest metadata: $key"
            fields["$key"]="$value"
            continue
        fi
        [[ "$line" =~ ^([^$'\t']+)$'\t'([^$'\t']+)$'\t'([^$'\t']+)$'\t'([^$'\t']+)$'\t'([^$'\t']+)$ ]] || \
            die "invalid manifest row at line $line_number"
        sha="${BASH_REMATCH[1]}"; size="${BASH_REMATCH[2]}"; role="${BASH_REMATCH[3]}"
        target="${BASH_REMATCH[4]}"; asset="${BASH_REMATCH[5]}"
        [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "invalid SHA-256 for $asset"
        limit="$SCRIPT_LIMIT"
        if [[ "$kind" == release ]]; then
            case "$asset:$role:$target" in
                "$BUNDLE_NAME:bundle:-") limit="$BUNDLE_LIMIT" ;;
                'install-tui.sh:bootstrap:-') ;;
                *) die "unregistered release asset: $asset" ;;
            esac
        elif [[ "$kind" == files ]]; then
            metadata="$(asset_metadata "$asset")" || die "unregistered bundle file: $asset"
            IFS=$'\t' read -r expected_role expected_target <<< "$metadata"
            [[ "$role" == "$expected_role" && "$target" == "$expected_target" ]] || die "invalid role or target for $asset"
            [[ "$asset" == lib/* ]] || roots=$((roots + 1))
        else
            die 'invalid manifest kind'
        fi
        if [[ ! "$size" =~ ^[1-9][0-9]{0,7}$ ]] || ((size > limit)); then
            die "invalid size for $asset"
        fi
        [[ -z "${seen[$asset]+present}" ]] || die "duplicate manifest asset: $asset"
        seen["$asset"]=1
        ASSETS+=("$asset"); DIGESTS+=("$sha"); SIZES+=("$size")
        ((${#ASSETS[@]} <= MEMBER_LIMIT)) || die 'manifest has too many files'
        if [[ "$kind" == release ]]; then
            case "$asset" in
                "$BUNDLE_NAME") BUNDLE_DIGEST="$sha"; BUNDLE_SIZE="$size" ;;
                install-tui.sh) BOOTSTRAP_DIGEST="$sha"; BOOTSTRAP_SIZE="$size" ;;
            esac
        fi
    done < "$manifest"
    [[ "$header" == true && "${fields[format]-}" == 1 && "${fields[release_tag]-}" == "$RELEASE_TAG" &&
       "${fields[revision]-}" =~ ^[0-9a-f]{40}$ && -n "${fields[generated_at]-}" ]] || die 'invalid or incomplete manifest metadata'
    [[ -z "$expected_revision" || "${fields[revision]}" == "$expected_revision" ]] || die 'release and file manifest revisions differ'
    if [[ "$kind" == release ]]; then
        ((${#ASSETS[@]} == 2)) && [[ -n "${seen[$BUNDLE_NAME]+present}" && -n "${seen[install-tui.sh]+present}" ]] || \
            die 'release must contain its bootstrap and TUI bundle'
        REVISION="${fields[revision]}"
    else
        ((roots == 14)) || die 'bundle must contain all 14 registered TUI scripts'
        for name in anland-common.sh anland-archive-common.sh anland-compositor-common.sh; do
            [[ -n "${seen[lib/$name]+present}" ]] || die "bundle is missing shared library: $name"
        done
    fi
}

verify_file() {
    local file="$1" digest="$2" size="$3" actual_sha
    [[ -f "$file" && ! -L "$file" ]] || die "missing regular file: ${file##*/}"
    [[ "$(stat -c '%s' -- "$file")" == "$size" ]] || die "size mismatch: ${file##*/}"
    actual_sha="$(sha256sum < "$file")"
    [[ "${actual_sha%% *}" == "$digest" ]] || die "SHA-256 mismatch: ${file##*/}"
}

verify_files() {
    local directory="$1" index path relative
    local -A expected=()
    check_directory_entries "$directory"
    for index in "${!ASSETS[@]}"; do
        relative="${ASSETS[$index]}"; expected["$relative"]=1
        verify_file "$directory/$relative" "${DIGESTS[$index]}" "${SIZES[$index]}"
        bash -n "$directory/$relative" || die "invalid shell syntax: $relative"
        if [[ "$relative" == install-tui.sh ]]; then
            [[ "${DIGESTS[$index]}" == "$BOOTSTRAP_DIGEST" && "${SIZES[$index]}" == "$BOOTSTRAP_SIZE" ]] || \
                die 'bundle bootstrap does not match the release manifest'
        fi
    done
    shopt -s nullglob dotglob
    for path in "$directory"/*.sh "$directory"/lib/*; do
        relative="${path#"$directory"/}"
        [[ -n "${expected[$relative]+present}" ]] || die "unlisted bundle file: $relative"
    done
    shopt -u nullglob dotglob
}
# Inspect the uncompressed tar stream before extracting any member. GNU tar's
# escaped listing makes whitespace/control characters unambiguous; the allowed
# path grammar below excludes every escape and all links or special files.
validate_bundle_archive() {
    local archive="$1" listing="$2" mode owner size date time name extra relative
    local count=0 total=0 limit
    local -A seen=()
    limit=$((EXPANDED_LIMIT + MANIFEST_LIMIT))
    if ! (set -o pipefail; GZIP= gzip -cd -- "$archive" | head -c "$limit" | \
        LC_ALL=C TZ=UTC TAR_OPTIONS= tar --list --verbose --numeric-owner --full-time \
            --quoting-style=escape --absolute-names --file - | head -n "$((MEMBER_LIMIT + 1))") > "$listing"; then
        die 'invalid or oversized TUI archive'
    fi
    while read -r mode owner size date time name extra; do
        [[ -n "$mode" && -z "${extra:-}" && "$size" =~ ^[0-9]{1,10}$ ]] || die 'invalid TUI archive header'
        count=$((count + 1))
        ((count <= MEMBER_LIMIT)) || die 'TUI archive has too many members'
        [[ -z "${seen[$name]+present}" ]] || die "duplicate TUI archive member: $name"
        seen["$name"]=1
        case "$name" in
            tui/|tui/lib/)
                [[ "$mode" == d* && "$size" == 0 ]] || die "invalid TUI archive directory: $name"
                ;;
            tui/*)
                [[ "$mode" == -* ]] || die "TUI archive member is not a regular file: $name"
                relative="${name#tui/}"
                if [[ "$relative" != "$FILES_NAME" ]]; then
                    asset_metadata "$relative" >/dev/null || die "unexpected TUI archive member: $name"
                fi
                ((10#$size > 0 && 10#$size <= SCRIPT_LIMIT)) || die "invalid TUI archive member size: $name"
                if [[ "$relative" == "$FILES_NAME" ]]; then
                    ((10#$size <= MANIFEST_LIMIT)) || die 'TUI file manifest is too large'
                fi
                total=$((total + 10#$size))
                ((total <= EXPANDED_LIMIT)) || die 'TUI archive exceeds the expanded size limit'
                ;;
            *) die "unexpected TUI archive member: $name" ;;
        esac
    done < "$listing"
    [[ -n "${seen[tui/$FILES_NAME]+present}" ]] || die 'TUI archive has no file manifest'
}

extract_bundle_archive() {
    local archive="$1" destination="$2"
    mkdir -m 0700 -- "$destination"
    TAR_OPTIONS= GZIP= tar --extract --gzip --file "$archive" --directory "$destination" \
        --no-same-owner --no-same-permissions --delay-directory-restore || die 'unable to extract TUI archive'
    [[ -d "$destination/tui" && ! -L "$destination/tui" ]] || die 'TUI archive root is missing'
}

fetch_file() {
    local name="$1" destination="$2" limit="$3"
    curl --fail --location --silent --show-error --retry 2 --retry-delay 1 \
        --connect-timeout 15 --max-time 180 --max-filesize "$limit" \
        --proto '=http,https' --proto-redir '=http,https' \
        --output "$destination" "$DOWNLOAD_BASE/$name" || die "unable to download $name from $SOURCE"
}

main() {
    local parent manifest_after candidate name
    parse_arguments "$@"
    require_commands realpath stat tr wc sha256sum bash flock mkdir mktemp mv rm chmod cmp tar gzip head cp
    OUTPUT="${OUTPUT%/}"
    [[ -n "$OUTPUT" && ! -L "$OUTPUT" ]] || argument_error '--output must be a regular directory, not a symlink or filesystem root'
    OUTPUT="$(realpath -m -- "$OUTPUT")"
    [[ "$OUTPUT" != / ]] || argument_error '--output cannot be the filesystem root'
    parent="${OUTPUT%/*}"
    mkdir -p -- "$parent"
    [[ ! -L "$OUTPUT.lock" ]] || die 'download lock cannot be a symlink'
    exec 9>>"$OUTPUT.lock"
    flock 9
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ "$CHECK" == true ]]; then
        parse_manifest "$OUTPUT/$MANIFEST_NAME" release
        parse_manifest "$OUTPUT/$FILES_NAME" files "$REVISION"
        verify_files "$OUTPUT"
        printf 'Verified %s TUI scripts and libraries at %s (revision %s)\n' "${#ASSETS[@]}" "$OUTPUT" "$REVISION"
        return
    fi
    require_commands curl
    if [[ -e "$OUTPUT" ]]; then check_directory_entries "$OUTPUT"; fi
    case "$SOURCE" in
        github) DOWNLOAD_BASE="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG" ;;
        cnb) DOWNLOAD_BASE="https://cnb.cool/${REPOSITORY,,}/-/releases/download/$RELEASE_TAG" ;;
    esac
    DOWNLOAD_BASE="${DROIDSPACES_TUI_DOWNLOAD_BASE:-$DOWNLOAD_BASE}"
    DOWNLOAD_BASE="${DOWNLOAD_BASE%/}"
    case "$DOWNLOAD_BASE" in http://?*|https://?*) ;; *) argument_error 'download base must be an HTTP(S) URL' ;; esac
    [[ "$DOWNLOAD_BASE" != *[$'\r\n\t']* && "$DOWNLOAD_BASE" != *\?* && "$DOWNLOAD_BASE" != *\#* ]] || argument_error 'invalid download base URL'
    WORK_DIR="$(mktemp -d "$parent/.${OUTPUT##*/}.download.XXXXXXXX")"
    fetch_file "$MANIFEST_NAME" "$WORK_DIR/$MANIFEST_NAME" "$MANIFEST_LIMIT"
    parse_manifest "$WORK_DIR/$MANIFEST_NAME" release
    fetch_file "$BUNDLE_NAME" "$WORK_DIR/$BUNDLE_NAME" "$BUNDLE_SIZE"
    verify_file "$WORK_DIR/$BUNDLE_NAME" "$BUNDLE_DIGEST" "$BUNDLE_SIZE"
    validate_bundle_archive "$WORK_DIR/$BUNDLE_NAME" "$WORK_DIR/archive.list"
    extract_bundle_archive "$WORK_DIR/$BUNDLE_NAME" "$WORK_DIR/unpacked"
    candidate="$WORK_DIR/unpacked/tui"
    parse_manifest "$candidate/$FILES_NAME" files "$REVISION"
    verify_files "$candidate"
    manifest_after="$WORK_DIR/.manifest-after"
    fetch_file "$MANIFEST_NAME" "$manifest_after" "$MANIFEST_LIMIT"
    cmp -s -- "$WORK_DIR/$MANIFEST_NAME" "$manifest_after" || die 'release changed while downloading; retry the build'
    cp -- "$WORK_DIR/$MANIFEST_NAME" "$candidate/$MANIFEST_NAME"
    chmod 0755 -- "$candidate" "$candidate/lib" "$candidate"/*.sh
    chmod 0644 -- "$candidate/$MANIFEST_NAME" "$candidate/$FILES_NAME"
    for name in "$candidate"/lib/*.sh; do chmod 0644 -- "$name"; done
    if [[ -d "$OUTPUT" ]]; then
        BACKUP_DIR="$(mktemp -d "$parent/.${OUTPUT##*/}.previous.XXXXXXXX")"
        OLD_MOVED=true
        mv -T -- "$OUTPUT" "$BACKUP_DIR"
    fi
    mv -T -- "$candidate" "$OUTPUT"
    PUBLISHED=true
    printf 'Downloaded %s TUI scripts and libraries from %s to %s (revision %s)\n' "${#ASSETS[@]}" "$SOURCE" "$OUTPUT" "$REVISION"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
