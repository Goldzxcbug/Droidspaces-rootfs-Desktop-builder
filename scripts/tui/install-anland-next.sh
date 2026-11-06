#!/usr/bin/env bash
set -euo pipefail

# Install the Anland Next session package published by build-anland-packages.yml.
# The package itself remains owned by apt, dnf, or pacman; this script only
# selects, verifies, and installs the native package for the current system.
readonly DEFAULT_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly RELEASE_REPOSITORY="${ANLAND_NEXT_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}"
RELEASE_TAG="${ANLAND_NEXT_RELEASE_TAG:-}"
readonly ROLLING_RELEASE_TAG="anland-session-packages"
readonly MANIFEST_NAME="anland-session-manifest"
readonly CHECKSUMS_NAME="SHA256SUMS"
readonly MAX_MANIFEST_BYTES=$((1024 * 1024))
readonly MAX_CHECKSUMS_BYTES=$((1024 * 1024))
readonly MAX_PACKAGE_BYTES=$((128 * 1024 * 1024))
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly APT_HOLD_STATE="/var/lib/anland-next/apt-holds"
readonly DNF_MANAGED_BEGIN="# BEGIN anland-next package holds"
readonly DNF_MANAGED_END="# END anland-next package holds"
readonly MESA_DNF_MANAGED_BEGIN="# BEGIN install-mesa package holds"
readonly MESA_DNF_MANAGED_END="# END install-mesa package holds"
readonly SYSTEMD257_STATE="/etc/droidspaces-systemd257"
readonly COMPONENT_STATE_DIR="${DROIDSPACES_COMPONENT_STATE_DIR:-/var/lib/droidspaces-tui/components}"
readonly DESKTOP_CONFIG="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"
readonly COMPONENT_NAME="next"

WORK_DIR=""
PREPARED_WORK_DIR="${ANLAND_NEXT_WORK_DIR:-}"
PREPARED_PACKAGE_FILE="${ANLAND_NEXT_PACKAGE_FILE:-}"
UI_LANG="en"
TARGET=""
PACKAGE_TYPE=""
MANIFEST_TARGET=""
ASSET_PREFIX=""
ASSET_SUFFIX=""
PACKAGE_NAME=""
PACKAGE_FILE=""
PACKAGE_DIR=""
PACKAGE_VERSION=""
DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
CHECKSUMS_FILE=""
EXPECTED_MANIFEST_SHA256=""
EXPECTED_PACKAGE_SHA256=""
OFFICIAL_RELEASE_METADATA=""
UNINSTALL=false

detect_language() {
    local locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
    locale_name="${locale_name,,}"
    if [[ "$locale_name" == zh* ]]; then
        UI_LANG="zh"
    fi
}

msg() {
    if [[ "$UI_LANG" == "zh" ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

log() {
    printf '[anland-next] %s\n' "$(msg "$1" "$2")"
}

die() {
    printf '[anland-next] %s: %s\n' "$(msg '错误' 'Error')" "$(msg "$1" "$2")" >&2
    exit 1
}

record_component_version() {
    local version="$1" state_file="$COMPONENT_STATE_DIR/anland-next.version" temporary_file
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 0
    if ! mkdir -p -- "$COMPONENT_STATE_DIR"; then
        log "无法记录已安装的 Next 版本。" "Could not record the installed Next version."
        return 0
    fi
    temporary_file="$(mktemp "$state_file.tmp.XXXXXXXX")" || {
        log "无法记录已安装的 Next 版本。" "Could not record the installed Next version."
        return 0
    }
    if printf '%s\n' "$version" > "$temporary_file" && \
        chmod 0644 "$temporary_file" && mv -f -- "$temporary_file" "$state_file"; then
        return 0
    fi
    rm -f -- "$temporary_file" || true
    log "无法记录已安装的 Next 版本。" "Could not record the installed Next version."
    return 0
}

update_desktop_config() {
    local desktop="anland-next" config_dir temporary_file line configured_desktop=""
    local desktop_lines=0

    config_dir="$(dirname -- "$DESKTOP_CONFIG")"
    if [[ ! -e "$DESKTOP_CONFIG" && ! -L "$DESKTOP_CONFIG" ]]; then
        if [[ ! -d "$config_dir" ]]; then
            install -d -m 0755 -- "$config_dir" || \
                die "无法创建桌面配置目录。" "Could not create the desktop configuration directory."
        fi
        temporary_file="$(mktemp "$config_dir/.droidspaces-desktop.conf.tmp.XXXXXXXX")" || \
            die "无法创建临时桌面配置。" "Could not create a temporary desktop configuration."
        if ! printf 'DESKTOP=%s\nDISPLAY_BACKEND=anland-wayland\n' "$desktop" > "$temporary_file" || \
            ! chmod 0644 "$temporary_file" || ! mv -f -- "$temporary_file" "$DESKTOP_CONFIG"; then
            rm -f -- "$temporary_file" || true
            die "无法创建桌面配置。" "Could not create the desktop configuration."
        fi
        log "已创建桌面配置：DESKTOP=${desktop}。" \
            "Created the desktop configuration with DESKTOP=${desktop}."
        return
    fi

    if [[ ! -f "$DESKTOP_CONFIG" || -L "$DESKTOP_CONFIG" || ! -r "$DESKTOP_CONFIG" ]]; then
        die "桌面配置不是可安全修改的普通文件：${DESKTOP_CONFIG}。" \
            "The desktop configuration is not a safely writable regular file: ${DESKTOP_CONFIG}."
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            DESKTOP=*)
                configured_desktop="${line#DESKTOP=}"
                ((desktop_lines += 1))
                ;;
        esac
    done < "$DESKTOP_CONFIG"
    if ((desktop_lines != 1)) || \
        [[ ! "$configured_desktop" =~ ^(none|[a-z][a-z0-9-]*)$ ]]; then
        die "桌面配置格式无效，未覆盖原文件。" \
            "The desktop configuration is invalid; the original file was not overwritten."
    fi
    if [[ "$configured_desktop" != none && "$configured_desktop" != anland-next ]]; then
        log "保留现有桌面配置：DESKTOP=${configured_desktop}。" \
            "Keeping the existing desktop configuration: DESKTOP=${configured_desktop}."
        return
    fi

    temporary_file="$(mktemp "$config_dir/.droidspaces-desktop.conf.tmp.XXXXXXXX")" || \
        die "无法创建临时桌面配置。" "Could not create a temporary desktop configuration."
    if ! awk -v desktop="$desktop" '
        /^DESKTOP=/ { print "DESKTOP=" desktop; next }
        /^DISPLAY_BACKEND=/ { if (!backend++) print "DISPLAY_BACKEND=anland-wayland"; next }
        { print }
        END { if (!backend) print "DISPLAY_BACKEND=anland-wayland" }
    ' "$DESKTOP_CONFIG" > "$temporary_file" || ! chmod 0644 "$temporary_file" || \
        ! mv -f -- "$temporary_file" "$DESKTOP_CONFIG"; then
        rm -f -- "$temporary_file" || true
        die "无法更新桌面配置。" "Could not update the desktop configuration."
    fi
    log "已将桌面配置更新为 DESKTOP=${desktop}。" \
        "Updated the desktop configuration to DESKTOP=${desktop}."
}

parse_arguments() {
    local argument

    for argument in "$@"; do
        case "$argument" in
            -1|--1)
                DOWNLOAD_SOURCE="1"
                SKIP_SOURCE_PROBE=true
                ;;
            -2|--2)
                DOWNLOAD_SOURCE="2"
                SKIP_SOURCE_PROBE=true
                ;;
            -3|--3)
                DOWNLOAD_SOURCE="3"
                SKIP_SOURCE_PROBE=true
                ;;
            --uninstall)
                UNINSTALL=true
                ;;
            -h|--help)
                cat <<EOF
