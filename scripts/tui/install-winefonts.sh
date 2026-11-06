#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly RELEASE_REPOSITORY="${WINEFONTS_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}"
readonly RELEASE_TAG="${WINEFONTS_RELEASE_TAG:-winefonts}"
readonly MANIFEST_NAME="winefonts-manifest"
readonly LICENSE_INVENTORY="FONT-LICENSES.tsv"
readonly FONT_PARENT="/usr/local/share/fonts"
readonly FONT_TARGET="$FONT_PARENT/winefonts"
readonly COMPONENT_STATE_DIR="/var/lib/droidspaces-tui/components"
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly MAX_ARCHIVE_BYTES=$((2 * 1024 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((8 * 1024 * 1024 * 1024))
readonly MAX_ARCHIVE_ENTRIES=50000

UI_LANG=en
DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
WORK_DIR=""
ARCHIVE_NAME=""
EXPECTED_ARCHIVE_SHA256=""
EXPECTED_ARCHIVE_SIZE=""
EXPECTED_FONT_COUNT=""
EXPECTED_FONT_BYTES=""
RELEASE_METADATA=""
EXTRACTED_FONT_DIR=""
INSTALL_STAGING=""
INSTALL_BACKUP=""
INSTALL_TARGET=""
NEW_TARGET_ACTIVE=false
INSTALL_SUCCEEDED=false
UNINSTALL=false
ASSUME_YES=false

detect_language() {
    local locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
    locale_name="${locale_name,,}"
    [[ "$locale_name" == zh* ]] && UI_LANG=zh
    return 0
}

msg() {
    if [[ "$UI_LANG" == zh ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

log() {
    printf '[winefonts] %s\n' "$(msg "$1" "$2")"
}

record_component_version() {
    local version="$1" state_file="$COMPONENT_STATE_DIR/fonts.version" temporary_file
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 0
    if ! mkdir -p -- "$COMPONENT_STATE_DIR"; then
        log "无法记录已安装的字体版本。" "Could not record the installed font version."
        return 0
    fi
    temporary_file="$(mktemp "$state_file.tmp.XXXXXXXX")" || {
        log "无法记录已安装的字体版本。" "Could not record the installed font version."
        return 0
    }
    if printf '%s\n' "$version" > "$temporary_file" && \
        chmod 0644 "$temporary_file" && mv -f -- "$temporary_file" "$state_file"; then
        return 0
    fi
    rm -f -- "$temporary_file" || true
    log "无法记录已安装的字体版本。" "Could not record the installed font version."
    return 0
}

die() {
    printf '[winefonts] %s: %s\n' "$(msg '错误' 'Error')" "$(msg "$1" "$2")" >&2
    exit 1
}

usage() {
    cat <<EOF
$(msg '用法' 'Usage'): $0 [--1|--2|--3] [-y|--yes]

  $(msg '不带参数：测试三个下载源的延迟后交互选择' 'No option: test all three sources, then choose interactively')
  --1, -1  GitHub
  --2, -2  gh-proxy.com
  --3, -3  CNB
  --uninstall  $(msg '卸载由本脚本管理的 Wine 字体' 'Uninstall Wine fonts managed by this script')
  -y, --yes  $(msg '跳过替换确认，仅在非交互场景使用' 'Skip the replacement confirmation; use only in noninteractive scenarios')

$(msg '安装目录：/usr/local/share/fonts/winefonts' 'Install directory: /usr/local/share/fonts/winefonts')
$(msg '安装器绝不会删除或修改 /usr/share/fonts。' 'The installer never deletes or changes /usr/share/fonts.')
EOF
}

parse_arguments() {
    local argument
    for argument in "$@"; do
        case "$argument" in
            -1|--1) DOWNLOAD_SOURCE=1; SKIP_SOURCE_PROBE=true ;;
            -2|--2) DOWNLOAD_SOURCE=2; SKIP_SOURCE_PROBE=true ;;
            -3|--3) DOWNLOAD_SOURCE=3; SKIP_SOURCE_PROBE=true ;;
            --uninstall) UNINSTALL=true ;;
            -y|--yes) ASSUME_YES=true ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "不支持的参数：$argument。请使用 --1、--2 或 --3。" \
                    "Unsupported argument: $argument. Use --1, --2, or --3."
                ;;
        esac
    done
}

