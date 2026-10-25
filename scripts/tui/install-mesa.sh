#!/usr/bin/env bash
set -euo pipefail

# Mesa 源仓库：https://github.com/lfdevs/mesa-for-android-container
# 媒体解码源仓库：https://github.com/Re-s/droidspaces-media-decode
# 分发地址：https://github.com/Goldzxcbug/droidspaces-package/releases/tag/mesa-for-android-container
# 安装面向 Android 容器的 ARM64 Mesa 构建。
# 同时安装 droidspaces-media-decode 发布的 MediaCodec VA-API 驱动。
# 根据 /etc/os-release 选择 Mesa 归档格式和包管理器。
readonly RELEASE_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly CNB_RELEASE_REPOSITORY="goldzxcbug/droidspaces-package"
readonly DISTRIBUTION_TAG="mesa-for-android-container"
readonly DISTRIBUTION_MANIFEST_NAME="mesa-distribution-manifest"
readonly MEDIA_DRIVER_NAME="msm_drm_drv_video.so"
readonly MEDIA_CHECKSUMS_NAME="SHA256SUMS"
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly APT_HOLD_PREFERENCES="/etc/apt/preferences.d/hold-anland-package"
readonly DNF_CONFIG="/etc/dnf/dnf.conf"
readonly DNF_MANAGED_BEGIN="# BEGIN install-mesa package holds"
readonly DNF_MANAGED_END="# END install-mesa package holds"
readonly PACMAN_CONFIG="/etc/pacman.conf"
readonly PACMAN_MANAGED_BEGIN="# BEGIN install-mesa package holds"
readonly PACMAN_MANAGED_END="# END install-mesa package holds"
readonly SYSTEMD257_STATE="/etc/droidspaces-systemd257"
readonly COMPONENT_STATE_DIR="/var/lib/droidspaces-tui/components"
readonly MAX_ARCHIVE_BYTES=$((512 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((2 * 1024 * 1024 * 1024))
readonly MAX_MEDIA_DRIVER_BYTES=$((16 * 1024 * 1024))
readonly MAX_MANIFEST_BYTES=$((1024 * 1024))
readonly MAX_CHECKSUMS_BYTES=$((1024 * 1024))

UI_LANG="en"
TARGET=""
PACKAGE_MANAGER=""
ASSET_PATTERN=""
ARCHIVE_KIND=""
WORK_DIR=""
ARCHIVE_FILE=""
ARCHIVE_NAME=""
RELEASE_TAG=""
DOWNLOAD_URL=""
DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
MESA_MANIFEST_FILE=""
AUTHORITATIVE_MANIFEST_FILE=""
OFFICIAL_DOWNLOAD_URL=""
EXPECTED_ARCHIVE_SIZE=""
EXPECTED_ARCHIVE_SHA256=""
MEDIA_RELEASE_TAG=""
MEDIA_DRIVER_DOWNLOAD_URL=""
MEDIA_DRIVER_RELEASE_DIGEST=""
MEDIA_DRIVER_RELEASE_SIZE=""
MEDIA_CHECKSUMS_DOWNLOAD_URL=""
MEDIA_CHECKSUMS_RELEASE_DIGEST=""
MEDIA_CHECKSUMS_RELEASE_SIZE=""
MEDIA_DRIVER_FILE=""
MEDIA_CHECKSUMS_FILE=""
MEDIA_DRIVER_TEMP_FILE=""
MEDIA_DRIVER_INSTALL_DIR=""
MEDIA_DRIVER_INSTALL_PATH=""
MESA_PACKAGE_NAMES=()
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
    printf '[install-mesa] %s\n' "$(msg "$1" "$2")"
}

record_component_version() {
    local version="$1" state_file="$COMPONENT_STATE_DIR/mesa.version" temporary_file
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 0
    if ! mkdir -p -- "$COMPONENT_STATE_DIR"; then
        log "无法记录已安装的 Mesa 版本。" "Could not record the installed Mesa version."
        return 0
    fi
    temporary_file="$(mktemp "$state_file.tmp.XXXXXXXX")" || {
        log "无法记录已安装的 Mesa 版本。" "Could not record the installed Mesa version."
        return 0
    }
    if printf '%s\n' "$version" > "$temporary_file" && \
        chmod 0644 "$temporary_file" && mv -f -- "$temporary_file" "$state_file"; then
        return 0
    fi
    rm -f -- "$temporary_file" || true
    log "无法记录已安装的 Mesa 版本。" "Could not record the installed Mesa version."
    return 0
}

mesa_archive_version() {
    local version="${ARCHIVE_NAME#mesa-for-android-container_}"
    case "$version" in
        *_archlinux_arm64.tar) version="${version%_archlinux_arm64.tar}" ;;
        *_debian_trixie_arm64.tar.gz) version="${version%_debian_trixie_arm64.tar.gz}" ;;
        *_ubuntu_noble_arm64.tar.gz) version="${version%_ubuntu_noble_arm64.tar.gz}" ;;
        *_ubuntu_questing_arm64.tar.gz) version="${version%_ubuntu_questing_arm64.tar.gz}" ;;
        *_ubuntu_resolute_arm64.tar.gz) version="${version%_ubuntu_resolute_arm64.tar.gz}" ;;
        *_fedora_43_arm64.tar.gz) version="${version%_fedora_43_arm64.tar.gz}" ;;
        *_fedora_44_arm64.tar.gz) version="${version%_fedora_44_arm64.tar.gz}" ;;
        *) return 1 ;;
    esac
    printf '%s' "$version"
}

die() {
    printf '[install-mesa] %s: %s\n' \
        "$(msg '错误' 'Error')" "$(msg "$1" "$2")" >&2
    exit 1
}

usage() {
    cat <<EOF
$(msg '用法' 'Usage'): $0

  -1, --1       $(msg '使用 GitHub 并跳过测速。' 'Use GitHub and skip latency checks.')
  -2, --2       $(msg '使用 gh-proxy.com 并跳过测速。' 'Use gh-proxy.com and skip latency checks.')
  -3, --3       $(msg '使用 CNB 国内镜像并跳过测速。' 'Use the CNB mirror and skip latency checks.')
  --uninstall   $(msg '卸载自定义驱动并恢复发行版 Mesa' 'Uninstall custom drivers and restore distribution Mesa')
  -h, --help    $(msg '显示此帮助。' 'Show this help.')

$(msg '未指定下载源时，将测试三个源并提示选择。' 'Without a source option, all three sources are probed before prompting.')
EOF
}

set_download_source_argument() {
    local source="$1"

    if [[ -n "$DOWNLOAD_SOURCE" && "$DOWNLOAD_SOURCE" != "$source" ]]; then
        die "不能同时指定多个下载源。" "Conflicting download-source options were provided."
    fi
    DOWNLOAD_SOURCE="$source"
    SKIP_SOURCE_PROBE=true
}

parse_arguments() {
    local argument

    for argument in "$@"; do
        case "$argument" in
            -1|--1)
                set_download_source_argument "1"
                ;;
            -2|--2)
                set_download_source_argument "2"
                ;;
            -3|--3)
                set_download_source_argument "3"
                ;;
            --uninstall)
                UNINSTALL=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "不支持的参数：${argument}。可用参数为 -1/--1、-2/--2、-3/--3。" \
                    "Unsupported argument: ${argument}. Valid arguments are -1/--1, -2/--2, and -3/--3."
                ;;
        esac
    done
}