用法: $0 [选项]

安装或卸载 Anland Next session 原生软件包。

  -1, --1          使用 GitHub
  -2, --2          使用 gh-proxy.com
  -3, --3          使用 CNB
  --uninstall      卸载 anland-session，不删除发行版依赖
  -h, --help       显示帮助
EOF
                exit 0
                ;;
            *)
                die "不支持的参数：${argument}。可用参数为 -1/--1、-2/--2、-3/--3、--uninstall。" \
                    "Unsupported argument: ${argument}. Valid arguments are -1/--1, -2/--2, -3/--3, and --uninstall."
                ;;
        esac
    done
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

require_root() {
    if (( EUID == 0 )); then
        return
    fi

    command -v sudo >/dev/null 2>&1 || \
        die "请使用 root 账户运行此脚本。" "Please run this script as root."
    log "正在通过 sudo 重新运行安装程序..." "Restarting the installer with sudo..."
    local script_path="${BASH_SOURCE[0]}"
    [[ "$script_path" = /* ]] || script_path="$PWD/$script_path"
    local status
    if sudo env \
        "ANLAND_NEXT_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "ANLAND_NEXT_RELEASE_TAG=$RELEASE_TAG" \
        "ANLAND_NEXT_WORK_DIR=$WORK_DIR" \
        "ANLAND_NEXT_PACKAGE_FILE=$PACKAGE_FILE" \
        "DROIDSPACES_COMPONENT_STATE_DIR=$COMPONENT_STATE_DIR" \
        "DROIDSPACES_DESKTOP_CONFIG=$DESKTOP_CONFIG" \
        bash "$script_path" "$@"; then
        status=0
    else
        status=$?
    fi
    cleanup
    exit "$status"
}

detect_target() {
    [[ -r /etc/os-release ]] || \
        die "无法读取 /etc/os-release。" "Unable to read /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ -n "${ID:-}" ]] || \
        die "/etc/os-release 缺少 ID。" "/etc/os-release does not contain ID."
    local distro_id="${ID,,}"
    local version_id="${VERSION_ID:-}"
    local system_name="${PRETTY_NAME:-$distro_id${version_id:+ $version_id}}"

    case "$distro_id" in
        arch|archarm|archlinux)
            TARGET="Arch Linux"
            PACKAGE_TYPE="pkg.tar.*"
            MANIFEST_TARGET="arch"
            ASSET_PREFIX="anland-session-arch-anland-session-"
            ASSET_SUFFIX="-aarch64.pkg.tar.zst"
            ;;
        *)
            [[ -n "$version_id" ]] || \
                die "/etc/os-release 缺少 VERSION_ID。" "/etc/os-release does not contain VERSION_ID."
            case "$distro_id:$version_id" in
                debian:13*)
                    TARGET="Debian 13"
                    PACKAGE_TYPE="deb"
                    MANIFEST_TARGET="debian13"
                    ASSET_PREFIX="anland-session-debian13-anland-session_"
                    ASSET_SUFFIX="_arm64.deb"
                    ;;
                ubuntu:26.04*)
                    TARGET="Ubuntu 26.04"
                    PACKAGE_TYPE="deb"
                    MANIFEST_TARGET="ubuntu2604"
                    ASSET_PREFIX="anland-session-ubuntu2604-anland-session_"
                    ASSET_SUFFIX="_arm64.deb"
                    ;;
                fedora:43*)
                    TARGET="Fedora 43"
                    PACKAGE_TYPE="rpm"
                    MANIFEST_TARGET="fedora43"
                    ASSET_PREFIX="anland-session-fedora43-anland-session-"
                    ASSET_SUFFIX=".aarch64.rpm"
                    ;;
                fedora:44*)
                    TARGET="Fedora 44"
                    PACKAGE_TYPE="rpm"
                    MANIFEST_TARGET="fedora44"
                    ASSET_PREFIX="anland-session-fedora44-anland-session-"
                    ASSET_SUFFIX=".aarch64.rpm"
                    ;;
                *)
                    die "不支持当前系统 ${system_name}。仅支持 Debian 13、Ubuntu 26.04、Fedora 43/44、Arch Linux。" \
                        "Unsupported system: ${system_name}. Supported systems are Debian 13, Ubuntu 26.04, Fedora 43/44, and Arch Linux."
                    ;;
            esac
            ;;
    esac

    log "已识别系统：${system_name} -> ${TARGET}" \
        "Detected system: ${system_name} -> ${TARGET}"
}

check_architecture() {
    case "$(uname -m)" in
        aarch64|arm64) ;;
        *)
            die "预编译包仅支持 ARM64/aarch64，当前架构为 $(uname -m)。" \
                "The prebuilt packages support ARM64/aarch64 only; current architecture is $(uname -m)."
            ;;
    esac
}

validate_repository() {
    if [[ ! "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        die "Release 仓库必须是 owner/repository 格式。" \
            "The Release repository must use the owner/repository format."
    fi
}

validate_release_tag() {
    case "$RELEASE_TAG" in
        "$ROLLING_RELEASE_TAG") ;;
        *)
            die "Release tag 只能是 ${ROLLING_RELEASE_TAG}。" \
                "The Release tag must be ${ROLLING_RELEASE_TAG}."
            ;;
    esac
}

resolve_release_tag() {
    validate_repository
    if [[ -z "$RELEASE_TAG" ]]; then
        RELEASE_TAG="$ROLLING_RELEASE_TAG"
    fi
    validate_release_tag
    log "使用固定滚动 Release: ${RELEASE_TAG}" "Using rolling Release: ${RELEASE_TAG}"
}

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --timeout=20 --waitretry=3 --retry-connrefused -O "$destination" "$url"
    else
        die "未找到 curl 或 wget，无法下载安装包。" "Neither curl nor wget was found; packages cannot be downloaded."
    fi
}

download_stdout() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 60 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 --timeout=20 --waitretry=3 --retry-connrefused -O - "$url"
    else
        die "未找到 curl 或 wget，无法读取 Release 信息。" "Neither curl nor wget was found; Release information cannot be read."
    fi
}

release_download_base() {
    case "$DOWNLOAD_SOURCE" in
        1) printf '%s/%s/releases/download/%s' "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        2) printf '%s/%s/releases/download/%s' "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        3) printf '%s/%s/-/releases/download/%s' "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        *) die "下载源选择无效。" "The selected download source is invalid." ;;
    esac
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
    local source="$1"

    case "$source" in
        1)
            printf '%s/%s/releases/download/%s/%s' \
                "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        2)
            printf '%s/%s/releases/download/%s/%s' \
                "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        3)
            printf '%s/%s/-/releases/download/%s/%s' \
                "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        *) return 1 ;;
    esac
}

format_latency() {
    local seconds="$1"

    awk -v seconds="$seconds" 'BEGIN { printf "%d ms", (seconds * 1000) + 0.5 }'
}

probe_download_source() {
    local source="$1"
    local probe_url latency started finished probe_status=0
    local -a probe_command

    probe_url="$(download_source_probe_url "$source")" || return 1
    if command -v curl >/dev/null 2>&1; then
        if latency="$(curl -fsSL --connect-timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" \
            --max-time "$SOURCE_PROBE_TIMEOUT_SECONDS" --output /dev/null \
            --write-out '%{time_total}' "$probe_url" 2>/dev/null)"; then
            if awk -v seconds="$latency" -v limit="$SOURCE_PROBE_TIMEOUT_SECONDS" \
                'BEGIN { exit (seconds < limit ? 0 : 1) }'; then
                format_latency "$latency"
                return
            fi
            printf '%s' "$(msg '超时' 'timeout')"
            return
        else
            probe_status=$?
        fi
    elif command -v wget >/dev/null 2>&1; then
        command -v timeout >/dev/null 2>&1 || \
            die "wget 测试下载源需要 timeout 命令以限制为 ${SOURCE_PROBE_TIMEOUT_SECONDS} 秒。" \
                "Testing download sources with wget requires timeout to enforce the ${SOURCE_PROBE_TIMEOUT_SECONDS}-second limit."
        started="$(date +%s%3N 2>/dev/null || true)"
        probe_command=(wget -q --tries=1 --timeout="$SOURCE_PROBE_TIMEOUT_SECONDS" -O /dev/null "$probe_url")
        probe_command=(timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" "${probe_command[@]}")
        if "${probe_command[@]}"; then
            finished="$(date +%s%3N 2>/dev/null || true)"
            if [[ "$started" =~ ^[0-9]+$ && "$finished" =~ ^[0-9]+$ ]]; then
                if (( finished - started < SOURCE_PROBE_TIMEOUT_SECONDS * 1000 )); then
                    printf '%d ms' "$((finished - started))"
                else
                    printf '%s' "$(msg '超时' 'timeout')"
                fi
            else
                printf '%s' "$(msg '可用' 'available')"
            fi
            return
        else
            probe_status=$?
        fi
    else
        die "未找到 curl 或 wget，无法测试下载源。" "Neither curl nor wget was found; download sources cannot be tested."
    fi

    if (( probe_status == 28 || probe_status == 124 )); then
        printf '%s' "$(msg '超时' 'timeout')"
    else
        printf '%s' "$(msg '不可用' 'unavailable')"
    fi
}

select_download_source() {
    local source latency choice recommendation

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
        if [[ "$source" == "3" ]]; then
            recommendation="$(msg '（推荐）' ' (recommended)')"
        fi
        printf '%s. %s%s %s: %s\n' "$source" "$(download_source_name "$source")" \
            "$recommendation" "$(msg '延迟' 'latency')" "$latency"
    done

    while :; do
        printf '%s' "$(msg '请输入下载源编号 [1-3]: ' 'Choose a download source [1-3]: ')"
        if ! IFS= read -r choice; then
            die "无法读取下载源选择。请使用 -1/--1、-2/--2 或 -3/--3 指定下载源。" \
                "Unable to read a download-source choice. Specify -1/--1, -2/--2, or -3/--3."
        fi
        case "$choice" in
            1|2|3)
                DOWNLOAD_SOURCE="$choice"
                return
                ;;
            *)
                log "请输入 1、2 或 3。" "Enter 1, 2, or 3."
                ;;
        esac
    done
}

fetch_official_release_metadata() {
    local api_url

    api_url="${GITHUB_API_URL}/repos/${RELEASE_REPOSITORY}/releases/tags/${RELEASE_TAG}"
    if ! OFFICIAL_RELEASE_METADATA="$(download_stdout "$api_url")"; then
        log "无法获取 GitHub 官方 SHA-256 校验值，拒绝使用第三方镜像包。" \
            "Could not obtain GitHub's official SHA-256 digest; refusing the third-party mirror package."
        return 1
    fi
}

release_asset_sha256() {
    local requested_name="$1"
    local digest

    if ! digest="$(jq -er --arg name "$requested_name" --arg tag "$RELEASE_TAG" '
        if .tag_name != $tag then
            error("release tag mismatch")
        else
            [.assets[] | select(.name == $name) | .digest] |
            if length == 1 then .[0] else error("asset digest is not unique") end
        end
    ' <<< "$OFFICIAL_RELEASE_METADATA" 2>/dev/null)"; then
        return 1
    fi
    if [[ ! "$digest" =~ ^sha256:([0-9A-Fa-f]{64})$ ]]; then
        return 1
    fi

    printf '%s' "${BASH_REMATCH[1],,}"
}

resolve_official_manifest_sha256() {
    EXPECTED_MANIFEST_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "1" ]]; then
        return
    fi
    command -v jq >/dev/null 2>&1 || \
        die "选择第三方镜像需要 jq 来校验 GitHub Release。" \
            "Selecting a third-party mirror requires jq to verify the GitHub Release."
    command -v sha256sum >/dev/null 2>&1 || \
        die "选择第三方镜像需要 sha256sum 来校验下载文件。" \
            "Selecting a third-party mirror requires sha256sum to verify downloaded files."
    if ! fetch_official_release_metadata; then
        return 1
    fi
    if ! EXPECTED_MANIFEST_SHA256="$(release_asset_sha256 "$MANIFEST_NAME")"; then
        log "GitHub Release 未提供 ${MANIFEST_NAME} 的 SHA-256 校验值，拒绝使用第三方镜像包。" \
            "GitHub Release did not provide a SHA-256 digest for ${MANIFEST_NAME}; refusing the third-party mirror package."
        return 1
    fi
}

resolve_official_package_sha256() {
    EXPECTED_PACKAGE_SHA256=""
    [[ "$DOWNLOAD_SOURCE" == 1 ]] && return 0
    EXPECTED_PACKAGE_SHA256="$(release_asset_sha256 "$PACKAGE_NAME")" || {
        log "GitHub Release 未提供 ${PACKAGE_NAME} 的 SHA-256 校验值。" \
            "GitHub Release has no valid SHA-256 digest for ${PACKAGE_NAME}."
        return 1
    }
}

checksum_sha256_for_asset() {
    local checksums_file="$1" asset_name="$2"

    awk -v asset_name="$asset_name" '
        $1 ~ /^[0-9A-Fa-f]+$/ && length($1) == 64 && NF == 2 {
            name = $2
            sub(/^\*/, "", name)
            if (name == asset_name) {
                digest = tolower($1)
                count += 1
            }
        }
        END {
            if (count == 1) {
                print digest
            } else {
                exit 1
            }
        }
    ' "$checksums_file"
}

