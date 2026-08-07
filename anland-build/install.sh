#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ARCHIVE_URL="https://github.com/Goldzxcbug/Droidspaces-rootfs-KDE-builder/archive/refs/heads/main.tar.gz"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
WORK_DIR=""
UI_LANG="en"

detect_language() {
    local locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
    locale_name="${locale_name,,}"
    if [[ "$locale_name" == zh* ]]; then
        UI_LANG="zh"
    else
        UI_LANG="en"
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
    printf '[anland-build] %s\n' "$(msg "$1" "$2")"
}

die() {
    printf '[anland-build] %s: %s\n' "$(msg '错误' 'Error')" "$(msg "$1" "$2")" >&2
    exit 1
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

    if command -v sudo >/dev/null 2>&1; then
        log "正在通过 sudo 重新运行安装程序..." "Restarting the installer with sudo..."
        exec sudo -- "$0" "$@"
    fi

    die "请使用 root 账户运行此脚本。" "Please run this script as root."
}

detect_target() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。" "Unable to read /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ -n "${ID:-}" ]] || die "/etc/os-release 缺少 ID。" "/etc/os-release does not contain ID."
    local distro_id="${ID,,}"
    local version_id="${VERSION_ID:-}"
    local system_name="${PRETTY_NAME:-$distro_id${version_id:+ $version_id}}"

    # Arch Linux ARM identifies itself as archarm and uses BUILD_ID=rolling;
    # it normally has no VERSION_ID.  Keep the version requirement for the
    # fixed-release Debian, Ubuntu, and Fedora package sets below.
    case "$distro_id" in
        arch|archarm)
            TARGET="Arch"
            PACKAGE_TYPE="pkg.tar.*"
            ;;
        *)
            [[ -n "$version_id" ]] || die "/etc/os-release 缺少 VERSION_ID。" "/etc/os-release does not contain VERSION_ID."
            case "$distro_id:$version_id" in
                debian:13*) TARGET="Debian13"; PACKAGE_TYPE="deb" ;;
                ubuntu:26.04*) TARGET="ubuntu2604"; PACKAGE_TYPE="deb" ;;
                fedora:43*) TARGET="Fedora43"; PACKAGE_TYPE="rpm" ;;
                fedora:44*) TARGET="Fedora44"; PACKAGE_TYPE="rpm" ;;
                *)
                    die "不支持当前系统 ${system_name}。仅支持 Debian 13、Ubuntu 26.04、Fedora 43/44、Arch Linux。" \
                        "Unsupported system: ${system_name}. Supported systems are Debian 13, Ubuntu 26.04, Fedora 43/44, and Arch Linux."
                    ;;
            esac
            ;;
    esac

    log "已识别系统: ${system_name} -> ${TARGET}" \
        "Detected system: ${system_name} -> ${TARGET}"
}

check_architecture() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        aarch64|arm64) ;;
        *) die "预编译包仅支持 ARM64/aarch64，当前架构为 ${arch}。" \
            "The prebuilt packages support ARM64/aarch64 only; the current architecture is ${arch}." ;;
    esac
}

has_packages() {
    local base="$1"
    compgen -G "$base/*.${PACKAGE_TYPE}" >/dev/null
}

download_packages() {
    local archive extract_root
    WORK_DIR="$(mktemp -d -t anland-build.XXXXXXXX)"
    archive="$WORK_DIR/repository.tar.gz"

    log "本地未找到 ${TARGET} 安装包，正在下载仓库快照..." \
        "Local ${TARGET} packages were not found; downloading the repository snapshot..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 20 "$REPO_ARCHIVE_URL" -o "$archive"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$archive" "$REPO_ARCHIVE_URL"
    else
        die "未找到 curl 或 wget，无法下载安装包。" "Neither curl nor wget was found; packages cannot be downloaded."
    fi

    tar -xzf "$archive" -C "$WORK_DIR"
    extract_root="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ -n "$extract_root" ]] || die "下载的仓库快照内容异常。" "The downloaded repository snapshot is invalid."
    PACKAGE_DIR="$extract_root/anland-build/$TARGET"
    has_packages "$PACKAGE_DIR" || die "仓库快照中缺少 ${TARGET} 的安装包。" "The repository snapshot does not contain packages for ${TARGET}."
}

