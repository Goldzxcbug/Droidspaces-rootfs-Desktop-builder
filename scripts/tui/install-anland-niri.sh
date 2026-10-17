#!/usr/bin/env bash
set -euo pipefail

# The package archives are deliberately kept out of Git. Override the
# repository when installing packages published by a fork.
readonly DEFAULT_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly RELEASE_REPOSITORY="${ANLAND_NIRI_RELEASE_REPOSITORY:-${ANLAND_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}}"
RELEASE_TAG="${ANLAND_NIRI_RELEASE_TAG:-}"
readonly ROLLING_RELEASE_TAG="anland-niri-packages"
readonly MANIFEST_NAME="anland-niri-manifest"
readonly MAX_ARCHIVE_BYTES=$((512 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((2 * 1024 * 1024 * 1024))
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly APT_HOLD_STATE="/var/lib/anland-niri/apt-holds"
readonly DNF_MANAGED_BEGIN="# BEGIN anland-niri package holds"
readonly DNF_MANAGED_END="# END anland-niri package holds"
readonly MESA_DNF_MANAGED_BEGIN="# BEGIN install-mesa package holds"
readonly MESA_DNF_MANAGED_END="# END install-mesa package holds"
readonly SYSTEMD257_STATE="/etc/droidspaces-systemd257"
readonly COMPONENT_STATE_DIR="${DROIDSPACES_COMPONENT_STATE_DIR:-/var/lib/droidspaces-tui/components}"
readonly DESKTOP_CONFIG="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"

WORK_DIR=""
PREPARED_WORK_DIR="${ANLAND_NIRI_WORK_DIR:-}"
PREPARED_PACKAGE_DIR="${ANLAND_NIRI_PACKAGE_DIR:-}"
PREPARED_ARCHIVE_NAME="${ANLAND_NIRI_ARCHIVE_NAME:-}"
UI_LANG="en"
TARGET=""
PACKAGE_TYPE=""
ARCHIVE_PREFIX=""
ARCHIVE_SUFFIX=""
ARCHIVE_NAME=""
ARCHIVE_TARGET=""
PACKAGE_DIR=""
DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
EXPECTED_MANIFEST_SHA256=""
EXPECTED_ARCHIVE_SHA256=""
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
    printf '[anland-niri] %s\n' "$(msg "$1" "$2")"
}

record_component_version() {
    local version="$1" state_file="$COMPONENT_STATE_DIR/niri.version" temporary_file
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 0
    if ! mkdir -p -- "$COMPONENT_STATE_DIR"; then
        log "无法记录已安装的 Niri 版本。" "Could not record the installed Niri version."
        return 0
    fi
    temporary_file="$(mktemp "$state_file.tmp.XXXXXXXX")" || {
        log "无法记录已安装的 Niri 版本。" "Could not record the installed Niri version."
        return 0
    }
    if printf '%s\n' "$version" > "$temporary_file" && \
        chmod 0644 "$temporary_file" && mv -f -- "$temporary_file" "$state_file"; then
        return 0
    fi
    rm -f -- "$temporary_file" || true
    log "无法记录已安装的 Niri 版本。" "Could not record the installed Niri version."
    return 0
}

update_desktop_config() {
    local desktop="niri" config_dir temporary_file line configured_desktop=""
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
    if [[ "$configured_desktop" != none && "$configured_desktop" != niri ]]; then
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

die() {
    printf '[anland-niri] %s: %s\n' "$(msg '错误' 'Error')" "$(msg "$1" "$2")" >&2
    exit 1
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
            *)
                die "不支持的参数：${argument}。可用参数为 -1/--1、-2/--2、-3/--3、--uninstall。" \
                    "Unsupported argument: ${argument}. Valid arguments are -1/--1, -2/--2, -3/--3, and --uninstall."
                ;;
        esac
    done
}

other_xwayland_owner() {
    local component
    for component in kde gnome niri hyprland mango denial; do
        [[ "$component" != niri ]] || continue
        if [[ -s "$COMPONENT_STATE_DIR/$component.version" ||
              -s "/var/lib/anland-$component/apt-holds" || -s "/var/lib/anland-$component/pacman-packages" ]] ||
            grep -Fqx "# BEGIN anland-$component package holds" /etc/pacman.conf /etc/dnf/dnf.conf 2>/dev/null; then
            printf '%s' "$component"; return 0
        fi
    done
    # Legacy Arch KDE/GNOME installers added plain IgnorePkg entries.
    local legacy
    for legacy in kwin mutter; do
        if grep -Eq "^[[:space:]]*IgnorePkg[[:space:]]*=.*(^|[[:space:]])${legacy}([[:space:]]|$)" /etc/pacman.conf 2>/dev/null; then
            printf '%s' "$legacy"; return 0
        fi
    done
    return 1
}

uninstall_package_action() {
    case "$1" in
        xwayland|xorg-x11-server-Xwayland|xorg-xwayland)
            if other_xwayland_owner >/dev/null; then printf keep; else printf restore; fi ;;
        niri-anland) printf remove ;;
        xwayland-satellite) printf auxiliary ;;
        *) return 1 ;;
    esac
}