prepare_cnb_checksums() {
    local base_url="$1" checksum_size

    [[ "$DOWNLOAD_SOURCE" == 3 ]] || return 0
    CHECKSUMS_FILE="$WORK_DIR/$CHECKSUMS_NAME"
    download_file "$base_url/$CHECKSUMS_NAME" "$CHECKSUMS_FILE" || return 1
    checksum_size="$(stat -c '%s' "$CHECKSUMS_FILE")" || return 1
    [[ "$checksum_size" =~ ^[0-9]+$ && "$checksum_size" -gt 0 && \
       "$checksum_size" -le "$MAX_CHECKSUMS_BYTES" ]] || return 1
    EXPECTED_MANIFEST_SHA256="$(checksum_sha256_for_asset "$CHECKSUMS_FILE" "$MANIFEST_NAME")" || {
        log "CNB Release 的 ${CHECKSUMS_NAME} 缺少 ${MANIFEST_NAME} 的唯一 SHA-256 校验值。" \
            "The CNB Release ${CHECKSUMS_NAME} has no unique SHA-256 digest for ${MANIFEST_NAME}."
        return 1
    }
}

resolve_cnb_package_sha256() {
    [[ "$DOWNLOAD_SOURCE" == 3 ]] || return 0
    EXPECTED_PACKAGE_SHA256="$(checksum_sha256_for_asset "$CHECKSUMS_FILE" "$PACKAGE_NAME")" || {
        log "CNB Release 的 ${CHECKSUMS_NAME} 缺少 ${PACKAGE_NAME} 的唯一 SHA-256 校验值。" \
            "The CNB Release ${CHECKSUMS_NAME} has no unique SHA-256 digest for ${PACKAGE_NAME}."
        return 1
    }
}