locate_packages() {
    PACKAGE_DIR="$SCRIPT_DIR/$TARGET"
    if [[ -n "$SCRIPT_DIR" ]] && has_packages "$PACKAGE_DIR"; then
        log "使用本地安装包: $PACKAGE_DIR" "Using local packages: $PACKAGE_DIR"
    else
        download_packages
    fi
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
    apt-get install -y --allow-downgrades --allow-change-held-packages "${files[@]}"

    for file in "${files[@]}"; do
        package="$(dpkg-deb -f "$file" Package)"
        [[ -n "$package" ]] && packages+=("$package")
    done
    mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sort -u)

    log "正在设置 APT hold..." "Applying APT holds..."
    apt-mark hold "${packages[@]}"
    printf '  hold: %s\n' "${packages[@]}"
}

install_rpm_packages() {
    local -a files packages
    local -a exclude_patterns=("kwin*" "xorg-x11-server-Xwayland*")
    local current_excludes exclude_key pattern

    command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
    command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.rpm' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 rpm 包。" "No installable rpm packages were found."

    log "正在安装 ${#files[@]} 个 rpm 包并自动处理依赖..." \
        "Installing ${#files[@]} rpm packages and resolving dependencies..."
    dnf install -y "${files[@]}"

    mapfile -t packages < <(rpm -qp --queryformat '%{NAME}\n' "${files[@]}" | sort -u)
    log "正在设置 DNF exclude（等效于 hold）..." "Applying DNF excludes (equivalent to hold)..."
    touch /etc/dnf/dnf.conf
    if grep -q '^exclude=' /etc/dnf/dnf.conf; then
        exclude_key="exclude"
    elif grep -q '^excludepkgs=' /etc/dnf/dnf.conf; then
        exclude_key="excludepkgs"
    else
        exclude_key=""
    fi

    if [[ -n "$exclude_key" ]]; then
        current_excludes="$(sed -n "s/^${exclude_key}=//p" /etc/dnf/dnf.conf | head -n1)"
        for pattern in "${exclude_patterns[@]}"; do
            case " $current_excludes " in
                *" $pattern "*) ;;
                *)
                    sed -i "/^${exclude_key}=/{s|$| $pattern|;}" /etc/dnf/dnf.conf
                    current_excludes="$current_excludes $pattern"
                    ;;
            esac
        done
    else
        printf '\n# anland-build: hold patched KWin/Xwayland packages\nexclude=%s\n' \
            "${exclude_patterns[*]}" >> /etc/dnf/dnf.conf
    fi
    printf '  hold: %s\n' "${packages[@]}"
}

install_arch_packages() {
    local -a files packages
    local pacman_conf

    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 Arch 包。" "No installable Arch packages were found."

    log "正在安装 ${#files[@]} 个 Arch 包..." "Installing ${#files[@]} Arch packages..."
    pacman_conf="$(mktemp -t anland-pacman.XXXXXXXX)"
    cp /etc/pacman.conf "$pacman_conf"
    if grep -q '^#LocalFileSigLevel = Optional$' "$pacman_conf"; then
        sed -i 's/^#LocalFileSigLevel = Optional$/LocalFileSigLevel = Optional/' "$pacman_conf"
    else
        printf '\n[options]\nLocalFileSigLevel = Optional\n' >> "$pacman_conf"
    fi
    pacman --config "$pacman_conf" -U --noconfirm "${files[@]}"
    rm -f -- "$pacman_conf"

    if ! grep -q '^IgnorePkg.*kwin' /etc/pacman.conf; then
        sed -i '/^\[options\]$/a IgnorePkg = kwin xorg-xwayland' /etc/pacman.conf
    fi
    mapfile -t packages < <(pacman -Qq -p "${files[@]}" | sort -u)
    printf '  hold: %s\n' "${packages[@]}"
}

main() {
    detect_language
    require_root "$@"
    detect_target
    check_architecture
    locate_packages

    case "$PACKAGE_TYPE" in
        deb) install_deb_packages ;;
        rpm) install_rpm_packages ;;
        pkg.tar.*) install_arch_packages ;;
    esac

    log "安装完成，patched KWin/Xwayland 已锁定。" "Installation complete; patched KWin/Xwayland packages are now locked."
}

main "$@"