uninstall_mesa_apt() {
    local package candidate backup=""
    local -a packages=(libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-vulkan-drivers)
    local -a package_specs=()
    command -v apt-cache >/dev/null 2>&1 || die "未找到 apt-cache。" "apt-cache was not found."
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    if [[ -e "$APT_HOLD_PREFERENCES" ]]; then
        [[ -f "$APT_HOLD_PREFERENCES" && ! -L "$APT_HOLD_PREFERENCES" ]] || \
            die "Mesa 锁定配置路径异常。" "The Mesa hold configuration path is invalid."
        grep -Fqx '# /etc/apt/preferences.d/hold-anland-package' "$APT_HOLD_PREFERENCES" && \
            grep -Fqx 'Pin-Priority: -1' "$APT_HOLD_PREFERENCES" || \
            die "Mesa 锁定配置已被修改，拒绝自动删除。" \
                "The Mesa hold configuration was modified; refusing to remove it automatically."
        backup="$(mktemp -t install-mesa-apt-hold.XXXXXXXX)"
        cp -p -- "$APT_HOLD_PREFERENCES" "$backup"
        rm -f -- "$APT_HOLD_PREFERENCES"
    fi
    for package in "${packages[@]}"; do
        candidate="$(apt-cache madison "$package" | awk -F '|' 'NR == 1 {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }')"
        if [[ -z "$candidate" ]]; then
            [[ -z "$backup" ]] || install -m 0644 "$backup" "$APT_HOLD_PREFERENCES"
            rm -f -- "$backup"
            die "找不到 $package 的官方候选版本。" "No distribution candidate was found for $package."
        fi
        package_specs+=("$package=$candidate")
    done
    if ! apt-get install -y --reinstall --allow-downgrades "${package_specs[@]}"; then
        [[ -z "$backup" ]] || install -m 0644 "$backup" "$APT_HOLD_PREFERENCES"
        rm -f -- "$backup"
        die "恢复发行版 Mesa 失败。" "Failed to restore distribution Mesa packages."
    fi
    rm -f -- "$backup"
}