validate_package_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ && "$1" != *..* ]]
}

resolve_manifest_package() {
    local manifest_file="$1" format release_tag
    local -a selected_names=()

    format="$(awk -F= '$1 == "format" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    release_tag="$(awk -F= '$1 == "release_tag" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    [[ "$format" == 1 && "$release_tag" == "$RELEASE_TAG" ]] || return 1
    mapfile -t selected_names < <(
        awk -F= -v key="$MANIFEST_TARGET" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest_file"
    )
    [[ "${#selected_names[@]}" -eq 1 ]] || return 1
    PACKAGE_NAME="${selected_names[0]}"
    validate_package_name "$PACKAGE_NAME" || return 1
    case "$PACKAGE_NAME" in
        "${ASSET_PREFIX}"*"${ASSET_SUFFIX}") ;;
        *) return 1 ;;
    esac
}

validate_package_file() {
    local package package_arch package_version package_release package_info
    local package_name package_architecture
    [[ -f "$PACKAGE_FILE" && ! -L "$PACKAGE_FILE" ]] || return 1
    local package_size
    package_size="$(stat -c '%s' "$PACKAGE_FILE")"
    [[ "$package_size" =~ ^[0-9]+$ && "$package_size" -gt 0 && \
       "$package_size" -le "$MAX_PACKAGE_BYTES" ]] || return 1

    case "$PACKAGE_TYPE" in
        deb)
            package="$(dpkg-deb -f "$PACKAGE_FILE" Package)"
            package_arch="$(dpkg-deb -f "$PACKAGE_FILE" Architecture)"
            package_version="$(dpkg-deb -f "$PACKAGE_FILE" Version)"
            [[ "$package" == anland-session && "$package_arch" == arm64 ]] || return 1
            ;;
        rpm)
            IFS=$'\t' read -r package package_arch package_version package_release < <(
                rpm -qp --queryformat '%{NAME}\t%{ARCH}\t%{VERSION}\t%{RELEASE}\n' "$PACKAGE_FILE"
            )
            [[ "$package" == anland-session && "$package_arch" == aarch64 ]] || return 1
            package_version="${package_version}-${package_release}"
            ;;
        pkg.tar.*)
            package_info="$(LC_ALL=C pacman -Qip "$PACKAGE_FILE")"
            package_name="$(sed -n 's/^[[:space:]]*Name[[:space:]]*:[[:space:]]*//p' <<< "$package_info")"
            package_architecture="$(sed -n 's/^[[:space:]]*Architecture[[:space:]]*:[[:space:]]*//p' <<< "$package_info")"
            package_version="$(sed -n 's/^[[:space:]]*Version[[:space:]]*:[[:space:]]*//p' <<< "$package_info")"
            [[ "$package_name" == anland-session && "$package_architecture" == aarch64 ]] || return 1
            ;;
        *) return 1 ;;
    esac
    [[ "$package_version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 1
    PACKAGE_VERSION="$package_version"
}

require_runtime_dependencies() {
    local command_name
    for command_name in awk find grep mktemp realpath sed sort stat sha256sum; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "缺少运行安装器所需的命令：${command_name}。" \
                "The installer requires the missing command: ${command_name}."
    done
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
        die "未找到 curl 或 wget。" "Neither curl nor wget was found."
    case "$PACKAGE_TYPE" in
        deb)
            command -v dpkg-deb >/dev/null 2>&1 || die "未找到 dpkg-deb。" "dpkg-deb was not found."
            ;;
        rpm)
            command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
            ;;
        pkg.tar.*)
            command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
            ;;
    esac
}

validate_release_asset_checksum() {
    local asset_file="$1"
    local expected_checksum="$2"
    local asset_name="$3"
    local actual_checksum

    if ! actual_checksum="$(sha256sum "$asset_file" | awk '{print $1}')" || \
        ! [[ "$actual_checksum" =~ ^[0-9a-f]{64}$ ]] || \
        [[ "$actual_checksum" != "$expected_checksum" ]]; then
        log "下载的 ${asset_name} 未通过 SHA-256 校验。" \
            "Downloaded ${asset_name} failed SHA-256 verification."
        return 1
    fi
}

download_packages_once() {
    local base_url manifest_file manifest_size
    base_url="$(release_download_base)"
    manifest_file="$WORK_DIR/$MANIFEST_NAME"
    OFFICIAL_RELEASE_METADATA=""
    if [[ "$DOWNLOAD_SOURCE" == 3 ]]; then
        prepare_cnb_checksums "$base_url" || return 1
    else
        resolve_official_manifest_sha256 || return 1
    fi

    log "正在从 $(download_source_name "$DOWNLOAD_SOURCE") 下载 ${TARGET} Anland Next 包..." \
        "Downloading the Anland Next package for ${TARGET} from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$base_url/$MANIFEST_NAME" "$manifest_file" || return 1
    manifest_size="$(stat -c '%s' "$manifest_file")"
    [[ "$manifest_size" =~ ^[0-9]+$ && "$manifest_size" -le "$MAX_MANIFEST_BYTES" ]] || return 1
    if [[ -n "$EXPECTED_MANIFEST_SHA256" ]]; then
        validate_release_asset_checksum "$manifest_file" "$EXPECTED_MANIFEST_SHA256" "$MANIFEST_NAME" || return 1
    fi
    resolve_manifest_package "$manifest_file" || {
        log "Release 清单中没有 ${TARGET} 的匹配原生包。" \
            "The Release manifest has no matching native package for ${TARGET}."
        return 1
    }
    if [[ "$DOWNLOAD_SOURCE" == 3 ]]; then
        resolve_cnb_package_sha256 || return 1
    else
        resolve_official_package_sha256 || return 1
    fi
    PACKAGE_FILE="$WORK_DIR/$PACKAGE_NAME"
    download_file "$base_url/$PACKAGE_NAME" "$PACKAGE_FILE" || return 1
    if [[ -n "$EXPECTED_PACKAGE_SHA256" ]]; then
        validate_release_asset_checksum "$PACKAGE_FILE" "$EXPECTED_PACKAGE_SHA256" "$PACKAGE_NAME" || return 1
    fi
    PACKAGE_DIR="${PACKAGE_FILE%/*}"
    validate_package_file || {
        log "下载的软件包不是当前系统的有效 ARM64 anland-session 包。" \
            "The downloaded package is not a valid ARM64 anland-session package for this system."
        return 1
    }
}