uninstall_fonts() {
    if [[ -e "$FONT_TARGET" || -L "$FONT_TARGET" ]]; then
        [[ -d "$FONT_TARGET" && ! -L "$FONT_TARGET" ]] || \
            die "管理目录不是普通目录，拒绝删除：$FONT_TARGET" \
                "The managed path is not a regular directory; refusing to remove it: $FONT_TARGET"
        rm -rf -- "$FONT_TARGET"
    fi
    rm -f -- "$COMPONENT_STATE_DIR/fonts.version"
    if command -v fc-cache >/dev/null 2>&1; then
        fc-cache -f || die "刷新 Fontconfig 缓存失败。" "Failed to refresh the Fontconfig cache."
    fi
    log "Wine 字体已卸载；/usr/share/fonts 未修改。" \
        "Wine fonts were uninstalled; /usr/share/fonts was not modified."
}

rollback_install() {
    [[ "$INSTALL_SUCCEEDED" == false ]] || return 0

    if [[ "$NEW_TARGET_ACTIVE" == true && -n "$INSTALL_TARGET" && \
        "$INSTALL_TARGET" = /*/winefonts && "$INSTALL_TARGET" != /winefonts ]]; then
        if [[ -d "$INSTALL_TARGET" && ! -L "$INSTALL_TARGET" ]]; then
            rm -rf -- "$INSTALL_TARGET"
        fi
        NEW_TARGET_ACTIVE=false
    fi
    if [[ -n "$INSTALL_BACKUP" && -d "$INSTALL_BACKUP" && ! -L "$INSTALL_BACKUP" ]]; then
        if [[ -n "$INSTALL_TARGET" && ! -e "$INSTALL_TARGET" && ! -L "$INSTALL_TARGET" ]]; then
            if mv -- "$INSTALL_BACKUP" "$INSTALL_TARGET"; then
                INSTALL_BACKUP=""
                command -v fc-cache >/dev/null 2>&1 && fc-cache -f >/dev/null 2>&1 || true
                log "已恢复安装前的字体目录。" "Restored the previous font directory."
            else
                log "无法自动恢复旧目录，备份保留在：$INSTALL_BACKUP" \
                    "Could not restore the old directory; the backup remains at: $INSTALL_BACKUP"
            fi
        fi
    fi
}

cleanup() {
    rollback_install || true
    if [[ -n "$INSTALL_STAGING" && -d "$INSTALL_STAGING" && ! -L "$INSTALL_STAGING" ]]; then
        rm -rf -- "$INSTALL_STAGING"
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

validate_release_settings() {
    [[ "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
        die "Release 仓库必须使用 owner/repository 格式。" \
            "The Release repository must use owner/repository format."
    [[ "$RELEASE_TAG" == winefonts ]] || \
        die "Release tag 只能是 winefonts。" "The Release tag must be winefonts."
}

require_root() {
    (( EUID == 0 )) && return
    command -v sudo >/dev/null 2>&1 || \
        die "请使用 root 账户运行，或先安装 sudo。" "Run as root or install sudo first."

    local script_path="${BASH_SOURCE[0]}"
    [[ "$script_path" = /* ]] || script_path="$PWD/$script_path"
    [[ -f "$script_path" && -r "$script_path" ]] || \
        die "无法通过 sudo 重新读取安装脚本，请先把脚本下载到文件。" \
            "The installer cannot be reread through sudo; download it to a file first."
    log "正在通过 sudo 重新运行安装程序..." "Restarting the installer through sudo..."
    exec sudo env \
        "WINEFONTS_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "WINEFONTS_RELEASE_TAG=$RELEASE_TAG" \
        bash "$script_path" "$@"
}

require_commands() {
    local command_name
    for command_name in awk chmod chown cp curl fc-cache find install mkdir mktemp mv \
        rm rmdir sha256sum stat tar xz; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "缺少命令：$command_name。安装器不会自动运行包管理器。" \
                "Missing command: $command_name. The installer does not run a package manager automatically."
    done
}

require_release_metadata_parser() {
    [[ "$DOWNLOAD_SOURCE" == 3 ]] && return 0
    command -v jq >/dev/null 2>&1 || \
        die "未找到 jq，无法校验 GitHub Release 元数据。" \
            "jq was not found; GitHub Release metadata cannot be verified."
}

download_source_name() {
    case "$1" in
        1) printf 'GitHub' ;;
        2) printf 'gh-proxy.com' ;;
        3) printf 'CNB' ;;
        *) return 1 ;;
    esac
}

download_source_probe_url() {
    case "$1" in
        1) printf '%s/%s/releases/download/%s/%s' \
            "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME" ;;
        2) printf '%s/%s/releases/download/%s/%s' \
            "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME" ;;
        3) printf '%s/%s/-/releases/download/%s/%s' \
            "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME" ;;
        *) return 1 ;;
    esac
}

format_latency() {
    awk -v seconds="$1" 'BEGIN { printf "%d ms", (seconds * 1000) + 0.5 }'
}

probe_download_source() {
    local source="$1"
    local url latency result=0
    url="$(download_source_probe_url "$source")" || return 1
    if latency="$(curl -fsSL --connect-timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" \
        --max-time "$SOURCE_PROBE_TIMEOUT_SECONDS" --output /dev/null \
        --write-out '%{time_total}' "$url" 2>/dev/null)"; then
        if awk -v seconds="$latency" -v limit="$SOURCE_PROBE_TIMEOUT_SECONDS" \
            'BEGIN { exit (seconds < limit ? 0 : 1) }'; then
            format_latency "$latency"
        else
            printf '%s' "$(msg '超时' 'timeout')"
        fi
        return
    else
        result=$?
    fi
    if (( result == 28 )); then
        printf '%s' "$(msg '超时' 'timeout')"
    else
        printf '%s' "$(msg '不可用' 'unavailable')"
    fi
}

select_download_source() {
    local source latency recommendation choice
    if [[ "$SKIP_SOURCE_PROBE" == true ]]; then
        log "已按参数选择 $(download_source_name "$DOWNLOAD_SOURCE")，跳过延迟测试。" \
            "Selected $(download_source_name "$DOWNLOAD_SOURCE") from the command line; skipping latency checks."
        return
    fi

    log "正在测试下载源延迟（达到 ${SOURCE_PROBE_TIMEOUT_SECONDS} 秒视为超时）..." \
        "Testing download-source latency (timeouts at ${SOURCE_PROBE_TIMEOUT_SECONDS} seconds)..."
    for source in 1 2 3; do
        latency="$(probe_download_source "$source")"
        recommendation=""
        [[ "$source" == 3 ]] && recommendation="$(msg '（推荐）' ' (recommended)')"
        printf '%s. %s%s %s: %s\n' "$source" "$(download_source_name "$source")" \
            "$recommendation" "$(msg '延迟' 'latency')" "$latency"
    done

    while :; do
        printf '%s' "$(msg '请输入下载源编号 [1-3]: ' 'Choose a download source [1-3]: ')"
        if ! IFS= read -r choice; then
            die "无法读取下载源选择。请使用 -1/--1、-2/--2 或 -3/--3。" \
                "Unable to read a source choice. Specify -1/--1, -2/--2, or -3/--3."
        fi
        case "$choice" in
            1|2|3) DOWNLOAD_SOURCE="$choice"; return ;;
            *) log "请输入 1、2 或 3。" "Enter 1, 2, or 3." ;;
        esac
    done
}

release_download_base() {
    case "$DOWNLOAD_SOURCE" in
        1) printf '%s/%s/releases/download/%s' \
            "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        2) printf '%s/%s/releases/download/%s' \
            "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        3) printf '%s/%s/-/releases/download/%s' \
            "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        *) return 1 ;;
    esac
}

download_file() {
    local url="$1"
    local destination="$2"
    local temporary="$destination.part.$$"
    rm -f -- "$temporary"
    if ! curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 1800 \
        "$url" -o "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    mv -- "$temporary" "$destination"
}

fetch_release_metadata() {
    local url="$GITHUB_API_URL/repos/$RELEASE_REPOSITORY/releases/tags/$RELEASE_TAG"
    if ! RELEASE_METADATA="$(curl -fsSL --retry 3 --retry-all-errors \
        --connect-timeout 20 --max-time 120 "$url")"; then
        log "无法读取 GitHub 官方 Release 信息。" \
            "Could not read official GitHub Release metadata."
        return 1
    fi
    jq -e --arg tag "$RELEASE_TAG" \
        '.tag_name == $tag and .draft == false' \
        <<< "$RELEASE_METADATA" >/dev/null || {
        log "GitHub Release 状态或标签无效。" "The GitHub Release state or tag is invalid."
        return 1
    }
}

asset_metadata() {
    local name="$1"
    jq -er --arg name "$name" '
        [.assets[] | select(.name == $name)] |
        if length != 1 then error("asset is not unique")
        elif .[0].digest == null then error("asset digest is unavailable")
        else [.[0].digest, .[0].size] | @tsv
        end
    ' <<< "$RELEASE_METADATA"
}

verify_official_asset() {
    local file="$1"
    local name="$2"
    local maximum_size="$3"
    local metadata digest expected_sha expected_size actual_sha actual_size

    metadata="$(asset_metadata "$name")" || {
        log "GitHub Release 未提供 $name 的唯一 SHA-256 摘要。" \
            "GitHub Release does not provide a unique SHA-256 digest for $name."
        return 1
    }
    IFS=$'\t' read -r digest expected_size <<< "$metadata"
    [[ "$digest" =~ ^sha256:([0-9A-Fa-f]{64})$ ]] || return 1
    expected_sha="${BASH_REMATCH[1],,}"
    [[ "$expected_size" =~ ^[0-9]+$ ]] || return 1
    (( expected_size <= maximum_size )) || return 1

    actual_size="$(stat -c '%s' "$file")"
    actual_sha="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual_size" == "$expected_size" && "$actual_sha" == "$expected_sha" ]]
}

manifest_value() {
    local manifest="$1"
    local key="$2"
    awk -F= -v key="$key" '
        $1 == key {
            count++
            value = substr($0, index($0, "=") + 1)
        }
        END {
            if (count != 1) exit 1
            print value
        }
    ' "$manifest"
}

resolve_manifest() {
    local manifest="$1"
    local format manifest_tag
    format="$(manifest_value "$manifest" format)" || return 1
    manifest_tag="$(manifest_value "$manifest" release_tag)" || return 1
    ARCHIVE_NAME="$(manifest_value "$manifest" archive)" || return 1
    EXPECTED_ARCHIVE_SHA256="$(manifest_value "$manifest" archive_sha256)" || return 1
    EXPECTED_ARCHIVE_SIZE="$(manifest_value "$manifest" archive_size)" || return 1
    EXPECTED_FONT_COUNT="$(manifest_value "$manifest" font_file_count)" || return 1
    EXPECTED_FONT_BYTES="$(manifest_value "$manifest" font_file_bytes)" || return 1

    [[ "$format" == 1 && "$manifest_tag" == "$RELEASE_TAG" ]] || return 1
    [[ "$ARCHIVE_NAME" =~ ^winefonts-[0-9]{8}-[0-9]{6}\.tar\.xz$ ]] || return 1
    [[ "$EXPECTED_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$EXPECTED_ARCHIVE_SIZE" =~ ^[0-9]+$ ]] || return 1
    [[ "$EXPECTED_FONT_COUNT" =~ ^[0-9]+$ && "$EXPECTED_FONT_COUNT" -gt 0 ]] || return 1
    [[ "$EXPECTED_FONT_BYTES" =~ ^[0-9]+$ && "$EXPECTED_FONT_BYTES" -gt 0 ]] || return 1
    (( EXPECTED_ARCHIVE_SIZE <= MAX_ARCHIVE_BYTES ))
}

validate_archive() {
    local archive="$1"
    local members entry entry_count=0
    members="$(tar --quoting-style=escape -tJf "$archive")" || \
        die "下载文件不是有效的 tar.xz。" "The downloaded file is not a valid tar.xz archive."
    [[ -n "$members" ]] || die "下载压缩包为空。" "The downloaded archive is empty."

    while IFS= read -r entry; do
        entry_count=$((entry_count + 1))
        (( entry_count <= MAX_ARCHIVE_ENTRIES )) || \
            die "压缩包条目数量超过限制。" "The archive contains too many entries."
        [[ "$entry" != *\\* ]] || \
            die "压缩包包含不可安全解析的文件名。" "The archive contains an unsafe filename."
        case "$entry" in
            /*|.|./*|..|../*|*/.|*/./*|*/..|*/../*|*//* )
                die "压缩包包含不安全路径。" "The archive contains an unsafe path."
                ;;
            winefonts/|winefonts/*) ;;
            *)
                die "压缩包包含 winefonts/ 之外的文件。" \
                    "The archive contains files outside winefonts/."
                ;;
        esac
    done <<< "$members"

    LC_ALL=C tar -tvJf "$archive" | awk -v maximum="$MAX_EXTRACTED_BYTES" '
        {
            type = substr($1, 1, 1)
            if (type !~ /^[-d]$/ || $3 !~ /^[0-9]+$/) exit 1
            total += $3
            if (total > maximum) exit 1
        }
    ' || die "压缩包包含链接、特殊文件或解压后超过大小限制。" \
        "The archive contains links, special files, or exceeds the extracted-size limit."
}

safe_relative_path() {
    local path="$1"
    [[ -n "$path" && "$path" != /* && "$path" != *\\* && "$path" != *$'\n'* && \
        "$path" != *$'\r'* && "$path" != *$'\t'* ]] || return 1
    case "/$path/" in
        */./*|*/../*|*//* ) return 1 ;;
    esac
    [[ "$path" != . && "$path" != .. ]]
}

is_font_file() {
    local lower="${1,,}"
    case "$lower" in
        *.ttf|*.ttc|*.otf|*.otc|*.woff|*.woff2|*.fon) return 0 ;;
        *) return 1 ;;
    esac
}

is_allowed_license() {
    case "$1" in
        OFL-1.1|Apache-2.0|Ubuntu-Font-1.0|CC-BY-4.0|\
        'GPL-2.0-or-later WITH Font-exception-2.0') return 0 ;;
        *) return 1 ;;
    esac
}

validate_extracted_tree() {
    local root="$1"
    local inventory="$root/$LICENSE_INVENTORY"
    local font_path spdx_id license_path source_url extra path relative actual_bytes=0
    local -A declared_fonts=()

    [[ -d "$root" && ! -L "$root" ]] || return 1
    [[ -f "$inventory" && ! -L "$inventory" ]] || return 1
    [[ -z "$(find "$root" -mindepth 1 ! -type d ! -type f -print -quit)" ]] || return 1

    while IFS=$'\t' read -r font_path spdx_id license_path source_url extra || [[ -n "$font_path$spdx_id$license_path$source_url$extra" ]]; do
        source_url="${source_url%$'\r'}"
        [[ -z "$font_path" || "$font_path" == \#* ]] && continue
        [[ -n "$spdx_id" && -n "$license_path" && -n "$source_url" && -z "$extra" ]] || return 1
        safe_relative_path "$font_path" || return 1
        safe_relative_path "$license_path" || return 1
        is_font_file "$font_path" || return 1
        is_allowed_license "$spdx_id" || return 1
        [[ "$license_path" == licenses/* && "$source_url" == https://* ]] || return 1
        [[ -f "$root/$font_path" && ! -L "$root/$font_path" ]] || return 1
        [[ -s "$root/$license_path" && ! -L "$root/$license_path" ]] || return 1
        [[ -z "${declared_fonts[$font_path]:-}" ]] || return 1
        declared_fonts["$font_path"]=1
        actual_bytes=$((actual_bytes + $(stat -c '%s' "$root/$font_path")))
    done < "$inventory"

    while IFS= read -r -d '' path; do
        relative="${path#"$root/"}"
        safe_relative_path "$relative" || return 1
        if is_font_file "$relative"; then
            [[ -n "${declared_fonts[$relative]:-}" ]] || return 1
        else
            case "$relative" in
                "$LICENSE_INVENTORY"|README.md|licenses/*.txt|licenses/*.md) ;;
                *) return 1 ;;
            esac
        fi
    done < <(find "$root" -type f -print0)

    [[ "${#declared_fonts[@]}" == "$EXPECTED_FONT_COUNT" && "$actual_bytes" == "$EXPECTED_FONT_BYTES" ]]
}

download_and_extract() {
    local base manifest archive actual_sha actual_size attempt extract_dir
    WORK_DIR="$(mktemp -d -t winefonts.XXXXXXXX)"
    chmod 0700 "$WORK_DIR"
    base="$(release_download_base)"
    manifest="$WORK_DIR/$MANIFEST_NAME"

    for attempt in 1 2 3; do
        log "正在从 $(download_source_name "$DOWNLOAD_SOURCE") 下载 Release 清单..." \
            "Downloading the Release manifest from $(download_source_name "$DOWNLOAD_SOURCE")..."
        if ! download_file "$base/$MANIFEST_NAME" "$manifest" || \
            { [[ "$DOWNLOAD_SOURCE" != 3 ]] && \
              { ! fetch_release_metadata || ! verify_official_asset "$manifest" "$MANIFEST_NAME" $((1024 * 1024)); }; } || \
            ! resolve_manifest "$manifest"; then
            log "Release 正在更新或网络暂时失败，准备重试（$attempt/3）。" \
                "The Release is updating or the network failed; retrying ($attempt/3)."
            continue
        fi

        archive="$WORK_DIR/$ARCHIVE_NAME"
        log "正在下载开源字体包：$ARCHIVE_NAME" "Downloading open-source fonts: $ARCHIVE_NAME"
        if ! download_file "$base/$ARCHIVE_NAME" "$archive" || \
            { [[ "$DOWNLOAD_SOURCE" != 3 ]] && \
              { ! fetch_release_metadata || ! verify_official_asset "$archive" "$ARCHIVE_NAME" "$MAX_ARCHIVE_BYTES"; }; }; then
            log "Release 正在更新或网络暂时失败，准备重试（$attempt/3）。" \
                "The Release is updating or the network failed; retrying ($attempt/3)."
            continue
        fi
        actual_size="$(stat -c '%s' "$archive")"
        actual_sha="$(sha256sum "$archive" | awk '{print $1}')"
        if [[ "$actual_size" != "$EXPECTED_ARCHIVE_SIZE" || "$actual_sha" != "$EXPECTED_ARCHIVE_SHA256" ]]; then
            log "字体包与已校验清单不一致，准备重试（$attempt/3）。" \
                "The font archive does not match the verified manifest; retrying ($attempt/3)."
            continue
        fi

        validate_archive "$archive"
        extract_dir="$WORK_DIR/extracted-$attempt"
        mkdir -m 0700 "$extract_dir"
        if ! tar --no-same-owner --no-same-permissions -xJf "$archive" -C "$extract_dir"; then
            die "无法安全解压字体包。" "Could not safely extract the font archive."
        fi
        EXTRACTED_FONT_DIR="$extract_dir/winefonts"
        if ! validate_extracted_tree "$EXTRACTED_FONT_DIR"; then
            die "解压后的字体或许可证清单无效。" \
                "The extracted fonts or license inventory are invalid."
        fi
        return
    done

    die "连续三次无法稳定获取 Release 字体包，请稍后重试。" \
        "Could not obtain a consistent Release archive after three attempts; try again later."
}

confirm_replacement() {
    local target="$1"
    local answer
    [[ "$ASSUME_YES" == true ]] && return 0
    [[ -e "$target" || -L "$target" ]] || return 0
    [[ -d "$target" && ! -L "$target" ]] || \
        die "管理目录不是普通目录，拒绝替换：$target" \
            "The managed path is not a regular directory; refusing replacement: $target"
    if [[ ! -t 0 ]]; then
        die "非交互运行时拒绝替换已有字体目录。" \
            "Refusing to replace an existing font directory noninteractively."
    fi
    printf '%s' "$(msg \
        "已存在 $target，是否仅替换这个由安装器管理的目录？[y/N]: " \
        "$target already exists. Replace only this installer-managed directory? [y/N]: ")"
    IFS= read -r answer || answer=""
    case "${answer,,}" in
        y|yes|是) return 0 ;;
        *) die "用户取消安装；现有字体未修改。" "Installation cancelled; existing fonts were not changed." ;;
    esac
}

install_fonts() {
    local source="$1"
    local target="$2"
    local parent backup_template

    [[ "$target" = /*/winefonts && "$target" != /winefonts ]] || \
        die "内部安装目标无效。" "The internal installation target is invalid."
    INSTALL_TARGET="$target"
    parent="${target%/*}"
    [[ ! -L "$target" && ( ! -e "$target" || -d "$target" ) ]] || \
        die "管理目录不是普通目录，拒绝替换：$target" \
            "The managed path is not a regular directory; refusing replacement: $target"
    install -d -m 0755 "$parent"
    INSTALL_STAGING="$(mktemp -d "$parent/.winefonts.new.XXXXXXXX")"
    cp -a -- "$source/." "$INSTALL_STAGING/"
    chown -R 0:0 "$INSTALL_STAGING"
    find "$INSTALL_STAGING" -type d -exec chmod 0755 {} +
    find "$INSTALL_STAGING" -type f -exec chmod 0644 {} +

    if [[ -d "$target" ]]; then
        backup_template="$parent/.winefonts.backup.XXXXXXXX"
        INSTALL_BACKUP="$(mktemp -d "$backup_template")"
        rmdir -- "$INSTALL_BACKUP"
        mv -- "$target" "$INSTALL_BACKUP"
    fi
    if ! mv -- "$INSTALL_STAGING" "$target"; then
        die "无法启用新字体目录。" "Could not activate the new font directory."
    fi
    INSTALL_STAGING=""
    NEW_TARGET_ACTIVE=true

    if ! fc-cache -f; then
        die "刷新 Fontconfig 缓存失败，正在恢复旧字体。" \
            "Fontconfig cache refresh failed; restoring the previous fonts."
    fi
    [[ -f "$target/$LICENSE_INVENTORY" ]] || \
        die "安装后许可证清单缺失，正在恢复旧字体。" \
            "The license inventory is missing after installation; restoring the previous fonts."
    [[ -n "$(find "$target" -type f \( -iname '*.ttf' -o -iname '*.ttc' -o -iname '*.otf' \
        -o -iname '*.otc' -o -iname '*.woff' -o -iname '*.woff2' -o -iname '*.fon' \) -print -quit)" ]] || \
        die "安装后没有找到字体文件，正在恢复旧字体。" \
            "No font files were found after installation; restoring the previous fonts."

    INSTALL_SUCCEEDED=true
    NEW_TARGET_ACTIVE=false
    if [[ -n "$INSTALL_BACKUP" && -d "$INSTALL_BACKUP" ]]; then
        rm -rf -- "$INSTALL_BACKUP"
        INSTALL_BACKUP=""
    fi
}

main() {
    local archive_version
    detect_language
    parse_arguments "$@"
    validate_release_settings
    require_root "$@"
    if [[ "$UNINSTALL" == true ]]; then
        uninstall_fonts
        return
    fi
    require_commands
    select_download_source
    require_release_metadata_parser
    log "下载源：$(download_source_name "$DOWNLOAD_SOURCE")" \
        "Download source: $(download_source_name "$DOWNLOAD_SOURCE")"
    download_and_extract
    confirm_replacement "$FONT_TARGET"
    install_fonts "$EXTRACTED_FONT_DIR" "$FONT_TARGET"
    archive_version="${ARCHIVE_NAME#winefonts-}"
    archive_version="${archive_version%.tar.xz}"
    record_component_version "$archive_version"
    log "安装完成：$FONT_TARGET" "Installation complete: $FONT_TARGET"
    log "未修改 /usr/share/fonts；商业字体需由用户从有许可证的电脑自行补全。" \
        "Did not modify /usr/share/fonts; users must supply licensed commercial fonts themselves."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