uninstall_mesa_dnf() {
    local backup stripped package
    local -a packages=()
    command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
    command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
    [[ -f "$DNF_CONFIG" ]] || die "找不到 DNF 配置。" "The DNF configuration was not found."
    mapfile -t packages < <(rpm -qa --queryformat '%{NAME}\n' | awk '/^mesa/ { print }' | sort -u)
    ((${#packages[@]} > 0)) || die "没有找到已安装的 Mesa 包。" "No installed Mesa packages were found."
    backup="$(mktemp -t install-mesa-uninstall.XXXXXXXX)"
    stripped="$(mktemp -t install-mesa-uninstall.XXXXXXXX)"
    cp -p -- "$DNF_CONFIG" "$backup"
    WORK_DIR="$(mktemp -d -t install-mesa-uninstall.XXXXXXXX)"
    if ! rewrite_without_managed_block \
        "$DNF_CONFIG" "$stripped" "$DNF_MANAGED_BEGIN" "$DNF_MANAGED_END" || \
        ! install -m 0644 "$stripped" "$DNF_CONFIG" || \
        ! dnf distro-sync -y --exclude='systemd*' "${packages[@]}"; then
        install -m 0644 "$backup" "$DNF_CONFIG" || true
        rm -f -- "$backup" "$stripped"
        die "恢复发行版 Mesa 失败。" "Failed to restore distribution Mesa packages."
    fi
    rm -f -- "$backup" "$stripped"
}

uninstall_mesa_pacman() {
    local backup stripped protected preserve_kde=false
    local -a packages=()
    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    [[ -f "$PACMAN_CONFIG" ]] || die "找不到 pacman.conf。" "pacman.conf was not found."
    mapfile -t packages < <(awk -v begin="$PACMAN_MANAGED_BEGIN" -v end="$PACMAN_MANAGED_END" '
        $0 == begin { inside = 1; next }
        $0 == end { inside = 0; next }
        inside && $1 == "IgnorePkg" {
            for (i = 3; i <= NF; i++) {
                if ($i !~ /^systemd(-libs|-sysvcompat)?$/ && \
                    $i != "kwin" && $i != "xorg-xwayland") print $i
            }
        }
    ' "$PACMAN_CONFIG" | sort -u)
    ((${#packages[@]} > 0)) || packages=(mesa)
    backup="$(mktemp -t install-mesa-uninstall.XXXXXXXX)"
    stripped="$(mktemp -t install-mesa-uninstall.XXXXXXXX)"
    protected="$(mktemp -t install-mesa-uninstall.XXXXXXXX)"
    cp -p -- "$PACMAN_CONFIG" "$backup"
    WORK_DIR="$(mktemp -d -t install-mesa-uninstall.XXXXXXXX)"
    if grep -Eq '^[[:space:]]*IgnorePkg[[:space:]]*=.*(^|[[:space:]])kwin([[:space:]]|$)' \
        "$PACMAN_CONFIG"; then
        preserve_kde=true
    fi
    if ! rewrite_without_managed_block \
        "$PACMAN_CONFIG" "$stripped" "$PACMAN_MANAGED_BEGIN" "$PACMAN_MANAGED_END"; then
        rm -f -- "$backup" "$stripped" "$protected"
        die "无法移除 Mesa 锁定配置。" "Failed to remove the Mesa hold configuration."
    fi
    if [[ "$preserve_kde" == true ]] && \
        ! grep -Eq '^[[:space:]]*IgnorePkg[[:space:]]*=.*(^|[[:space:]])kwin([[:space:]]|$)' "$stripped"; then
        awk '
            { print }
            /^\[options\][[:space:]]*$/ && !added {
                print "IgnorePkg = kwin xorg-xwayland"
                added = 1
            }
            END { if (!added) exit 1 }
        ' "$stripped" > "$protected" || {
            rm -f -- "$backup" "$stripped" "$protected"
            die "无法保留 Anland KDE 锁定。" "Failed to preserve the Anland KDE hold."
        }
    else
        cp -- "$stripped" "$protected"
    fi
    if ! install -m 0644 "$protected" "$PACMAN_CONFIG" || \
        ! pacman -S --noconfirm "${packages[@]}"; then
        install -m 0644 "$backup" "$PACMAN_CONFIG" || true
        rm -f -- "$backup" "$stripped" "$protected"
        die "恢复发行版 Mesa 失败。" "Failed to restore distribution Mesa packages."
    fi
    rm -f -- "$backup" "$stripped" "$protected"
}

uninstall_mesa() {
    case "$PACKAGE_MANAGER" in
        apt) uninstall_mesa_apt ;;
        dnf) uninstall_mesa_dnf ;;
        pacman) uninstall_mesa_pacman ;;
    esac
    rm -f -- "$MEDIA_DRIVER_INSTALL_PATH" "$COMPONENT_STATE_DIR/mesa.version"
    command -v ldconfig >/dev/null 2>&1 && ldconfig || true
    log "自定义 Mesa/MediaCodec 驱动已卸载，发行版 Mesa 已恢复。" \
        "Custom Mesa/MediaCodec drivers were uninstalled and distribution Mesa was restored."
}

cleanup() {
    if [[ -n "$MEDIA_DRIVER_TEMP_FILE" && -e "$MEDIA_DRIVER_TEMP_FILE" ]]; then
        rm -f -- "$MEDIA_DRIVER_TEMP_FILE"
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

require_root() {
    if (( EUID == 0 )); then
        return
    fi

    command -v sudo >/dev/null 2>&1 || die \
        "请使用 root 账户运行此脚本。" "Please run this script as root."
    log "正在通过 sudo 重新运行安装程序..." "Restarting the installer with sudo..."

    local script_path="${BASH_SOURCE[0]}"
    if [[ "$script_path" != /* ]]; then
        script_path="$PWD/$script_path"
    fi
    exec sudo --preserve-env=LANG,LC_ALL,LC_MESSAGES -- bash "$script_path" "$@"
}

media_driver_install_dir_for_target() {
    case "$1" in
        debian|ubuntu) printf '/usr/lib/aarch64-linux-gnu/dri' ;;
        fedora) printf '/usr/lib64/dri' ;;
        arch|archarm|archlinux) printf '/usr/lib/dri' ;;
        *) return 1 ;;
    esac
}

detect_target() {
    [[ -r /etc/os-release ]] || die \
        "无法读取 /etc/os-release。" "Unable to read /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ -n "${ID:-}" ]] || die \
        "/etc/os-release 缺少 ID。" "/etc/os-release does not contain ID."

    local distro_id="${ID,,}"
    local version_id="${VERSION_ID:-}"
    local system_name="${PRETTY_NAME:-$distro_id${version_id:+ $version_id}}"

    TARGET=""
    PACKAGE_MANAGER=""
    ASSET_PATTERN=""
    ARCHIVE_KIND=""

    case "$distro_id" in
        arch|archarm|archlinux)
            TARGET="Arch Linux"
            PACKAGE_MANAGER="pacman"
            ARCHIVE_KIND="tar"
            ASSET_PATTERN='^mesa-for-android-container_[^/]+_archlinux_arm64\.tar$'
            ;;
        debian)
            case "$version_id" in
                13*)
                    TARGET="Debian 13"
                    PACKAGE_MANAGER="apt"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_debian_trixie_arm64\.tar\.gz$'
                    ;;
                *)
                    die "不支持当前系统 ${system_name}。仅支持 Debian 13。" \
                        "Unsupported system: ${system_name}. Only Debian 13 is supported."
                    ;;
            esac
            ;;
        ubuntu)
            case "$version_id" in
                24.04*)
                    TARGET="Ubuntu 24.04"
                    PACKAGE_MANAGER="apt"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_ubuntu_noble_arm64\.tar\.gz$'
                    ;;
                25.10*)
                    TARGET="Ubuntu 25.10"
                    PACKAGE_MANAGER="apt"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_ubuntu_questing_arm64\.tar\.gz$'
                    ;;
                26.04*)
                    TARGET="Ubuntu 26.04"
                    PACKAGE_MANAGER="apt"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_ubuntu_resolute_arm64\.tar\.gz$'
                    ;;
                *)
                    die "不支持当前系统 ${system_name}。仅支持 Ubuntu 24.04、25.10、26.04。" \
                        "Unsupported system: ${system_name}. Only Ubuntu 24.04, 25.10, and 26.04 are supported."
                    ;;
            esac
            ;;
        fedora)
            case "$version_id" in
                43*)
                    TARGET="Fedora 43"
                    PACKAGE_MANAGER="dnf"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_fedora_43_arm64\.tar\.gz$'
                    ;;
                44*)
                    TARGET="Fedora 44"
                    PACKAGE_MANAGER="dnf"
                    ARCHIVE_KIND="tar.gz"
                    ASSET_PATTERN='^mesa-for-android-container_[^/]+_fedora_44_arm64\.tar\.gz$'
                    ;;
                *)
                    die "不支持当前系统 ${system_name}。仅支持 Fedora 43/44。" \
                        "Unsupported system: ${system_name}. Only Fedora 43/44 are supported."
                    ;;
            esac
            ;;
        *)
            die "不支持当前系统 ${system_name}。" "Unsupported system: ${system_name}."
            ;;
    esac

    MEDIA_DRIVER_INSTALL_DIR="$(media_driver_install_dir_for_target "$distro_id")" || die \
        "内部错误：无法确定 ${system_name} 的媒体解码驱动目录。" \
        "Internal error: could not determine the media decode driver directory for ${system_name}."
    MEDIA_DRIVER_INSTALL_PATH="${MEDIA_DRIVER_INSTALL_DIR}/${MEDIA_DRIVER_NAME}"

    log "已识别系统: ${system_name} -> ${TARGET}" \
        "Detected system: ${system_name} -> ${TARGET}"
}

check_architecture() {
    local architecture

    architecture="$(uname -m)"
    case "$architecture" in
        aarch64|arm64) ;;
        *)
            die "预编译 Mesa 包仅支持 ARM64/aarch64，当前架构为 ${architecture}。" \
                "The prebuilt Mesa packages support ARM64/aarch64 only; current architecture is ${architecture}."
            ;;
    esac
}

require_commands() {
    local command_name

    for command_name in awk cat chmod cmp cp dirname grep install mktemp mv od rm sed sha256sum sort stat tar tr uname; do
        command -v "$command_name" >/dev/null 2>&1 || die \
            "缺少运行安装器所需的命令：${command_name}。" \
            "The installer requires the missing command: ${command_name}."
    done

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        die "未找到 curl 或 wget，无法下载 Mesa。" \
            "Neither curl nor wget was found; Mesa cannot be downloaded."
    fi

    case "$PACKAGE_MANAGER" in
        apt)
            command -v ldconfig >/dev/null 2>&1 || die \
                "未找到 ldconfig。" "ldconfig was not found."
            ;;
        dnf)
            command -v ldconfig >/dev/null 2>&1 || die \
                "未找到 ldconfig。" "ldconfig was not found."
            ;;
        pacman)
            command -v pacman >/dev/null 2>&1 || die \
                "未找到 pacman。" "pacman was not found."
            [[ -r "$PACMAN_CONFIG" ]] || die \
                "无法读取 ${PACMAN_CONFIG}。" "Unable to read ${PACMAN_CONFIG}."
            ;;
    esac
}

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 5 --retry-all-errors --connect-timeout 20 --max-time 300 \
            --continue-at - "$url" -o "$destination"
    else
        wget --continue --tries=5 --timeout=20 --waitretry=3 --retry-connrefused \
            -O "$destination" "$url"
    fi
}

download_manifest_for_source() {
    local source="$1"
    local destination="$2"
    local manifest_url

    manifest_url="$(distribution_manifest_url_for_source "$source")" || return 1
    download_file "$manifest_url" "$destination"
}

# 分发清单是 Release 中的普通资产，读取它不消耗 GitHub API 配额；
# 构建矩阵并发很高，走 api.github.com 会因匿名配额（60 次/小时/IP）被限流。
parse_distribution_manifest() {
    local manifest_file="$1"
    local manifest_size rows checksum size asset archive_name canonical_base
    local archive_count=0 driver_count=0 checksums_count=0
    local archive_checksum="" archive_size=""
    local driver_checksum="" driver_size=""
    local checksums_checksum="" checksums_size=""

    manifest_size="$(stat -c '%s' "$manifest_file")" || die \
        "无法读取 Mesa 分发清单大小。" "Could not read the Mesa distribution manifest size."
    [[ "$manifest_size" =~ ^[0-9]+$ && "$manifest_size" -gt 0 && \
       "$manifest_size" -le "$MAX_MANIFEST_BYTES" ]] || die \
        "Mesa 分发清单大小无效。" "The Mesa distribution manifest size is invalid."
    rows="$(manifest_asset_rows "$manifest_file")" || die \
        "Mesa 分发清单格式无效。" "The Mesa distribution manifest format is invalid."

    while IFS=$'\t' read -r checksum size asset; do
        [[ -n "$checksum" && -n "$size" && -n "$asset" ]] || continue
        if [[ "$asset" =~ $ASSET_PATTERN ]]; then
            archive_name="$asset"
            archive_checksum="$checksum"
            archive_size="$size"
            archive_count=$((archive_count + 1))
        fi
        case "$asset" in
            "$MEDIA_DRIVER_NAME")
                driver_checksum="$checksum"
                driver_size="$size"
                driver_count=$((driver_count + 1))
                ;;
            "$MEDIA_CHECKSUMS_NAME")
                checksums_checksum="$checksum"
                checksums_size="$size"
                checksums_count=$((checksums_count + 1))
                ;;
        esac
    done <<< "$rows"

    (( archive_count == 1 )) || die \
        "${TARGET} 在 Mesa 分发清单中没有唯一的 ARM64 包。" \
        "The Mesa distribution manifest has no unique ARM64 archive for ${TARGET}."
    (( driver_count == 1 && checksums_count == 1 )) || die \
        "Mesa 分发清单缺少或重复媒体解码驱动资产。" \
        "The Mesa distribution manifest has missing or duplicate media decode driver assets."
    (( archive_size <= MAX_ARCHIVE_BYTES && driver_size <= MAX_MEDIA_DRIVER_BYTES && \
       checksums_size <= MAX_CHECKSUMS_BYTES )) || die \
        "Mesa 分发清单中的资产超过大小限制。" \
        "An asset in the Mesa distribution manifest exceeds its size limit."

    ARCHIVE_NAME="$archive_name"
    RELEASE_TAG="$DISTRIBUTION_TAG"
    EXPECTED_ARCHIVE_SHA256="$archive_checksum"
    EXPECTED_ARCHIVE_SIZE="$archive_size"
    MEDIA_RELEASE_TAG="$DISTRIBUTION_TAG"
    MEDIA_DRIVER_RELEASE_DIGEST="sha256:$driver_checksum"
    MEDIA_DRIVER_RELEASE_SIZE="$driver_size"
    MEDIA_CHECKSUMS_RELEASE_DIGEST="sha256:$checksums_checksum"
    MEDIA_CHECKSUMS_RELEASE_SIZE="$checksums_size"
    canonical_base="$GITHUB_RELEASE_URL/$RELEASE_REPOSITORY/releases/download/$DISTRIBUTION_TAG"
    OFFICIAL_DOWNLOAD_URL="$canonical_base/$ARCHIVE_NAME"
    MEDIA_DRIVER_DOWNLOAD_URL="$canonical_base/$MEDIA_DRIVER_NAME"
    MEDIA_CHECKSUMS_DOWNLOAD_URL="$canonical_base/$MEDIA_CHECKSUMS_NAME"
}

# 三个下载源都只读取各自 Release 上的分发清单：清单是普通资产，
# 不消耗 GitHub API 配额，避免 GitHub 托管 runner 共享出口 IP 时被 403 限流。
# 清单本身仍提供每个资产的 SHA-256 与大小，并继续与随包 SHA256SUMS 交叉校验。
resolve_release_asset() {
    local source_name

    source_name="$(download_source_name "$DOWNLOAD_SOURCE")" || die \
        "下载源选择无效。" "The selected download source is invalid."
    MESA_MANIFEST_FILE="$WORK_DIR/$DISTRIBUTION_MANIFEST_NAME"
    log "正在从 ${source_name} 读取 Mesa 滚动分发清单..." \
        "Reading the rolling Mesa distribution manifest from ${source_name}..."
    download_manifest_for_source "$DOWNLOAD_SOURCE" "$MESA_MANIFEST_FILE" || die \
        "无法从 ${source_name} 下载 Mesa 分发清单。" \
        "Could not download the Mesa distribution manifest from ${source_name}."
    parse_distribution_manifest "$MESA_MANIFEST_FILE"

    # 代理源转发的是 GitHub 内容，要求与 GitHub 权威清单逐字节一致；
    # CNB 镜像独立托管，沿用原有的清单自校验模型。
    if [[ "$DOWNLOAD_SOURCE" == "2" ]]; then
        AUTHORITATIVE_MANIFEST_FILE="$WORK_DIR/${DISTRIBUTION_MANIFEST_NAME}.github"
        download_manifest_for_source 1 "$AUTHORITATIVE_MANIFEST_FILE" || die \
            "无法从 GitHub 下载 Mesa 权威分发清单。" \
            "Could not download the authoritative Mesa distribution manifest from GitHub."
        cmp -s -- "$AUTHORITATIVE_MANIFEST_FILE" "$MESA_MANIFEST_FILE" || die \
            "${source_name} 的 Mesa 分发清单与 GitHub 不一致。" \
            "The Mesa distribution manifest on ${source_name} differs from GitHub."
    fi
    log "已选择 Mesa 包: ${ARCHIVE_NAME}" "Selected Mesa asset: ${ARCHIVE_NAME}"
}

manifest_asset_rows() {
    local manifest="$1"

    awk -F '\t' -v expected_tag="$DISTRIBUTION_TAG" '
        $0 == "format=1" { format_count += 1; next }
        $0 ~ /^format=/ { invalid = 1; next }
        $0 ~ /^release_tag=/ {
            release_tag_count += 1
            if ($0 != "release_tag=" expected_tag) invalid = 1
            next
        }
        $0 == "sha256\tsize\tasset" { header_count += 1; in_assets = 1; next }
        !in_assets && $0 == "" { next }
        !in_assets && $0 ~ /^[A-Za-z][A-Za-z0-9_]*=.*/ { next }
        in_assets && NF == 3 {
            if (length($1) != 64 || $1 !~ /^[0-9A-Fa-f]+$/ ||
                $2 !~ /^[0-9]+$/ || $2 == 0 ||
                $3 !~ /^[A-Za-z0-9][A-Za-z0-9._+-]*$/ || $3 ~ /\.\./ || seen[$3]++) {
                invalid = 1
            } else {
                print tolower($1) "\t" $2 "\t" $3
                asset_count += 1
            }
            next
        }
        { invalid = 1 }
        END {
            if (format_count != 1 || release_tag_count > 1 || header_count != 1 || asset_count == 0 || invalid) {
                exit 1
            }
        }
    ' "$manifest"
}

download_source_name() {
    case "$1" in
        1) printf 'GitHub' ;;
        2) printf 'gh-proxy.com' ;;
        3) printf 'CNB' ;;
        *) return 1 ;;
    esac
}

download_url_for_source() {
    local source="$1"

    download_url_for_release_asset "$source" "$RELEASE_REPOSITORY" "$OFFICIAL_DOWNLOAD_URL"
}

distribution_manifest_url_for_source() {
    case "$1" in
        1) printf '%s/%s/releases/download/%s/%s' \
            "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" \
            "$DISTRIBUTION_TAG" "$DISTRIBUTION_MANIFEST_NAME" ;;
        2) printf '%s/%s/releases/download/%s/%s' \
            "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" \
            "$DISTRIBUTION_TAG" "$DISTRIBUTION_MANIFEST_NAME" ;;
        3) printf '%s/%s/-/releases/download/%s/%s' \
            "$CNB_RELEASE_URL" "$CNB_RELEASE_REPOSITORY" \
            "$DISTRIBUTION_TAG" "$DISTRIBUTION_MANIFEST_NAME" ;;
        *) return 1 ;;
    esac
}