download_packages() {
    local attempt
    WORK_DIR="$(mktemp -d -t anland-next.XXXXXXXX)"

    for ((attempt = 1; attempt <= 3; attempt++)); do
        if (( attempt > 1 )); then
            rm -rf -- "$WORK_DIR"
            mkdir -m 700 -- "$WORK_DIR"
        fi
        if download_packages_once; then
            return
        fi
        if (( attempt < 3 )); then
            log "Release 正在更新或网络暂时失败，准备重新获取（第 ${attempt} 次）。" \
                "The Release is being updated or the network failed; retrying after attempt ${attempt}."
            sleep "$attempt"
        fi
    done

    die "无法稳定获取 Release 包，请稍后重试。" \
        "Unable to consistently download the Release package; please retry later."
}

use_prepared_package() {
    local prepared_work_dir prepared_package_file
    prepared_work_dir="$(realpath -e "$PREPARED_WORK_DIR")" || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    prepared_package_file="$(realpath -e "$PREPARED_PACKAGE_FILE")" || \
        die "预下载软件包无效。" "The pre-downloaded package is invalid."
    [[ "$prepared_work_dir" =~ ^/tmp/anland-next\.[A-Za-z0-9]+$ ]] || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    [[ "$prepared_package_file" == "$prepared_work_dir/"* ]] || \
        die "预下载软件包路径无效。" "The pre-downloaded package path is invalid."
    [[ -d "$prepared_work_dir" && -f "$prepared_package_file" ]] || \
        die "预下载软件包已不存在。" "The pre-downloaded package no longer exists."
    PACKAGE_NAME="${prepared_package_file##*/}"
    validate_package_name "$PACKAGE_NAME" || die "预下载包名无效。" "The pre-downloaded package name is invalid."
    case "$PACKAGE_NAME" in
        "${ASSET_PREFIX}"*"${ASSET_SUFFIX}") ;;
        *) die "预下载软件包与当前系统不匹配。" "The pre-downloaded package does not match this system." ;;
    esac
    WORK_DIR="$prepared_work_dir"
    PACKAGE_FILE="$prepared_package_file"
    PACKAGE_DIR="${PACKAGE_FILE%/*}"
    validate_package_file || die "预下载软件包校验失败。" "The pre-downloaded package failed validation."
}

package_installed_version() {
    case "$PACKAGE_TYPE" in
        deb) dpkg-query -W -f='${Version}' anland-session 2>/dev/null ;;
        rpm) rpm -q --queryformat '%{VERSION}-%{RELEASE}' anland-session 2>/dev/null ;;
        pkg.tar.*) pacman -Q anland-session 2>/dev/null | awk '{print $2}' ;;
    esac
}

verify_installed_package_version() {
    local installed_version

    installed_version="$(package_installed_version || true)"
    [[ "$installed_version" == "$PACKAGE_VERSION" ]] || \
        die "安装后的 anland-session 版本与下载包不一致（期望 ${PACKAGE_VERSION:-unknown}，实际 ${installed_version:-unknown}）。" \
            "The installed anland-session version does not match the downloaded package (expected ${PACKAGE_VERSION:-unknown}, got ${installed_version:-unknown})."
}

verify_installed_xwayland_paths() {
    local xwayland_binary=/usr/lib/anland/Xwayland

    [[ -x "$xwayland_binary" ]] || \
        die "已安装的 anland-session 缺少 Xwayland：$xwayland_binary。" \
            "The installed anland-session package is missing Xwayland: $xwayland_binary."
    grep -aFq '/usr/share/X11/xkb' "$xwayland_binary" || \
        die "已安装的 Xwayland 没有正确的 /usr XKB 数据路径。请更新 Anland Next 软件包。" \
            "The installed Xwayland has no correct /usr XKB data path. Update the Anland Next package."
    if grep -aFq '/usr/local/share/X11/xkb' "$xwayland_binary" || \
       grep -aFq '/usr/local/bin' "$xwayland_binary"; then
        die "已安装的 Xwayland 仍含错误的 /usr/local 运行时路径。请更新 Anland Next 软件包。" \
            "The installed Xwayland still embeds incorrect /usr/local runtime paths. Update the Anland Next package."
    fi
}

clear_stale_apt_holds() {
    local -a current_packages=("$@") previous_packages=()
    local previous current keep

    [[ -r "$APT_HOLD_STATE" ]] || return 0
    mapfile -t previous_packages < <(sed -nE 's/^([a-z0-9][a-z0-9+.-]*)$/\1/p' "$APT_HOLD_STATE" | sort -u)
    for previous in "${previous_packages[@]}"; do
        keep=false
        for current in "${current_packages[@]}"; do
            if [[ "$previous" == "$current" ]]; then
                keep=true
                break
            fi
        done
        if [[ "$keep" == false ]]; then
            apt-mark unhold "$previous" >/dev/null 2>&1 || true
        fi
    done
}

write_apt_hold_state() {
    install -d -m 0755 "$(dirname "$APT_HOLD_STATE")"
    printf '%s\n' "$@" | sort -u > "$APT_HOLD_STATE"
}

validate_managed_dnf_block() {
    local dnf_conf="$1"

    awk -v begin="$DNF_MANAGED_BEGIN" -v end="$DNF_MANAGED_END" '
        $0 == begin {
            if (inside) {
                invalid = 1
            }
            begins++
            inside = 1
        }
        $0 == end {
            if (!inside) {
                invalid = 1
            }
            ends++
            inside = 0
        }
        END { exit (!invalid && !inside && begins == ends && begins <= 1) ? 0 : 1 }
    ' "$dnf_conf"
}

rewrite_dnf_config_without_managed_block() {
    local dnf_conf="$1"
    local output_file="$2"

    validate_managed_dnf_block "$dnf_conf" || return 1

    awk -v begin="$DNF_MANAGED_BEGIN" -v end="$DNF_MANAGED_END" \
        -v legacy_begin="# anland-next: hold patched Next/Xwayland packages" '
        $0 == begin { managed = 1; next }
        $0 == end { managed = 0; next }
        managed { next }
        legacy_pending {
            if ($0 ~ /^[[:space:]]*exclude[[:space:]]*=[[:space:]]*anland-session\*[[:space:]]+xorg-x11-server-Xwayland\*[[:space:]]*$/) {
                legacy_pending = 0
                next
            }
            print legacy_begin
            legacy_pending = 0
        }
        $0 == legacy_begin {
            legacy_pending = 1
            next
        }
        { print }
        END {
            if (legacy_pending) {
                print legacy_begin
            }
        }
    ' "$dnf_conf" > "$output_file"
}

rewrite_dnf_config_without_mesa_block() {
    local dnf_conf="$1"
    local output_file="$2"

    awk -v begin="$MESA_DNF_MANAGED_BEGIN" -v end="$MESA_DNF_MANAGED_END" '
        $0 == begin {
            if (inside) {
                invalid = 1
            }
            begins++
            inside = 1
            next
        }
        $0 == end {
            if (!inside) {
                invalid = 1
            }
            ends++
            inside = 0
            next
        }
        !inside { print }
        END {
            if (invalid || inside || begins != ends || begins > 1) {
                exit 1
            }
        }
    ' "$dnf_conf" > "$output_file"
}