uninstall_niri_deb() {
    local package candidate action
    local -a packages=() package_specs=() remove_packages=()
    command -v apt-cache >/dev/null 2>&1 || die "未找到 apt-cache。" "apt-cache was not found."
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    command -v apt-mark >/dev/null 2>&1 || die "未找到 apt-mark。" "apt-mark was not found."
    if [[ -s "$APT_HOLD_STATE" ]]; then
        mapfile -t packages < <(sed -nE 's/^([a-z0-9][a-z0-9+.-]*)$/\1/p' "$APT_HOLD_STATE" | sort -u)
        ((${#packages[@]} > 0)) || die "APT hold 清单为空。" "The APT hold list is empty."
    elif dpkg-query -W -f='${db:Status-Status}' niri-anland 2>/dev/null | grep -Fqx installed; then
        # Older installers did not write KDE-style APT hold lists.
        for package in niri-anland xwayland-satellite xwayland; do
            if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -Fqx installed; then
                packages+=("$package")
            fi
        done
    else
        rm -f -- "$COMPONENT_STATE_DIR/niri.version"
        log "没有 Anland Niri 安装记录。" "No Anland Niri installation record was found."
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
    rm -f -- "$APT_HOLD_STATE" "$COMPONENT_STATE_DIR/niri.version" \
        "${APT_HOLD_STATE%/*}/packages.tsv"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_niri_rpm() {
    local dnf_conf="/etc/dnf/dnf.conf" backup stripped transaction package action
    local preserve_xwayland=false
    local -a packages=() restore_packages=() remove_packages=()
    command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
    command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
    [[ -f "$dnf_conf" ]] || die "找不到 DNF 配置。" "The DNF configuration was not found."
    if ! rpm -q niri-anland >/dev/null 2>&1 && [[ ! -s "$COMPONENT_STATE_DIR/niri.version" ]] &&
        ! grep -Fqx "$DNF_MANAGED_BEGIN" "$dnf_conf"; then
        log "没有 Anland Niri 安装记录。" "No Anland Niri installation record was found."
        return 0
    fi
    mapfile -t packages < <(rpm -qa --queryformat '%{NAME}\n' | awk '/^(niri-anland|xwayland-satellite|xorg-x11-server-Xwayland)$/' | sort -u)
    for package in "${packages[@]}"; do
        action="$(uninstall_package_action "$package")" || die "检测到未知软件包。" "An unknown package was detected."
        case "$action" in
            keep) ;;
            remove) remove_packages+=("$package") ;;
            *) restore_packages+=("$package") ;;
        esac
    done
    if other_xwayland_owner >/dev/null; then preserve_xwayland=true; fi
    backup="$(mktemp -t anland-niri-uninstall.XXXXXXXX)"
    stripped="$(mktemp -t anland-niri-uninstall.XXXXXXXX)"
    transaction="$(mktemp -t anland-niri-uninstall.XXXXXXXX)"
    cp -p -- "$dnf_conf" "$backup"
    if ! rewrite_dnf_config_without_managed_block "$dnf_conf" "$stripped" || \
        ! rewrite_dnf_config_for_package_install "$stripped" "$transaction" "$preserve_xwayland" || \
        ! install -m 0644 "$transaction" "$dnf_conf" || \
        ! { ((${#remove_packages[@]} == 0)) || dnf remove -y --no-autoremove "${remove_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || dnf distro-sync -y --exclude='mesa*' --exclude='systemd*' "${restore_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || dnf reinstall -y --exclude='mesa*' --exclude='systemd*' "${restore_packages[@]}"; }; then
        install -m 0644 "$backup" "$dnf_conf" || true
        rm -f -- "$backup" "$stripped" "$transaction"
        die "卸载 Anland Niri 或恢复发行版图形包失败。" "Failed to uninstall Anland Niri or restore distribution graphics packages."
    fi
    rm -f -- "$backup" "$stripped" "$transaction" "$COMPONENT_STATE_DIR/niri.version" \
        "${APT_HOLD_STATE%/*}/packages.tsv"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_niri_arch() {
    local package action backup stripped
    local -a packages=() restore_packages=() remove_packages=()
    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    [[ -f /etc/pacman.conf ]] || die "找不到 pacman.conf。" "pacman.conf was not found."
    if ! pacman -Q niri-anland >/dev/null 2>&1 && [[ ! -s "$COMPONENT_STATE_DIR/niri.version" ]]; then
        log "没有 Anland Niri 安装记录。" "No Anland Niri installation record was found."
        return 0
    fi
    for package in niri-anland xorg-xwayland; do
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
    backup="$(mktemp -t anland-niri-uninstall.XXXXXXXX)"
    stripped="$(mktemp -t anland-niri-uninstall.XXXXXXXX)"
    cp -p -- /etc/pacman.conf "$backup"
    if ! awk -v remove_list="${packages[*]}" \
        -v begin="# BEGIN anland-niri package holds" -v end="# END anland-niri package holds" '
        $0 == begin || $0 == end { next }
        BEGIN { remove_count = split(remove_list, remove_names, /[[:space:]]+/) }
        /^[[:space:]]*IgnorePkg[[:space:]]*=/ {
            equals = index($0, "=")
            count = split(substr($0, equals + 1), items, /[[:space:]]+/)
            output = ""
            for (i = 1; i <= count; i++) {
                remove = 0
                for (j = 1; j <= remove_count; j++) if (items[i] == remove_names[j]) remove = 1
                if (items[i] != "" && !remove) output = output (output == "" ? "" : " ") items[i]
            }
            if (output != "") print substr($0, 1, equals) " " output
            next
        }
        { print }
    ' /etc/pacman.conf > "$stripped" || \
        ! install -m 0644 "$stripped" /etc/pacman.conf || \
        ! { ((${#remove_packages[@]} == 0)) || pacman -R --noconfirm "${remove_packages[@]}"; } || \
        ! { ((${#restore_packages[@]} == 0)) || pacman -S --noconfirm "${restore_packages[@]}"; }; then
        install -m 0644 "$backup" /etc/pacman.conf || true
        rm -f -- "$backup" "$stripped"
        die "卸载 Anland Niri 或恢复发行版图形包失败。" "Failed to uninstall Anland Niri or restore distribution graphics packages."
    fi
    rm -f -- "$backup" "$stripped" "$COMPONENT_STATE_DIR/niri.version" \
        "${APT_HOLD_STATE%/*}/packages.tsv"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
}

uninstall_niri() {
    case "$PACKAGE_TYPE" in
        deb) uninstall_niri_deb ;;
        rpm) uninstall_niri_rpm ;;
        pkg.tar.*) uninstall_niri_arch ;;
    esac
    log "Anland Niri 已卸载，发行版图形包已恢复。" \
        "Anland Niri was uninstalled; distribution graphics packages were restored."
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

    command -v sudo >/dev/null 2>&1 || die "请使用 root 账户运行此脚本。" "Please run this script as root."
    log "正在通过 sudo 重新运行安装程序..." "Restarting the installer with sudo..."
    local script_path="${BASH_SOURCE[0]}"
    [[ "$script_path" = /* ]] || script_path="$PWD/$script_path"
    local status
    if sudo env \
        "ANLAND_NIRI_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "ANLAND_NIRI_RELEASE_TAG=$RELEASE_TAG" \
        "ANLAND_NIRI_WORK_DIR=$WORK_DIR" \
        "ANLAND_NIRI_PACKAGE_DIR=$PACKAGE_DIR" \
        "ANLAND_NIRI_ARCHIVE_NAME=$ARCHIVE_NAME" \
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
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。" "Unable to read /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ -n "${ID:-}" ]] || die "/etc/os-release 缺少 ID。" "/etc/os-release does not contain ID."
    local distro_id="${ID,,}"
    local version_id="${VERSION_ID:-}"
    local system_name="${PRETTY_NAME:-$distro_id${version_id:+ $version_id}}"

    case "$distro_id" in
        arch|archarm|archlinux)
            TARGET="Arch Linux"
            PACKAGE_TYPE="pkg.tar.*"
            ARCHIVE_PREFIX="anland-niri-arch-"
            ARCHIVE_SUFFIX="-aarch64.tar.gz"
            ARCHIVE_TARGET="arch"
            ;;
        *)
            [[ -n "$version_id" ]] || die "/etc/os-release 缺少 VERSION_ID。" "/etc/os-release does not contain VERSION_ID."
            case "$distro_id:$version_id" in
                debian:13*)
                    TARGET="Debian 13"
                    PACKAGE_TYPE="deb"
                    ARCHIVE_PREFIX="anland-niri-debian13-"
                    ARCHIVE_SUFFIX="-arm64.tar.gz"
                    ARCHIVE_TARGET="debian13"
                    ;;
                ubuntu:26.04*)
                    TARGET="Ubuntu 26.04"
                    PACKAGE_TYPE="deb"
                    ARCHIVE_PREFIX="anland-niri-ubuntu2604-"
                    ARCHIVE_SUFFIX="-arm64.tar.gz"
                    ARCHIVE_TARGET="ubuntu2604"
                    ;;
                fedora:43*)
                    TARGET="Fedora 43"
                    PACKAGE_TYPE="rpm"
                    ARCHIVE_PREFIX="anland-niri-fedora43-"
                    ARCHIVE_SUFFIX="-aarch64.tar.gz"
                    ARCHIVE_TARGET="fedora43"
                    ;;
                fedora:44*)
                    TARGET="Fedora 44"
                    PACKAGE_TYPE="rpm"
                    ARCHIVE_PREFIX="anland-niri-fedora44-"
                    ARCHIVE_SUFFIX="-aarch64.tar.gz"
                    ARCHIVE_TARGET="fedora44"
                    ;;
                *)
                    die "不支持当前系统 ${system_name}。仅支持 Debian 13、Ubuntu 26.04、Fedora 43/44、Arch Linux。" \
                        "Unsupported system: ${system_name}. Supported systems are Debian 13, Ubuntu 26.04, Fedora 43/44, and Arch Linux."
                    ;;
            esac
            ;;
    esac

    log "已识别系统: ${system_name} -> ${TARGET}" "Detected system: ${system_name} -> ${TARGET}"
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

validate_release_tag() {
    case "$RELEASE_TAG" in
        "$ROLLING_RELEASE_TAG") ;;
        *)
            die "Release tag 只能是 ${ROLLING_RELEASE_TAG}。" \
                "The Release tag must be ${ROLLING_RELEASE_TAG}."
            ;;
    esac
}

validate_repository() {
    if [[ ! "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        die "Release 仓库必须是 owner/repository 格式。" \
            "The Release repository must use the owner/repository format."
    fi
}

resolve_release_tag() {
    validate_repository
    if [[ -z "$RELEASE_TAG" ]]; then
        RELEASE_TAG="$ROLLING_RELEASE_TAG"
    fi
    validate_release_tag
    log "使用固定滚动 Release: ${RELEASE_TAG}" "Using rolling Release: ${RELEASE_TAG}"
}

resolve_archive_name() {
    local manifest_file="$1"
    local manifest_format manifest_release_tag selected_name checksum_key checksum_count checksum

    manifest_format="$(awk -F= '$1 == "format" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    manifest_release_tag="$(awk -F= '$1 == "release_tag" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    [[ "$manifest_format" == "1" && "$manifest_release_tag" == "$RELEASE_TAG" ]] || {
        log "Release 清单格式无效。" "The Release manifest format is invalid."
        return 1
    }

    selected_name="$(awk -F= -v key="$ARCHIVE_TARGET" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    case "$selected_name" in
        "${ARCHIVE_PREFIX}"*"${ARCHIVE_SUFFIX}") ;;
        *)
            log "Release 清单没有 ${TARGET} 的匹配 ARM64 包。" \
                "The Release manifest has no matching ARM64 archive for ${TARGET}."
            return 1
            ;;
    esac
    if [[ ! "$selected_name" =~ ^[A-Za-z0-9._+~_-]+$ || "$selected_name" == *..* ]]; then
        log "Release 清单中的包名无效。" "The archive name in the Release manifest is invalid."
        return 1
    fi

    ARCHIVE_NAME="$selected_name"
    EXPECTED_ARCHIVE_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "3" ]]; then
        checksum_key="${ARCHIVE_TARGET}_sha256"
        checksum_count="$(awk -F= -v key="$checksum_key" '$1 == key { count += 1 } END { print count + 0 }' "$manifest_file")" || return 1
        case "$checksum_count" in
            0)
                log "CNB 的旧 Release 清单没有 ${ARCHIVE_NAME} 的 SHA-256；将只执行归档结构和软件包元数据校验。" \
                    "The legacy CNB Release manifest has no SHA-256 for ${ARCHIVE_NAME}; only archive structure and package metadata will be verified."
                ;;
            1)
                checksum="$(awk -F= -v key="$checksum_key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest_file")" || return 1
                [[ "$checksum" =~ ^[0-9A-Fa-f]{64}$ ]] || {
                    log "CNB Release 清单中的 ${ARCHIVE_NAME} SHA-256 无效。" \
                        "The CNB Release manifest has an invalid SHA-256 for ${ARCHIVE_NAME}."
                    return 1
                }
                EXPECTED_ARCHIVE_SHA256="${checksum,,}"
                ;;
            *)
                log "CNB Release 清单中的 ${ARCHIVE_NAME} SHA-256 不唯一。" \
                    "The CNB Release manifest has multiple SHA-256 entries for ${ARCHIVE_NAME}."
                return 1
                ;;
        esac
    fi
    log "已选择 ${ARCHIVE_NAME}" "Selected ${ARCHIVE_NAME}"
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

resolve_official_archive_sha256() {
    EXPECTED_ARCHIVE_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "1" ]]; then
        return
    fi
    if EXPECTED_ARCHIVE_SHA256="$(release_asset_sha256 "$ARCHIVE_NAME")"; then
        return
    fi
    log "GitHub Release 未提供 ${ARCHIVE_NAME} 的 SHA-256 校验值，拒绝使用第三方镜像包。" \
        "GitHub Release did not provide a SHA-256 digest for ${ARCHIVE_NAME}; refusing the third-party mirror package."
    return 1
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

has_packages() {
    local directory="$1"
    compgen -G "$directory/*.${PACKAGE_TYPE}" >/dev/null
}

require_runtime_dependencies() {
    local command_name
    for command_name in awk du find mktemp realpath sha256sum sort stat tar; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "缺少运行安装器所需的命令：${command_name}。" \
                "The installer requires the missing command: ${command_name}."
    done

    case "$PACKAGE_TYPE" in
        deb) command -v dpkg-deb >/dev/null 2>&1 || die "未找到 dpkg-deb。" "dpkg-deb was not found." ;;
        rpm) command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found." ;;
        pkg.tar.*) command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found." ;;
    esac
}

validate_archive_contents() {
    local archive_file="$1"
    local archive_size members entry

    if ! archive_size="$(stat -c '%s' "$archive_file")" || ! [[ "$archive_size" =~ ^[0-9]+$ ]]; then
        log "无法读取下载包的大小。" "Unable to read the downloaded archive size."
        return 1
    fi
    if (( archive_size > MAX_ARCHIVE_BYTES )); then
        log "下载包超过允许的大小。" "The downloaded archive exceeds the allowed size."
        return 1
    fi
    if ! members="$(tar -tzf "$archive_file")" || [[ -z "$members" ]]; then
        log "下载包不是有效的非空 tar.gz 文件。" "The downloaded archive is not a valid non-empty tar.gz file."
        return 1
    fi
    while IFS= read -r entry; do
        case "$entry" in
            /*|.|./*|..|../*|*/.|*/./*|*/..|*/../*)
                log "下载包包含不安全路径。" "The downloaded archive contains an unsafe path."
                return 1
                ;;
            "anland-niri-packages/${ARCHIVE_TARGET}/"*) ;;
            *)
                log "下载包包含目标系统目录以外的文件。" \
                    "The downloaded archive contains files outside the target system directory."
                return 1
                ;;
        esac
    done <<< "$members"

    if ! LC_ALL=C tar -tvzf "$archive_file" | awk -v maximum="$MAX_EXTRACTED_BYTES" '
        {
            entry_type = substr($1, 1, 1)
            if (entry_type !~ /^[-d]$/ || $3 !~ /^[0-9]+$/) {
                exit 1
            }
            total += $3
            if (total > maximum) {
                exit 1
            }
        }
    '; then
        log "下载包包含不允许的条目，或解压后会超过大小限制。" \
            "The downloaded archive has a disallowed entry or exceeds the extraction size limit."
        return 1
    fi
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

validate_package_architecture() {
    local -a files=()
    local file package_arch

    case "$PACKAGE_TYPE" in
        deb)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
            for file in "${files[@]}"; do
                package_arch="$(dpkg-deb -f "$file" Architecture)"
                case "$package_arch" in arm64|all) ;; *) return 1 ;; esac
            done
            ;;
        rpm)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.rpm' -print | sort)
            for file in "${files[@]}"; do
                package_arch="$(rpm -qp --queryformat '%{ARCH}' "$file")"
                case "$package_arch" in aarch64|noarch) ;; *) return 1 ;; esac
            done
            ;;
        pkg.tar.*)
            mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
            for file in "${files[@]}"; do
                package_arch="$(LC_ALL=C pacman -Qip "$file" | sed -n 's/^[[:space:]]*Architecture[[:space:]]*:[[:space:]]*//p')"
                case "$package_arch" in aarch64|any) ;; *) return 1 ;; esac
            done
            ;;
    esac

    ((${#files[@]} > 0))
}

download_packages_once() {
    local base_url manifest_file archive_file extracted_size

    base_url="$(release_download_base)"
    manifest_file="$WORK_DIR/$MANIFEST_NAME"
    OFFICIAL_RELEASE_METADATA=""
    if [[ "$DOWNLOAD_SOURCE" != "3" ]]; then
        resolve_official_manifest_sha256 || return 1
    fi

    log "正在从 $(download_source_name "$DOWNLOAD_SOURCE") 下载 ${TARGET} 预编译包..." \
        "Downloading ${TARGET} prebuilt packages from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$base_url/$MANIFEST_NAME" "$manifest_file" || return 1
    if [[ -n "$EXPECTED_MANIFEST_SHA256" ]]; then
        validate_release_asset_checksum "$manifest_file" "$EXPECTED_MANIFEST_SHA256" "$MANIFEST_NAME" || return 1
    fi
    resolve_archive_name "$manifest_file" || return 1
    if [[ "$DOWNLOAD_SOURCE" != "3" ]]; then
        resolve_official_archive_sha256 || return 1
    fi

    archive_file="$WORK_DIR/$ARCHIVE_NAME"
    download_file "$base_url/$ARCHIVE_NAME" "$archive_file" || return 1
    if [[ -n "$EXPECTED_ARCHIVE_SHA256" ]]; then
        validate_release_asset_checksum "$archive_file" "$EXPECTED_ARCHIVE_SHA256" "$ARCHIVE_NAME" || return 1
    fi
    validate_archive_contents "$archive_file" || return 1
    if ! tar --no-same-owner --no-same-permissions -xzf "$archive_file" -C "$WORK_DIR"; then
        log "无法安全解压下载包。" "Unable to safely extract the downloaded archive."
        return 1
    fi

    PACKAGE_DIR="$WORK_DIR/anland-niri-packages/$ARCHIVE_TARGET"
    has_packages "$PACKAGE_DIR" || {
        log "未能获取 ${TARGET} 的安装包。" "Could not obtain packages for ${TARGET}."
        return 1
    }
    if ! extracted_size="$(du -sb "$PACKAGE_DIR" | awk '{print $1}')" || ! [[ "$extracted_size" =~ ^[0-9]+$ ]] || (( extracted_size > MAX_EXTRACTED_BYTES )); then
        log "解压后的软件包大小无效或超过限制。" \
            "The extracted package size is invalid or exceeds the limit."
        return 1
    fi
    if ! validate_package_architecture; then
        log "下载包中的软件包架构与当前系统不匹配。" \
            "The package architecture in the archive does not match this system."
        return 1
    fi
}

download_packages() {
    local attempt
    WORK_DIR="$(mktemp -d -t anland-niri.XXXXXXXX)"

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

use_prepared_packages() {
    local prepared_work_dir prepared_package_dir

    prepared_work_dir="$(realpath -e "$PREPARED_WORK_DIR")" || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    prepared_package_dir="$(realpath -e "$PREPARED_PACKAGE_DIR")" || \
        die "预下载包目录无效。" "The pre-downloaded package directory is invalid."
    [[ "$prepared_work_dir" =~ ^/tmp/anland-niri\.[A-Za-z0-9]+$ ]] || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    [[ "$prepared_package_dir" == "$prepared_work_dir/anland-niri-packages/$ARCHIVE_TARGET" ]] || \
        die "预下载包的目标系统不匹配。" "The pre-downloaded package target does not match this system."
    [[ -d "$prepared_work_dir" && -d "$prepared_package_dir" ]] || \
        die "预下载包已不存在。" "The pre-downloaded package directory no longer exists."

    WORK_DIR="$prepared_work_dir"
    PACKAGE_DIR="$prepared_package_dir"
    ARCHIVE_NAME="$PREPARED_ARCHIVE_NAME"
    case "$ARCHIVE_NAME" in "${ARCHIVE_PREFIX}"*"${ARCHIVE_SUFFIX}") ;; *)
        die "预下载包名与系统不匹配。" "The pre-downloaded archive name does not match this system." ;;
    esac
    has_packages "$PACKAGE_DIR" || die "预下载目录中没有可安装的软件包。" "The pre-downloaded directory has no installable packages."
    validate_package_architecture || \
        die "预下载包中的软件包架构与当前系统不匹配。" "The pre-downloaded package architecture does not match this system."
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
        -v legacy_begin="# anland-niri: hold patched Niri/Xwayland packages" '
        $0 == begin { managed = 1; next }
        $0 == end { managed = 0; next }
        managed { next }
        legacy_pending {
            if ($0 ~ /^[[:space:]]*exclude[[:space:]]*=[[:space:]]*niri-anland\*[[:space:]]+xorg-x11-server-Xwayland\*[[:space:]]*$/) {
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
    local preserve_xwayland="${3:-false}"

    awk -v preserve_xwayland="$preserve_xwayland" '
        function sanitize(line, equals, value, count, tokens, result, separator, i) {
            equals = index(line, "=")
            value = substr(line, equals + 1)
            gsub(/,/, " ", value)
            count = split(value, tokens, /[[:space:]]+/)
            result = ""
            separator = ""
            for (i = 1; i <= count; i++) {
                if (tokens[i] == "" || \
                    tokens[i] == "niri-anland*" || \
                    tokens[i] == "niri-anland" || \
                    tokens[i] == "xwayland-satellite*" || \
                    tokens[i] == "xwayland-satellite" || \
                    (preserve_xwayland != "true" && (tokens[i] == "xorg-x11-server-Xwayland*" || \
                    tokens[i] == "xorg-x11-server-Xwayland"))) {
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
    temporary_conf="$(mktemp -t anland-niri-dnf.XXXXXXXX)"
    mesa_stripped_conf="$(mktemp -t anland-niri-dnf.XXXXXXXX)"
    transaction_conf="$(mktemp -t anland-niri-dnf.XXXXXXXX)"
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
    local excluded_packages="niri-anland*,xwayland-satellite*,xorg-x11-server-Xwayland*"

    if [[ -e "$SYSTEMD257_STATE" ]]; then
        excluded_packages+=",systemd*"
    fi

    stripped_conf="$(mktemp -t anland-niri-dnf.XXXXXXXX)"
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
    temporary_conf="$(mktemp -t anland-niri-dnf.XXXXXXXX)"
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
    dnf_backup="$(mktemp -t anland-niri-dnf-backup.XXXXXXXX)"
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

install_arch_dependencies() {
    local file dependency name missing internal=' ' metadata
    local -a dependency_files=() dependency_names=()
    mapfile -t dependency_files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
    mapfile -t dependency_names < <(pacman -Qq -p "${dependency_files[@]}")
    local -a dependencies=() missing_names=()
    for file in "${dependency_files[@]}"; do
        metadata="$(bsdtar -xOf "$file" .PKGINFO)" || return 1
        while IFS= read -r dependency; do
            [[ -z "$dependency" ]] || dependencies+=("$dependency")
        done < <(sed -n 's/^depend = //p' <<< "$metadata")
        while IFS= read -r dependency; do internal+="${dependency%%[<>=]*} "; done < <(sed -n 's/^provides = //p' <<< "$metadata")
    done
    for name in "${dependency_names[@]}"; do internal+="$name "; done
    local -a external=()
    for dependency in "${dependencies[@]}"; do
        [[ "$internal" == *" ${dependency%%[<>=]*} "* ]] || external+=("$dependency")
    done
    ((${#external[@]})) || return 0
    missing="$(pacman -T "${external[@]}" || [[ "$?" == 127 ]])" || return 1
    [[ -n "$missing" ]] || return 0
    while IFS= read -r dependency; do missing_names+=("${dependency%%[<>=]*}"); done <<< "$missing"
    pacman -S --needed --noconfirm "${missing_names[@]}"
}

install_arch_packages() {
    local -a files packages
    local pacman_conf package

    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 Arch 包。" "No installable Arch packages were found."

    install_arch_dependencies || die "无法安装 Arch 运行时依赖。" "Could not install Arch runtime dependencies."
    log "正在安装 ${#files[@]} 个 Arch 包..." "Installing ${#files[@]} Arch packages..."
    pacman_conf="$(mktemp -t anland-niri-pacman.XXXXXXXX)"
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

    sed -i '/^# BEGIN anland-niri package holds$/d; /^# END anland-niri package holds$/d' /etc/pacman.conf
    for package in niri-anland xorg-xwayland; do
        if ! awk -v package="$package" '
            $1 == "IgnorePkg" {
                for (i = 3; i <= NF; i++) {
                    if ($i == package) {
                        found = 1
                    }
                }
            }
            END { exit found ? 0 : 1 }
        ' /etc/pacman.conf; then
            if grep -qE '^[[:space:]]*IgnorePkg[[:space:]]*=' /etc/pacman.conf; then
                sed -i -E "0,/^[[:space:]]*IgnorePkg[[:space:]]*=/{s/^([[:space:]]*IgnorePkg[[:space:]]*=.*)$/\\1 ${package}/}" /etc/pacman.conf
            elif grep -qE '^\[options\][[:space:]]*$' /etc/pacman.conf; then
                sed -i "/^\[options\][[:space:]]*$/a IgnorePkg = ${package}" /etc/pacman.conf
            else
                die "pacman.conf 缺少 [options] 段。" "pacman.conf has no [options] section."
            fi
        fi
    done
    mapfile -t packages < <(pacman -Qq -p "${files[@]}" | sort -u)
    ((${#packages[@]} > 0)) || die "无法读取 Arch 包名。" "Could not determine the Arch package names."
    printf '  hold: %s\n' "${packages[@]}"
}

main() {
    local archive_version
    detect_language
    parse_arguments "$@"
    detect_target
    check_architecture
    if [[ "$UNINSTALL" == true ]]; then
        require_root "$@"
        uninstall_niri
        return
    fi
    require_runtime_dependencies
    if [[ "$PACKAGE_TYPE" == "pkg.tar.*" ]]; then
        command -v bsdtar >/dev/null 2>&1 || die "未找到 bsdtar。" "bsdtar was not found."
    fi
    resolve_release_tag
    if [[ -n "$PREPARED_WORK_DIR" || -n "$PREPARED_PACKAGE_DIR" ]]; then
        use_prepared_packages
    else
        select_download_source
        download_packages
    fi
    require_root "$@"
    local owner
    if owner="$(other_xwayland_owner)"; then
        die "检测到 Anland $owner；请先卸载该组件以避免覆盖其 patched Xwayland。" \
            "Anland $owner is installed; uninstall it before replacing its patched Xwayland."
    fi

    case "$PACKAGE_TYPE" in
        deb) install_deb_packages ;;
        rpm) install_rpm_packages ;;
        pkg.tar.*) install_arch_packages ;;
    esac

    archive_version="${ARCHIVE_NAME#"$ARCHIVE_PREFIX"}"
    archive_version="${archive_version%"$ARCHIVE_SUFFIX"}"
    rm -f -- "${APT_HOLD_STATE%/*}/packages.tsv"
    record_component_version "$archive_version"
    update_desktop_config
    log "安装完成，patched Niri/Xwayland 已锁定。" \
        "Installation complete; patched Niri/Xwayland packages are now locked."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