download_url_for_release_asset() {
    local source="$1"
    local repository="$2"
    local official_url="$3"
    local source_url official_path asset_name

    case "$source" in
        1) source_url="$GITHUB_RELEASE_URL" ;;
        2) source_url="$GH_PROXY_RELEASE_URL" ;;
        3)
            official_path="${official_url#"$GITHUB_RELEASE_URL"}"
            [[ "$official_path" == "/${repository}/releases/download/${DISTRIBUTION_TAG}/"* ]] || return 1
            asset_name="${official_url##*/}"
            [[ "$asset_name" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
            printf '%s/%s/-/releases/download/%s/%s' \
                "$CNB_RELEASE_URL" "$CNB_RELEASE_REPOSITORY" \
                "$DISTRIBUTION_TAG" "$asset_name"
            return
            ;;
        *) return 1 ;;
    esac

    official_path="${official_url#"$GITHUB_RELEASE_URL"}"
    [[ "$official_path" == "/${repository}/releases/download/"* ]] || return 1
    printf '%s%s' "$source_url" "$official_path"
}

format_latency() {
    local seconds="$1"

    awk -v seconds="$seconds" 'BEGIN { printf "%d ms", (seconds * 1000) + 0.5 }'
}

probe_download_source() {
    local source="$1"
    local probe_url latency started finished probe_status=0
    local -a probe_command

    probe_url="$(distribution_manifest_url_for_source "$source")" || return 1
    # 仅探测第一个字节；Mesa 资产远大于 install-anland-kde.sh 测速使用的清单。
    if command -v curl >/dev/null 2>&1; then
        if latency="$(curl -fsSL --range 0-0 \
            --connect-timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" \
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
        probe_command=(wget -q --header='Range: bytes=0-0' --tries=1 \
            --timeout="$SOURCE_PROBE_TIMEOUT_SECONDS" -O /dev/null "$probe_url")
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
        die "未找到 curl 或 wget，无法测试下载源。" \
            "Neither curl nor wget was found; download sources cannot be tested."
    fi

    if (( probe_status == 28 || probe_status == 124 )); then
        printf '%s' "$(msg '超时' 'timeout')"
    else
        printf '%s' "$(msg '不可用' 'unavailable')"
    fi
}