rewrite_dnf_config_for_package_install() {
    local dnf_conf="$1"
    local output_file="$2"

    awk '
        function sanitize(line, equals, value, count, tokens, result, separator, i) {
            equals = index(line, "=")
            value = substr(line, equals + 1)
            gsub(/,/, " ", value)
            count = split(value, tokens, /[[:space:]]+/)
            result = ""
            separator = ""
            for (i = 1; i <= count; i++) {
                if (tokens[i] == "" || \
                    tokens[i] == "anland-session*" || \
                    tokens[i] == "anland-session") {
                    continue
                }
                result = result separator tokens[i]
                separator = ","
            }
            return result == "" ? "" : substr(line, 1, equals) result
        }
        /^\[main\][[:space:]]*$/ {
            in_main = 1
            print
            next
        }
        /^\[[^]]+\][[:space:]]*$/ {
            in_main = 0
            print
            next
        }
        {
            if (in_main && $0 ~ /^[[:space:]]*(exclude|excludepkgs)[[:space:]]*=/) {
                sanitized = sanitize($0)
                if (sanitized != "") {
                    print sanitized
                }
                next
            }
            print
        }
    ' "$dnf_conf" > "$output_file"
}

remove_managed_dnf_excludes() {
    local dnf_conf="$1"
    local temporary_conf mesa_stripped_conf transaction_conf

    # Local patched RPMs must bypass both hold blocks. The caller restores
    # the original configuration immediately after the DNF transaction.
    temporary_conf="$(mktemp -t anland-next-dnf.XXXXXXXX)"
    mesa_stripped_conf="$(mktemp -t anland-next-dnf.XXXXXXXX)"
    transaction_conf="$(mktemp -t anland-next-dnf.XXXXXXXX)"
    if ! rewrite_dnf_config_without_managed_block "$dnf_conf" "$temporary_conf" || \
        ! rewrite_dnf_config_without_mesa_block "$temporary_conf" "$mesa_stripped_conf" || \
        ! rewrite_dnf_config_for_package_install "$mesa_stripped_conf" "$transaction_conf"; then
        rm -f -- "$temporary_conf" "$mesa_stripped_conf" "$transaction_conf"
        return 1
    fi
    if ! install -m 0644 "$transaction_conf" "$dnf_conf"; then
        rm -f -- "$temporary_conf" "$mesa_stripped_conf" "$transaction_conf"
        return 1
    fi
    rm -f -- "$temporary_conf" "$mesa_stripped_conf" "$transaction_conf"
}

write_dnf_config_with_managed_block() {
    local dnf_conf="$1"
    local output_file="$2"
    local stripped_conf
    local excluded_packages="anland-session*"

    if [[ -e "$SYSTEMD257_STATE" ]]; then
        excluded_packages+=",systemd*"
    fi

    stripped_conf="$(mktemp -t anland-next-dnf.XXXXXXXX)"
    if ! rewrite_dnf_config_without_managed_block "$dnf_conf" "$stripped_conf"; then
        rm -f -- "$stripped_conf"
        return 1
    fi
    if ! awk -v begin="$DNF_MANAGED_BEGIN" -v end="$DNF_MANAGED_END" \
        -v excludes="$excluded_packages" '
        function contains(value, wanted, normalized, count, tokens, i) {
            normalized = value
            gsub(/,/, " ", normalized)
            count = split(normalized, tokens, /[[:space:]]+/)
            for (i = 1; i <= count; i++) {
                if (tokens[i] == wanted) {
                    return 1
                }
            }
            return 0
        }
        function merge_excludes(line, equals, value, trimmed, separator, count, wanted, i) {
            equals = index(line, "=")
            value = substr(line, equals + 1)
            trimmed = value
            sub(/[[:space:]]+$/, "", trimmed)
            separator = (trimmed == "" || trimmed ~ /,$/) ? "" : ","
            count = split(excludes, wanted, ",")
            for (i = 1; i <= count; i++) {
                if (!contains(value, wanted[i])) {
                    value = value separator wanted[i]
                    separator = ","
                }
            }
            return substr(line, 1, equals) value
        }
        function write_block() {
            print begin
            print "excludepkgs=" excludes
            print end
        }
        /^\[main\][[:space:]]*$/ {
            in_main = 1
            saw_main = 1
            print
            next
        }
        /^\[[^]]+\][[:space:]]*$/ {
            if (in_main && !saw_exclude) {
                write_block()
            }
            in_main = 0
            print
            next
        }
        {
            if (in_main && $0 ~ /^[[:space:]]*excludepkgs[[:space:]]*=/) {
                print merge_excludes($0)
                saw_exclude = 1
                next
            }
            print
        }
        END {
            if (in_main && !saw_exclude) {
                write_block()
            }
            if (!saw_main) {
                print "[main]"
                write_block()
            }
        }
    ' "$stripped_conf" > "$output_file"; then
        rm -f -- "$stripped_conf"
        return 1
    fi
    rm -f -- "$stripped_conf"
}

configure_dnf_excludes() {
    local dnf_conf="/etc/dnf/dnf.conf"
    local temporary_conf

    touch "$dnf_conf"
    temporary_conf="$(mktemp -t anland-next-dnf.XXXXXXXX)"
    if ! write_dnf_config_with_managed_block "$dnf_conf" "$temporary_conf"; then
        rm -f -- "$temporary_conf"
        return 1
    fi
    if ! install -m 0644 "$temporary_conf" "$dnf_conf"; then
        rm -f -- "$temporary_conf"
        return 1
    fi
    rm -f -- "$temporary_conf"
}

install_deb_packages() {
    local -a files packages
    local file package

    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    command -v dpkg-deb >/dev/null 2>&1 || die "未找到 dpkg-deb。" "dpkg-deb was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 deb 包。" "No installable deb packages were found."

    log "正在安装 ${#files[@]} 个 deb 包并自动处理依赖..." \
        "Installing ${#files[@]} deb packages and resolving dependencies..."
    apt-get install -y --reinstall --allow-downgrades --allow-change-held-packages "${files[@]}"

    for file in "${files[@]}"; do
        package="$(dpkg-deb -f "$file" Package)"
        [[ -n "$package" ]] && packages+=("$package")
    done
    mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sort -u)
    ((${#packages[@]} > 0)) || die "无法读取 deb 包名。" "Could not determine the deb package names."

    clear_stale_apt_holds "${packages[@]}"
    log "正在设置 APT hold..." "Applying APT holds..."
    apt-mark hold "${packages[@]}"
    write_apt_hold_state "${packages[@]}"
    printf '  hold: %s\n' "${packages[@]}"
}

install_rpm_packages() {
    local -a files packages dnf_install_options=() install_files=() reinstall_files=()
    local file package_name package_version installed_version
    local dnf_conf="/etc/dnf/dnf.conf"
    local dnf_backup

    command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
    command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.rpm' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 rpm 包。" "No installable rpm packages were found."

    for file in "${files[@]}"; do
        package_name="$(rpm -qp --queryformat '%{NAME}' "$file")"
        package_version="$(rpm -qp --queryformat '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' "$file")"
        installed_version="$(rpm -q --queryformat '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' "$package_name" 2>/dev/null || true)"
        if [[ "$installed_version" == "$package_version" ]]; then
            reinstall_files+=("$file")
        else
            install_files+=("$file")
        fi
    done

    log "正在安装 ${#files[@]} 个 rpm 包并自动处理依赖..." \
        "Installing ${#files[@]} rpm packages and resolving dependencies..."
    touch "$dnf_conf"
    dnf_backup="$(mktemp -t anland-next-dnf-backup.XXXXXXXX)"
    cp -p "$dnf_conf" "$dnf_backup"
    if grep -Fqx "$MESA_DNF_MANAGED_BEGIN" "$dnf_conf"; then
        dnf_install_options+=('--exclude=mesa*')
    fi
    if [[ -e "$SYSTEMD257_STATE" ]]; then
        dnf_install_options+=('--exclude=systemd*')
    fi
    if ! remove_managed_dnf_excludes "$dnf_conf" || \
        ! { ((${#install_files[@]} == 0)) || dnf --nogpgcheck install -y "${dnf_install_options[@]}" "${install_files[@]}"; } || \
        ! { ((${#reinstall_files[@]} == 0)) || dnf --nogpgcheck reinstall -y "${dnf_install_options[@]}" "${reinstall_files[@]}"; }; then
        install -m 0644 "$dnf_backup" "$dnf_conf" || true
        rm -f -- "$dnf_backup"
        die "rpm 软件包安装失败。" "RPM package installation failed."
    fi
    if ! install -m 0644 "$dnf_backup" "$dnf_conf"; then
        rm -f -- "$dnf_backup"
        die "无法恢复 DNF 锁定配置。" "Unable to restore the DNF hold configuration."
    fi

    mapfile -t packages < <(rpm -qp --queryformat '%{NAME}\n' "${files[@]}" | sort -u)
    ((${#packages[@]} > 0)) || die "无法读取 rpm 包名。" "Could not determine the rpm package names."
    log "正在设置 DNF exclude（等效于 hold）..." "Applying DNF excludes (equivalent to hold)..."
    if ! configure_dnf_excludes; then
        install -m 0644 "$dnf_backup" "$dnf_conf" || true
        rm -f -- "$dnf_backup"
        die "无法更新 DNF 锁定配置。" "Unable to update the DNF hold configuration."
    fi
    rm -f -- "$dnf_backup"
    printf '  hold: %s\n' "${packages[@]}"
}

write_pacman_hold_block() {
    local -a packages=("$@")
    local temporary
    ((${#packages[@]} > 0)) || return 0
    command -v pacman >/dev/null 2>&1 || return 0
    [[ -f /etc/pacman.conf ]] || return 0
    temporary="$(mktemp -t "anland-$COMPONENT_NAME-pacman.XXXXXXXX")" || return 1
    if ! awk -v begin="# BEGIN anland-$COMPONENT_NAME package holds" \
        -v end="# END anland-$COMPONENT_NAME package holds" \
        -v packages="${packages[*]}" '
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        skip { next }
        /^\[options\][[:space:]]*$/ && !wrote {
            print
            print begin
            print "IgnorePkg = " packages
            print end
            wrote = 1
            next
        }
        { print }
        END { if (skip) exit 1; if (!wrote) exit 1 }
    ' /etc/pacman.conf > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! install -m 0644 -- "$temporary" /etc/pacman.conf; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
}

remove_pacman_hold_entries() {
    local -a packages=("$@")
    local temporary
    command -v pacman >/dev/null 2>&1 || return 0
    [[ -f /etc/pacman.conf ]] || return 0
    temporary="$(mktemp -t "anland-$COMPONENT_NAME-pacman.XXXXXXXX")" || return 1
    if ! awk -v begin="# BEGIN anland-$COMPONENT_NAME package holds" \
        -v end="# END anland-$COMPONENT_NAME package holds" \
        -v remove_list="${packages[*]}" '
        BEGIN { remove_count = split(remove_list, remove_names, /[[:space:]]+/) }
        $0 == begin { inside = 1; next }
        $0 == end { inside = 0; next }
        inside { next }
        /^# BEGIN .* package holds$/ { foreign = 1; print; next }
        /^# END .* package holds$/ { foreign = 0; print; next }
        foreign { print; next }
        /^[[:space:]]*IgnorePkg[[:space:]]*=/ {
            equals = index($0, "=")
            count = split(substr($0, equals + 1), items, /[[:space:]]+/)
            output = ""
            for (i = 1; i <= count; i++) {
                remove = 0
                for (j = 1; j <= remove_count; j++) {
                    if (items[i] == remove_names[j]) remove = 1
                }
                if (items[i] != "" && !remove) output = output (output == "" ? "" : " ") items[i]
            }
            if (output != "") print substr($0, 1, equals) " " output
            next
        }
        { print }
    ' /etc/pacman.conf > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! install -m 0644 -- "$temporary" /etc/pacman.conf; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
}

install_arch_packages() {
    local -a files packages
    local pacman_conf

    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 Arch 包。" "No installable Arch packages were found."

    log "正在安装 ${#files[@]} 个 Arch 包..." "Installing ${#files[@]} Arch packages..."
    pacman_conf="$(mktemp -t anland-next-pacman.XXXXXXXX)"
    cp /etc/pacman.conf "$pacman_conf"
    if grep -Eq '^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=' "$pacman_conf"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=.*/LocalFileSigLevel = Optional/' "$pacman_conf"
    elif grep -qE '^\[options\][[:space:]]*$' "$pacman_conf"; then
        sed -i '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' "$pacman_conf"
    else
        rm -f -- "$pacman_conf"
        die "pacman.conf 缺少 [options] 段。" "pacman.conf has no [options] section."
    fi
    if ! pacman --config "$pacman_conf" -U --noconfirm "${files[@]}"; then
        rm -f -- "$pacman_conf"
        die "Arch 软件包安装失败。" "Arch package installation failed."
    fi
    rm -f -- "$pacman_conf"

    write_pacman_hold_block anland-session || \
        die "无法更新 pacman 锁定配置。" "Unable to update the pacman hold configuration."
    mapfile -t packages < <(pacman -Qq -p "${files[@]}" | sort -u)
    ((${#packages[@]} > 0)) || die "无法读取 Arch 包名。" "Could not determine the Arch package names."
    printf '  hold: %s\n' "${packages[@]}"
}

refresh_user_service() {
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemctl --user daemon-reload >/dev/null 2>&1; then
        if systemctl --user enable --now anland-session.service >/dev/null 2>&1; then
            log "已刷新、启用并启动 anland-session 用户服务。" \
                "Refreshed, enabled, and started the anland-session user service."
        else
            systemctl --user enable anland-session.service >/dev/null 2>&1 || true
            log "已启用 anland-session 用户服务，但当前未能启动；可稍后运行 systemctl --user restart anland-session.service。" \
                "The anland-session user service was enabled but could not start; run systemctl --user restart anland-session.service later."
        fi
    else
        log "当前没有可用的 systemd 用户总线；软件包已安装，可稍后运行 systemctl --user daemon-reload。" \
            "No systemd user bus is available; the package is installed, and systemctl --user daemon-reload can be run later."
    fi
}

stop_user_service() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl --user disable --now anland-session.service >/dev/null 2>&1 || true
}

uninstall_next_deb() {
    local package candidate action
    local -a packages=() package_specs=() remove_packages=()
    command -v apt-cache >/dev/null 2>&1 || die "未找到 apt-cache。" "apt-cache was not found."
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    command -v apt-mark >/dev/null 2>&1 || die "未找到 apt-mark。" "apt-mark was not found."
    if [[ -s "$APT_HOLD_STATE" ]]; then
        mapfile -t packages < <(sed -nE 's/^([a-z0-9][a-z0-9+.-]*)$/\1/p' "$APT_HOLD_STATE" | sort -u)
        ((${#packages[@]} > 0)) || die "APT hold 清单为空。" "The APT hold list is empty."
    elif dpkg-query -W -f='${db:Status-Status}' anland-session 2>/dev/null | grep -Fqx installed; then
        # Older installers did not write KDE-style APT hold lists.
        for package in anland-session; do
            if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -Fqx installed; then
                packages+=("$package")
            fi
        done
    else
        rm -f -- "$COMPONENT_STATE_DIR/anland-next.version"
        log "没有 Anland Next 安装记录。" "No Anland Next installation record was found."
        return 0
    fi
    local -a unhold_packages=()
    for package in "${packages[@]}"; do
        action="$(uninstall_package_action "$package")" || die "安装记录含未知软件包。" "The installation record contains an unknown package."
        [[ "$action" != keep ]] || continue
        unhold_packages+=("$package")
        if [[ "$action" == remove ]]; then
            remove_packages+=("$package")
            continue
        fi
        candidate="$(apt-cache madison "$package" | awk -F '|' 'NR == 1 {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }')"
        if [[ -z "$candidate" && "$action" == auxiliary ]]; then
            remove_packages+=("$package")
            continue
        fi
        [[ -n "$candidate" ]] || die "找不到 $package 的官方候选版本。" "No distribution candidate was found for $package."
        package_specs+=("$package=$candidate")
    done
    ((${#unhold_packages[@]} == 0)) || apt-mark unhold "${unhold_packages[@]}" >/dev/null
    ((${#package_specs[@]} == 0)) || apt-get install -y --reinstall --allow-downgrades --allow-change-held-packages "${package_specs[@]}"
    ((${#remove_packages[@]} == 0)) || apt-get remove -y --allow-change-held-packages "${remove_packages[@]}"
    rm -f -- "$APT_HOLD_STATE" "$COMPONENT_STATE_DIR/anland-next.version"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_next_rpm() {
    local dnf_conf="/etc/dnf/dnf.conf" backup stripped transaction package action
    local -a packages=() restore_packages=() remove_packages=()
    command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
    command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
    [[ -f "$dnf_conf" ]] || die "找不到 DNF 配置。" "The DNF configuration was not found."
    if ! rpm -q anland-session >/dev/null 2>&1 && [[ ! -s "$COMPONENT_STATE_DIR/anland-next.version" ]] &&
        ! grep -Fqx "$DNF_MANAGED_BEGIN" "$dnf_conf"; then
        log "没有 Anland Next 安装记录。" "No Anland Next installation record was found."
        return 0
    fi
    mapfile -t packages < <(rpm -qa --queryformat '%{NAME}\n' | awk '/^anland-session$/' | sort -u)
    for package in "${packages[@]}"; do
        action="$(uninstall_package_action "$package")" || die "检测到未知软件包。" "An unknown package was detected."
        case "$action" in
            keep) ;;
            remove) remove_packages+=("$package") ;;
            *) restore_packages+=("$package") ;;
        esac
    done
    backup="$(mktemp -t anland-next-uninstall.XXXXXXXX)"
    stripped="$(mktemp -t anland-next-uninstall.XXXXXXXX)"
    transaction="$(mktemp -t anland-next-uninstall.XXXXXXXX)"
    cp -p -- "$dnf_conf" "$backup"
    if ! rewrite_dnf_config_without_managed_block "$dnf_conf" "$stripped" || \
        ! rewrite_dnf_config_for_package_install "$stripped" "$transaction" || \
        ! install -m 0644 "$transaction" "$dnf_conf" || \
        ! { ((${#remove_packages[@]} == 0)) || dnf remove -y --no-autoremove "${remove_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || dnf distro-sync -y --exclude='mesa*' --exclude='systemd*' "${restore_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || dnf reinstall -y --exclude='mesa*' --exclude='systemd*' "${restore_packages[@]}"; }; then
        install -m 0644 "$backup" "$dnf_conf" || true
        rm -f -- "$backup" "$stripped" "$transaction"
        die "卸载 Anland Next 或恢复发行版图形包失败。" "Failed to uninstall Anland Next or restore distribution graphics packages."
    fi
    rm -f -- "$backup" "$stripped" "$transaction" "$COMPONENT_STATE_DIR/anland-next.version"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_next_arch() {
    local package action backup
    local -a packages=() restore_packages=() remove_packages=()
    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    [[ -f /etc/pacman.conf ]] || die "找不到 pacman.conf。" "pacman.conf was not found."
    if ! pacman -Q anland-session >/dev/null 2>&1 && [[ ! -s "$COMPONENT_STATE_DIR/anland-next.version" ]]; then
        log "没有 Anland Next 安装记录。" "No Anland Next installation record was found."
        return 0
    fi
    for package in anland-session; do
        pacman -Q "$package" >/dev/null 2>&1 || continue
        action="$(uninstall_package_action "$package")" || die "检测到未知软件包。" "An unknown package was detected."
        [[ "$action" != keep ]] || continue
        packages+=("$package")
        if [[ "$action" == remove ]]; then
            remove_packages+=("$package")
        else
            restore_packages+=("$package")
        fi
    done
    backup="$(mktemp -t anland-next-uninstall.XXXXXXXX)"
    cp -p -- /etc/pacman.conf "$backup"
    if ! remove_pacman_hold_entries "${packages[@]}" || \
        ! { ((${#remove_packages[@]} == 0)) || pacman -R --noconfirm "${remove_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || pacman -S --noconfirm "${restore_packages[@]}"; }; then
        install -m 0644 "$backup" /etc/pacman.conf || true
        rm -f -- "$backup"
        die "卸载 Anland Next 或恢复发行版图形包失败。" "Failed to uninstall Anland Next or restore distribution graphics packages."
    fi
    rm -f -- "$backup" "$COMPONENT_STATE_DIR/anland-next.version"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_package_action() {
    [[ "$1" == anland-session ]] || return 1
    printf remove
}

uninstall_package() {
    stop_user_service
    case "$PACKAGE_TYPE" in
        deb) uninstall_next_deb ;;
        rpm) uninstall_next_rpm ;;
        pkg.tar.*) uninstall_next_arch ;;
    esac
    log "Anland Next session 已卸载；发行版 Xwayland 和其他依赖未删除。" \
        "Anland Next session was uninstalled; distribution Xwayland and other dependencies were kept."
}

main() {
    detect_language
    parse_arguments "$@"
    detect_target
    check_architecture
    if [[ "$UNINSTALL" == true ]]; then
        require_root "$@"
        uninstall_package
        return
    fi

    require_runtime_dependencies
    resolve_release_tag

    if [[ -n "$PREPARED_WORK_DIR" || -n "$PREPARED_PACKAGE_FILE" ]]; then
        [[ -n "$PREPARED_WORK_DIR" && -n "$PREPARED_PACKAGE_FILE" ]] || \
            die "预下载环境变量不完整。" "The pre-downloaded package environment is incomplete."
        use_prepared_package
    else
        select_download_source
        download_packages
    fi
    require_root "$@"

    case "$PACKAGE_TYPE" in
        deb) install_deb_packages ;;
        rpm) install_rpm_packages ;;
        pkg.tar.*) install_arch_packages ;;
    esac
    verify_installed_package_version
    verify_installed_xwayland_paths
    refresh_user_service
    record_component_version "$PACKAGE_VERSION"
    update_desktop_config
    log "Anland Next session 安装完成（${PACKAGE_VERSION:-unknown}）。" \
        "Anland Next session installation completed (${PACKAGE_VERSION:-unknown})."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