select_download_source() {
    local source latency choice

    if [[ "$SKIP_SOURCE_PROBE" == true ]]; then
        log "已按参数选择 $(download_source_name "$DOWNLOAD_SOURCE")，跳过延迟测试。" \
            "Selected $(download_source_name "$DOWNLOAD_SOURCE") from the command line; skipping latency checks."
        return
    fi

    log "正在测试下载源延迟（达到 ${SOURCE_PROBE_TIMEOUT_SECONDS} 秒视为超时）..." \
        "Testing download-source latency (timeouts at ${SOURCE_PROBE_TIMEOUT_SECONDS} seconds)..."
    for source in 1 2 3; do
        latency="$(probe_download_source "$source")"
        printf '%s. %s %s: %s\n' "$source" "$(download_source_name "$source")" \
            "$(msg '延迟' 'latency')" "$latency"
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

resolve_expected_archive_sha256() {
    command -v sha256sum >/dev/null 2>&1 || die \
        "需要 sha256sum 来校验下载文件。" \
        "sha256sum is required to verify the downloaded file."
    [[ "$EXPECTED_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die \
        "Mesa 分发清单没有有效的 ${ARCHIVE_NAME} SHA-256 校验值。" \
        "The Mesa distribution manifest has no valid SHA-256 digest for ${ARCHIVE_NAME}."
}

validate_release_asset_checksum() {
    local asset_file="$1"
    local actual_checksum

    if ! actual_checksum="$(sha256sum "$asset_file" | awk '{print $1}')" || \
        ! [[ "$actual_checksum" =~ ^[0-9a-f]{64}$ ]] || \
        [[ "$actual_checksum" != "$EXPECTED_ARCHIVE_SHA256" ]]; then
        return 1
    fi
}

release_digest_sha256() {
    local digest="$1"

    [[ "$digest" =~ ^sha256:([0-9A-Fa-f]{64})$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1],,}"
}

# 媒体解码驱动的资产名、SHA-256 与大小同样来自分发清单，
# 因此这里不再查询 api.github.com。
resolve_media_decode_release() {
    release_digest_sha256 "$MEDIA_DRIVER_RELEASE_DIGEST" >/dev/null || die \
        "媒体解码驱动 Release 返回了无效的驱动 SHA-256 摘要。" \
        "The media decode driver Release returned an invalid driver SHA-256 digest."
    release_digest_sha256 "$MEDIA_CHECKSUMS_RELEASE_DIGEST" >/dev/null || die \
        "媒体解码驱动 Release 返回了无效的校验文件 SHA-256 摘要。" \
        "The media decode driver Release returned an invalid checksum-file SHA-256 digest."
    (( MEDIA_DRIVER_RELEASE_SIZE <= MAX_MEDIA_DRIVER_BYTES )) || die \
        "媒体解码驱动超过允许的大小。" \
        "The media decode driver exceeds the allowed size."
    (( MEDIA_CHECKSUMS_RELEASE_SIZE <= MAX_CHECKSUMS_BYTES )) || die \
        "媒体解码驱动校验文件超过允许的大小。" \
        "The media decode checksum file exceeds the allowed size."

    log "已选择媒体解码驱动: ${MEDIA_DRIVER_NAME} (${MEDIA_RELEASE_TAG})" \
        "Selected media decode driver: ${MEDIA_DRIVER_NAME} (${MEDIA_RELEASE_TAG})"
}

validate_sha256_file() {
    local file="$1"
    local expected_checksum="$2"
    local actual_checksum

    actual_checksum="$(sha256sum "$file" | awk '{print $1}')" || return 1
    [[ "$actual_checksum" =~ ^[0-9a-f]{64}$ && "$actual_checksum" == "$expected_checksum" ]]
}

validate_aarch64_shared_object() {
    local file="$1"
    local elf_identity elf_type_and_machine

    elf_identity="$(od -An -tx1 -N6 "$file" | tr -d '[:space:]')" || return 1
    elf_type_and_machine="$(od -An -tx1 -j16 -N4 "$file" | tr -d '[:space:]')" || return 1
    [[ "$elf_identity" == "7f454c460201" && "$elf_type_and_machine" == "0300b700" ]]
}

download_media_decode_driver() {
    local driver_url checksums_url checksums_digest release_driver_digest checksums_size
    local manifest_driver_digest driver_size

    MEDIA_DRIVER_FILE="$WORK_DIR/$MEDIA_DRIVER_NAME"
    MEDIA_CHECKSUMS_FILE="$WORK_DIR/$MEDIA_CHECKSUMS_NAME"
    driver_url="$(download_url_for_release_asset \
        "$DOWNLOAD_SOURCE" "$RELEASE_REPOSITORY" "$MEDIA_DRIVER_DOWNLOAD_URL")" || die \
        "无法构造媒体解码驱动的下载地址。" \
        "Could not build the media decode driver download URL."
    checksums_url="$(download_url_for_release_asset \
        "$DOWNLOAD_SOURCE" "$RELEASE_REPOSITORY" "$MEDIA_CHECKSUMS_DOWNLOAD_URL")" || die \
        "无法构造媒体解码驱动校验文件的下载地址。" \
        "Could not build the media decode driver checksum download URL."

    log "正在从 $(download_source_name "$DOWNLOAD_SOURCE") 下载媒体解码驱动 ${MEDIA_RELEASE_TAG}..." \
        "Downloading media decode driver ${MEDIA_RELEASE_TAG} from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$checksums_url" "$MEDIA_CHECKSUMS_FILE" || die \
        "媒体解码驱动校验文件下载失败。" \
        "The media decode driver checksum file download failed."
    checksums_size="$(stat -c '%s' "$MEDIA_CHECKSUMS_FILE")" || die \
        "无法读取媒体解码驱动校验文件大小。" \
        "Unable to read the media decode checksum-file size."
    [[ "$checksums_size" =~ ^[0-9]+$ && "$checksums_size" -eq "$MEDIA_CHECKSUMS_RELEASE_SIZE" ]] || die \
        "下载的 ${MEDIA_CHECKSUMS_NAME} 大小与 Release 不一致。" \
        "Downloaded ${MEDIA_CHECKSUMS_NAME} size does not match the Release."
    checksums_digest="$(release_digest_sha256 "$MEDIA_CHECKSUMS_RELEASE_DIGEST")" || die \
        "媒体解码驱动 Release 返回了无效的校验文件 SHA-256 摘要。" \
        "The media decode driver Release returned an invalid checksum-file SHA-256 digest."
    validate_sha256_file "$MEDIA_CHECKSUMS_FILE" "$checksums_digest" || die \
        "下载的 ${MEDIA_CHECKSUMS_NAME} 未通过 Release SHA-256 校验。" \
        "Downloaded ${MEDIA_CHECKSUMS_NAME} failed Release SHA-256 verification."

    manifest_driver_digest="$(awk -v name="$MEDIA_DRIVER_NAME" '
        $1 ~ /^[0-9A-Fa-f]{64}$/ && $2 == name { print tolower($1) }
    ' "$MEDIA_CHECKSUMS_FILE")"
    [[ "$manifest_driver_digest" =~ ^[0-9a-f]{64}$ ]] || die \
        "${MEDIA_CHECKSUMS_NAME} 中缺少唯一有效的 ${MEDIA_DRIVER_NAME} 摘要。" \
        "${MEDIA_CHECKSUMS_NAME} does not contain one valid digest for ${MEDIA_DRIVER_NAME}."
    [[ "$(awk -v name="$MEDIA_DRIVER_NAME" '$2 == name { count++ } END { print count + 0 }' \
        "$MEDIA_CHECKSUMS_FILE")" == "1" ]] || die \
        "${MEDIA_CHECKSUMS_NAME} 中的 ${MEDIA_DRIVER_NAME} 摘要不唯一。" \
        "${MEDIA_CHECKSUMS_NAME} contains multiple digests for ${MEDIA_DRIVER_NAME}."
    release_driver_digest="$(release_digest_sha256 "$MEDIA_DRIVER_RELEASE_DIGEST")" || die \
        "媒体解码驱动 Release 返回了无效的驱动 SHA-256 摘要。" \
        "The media decode driver Release returned an invalid driver SHA-256 digest."
    [[ "$manifest_driver_digest" == "$release_driver_digest" ]] || die \
        "${MEDIA_CHECKSUMS_NAME} 与 Release 中的驱动摘要不一致。" \
        "The driver digests in ${MEDIA_CHECKSUMS_NAME} and the Release do not match."

    download_file "$driver_url" "$MEDIA_DRIVER_FILE" || die \
        "媒体解码驱动下载失败。" "The media decode driver download failed."
    [[ -f "$MEDIA_DRIVER_FILE" ]] || die \
        "下载的媒体解码驱动不存在。" "The downloaded media decode driver does not exist."
    driver_size="$(stat -c '%s' "$MEDIA_DRIVER_FILE")" || die \
        "无法读取媒体解码驱动大小。" "Unable to read the media decode driver size."
    [[ "$driver_size" =~ ^[0-9]+$ && "$driver_size" -eq "$MEDIA_DRIVER_RELEASE_SIZE" ]] || die \
        "下载的媒体解码驱动大小与 Release 不一致。" \
        "The downloaded media decode driver size does not match the Release."
    validate_sha256_file "$MEDIA_DRIVER_FILE" "$manifest_driver_digest" || die \
        "下载的 ${MEDIA_DRIVER_NAME} 未通过 SHA-256 校验。" \
        "Downloaded ${MEDIA_DRIVER_NAME} failed SHA-256 verification."
    validate_aarch64_shared_object "$MEDIA_DRIVER_FILE" || die \
        "下载的 ${MEDIA_DRIVER_NAME} 不是 AArch64 ELF 共享对象。" \
        "Downloaded ${MEDIA_DRIVER_NAME} is not an AArch64 ELF shared object."
}

validate_archive_size() {
    local archive_size="$1"

    [[ -f "$archive_size" ]] || die \
        "下载文件不存在。" "The downloaded file does not exist."
    local size
    size="$(stat -c '%s' "$archive_size")" || die \
        "无法读取下载文件大小。" "Unable to read the downloaded file size."
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || die \
        "下载文件为空。" "The downloaded file is empty."
    (( size <= MAX_ARCHIVE_BYTES )) || die \
        "下载包超过允许的大小。" "The downloaded archive exceeds the allowed size."
    if [[ -n "$EXPECTED_ARCHIVE_SIZE" && "$size" -ne "$EXPECTED_ARCHIVE_SIZE" ]]; then
        die "下载的 ${ARCHIVE_NAME} 大小与 Mesa 分发清单不一致。" \
            "Downloaded ${ARCHIVE_NAME} size does not match the Mesa distribution manifest."
    fi
}

validate_archive_paths() {
    local archive_file="$1"
    local entry
    local total_size=0
    local entry_size
    local listing_file="$WORK_DIR/archive.list"
    local verbose_listing_file="$WORK_DIR/archive.verbose"
    local entry_sizes_file="$WORK_DIR/archive.sizes"

    if [[ "$ARCHIVE_KIND" == "tar.gz" ]]; then
        if ! tar -tzf "$archive_file" > "$listing_file"; then
            die "无法读取下载包内容。" "Unable to read the downloaded archive contents."
        fi
        [[ -s "$listing_file" ]] || die \
            "下载包中没有文件。" "The downloaded archive contains no files."
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            case "$entry" in
                /*|.|..|../*|*/../*|*/..)
                    die "下载包包含不安全路径：${entry}" \
                        "The downloaded archive contains an unsafe path: ${entry}"
                    ;;
            esac
        done < "$listing_file"

        if ! LC_ALL=C tar -tvzf "$archive_file" > "$verbose_listing_file"; then
            die "无法读取下载包条目大小。" "Unable to read the downloaded archive entry sizes."
        fi
        awk '$3 ~ /^[0-9]+$/ { print $3 }' \
            "$verbose_listing_file" > "$entry_sizes_file"
        [[ -s "$entry_sizes_file" ]] || die \
            "下载包中没有可校验的条目。" "The downloaded archive has no verifiable entries."
        while IFS= read -r entry_size; do
            [[ "$entry_size" =~ ^[0-9]+$ ]] || die \
                "无法读取下载包条目大小。" "Unable to read an archive entry size."
            total_size=$((total_size + entry_size))
            (( total_size <= MAX_EXTRACTED_BYTES )) || die \
                "下载包解压后超过允许的大小。" \
                "The downloaded archive exceeds the allowed extracted size."
        done < "$entry_sizes_file"
    else
        if ! tar -tf "$archive_file" > "$listing_file"; then
            die "无法读取 Arch 下载包内容。" "Unable to read the Arch archive contents."
        fi
        [[ -s "$listing_file" ]] || die \
            "Arch 下载包中没有文件。" "The Arch archive contains no files."
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            entry="${entry#./}"
            case "$entry" in
                /*|.|..|../*|*/../*|*/..)
                    die "Arch 下载包包含不安全路径：${entry}" \
                        "The Arch archive contains an unsafe path: ${entry}"
                    ;;
                ""|*/)
                    ;;
                *.pkg.tar.*|*.sig)
                    [[ "$entry" != */* ]] || die \
                        "Arch 下载包包含不安全路径：${entry}" \
                        "The Arch archive contains an unsafe path: ${entry}"
                    ;;
                *)
                    die "Arch 下载包包含未知文件：${entry}" \
                        "The Arch archive contains an unexpected file: ${entry}"
                    ;;
            esac
        done < "$listing_file"

        if ! LC_ALL=C tar -tvf "$archive_file" > "$verbose_listing_file"; then
            die "无法读取 Arch 下载包条目大小。" \
                "Unable to read the Arch archive entry sizes."
        fi
        awk '$3 ~ /^[0-9]+$/ { print $3 }' \
            "$verbose_listing_file" > "$entry_sizes_file"
        [[ -s "$entry_sizes_file" ]] || die \
            "Arch 下载包中没有可校验的条目。" \
            "The Arch archive has no verifiable entries."
        while IFS= read -r entry_size; do
            [[ "$entry_size" =~ ^[0-9]+$ ]] || die \
                "无法读取 Arch 下载包条目大小。" "Unable to read an Arch archive entry size."
            total_size=$((total_size + entry_size))
            (( total_size <= MAX_EXTRACTED_BYTES )) || die \
                "Arch 下载包解压后超过允许的大小。" \
                "The Arch archive exceeds the allowed extracted size."
        done < "$entry_sizes_file"
    fi
}

configure_apt_holds() {
    local preferences_file="$APT_HOLD_PREFERENCES"

    install -d -m 0755 "$(dirname "$preferences_file")"
    cat > "$preferences_file" <<'EOF'
# /etc/apt/preferences.d/hold-anland-package

Package: libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-vulkan-drivers
Pin: release *
Pin-Priority: -1
EOF
    [[ -s "$preferences_file" ]] || die \
        "无法写入 APT 版本锁定配置。" "Unable to write the APT version hold configuration."
    log "已写入 APT 软件包锁定: ${preferences_file}" \
        "Wrote the APT package hold configuration: ${preferences_file}"
}

rewrite_without_managed_block() {
    local input_file="$1"
    local output_file="$2"
    local begin_marker="$3"
    local end_marker="$4"

    awk -v begin="$begin_marker" -v end="$end_marker" '
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
    ' "$input_file" > "$output_file"
}

write_dnf_config_with_managed_block() {
    local input_file="$1"
    local output_file="$2"
    local stripped_file="$WORK_DIR/dnf.conf.stripped"
    local excluded_packages="mesa*"

    if [[ -e "$SYSTEMD257_STATE" ]]; then
        excluded_packages+=",systemd*"
    fi

    rewrite_without_managed_block \
        "$input_file" "$stripped_file" "$DNF_MANAGED_BEGIN" "$DNF_MANAGED_END" || return 1

    # DNF 会把兼容 yum 的 exclude 别名与 excludepkgs 绑定到同一个追加列表。
    # 使用不同键可以避免 INI 解析器替换重复键，同时兼容 Anland 的
    # excludepkgs 规则。
    awk -v begin="$DNF_MANAGED_BEGIN" -v end="$DNF_MANAGED_END" \
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
            print "exclude=" excludes
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
            if (in_main && $0 ~ /^[[:space:]]*exclude[[:space:]]*=/) {
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
    ' "$stripped_file" > "$output_file"
}

configure_dnf_holds() {
    local temporary_config="$WORK_DIR/dnf.conf.locked"

    install -d -m 0755 "$(dirname "$DNF_CONFIG")"
    if [[ ! -e "$DNF_CONFIG" ]]; then
        install -m 0644 /dev/null "$DNF_CONFIG"
    fi
    [[ -f "$DNF_CONFIG" ]] || die \
        "DNF 配置不是普通文件：${DNF_CONFIG}。" \
        "The DNF configuration is not a regular file: ${DNF_CONFIG}."

    if ! write_dnf_config_with_managed_block "$DNF_CONFIG" "$temporary_config"; then
        die "DNF 锁定配置中的托管标记无效。" \
            "The managed markers in the DNF hold configuration are invalid."
    fi
    install -m 0644 "$temporary_config" "$DNF_CONFIG" || die \
        "无法写入 DNF 软件包锁定配置。" "Unable to write the DNF package hold configuration."
    log "已写入 DNF 软件包锁定: ${DNF_CONFIG}" \
        "Wrote the DNF package hold configuration: ${DNF_CONFIG}"
}

write_pacman_config_with_managed_block() {
    local input_file="$1"
    local output_file="$2"
    local packages_line="$3"
    local stripped_file="$WORK_DIR/pacman.conf.stripped"

    rewrite_without_managed_block \
        "$input_file" "$stripped_file" "$PACMAN_MANAGED_BEGIN" "$PACMAN_MANAGED_END" || return 1

    awk -v begin="$PACMAN_MANAGED_BEGIN" -v end="$PACMAN_MANAGED_END" \
        -v packages="$packages_line" '
        function write_block() {
            print begin
            print "IgnorePkg = " packages
            print end
        }
        /^\[options\][[:space:]]*$/ {
            in_options = 1
            saw_options = 1
            print
            next
        }
        /^\[[^]]+\][[:space:]]*$/ {
            if (in_options && !wrote_block) {
                write_block()
                wrote_block = 1
            }
            in_options = 0
            print
            next
        }
        { print }
        END {
            if (in_options && !wrote_block) {
                write_block()
            }
            if (!saw_options) {
                exit 2
            }
        }
    ' "$stripped_file" > "$output_file"
}

configure_pacman_holds() {
    local package packages_line
    local temporary_config="$WORK_DIR/pacman.conf.locked"
    local sorted_packages_file="$WORK_DIR/pacman-holds.list"
    local -a packages=("$@")
    local -a unique_packages=()

    if [[ -e "$SYSTEMD257_STATE" ]]; then
        packages+=(systemd systemd-libs systemd-sysvcompat)
    fi
    if ! printf '%s\n' "${packages[@]}" | sort -u > "$sorted_packages_file"; then
        die "无法整理 Arch 软件包锁定列表。" "Unable to prepare the Arch package hold list."
    fi
    mapfile -t unique_packages < "$sorted_packages_file"
    ((${#unique_packages[@]} > 0)) || die \
        "没有可锁定的 Arch 软件包。" "There are no Arch packages to hold."
    for package in "${unique_packages[@]}"; do
        [[ "$package" =~ ^[[:alnum:]@._+*-]+$ ]] || die \
            "Arch 软件包名无效：${package}。" "Invalid Arch package name: ${package}."
    done
    printf -v packages_line '%s ' "${unique_packages[@]}"
    packages_line="${packages_line% }"

    if ! write_pacman_config_with_managed_block \
        "$PACMAN_CONFIG" "$temporary_config" "$packages_line"; then
        die "pacman.conf 缺少 [options] 段，或锁定配置中的托管标记无效。" \
            "pacman.conf has no [options] section, or its managed hold markers are invalid."
    fi
    install -m 0644 "$temporary_config" "$PACMAN_CONFIG" || die \
        "无法写入 Pacman 软件包锁定配置。" \
        "Unable to write the Pacman package hold configuration."
    log "已写入 Pacman 软件包锁定: ${PACMAN_CONFIG}" \
        "Wrote the Pacman package hold configuration: ${PACMAN_CONFIG}"
}

configure_package_holds() {
    case "$PACKAGE_MANAGER" in
        apt)
            configure_apt_holds
            ;;
        dnf)
            configure_dnf_holds
            ;;
        pacman)
            configure_pacman_holds "${MESA_PACKAGE_NAMES[@]}"
            ;;
        *)
            die "内部错误：无法为 ${PACKAGE_MANAGER} 配置软件包锁定。" \
                "Internal error: cannot configure package holds for ${PACKAGE_MANAGER}."
            ;;
    esac
}

install_arch_packages() {
    local pacman_config
    local entry
    local package_listing_file="$WORK_DIR/arch-package-files.list"
    local package_names_file="$WORK_DIR/arch-package-names.list"
    local -a package_files=()

    pacman_config="$WORK_DIR/pacman.conf"
    cp -p "$PACMAN_CONFIG" "$pacman_config"

    # Mesa Release 软件包有意不签名，因此仅在此临时 Pacman 配置中
    # 放宽签名策略。
    if grep -Eq '^[[:space:]]*#?[[:space:]]*SigLevel[[:space:]]*=' "$pacman_config"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*SigLevel[[:space:]]*=.*/SigLevel = Never/' "$pacman_config"
    elif grep -qE '^\[options\][[:space:]]*$' "$pacman_config"; then
        sed -i '/^\[options\][[:space:]]*$/a SigLevel = Never' "$pacman_config"
    else
        die "pacman.conf 缺少 [options] 段。" "pacman.conf has no [options] section."
    fi

    if ! tar -tf "$ARCHIVE_FILE" > "$package_listing_file"; then
        die "无法读取 Arch 下载包内容。" "Unable to read the Arch archive contents."
    fi
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        entry="${entry#./}"
        case "$entry" in
            *.pkg.tar.*)
                package_files+=("$WORK_DIR/$entry")
                ;;
        esac
    done < "$package_listing_file"
    ((${#package_files[@]} > 0)) || die \
        "Arch 下载包中没有可安装的软件包。" "The Arch archive has no installable packages."
    if ! pacman -Qq -p "${package_files[@]}" | sort -u > "$package_names_file"; then
        die "无法读取 Arch Mesa 包名。" "Could not determine the Arch Mesa package names."
    fi
    [[ -s "$package_names_file" ]] || die \
        "无法读取 Arch Mesa 包名。" "Could not determine the Arch Mesa package names."
    mapfile -t MESA_PACKAGE_NAMES < "$package_names_file"
    ((${#MESA_PACKAGE_NAMES[@]} > 0)) || die \
        "无法读取 Arch Mesa 包名。" "Could not determine the Arch Mesa package names."

    log "正在安装 Arch GPU 初始化所需的 LLVM 22..." \
        "Installing LLVM 22 required for Arch GPU initialization..."
    pacman -S --noconfirm --needed llvm22

    log "正在安装 ${#package_files[@]} 个 Arch Mesa 包..." \
        "Installing ${#package_files[@]} Arch Mesa packages..."
    pacman --config "$pacman_config" -U --noconfirm "${package_files[@]}"
}

install_tar_gz() {
    log "正在解压 ${TARGET} Mesa 驱动..." "Extracting the ${TARGET} Mesa driver..."
    tar --extract --gzip --file "$ARCHIVE_FILE" --directory / \
        --no-same-owner --keep-directory-symlink
    ldconfig
}

install_media_decode_driver() {
    install -d -m 0755 "$MEDIA_DRIVER_INSTALL_DIR" || die \
        "无法创建媒体解码驱动目录：${MEDIA_DRIVER_INSTALL_DIR}。" \
        "Unable to create the media decode driver directory: ${MEDIA_DRIVER_INSTALL_DIR}."
    MEDIA_DRIVER_TEMP_FILE="$(mktemp "${MEDIA_DRIVER_INSTALL_PATH}.tmp.XXXXXXXX")" || die \
        "无法在目标目录创建媒体解码驱动临时文件。" \
        "Unable to create a temporary media decode driver in the destination directory."
    if ! install -m 0644 "$MEDIA_DRIVER_FILE" "$MEDIA_DRIVER_TEMP_FILE"; then
        rm -f -- "$MEDIA_DRIVER_TEMP_FILE"
        die "无法写入媒体解码驱动。" "Unable to write the media decode driver."
    fi
    if ! mv -f -- "$MEDIA_DRIVER_TEMP_FILE" "$MEDIA_DRIVER_INSTALL_PATH"; then
        rm -f -- "$MEDIA_DRIVER_TEMP_FILE"
        die "无法安装媒体解码驱动。" "Unable to install the media decode driver."
    fi
    MEDIA_DRIVER_TEMP_FILE=""
    log "已安装媒体解码驱动: ${MEDIA_DRIVER_INSTALL_PATH} (${MEDIA_RELEASE_TAG})" \
        "Installed media decode driver: ${MEDIA_DRIVER_INSTALL_PATH} (${MEDIA_RELEASE_TAG})"
}

install_mesa() {
    log "正在下载并安装最新版 Mesa 和媒体解码驱动..." \
        "Downloading and installing the latest Mesa and media decode drivers..."
    WORK_DIR="$(mktemp -d -t install-mesa.XXXXXXXX)" || die \
        "无法创建临时目录。" "Unable to create a temporary directory."
    chmod 0700 "$WORK_DIR" || die \
        "无法保护临时目录。" "Unable to secure the temporary directory."
    resolve_release_asset
    resolve_media_decode_release
    resolve_expected_archive_sha256
    DOWNLOAD_URL="$(download_url_for_source "$DOWNLOAD_SOURCE")" || die \
        "无法构造所选下载源的地址。" "Could not build the selected download-source URL."
    ARCHIVE_FILE="$WORK_DIR/$ARCHIVE_NAME"

    log "正在从 $(download_source_name "$DOWNLOAD_SOURCE") 下载 ${ARCHIVE_NAME}..." \
        "Downloading ${ARCHIVE_NAME} from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$DOWNLOAD_URL" "$ARCHIVE_FILE" || die \
        "Mesa 驱动下载失败。" "The Mesa driver download failed."
    validate_archive_size "$ARCHIVE_FILE"
    if ! validate_release_asset_checksum "$ARCHIVE_FILE"; then
        die "下载的 ${ARCHIVE_NAME} 未通过 SHA-256 校验。" \
            "Downloaded ${ARCHIVE_NAME} failed SHA-256 verification."
    fi
    validate_archive_paths "$ARCHIVE_FILE"
    download_media_decode_driver

    case "$PACKAGE_MANAGER" in
        pacman)
            tar --extract --file "$ARCHIVE_FILE" --directory "$WORK_DIR" \
                --no-same-owner
            install_arch_packages
            ;;
        apt|dnf)
            install_tar_gz
            ;;
        *)
            die "内部错误：未知的软件包管理器 ${PACKAGE_MANAGER}。" \
                "Internal error: unknown package manager ${PACKAGE_MANAGER}."
            ;;
    esac
    configure_package_holds
    install_media_decode_driver
    record_component_version "$(mesa_archive_version)"
}

main() {
    detect_language
    parse_arguments "$@"
    detect_target
    check_architecture
    require_root "$@"
    if [[ "$UNINSTALL" == true ]]; then
        uninstall_mesa
        return
    fi
    select_download_source
    require_commands
    install_mesa
    log "Mesa 和媒体解码驱动安装完成，相关软件包已锁定。" \
        "Mesa and media decode driver installation completed; related packages are now held."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
