#!/usr/bin/env bash
set -uo pipefail

readonly TUI_VERSION="1.5"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
readonly DESKTOP_CONFIG="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"
readonly HANGOVER_CACHE_DIR="/var/cache/hangover-wine"
readonly HANGOVER_MANIFEST_NAME="hangover-wine-manifest"
readonly COMPONENT_STATE_DIR="${DROIDSPACES_COMPONENT_STATE_DIR:-/var/lib/droidspaces-tui/components}"
readonly COMPONENT_RELEASE_REPOSITORY="${DROIDSPACES_COMPONENT_REPOSITORY:-Goldzxcbug/droidspaces-package}"
readonly COMPONENT_GITHUB_DOWNLOAD_BASE="${DROIDSPACES_COMPONENT_GITHUB_BASE:-https://github.com/$COMPONENT_RELEASE_REPOSITORY/releases/download}"
readonly COMPONENT_PROXY_DOWNLOAD_BASE="${DROIDSPACES_COMPONENT_PROXY_BASE:-https://gh-proxy.com/https://github.com/$COMPONENT_RELEASE_REPOSITORY/releases/download}"
readonly COMPONENT_CNB_DOWNLOAD_BASE="${DROIDSPACES_COMPONENT_CNB_BASE:-https://cnb.cool/goldzxcbug/droidspaces-package/-/releases/download}"
readonly COMPONENT_MANIFEST_MAX_BYTES=$((1024 * 1024))
readonly COMPONENT_VERSION_TIMEOUT=10
readonly INSTALLED_TUI_PATH="/usr/local/bin/droidspaces-tui"
readonly TUI_RELEASE_REPOSITORY="${DROIDSPACES_TUI_REPOSITORY:-Goldzxcbug/droidspaces-package}"
readonly TUI_RELEASE_TAG="Gold-bug-tui"
readonly TUI_BOOTSTRAP_NAME="install-tui.sh"
readonly TUI_MANIFEST_NAME="Gold-bug-tui-manifest"
readonly TUI_GITHUB_API_URL="${DROIDSPACES_TUI_API_URL:-https://api.github.com}"
readonly TUI_GITHUB_DOWNLOAD_BASE="${DROIDSPACES_TUI_GITHUB_BASE:-https://github.com/$TUI_RELEASE_REPOSITORY/releases/download}"
readonly TUI_PROXY_DOWNLOAD_BASE="${DROIDSPACES_TUI_PROXY_BASE:-https://gh-proxy.com/https://github.com/$TUI_RELEASE_REPOSITORY/releases/download}"
readonly TUI_CNB_DOWNLOAD_BASE="${DROIDSPACES_TUI_CNB_BASE:-https://cnb.cool/goldzxcbug/droidspaces-package/-/releases/download}"
readonly LINUXMIRRORS_SCRIPT_URL="https://linuxmirrors.cn/main.sh"

UI_LANG="en"
DOWNLOAD_SOURCE=""
SYSTEM_ID="unknown"
SYSTEM_VERSION=""
SYSTEM_LABEL="Unknown Linux"
ARCHITECTURE="unknown"
CACHE_ACTION=""
UPDATE_WORK_DIR=""
UPDATE_UPDATER_PATH=""
MIRROR_WORK_DIR=""
COMPONENT_VERSION_WORK_DIR=""
COMPONENT_VERSION_DEADLINE=0
COMPONENT_STATUS_CHANGED=false
COMPONENT_REFRESH_REQUIRED=false
SPINNER_INDEX=0
DESKTOP_PROFILE=""
DESKTOP_COMPONENT=""
DESKTOP_COMPONENT_LABEL=""
DESKTOP_COMPONENT_MODE="choose"
MENU_INPUT_BUFFER=""
MENU_CHOICE=""
MENU_ESCAPE_SEQUENCE=""
MENU_TTY_ECHO_DISABLED=false
DYNAMIC_MENU_DRAWN=false

readonly -a COMPONENT_NAMES=(mesa hangover fonts kde gnome niri hyprland mango denial anland-next)
readonly -a SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
declare -A COMPONENT_CURRENT_VERSIONS=()
declare -A COMPONENT_UPSTREAM_VERSIONS=()
declare -A COMPONENT_VERSION_PIDS=()
declare -A COMPONENT_INSTALLED=()

COLOR_RESET=""
COLOR_BOLD=""
COLOR_BLUE=""
COLOR_CYAN=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_DIM=""

detect_language() {
    local locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
    locale_name="${locale_name,,}"
    [[ "$locale_name" == zh* ]] && UI_LANG="zh"
    return 0
}

set_default_download_source() {
    [[ -z "$DOWNLOAD_SOURCE" ]] || return 0
    if [[ "$UI_LANG" == "zh" ]]; then
        DOWNLOAD_SOURCE="3"
    else
        DOWNLOAD_SOURCE="1"
    fi
}

msg() {
    if [[ "$UI_LANG" == "zh" ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

die() {
    printf 'droidspaces-tui: %s\n' "$(msg "$1" "$2")" >&2
    exit 1
}

usage() {
    cat <<EOF
$(msg '用法' 'Usage'): $0 [$(msg '选项' 'options')]

  --source auto|github|proxy|cnb
                       $(msg '设置初始下载源' 'Set the initial download source')
  --clean-cache manifest|all
                       $(msg '清理 Hangover 清单或全部下载缓存' 'Clean the Hangover manifest or all downloads')
  --no-color           $(msg '关闭彩色输出' 'Disable colored output')
  -h, --help           $(msg '显示此帮助' 'Show this help')
EOF
}

set_download_source_name() {
    case "${1,,}" in
        auto) DOWNLOAD_SOURCE="auto" ;;
        github|1) DOWNLOAD_SOURCE="1" ;;
        proxy|gh-proxy|2) DOWNLOAD_SOURCE="2" ;;
        cnb|3) DOWNLOAD_SOURCE="3" ;;
        *)
            die "不支持的下载源：$1" "Unsupported download source: $1"
            ;;
    esac
}

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --source)
                (($# >= 2)) || die "--source 缺少参数。" "--source requires a value."
                set_download_source_name "$2"
                shift 2
                ;;
            --source=*)
                set_download_source_name "${1#*=}"
                shift
                ;;
            --clean-cache)
                (($# >= 2)) || die "--clean-cache 缺少参数。" "--clean-cache requires a value."
                CACHE_ACTION="$2"
                shift 2
                ;;
            --clean-cache=*)
                CACHE_ACTION="${1#*=}"
                shift
                ;;
            --no-color)
                NO_COLOR=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "不支持的参数：$1" "Unsupported option: $1"
                ;;
        esac
    done
}

validate_cache_action() {
    case "$CACHE_ACTION" in
        ""|manifest|all) ;;
        *)
            die "不支持的缓存清理范围：$CACHE_ACTION" \
                "Unsupported cache-cleaning scope: $CACHE_ACTION"
            ;;
    esac
}

init_colors() {
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
        COLOR_RESET=$'\033[0m'
        COLOR_BOLD=$'\033[1m'
        COLOR_BLUE=$'\033[34m'
        COLOR_CYAN=$'\033[36m'
        COLOR_GREEN=$'\033[32m'
        COLOR_YELLOW=$'\033[33m'
        COLOR_RED=$'\033[31m'
        COLOR_DIM=$'\033[2m'
    fi
}

detect_system() {
    if [[ -r /etc/os-release ]]; then
        local ID="" VERSION_ID="" PRETTY_NAME=""
        # shellcheck disable=SC1091
        source /etc/os-release
        SYSTEM_ID="${ID,,}"
        SYSTEM_VERSION="$VERSION_ID"
        SYSTEM_LABEL="${PRETTY_NAME:-${ID:-Unknown Linux}${VERSION_ID:+ $VERSION_ID}}"
    fi
    ARCHITECTURE="$(uname -m 2>/dev/null || printf 'unknown')"
}

set_desktop_component() {
    DESKTOP_PROFILE="$1"
    DESKTOP_COMPONENT=""
    DESKTOP_COMPONENT_LABEL=""
    DESKTOP_COMPONENT_MODE="choose"
    case "$DESKTOP_PROFILE" in
        kde|kde-mobile)
            DESKTOP_COMPONENT="kde"
            DESKTOP_COMPONENT_LABEL="Anland KDE (KWin/Xwayland)"
            DESKTOP_COMPONENT_MODE="direct"
            ;;
        niri)
            DESKTOP_COMPONENT="niri"
            DESKTOP_COMPONENT_LABEL="Anland Niri (Niri/Xwayland)"
            DESKTOP_COMPONENT_MODE="direct"
            ;;
        hyprland|mango|denial)
            DESKTOP_COMPONENT="$DESKTOP_PROFILE"
            DESKTOP_COMPONENT_LABEL="Anland ${DESKTOP_PROFILE^}"
            DESKTOP_COMPONENT_MODE="direct"
            ;;
        gnome)
            DESKTOP_COMPONENT="gnome"
            DESKTOP_COMPONENT_LABEL="Anland GNOME (Mutter/Xwayland)"
            DESKTOP_COMPONENT_MODE="direct"
            ;;
        anland-next)
            DESKTOP_COMPONENT="anland-next"
            DESKTOP_COMPONENT_LABEL="Anland Next session"
            DESKTOP_COMPONENT_MODE="direct"
            ;;
    esac
}

detect_desktop_component() {
    local line desktop="" desktop_lines=0

    set_desktop_component none

    if [[ -e "$DESKTOP_CONFIG" || -L "$DESKTOP_CONFIG" ]]; then
        if [[ -f "$DESKTOP_CONFIG" && ! -L "$DESKTOP_CONFIG" && -r "$DESKTOP_CONFIG" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                case "$line" in
                    DESKTOP=*)
                        desktop="${line#DESKTOP=}"
                        ((desktop_lines += 1))
                        ;;
                esac
            done < "$DESKTOP_CONFIG"
            if ((desktop_lines == 1)) && \
                [[ "$desktop" =~ ^(none|[a-z][a-z0-9-]*)$ ]]; then
                set_desktop_component "$desktop"
            fi
        fi
        return
    fi

    # Compatibility for RootFS images built before the desktop config existed.
    if managed_component_installed kde; then
        set_desktop_component kde
    elif managed_component_installed niri; then
        set_desktop_component niri
    elif managed_component_installed gnome; then
        set_desktop_component gnome
    elif managed_component_installed hyprland; then
        set_desktop_component hyprland
    elif managed_component_installed mango; then
        set_desktop_component mango
    elif managed_component_installed denial; then
        set_desktop_component denial
    elif managed_component_installed anland-next; then
        set_desktop_component anland-next
    else
        set_desktop_component none
    fi
}

clear_screen() {
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
        printf '\033[2J\033[H'
    else
        printf '\n'
    fi
}

begin_dynamic_menu() {
    MENU_INPUT_BUFFER=""
    MENU_CHOICE=""
    MENU_ESCAPE_SEQUENCE=""
    DYNAMIC_MENU_DRAWN=false
}

dynamic_ui_supported() {
    [[ -t 0 && -t 1 && "${TERM:-dumb}" != "dumb" ]]
}

disable_dynamic_menu_echo() {
    [[ "$MENU_TTY_ECHO_DISABLED" == false ]] || return 0
    command -v stty >/dev/null 2>&1 || return 0
    if stty -echo 2>/dev/null; then
        MENU_TTY_ECHO_DISABLED=true
    fi
}

restore_dynamic_menu_echo() {
    [[ "$MENU_TTY_ECHO_DISABLED" == true ]] || return 0
    stty echo 2>/dev/null || true
    MENU_TTY_ECHO_DISABLED=false
}

draw_dynamic_menu_frame() {
    if dynamic_ui_supported; then
        if [[ "$DYNAMIC_MENU_DRAWN" == true ]]; then
            printf '\033[H'
        else
            printf '\033[2J\033[H'
            DYNAMIC_MENU_DRAWN=true
        fi
    else
        printf '\n'
    fi
}

draw_dynamic_menu_prompt() {
    if dynamic_ui_supported; then
        printf '\r\033[2K'
    fi
    printf '%s: %s' "$(msg '请选择' 'Select')" "$MENU_INPUT_BUFFER"
    if component_versions_pending && dynamic_ui_supported; then
        printf '  %b%s%b' "$COLOR_CYAN" \
            "${SPINNER_FRAMES[$((SPINNER_INDEX % ${#SPINNER_FRAMES[@]}))]}" \
            "$COLOR_RESET"
    fi
    if dynamic_ui_supported; then
        printf '\033[J'
    fi
}

read_dynamic_menu_choice() {
    local key="" line="" read_status=0
    MENU_CHOICE=""

    if ! dynamic_ui_supported; then
        if IFS= read -r line; then
            MENU_CHOICE="$line"
            return 0
        fi
        return 2
    fi

    disable_dynamic_menu_echo
    if component_versions_pending; then
        IFS= read -r -s -n 1 -t 0.12 key
        read_status=$?
        if ((read_status != 0)); then
            if ((read_status > 128)); then
                SPINNER_INDEX=$((SPINNER_INDEX + 1))
                return 1
            fi
            restore_dynamic_menu_echo
            return 2
        fi
    elif ! IFS= read -r -s -n 1 key; then
        restore_dynamic_menu_echo
        return 2
    fi

    case "$MENU_ESCAPE_SEQUENCE" in
        start)
            case "$key" in
                '[') MENU_ESCAPE_SEQUENCE="csi" ;;
                O) MENU_ESCAPE_SEQUENCE="ss3" ;;
                *) MENU_ESCAPE_SEQUENCE="" ;;
            esac
            return 1
            ;;
        csi)
            case "$key" in
                [@-~]) MENU_ESCAPE_SEQUENCE="" ;;
            esac
            return 1
            ;;
        ss3)
            MENU_ESCAPE_SEQUENCE=""
            return 1
            ;;
    esac

    case "$key" in
        "")
            MENU_CHOICE="$MENU_INPUT_BUFFER"
            MENU_INPUT_BUFFER=""
            return 0
            ;;
        $'\177'|$'\b')
            if [[ -n "$MENU_INPUT_BUFFER" ]]; then
                MENU_INPUT_BUFFER="${MENU_INPUT_BUFFER%?}"
            fi
            ;;
        $'\025')
            MENU_INPUT_BUFFER=""
            ;;
        $'\004') restore_dynamic_menu_echo; return 2 ;;
        $'\e') MENU_ESCAPE_SEQUENCE="start" ;;
        *)
            if [[ "$key" != [[:cntrl:]] ]] && ((${#MENU_INPUT_BUFFER} < 64)); then
                MENU_INPUT_BUFFER+="$key"
            fi
            ;;
    esac
    return 1
}

source_label() {
    case "$DOWNLOAD_SOURCE" in
        auto) msg "自动测速后选择" "Probe and choose" ;;
        1) printf 'GitHub' ;;
        2) printf 'gh-proxy.com' ;;
        3) printf 'CNB' ;;
    esac
}

hangover_cache_size() {
    local output

    if [[ ! -e "$HANGOVER_CACHE_DIR" && ! -L "$HANGOVER_CACHE_DIR" ]]; then
        printf '0 B'
    elif [[ -L "$HANGOVER_CACHE_DIR" || ! -d "$HANGOVER_CACHE_DIR" ]]; then
        msg "路径异常" "invalid path"
    elif output="$(du -sh -- "$HANGOVER_CACHE_DIR" 2>/dev/null)"; then
        printf '%s' "${output%%[[:space:]]*}"
    elif command -v sudo >/dev/null 2>&1 && \
        output="$(sudo -n du -sh -- "$HANGOVER_CACHE_DIR" 2>/dev/null)"; then
        printf '%s' "${output%%[[:space:]]*}"
    else
        msg "需要 root 权限" "root access required"
    fi
}

clean_cache_as_root() {
    local action="$1"

    if ((EUID != 0)); then
        command -v sudo >/dev/null 2>&1 || die \
            "清理缓存需要 root 权限，且系统未安装 sudo。" \
            "Cache cleaning requires root access, and sudo is unavailable."
        exec sudo --preserve-env=LANG,LC_ALL,LC_MESSAGES -- \
            "$SCRIPT_PATH" --no-color --clean-cache "$action"
    fi

    if [[ ! -e "$HANGOVER_CACHE_DIR" && ! -L "$HANGOVER_CACHE_DIR" ]]; then
        return
    fi
    [[ ! -L "$HANGOVER_CACHE_DIR" && -d "$HANGOVER_CACHE_DIR" ]] || die \
        "拒绝清理异常缓存路径：$HANGOVER_CACHE_DIR" \
        "Refusing to clean an invalid cache path: $HANGOVER_CACHE_DIR"

    case "$action" in
        manifest)
            if [[ -d "$HANGOVER_CACHE_DIR/$HANGOVER_MANIFEST_NAME" ]]; then
                die "缓存清单路径异常，拒绝删除。" \
                    "The cached manifest path is invalid; refusing to delete it."
            fi
            rm -f -- "$HANGOVER_CACHE_DIR/$HANGOVER_MANIFEST_NAME"
            ;;
        all)
            command -v find >/dev/null 2>&1 || die \
                "缺少命令：find。" "Required command is missing: find."
            find "$HANGOVER_CACHE_DIR" -mindepth 1 -delete
            ;;
    esac
}

cleanup_mirror_files() {
    if [[ -n "$MIRROR_WORK_DIR" && -d "$MIRROR_WORK_DIR" ]]; then
        rm -rf -- "$MIRROR_WORK_DIR"
    fi
    MIRROR_WORK_DIR=""
}

draw_header() {
    printf '%b%s%b\n' "$COLOR_BLUE" "====================================================" "$COLOR_RESET"
    printf '  %b%s%b  %b%s%b\n' \
        "$COLOR_BOLD$COLOR_CYAN" "Droidspaces Toolkit" "$COLOR_RESET" \
        "$COLOR_DIM" "v$TUI_VERSION" "$COLOR_RESET"
    printf '%b%s%b\n' "$COLOR_BLUE" "----------------------------------------------------" "$COLOR_RESET"
    printf '  %s: %s (%s)\n' "$(msg '系统' 'System')" "$SYSTEM_LABEL" "$ARCHITECTURE"
    printf '  %s: %s\n' "$(msg '下载源' 'Source')" "$(source_label)"
    printf '%b%s%b\n' "$COLOR_BLUE" "====================================================" "$COLOR_RESET"
}

installer_names() {
    case "$1" in
        mesa) printf '%s\n%s\n' "install-mesa.sh" "install-mesa" ;;
        hangover) printf '%s\n%s\n' "install-hangover-wine.sh" "install-hangover-wine" ;;
        fonts) printf '%s\n%s\n' "install-winefonts.sh" "install-winefonts" ;;
        kde) printf '%s\n%s\n' "install-anland-kde.sh" "install-anland-kde" ;;
        gnome) printf '%s\n%s\n' "install-anland-gnome.sh" "install-anland-gnome" ;;
        niri) printf '%s\n%s\n' "install-anland-niri.sh" "install-anland-niri" ;;
        hyprland|mango|denial) printf '%s\n%s\n' "install-anland-$1.sh" "install-anland-$1" ;;
        anland-next) printf '%s\n%s\n' "install-anland-next.sh" "install-anland-next" ;;
        *) return 1 ;;
    esac
}

resolve_installer() {
    local names source_name installed_name candidate
    names="$(installer_names "$1")" || return 1
    source_name="${names%%$'\n'*}"
    installed_name="${names#*$'\n'}"

    if [[ -n "${DROIDSPACES_INSTALLER_DIR:-}" ]]; then
        candidate="${DROIDSPACES_INSTALLER_DIR%/}/$source_name"
        [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    fi

    candidate="$SCRIPT_DIR/$source_name"
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }

    candidate="/usr/local/sbin/$installed_name"
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }

    command -v "$installed_name" 2>/dev/null || return 1
}

is_arm64() {
    case "$ARCHITECTURE" in
        aarch64|arm64) return 0 ;;
        *) return 1 ;;
    esac
}

supports_common_packages() {
    case "$SYSTEM_ID:$SYSTEM_VERSION" in
        arch:*|archarm:*|archlinux:*|debian:13*|ubuntu:24.04*|ubuntu:25.10*|ubuntu:26.04*|fedora:43*|fedora:44*)
            return 0
            ;;
        *) return 1 ;;
    esac
}

component_supported() {
    local component="$1"
    [[ "$component" == "fonts" ]] && return 0
    is_arm64 || return 1

    case "$component" in
        mesa|hangover)
            if [[ "$component" == "mesa" ]]; then
                supports_common_packages
            else
                case "$SYSTEM_ID:$SYSTEM_VERSION" in
                    arch:*|archarm:*|debian:13*|ubuntu:24.04*|ubuntu:25.10*|ubuntu:26.04*|fedora:43*|fedora:44*) return 0 ;;
                    *) return 1 ;;
                esac
            fi
            ;;
        kde)
            case "$SYSTEM_ID:$SYSTEM_VERSION" in
                arch:*|archarm:*|debian:13*|ubuntu:26.04*|fedora:43*|fedora:44*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        niri|gnome|hyprland|mango|denial)
            case "$SYSTEM_ID:$SYSTEM_VERSION" in
                debian:13*|ubuntu:26.04*|fedora:43*|fedora:44*|arch:*|archarm:*|archlinux:*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        anland-next)
            case "$SYSTEM_ID:$SYSTEM_VERSION" in
                arch:*|archarm:*|archlinux:*|debian:13*|ubuntu:26.04*|fedora:43*|fedora:44*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

valid_component_version() {
    [[ "$1" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]]
}

stored_component_version() {
    local component="$1" version_file="$COMPONENT_STATE_DIR/$1.version" version
    [[ -f "$version_file" && ! -L "$version_file" ]] || return 1
    IFS= read -r version < "$version_file" || return 1
    valid_component_version "$version" || return 1
    printf '%s' "$version"
}

installed_package_version() {
    local package output version
    case "$SYSTEM_ID" in
        debian|ubuntu)
            command -v dpkg-query >/dev/null 2>&1 || return 1
            for package in "$@"; do
                output="$(dpkg-query -W -f='${db:Status-Abbrev}\t${Version}\n' \
                    "$package" 2>/dev/null)" || continue
                if [[ "$output" == ?i$' '*$'\t'* ]]; then
                    version="${output#*$'\t'}"
                    version="${version%%$'\n'*}"
                    valid_component_version "$version" || continue
                    printf '%s' "$version"
                    return 0
                fi
            done
            ;;
        fedora)
            command -v rpm >/dev/null 2>&1 || return 1
            for package in "$@"; do
                version="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}\n' \
                    "$package" 2>/dev/null)" || continue
                version="${version%%$'\n'*}"
                valid_component_version "$version" || continue
                printf '%s' "$version"
                return 0
            done
            ;;
        arch|archarm|archlinux)
            command -v pacman >/dev/null 2>&1 || return 1
            for package in "$@"; do
                output="$(pacman -Q "$package" 2>/dev/null)" || continue
                version="${output#* }"
                valid_component_version "$version" || continue
                printf '%s' "$version"
                return 0
            done
            ;;
    esac
    return 1
}

detected_component_package_version() {
    local component="$1" version=""
    case "$component" in
        mesa)
            case "$SYSTEM_ID" in
                debian|ubuntu)
                    version="$(installed_package_version mesa-vulkan-drivers libglx-mesa0 libegl-mesa0)" || true
                    ;;
                fedora) version="$(installed_package_version mesa-dri-drivers)" || true ;;
                arch|archarm|archlinux) version="$(installed_package_version mesa)" || true ;;
            esac
            ;;
        hangover)
            version="$(installed_package_version hangover-wine)" || true
            ;;
        fonts)
            [[ -d /usr/local/share/fonts/winefonts ]] && version="$(msg '未知版本' 'unknown')"
            ;;
        kde)
            version="$(installed_package_version kwin-wayland kwin-x11 kwin-common kwin)" || true
            ;;
        niri)
            version="$(installed_package_version niri-anland)" || true
            ;;
        hyprland)
            version="$(installed_package_version hyprland-anland hyprland)" || true
            ;;
        mango)
            version="$(installed_package_version mango-anland)" || true
            ;;
        denial)
            version="$(installed_package_version denial)" || true
            ;;
        gnome)
            version="$(installed_package_version mutter-common mutter)" || true
            ;;
        anland-next)
            version="$(installed_package_version anland-session)" || true
            ;;
    esac
    if [[ -n "$version" ]]; then
        printf '%s' "$version"
        return 0
    fi
    return 1
}

detect_current_component_version() {
    local component="$1" version="" stored=""
    if stored="$(stored_component_version "$component")"; then
        printf '%s' "$stored"
    elif version="$(detected_component_package_version "$component")"; then
        printf '%s' "$version"
    else
        printf '%s' "$(msg '未知版本' 'unknown')"
    fi
}

managed_component_installed() {
    local component="$1"
    # Version/hold records can outlive packages removed outside the installer.
    detected_component_package_version "$component" >/dev/null 2>&1 || return 1
    stored_component_version "$component" >/dev/null 2>&1 && return 0
    case "$component" in
        mesa)
            case "$SYSTEM_ID" in
                debian|ubuntu) [[ -f /etc/apt/preferences.d/hold-anland-package ]] ;;
                fedora) grep -Fqx '# BEGIN install-mesa package holds' /etc/dnf/dnf.conf 2>/dev/null ;;
                arch|archarm|archlinux)
                    grep -Fqx '# BEGIN install-mesa package holds' /etc/pacman.conf 2>/dev/null
                    ;;
                *) return 1 ;;
            esac
            ;;
        hangover|fonts|niri|mango|denial|anland-next)
            # These components use dedicated package names (or a managed font directory).
            return 0
            ;;
        kde)
            case "$SYSTEM_ID" in
                debian|ubuntu) [[ -s /var/lib/anland-kde/apt-holds ]] ;;
                fedora) grep -Fqx '# BEGIN anland-kde package holds' /etc/dnf/dnf.conf 2>/dev/null ;;
                arch|archarm|archlinux)
                    grep -Eq '^[[:space:]]*IgnorePkg[[:space:]]*=.*(^|[[:space:]])kwin([[:space:]]|$)' \
                        /etc/pacman.conf 2>/dev/null
                    ;;
                *) return 1 ;;
            esac
            ;;
        hyprland)
            installed_package_version hyprland-anland >/dev/null 2>&1 && return 0
            # Debian/Ubuntu replace the distribution's hyprland package.
            case "$SYSTEM_ID" in
                debian|ubuntu) [[ -s /var/lib/anland-hyprland/apt-holds ]] ;;
                *) return 1 ;;
            esac
            ;;
        gnome)
            case "$SYSTEM_ID" in
                debian|ubuntu) [[ -s /var/lib/anland-gnome/apt-holds ]] ;;
                fedora) grep -Fqx '# BEGIN anland-gnome package holds' /etc/dnf/dnf.conf 2>/dev/null ;;
                arch|archarm|archlinux)
                    [[ -s /var/lib/anland-gnome/pacman-packages ]] || \
                        grep -Eq '^[[:space:]]*IgnorePkg[[:space:]]*=.*(^|[[:space:]])mutter([[:space:]]|$)' \
                            /etc/pacman.conf 2>/dev/null
                    ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

component_versions_match() {
    local component="$1"
    local current="${COMPONENT_CURRENT_VERSIONS[$1]:-}"
    local upstream="${COMPONENT_UPSTREAM_VERSIONS[$1]:-}"
    [[ -n "$current" && -n "$upstream" ]] || return 1
    [[ "$upstream" != pending && "$upstream" != "$(msg '超时' 'timeout')" ]] || return 1
    [[ "$current" == "$upstream" ]] && return 0

    case "$component" in
        hangover)
            [[ "$current" == "$upstream"~* || "$current" == "$upstream"-[0-9]* ]]
            ;;
        kde|gnome)
            current="${current#*:}"
            [[ "$current" == "$upstream"-* ]]
            ;;
        niri|hyprland|mango|denial)
            current="${current#*:}"
            [[ "$current" == "$upstream" || "$current" == "$upstream"-* || "$current" == "$upstream"+* ]]
            ;;
        anland-next)
            # Debian uses the bare package version; RPM and pacman append
            # their package-release suffixes to the same upstream version.
            [[ "$current" == "$upstream" || "$current" == "$upstream"-* ]]
            ;;
        *) return 1 ;;
    esac
}

component_release_parts() {
    local component="$1" tag prefix suffix
    case "$component" in
        mesa)
            tag="mesa-for-android-container"
            prefix="mesa-for-android-container_"
            case "$SYSTEM_ID:$SYSTEM_VERSION" in
                arch:*|archarm:*|archlinux:*) suffix="_archlinux_arm64.tar" ;;
                debian:13*) suffix="_debian_trixie_arm64.tar.gz" ;;
                ubuntu:24.04*) suffix="_ubuntu_noble_arm64.tar.gz" ;;
                ubuntu:25.10*) suffix="_ubuntu_questing_arm64.tar.gz" ;;
                ubuntu:26.04*) suffix="_ubuntu_resolute_arm64.tar.gz" ;;
                fedora:43*) suffix="_fedora_43_arm64.tar.gz" ;;
                fedora:44*) suffix="_fedora_44_arm64.tar.gz" ;;
                *) return 1 ;;
            esac
            ;;
        hangover)
            tag="hangover-wine-packages"
            case "$SYSTEM_ID:$SYSTEM_VERSION" in
                arch:*|archarm:*) prefix="hangover-wine-arch-"; suffix="-aarch64.tar.gz" ;;
                debian:13*) prefix="hangover-wine-debian13-"; suffix="-arm64.tar.gz" ;;
                ubuntu:24.04*) prefix="hangover-wine-ubuntu2404-"; suffix="-arm64.tar.gz" ;;
                ubuntu:25.10*) prefix="hangover-wine-ubuntu2510-"; suffix="-arm64.tar.gz" ;;
                ubuntu:26.04*) prefix="hangover-wine-ubuntu2604-"; suffix="-arm64.tar.gz" ;;
                fedora:43*) prefix="hangover-wine-fedora43-"; suffix="-aarch64.tar.gz" ;;
                fedora:44*) prefix="hangover-wine-fedora44-"; suffix="-aarch64.tar.gz" ;;
                *) return 1 ;;
            esac
            ;;
        fonts)
            tag="winefonts"
            prefix="winefonts-"
            suffix=".tar.xz"
            ;;
        kde)
            tag="anland-kde-packages"
            case "$SYSTEM_ID:$SYSTEM_VERSION" in
                arch:*|archarm:*) prefix="anland-kde-arch-kwin-"; suffix="-aarch64.tar.gz" ;;
                debian:13*) prefix="anland-kde-debian13-kwin-"; suffix="-arm64.tar.gz" ;;
                ubuntu:26.04*) prefix="anland-kde-ubuntu2604-kwin-"; suffix="-arm64.tar.gz" ;;
                fedora:43*) prefix="anland-kde-fedora43-kwin-"; suffix="-aarch64.tar.gz" ;;
                fedora:44*) prefix="anland-kde-fedora44-kwin-"; suffix="-aarch64.tar.gz" ;;
                *) return 1 ;;
            esac
            ;;
        niri|hyprland|mango|denial)
            is_arm64 || return 1
            tag="anland-$component-packages"
            case "$SYSTEM_ID:$SYSTEM_VERSION" in
                arch:*|archarm:*|archlinux:*) prefix="anland-$component-arch-"; suffix="-aarch64.tar.gz" ;;
                debian:13*) prefix="anland-$component-debian13-"; suffix="-arm64.tar.gz" ;;
                ubuntu:26.04*) prefix="anland-$component-ubuntu2604-"; suffix="-arm64.tar.gz" ;;
                fedora:43*) prefix="anland-$component-fedora43-"; suffix="-aarch64.tar.gz" ;;
                fedora:44*) prefix="anland-$component-fedora44-"; suffix="-aarch64.tar.gz" ;;
                *) return 1 ;;
            esac
            ;;
        gnome)
            tag="anland-gnome-packages"
            case "$SYSTEM_ID:$SYSTEM_VERSION" in
                arch:*|archarm:*|archlinux:*) prefix="anland-gnome-arch-mutter-"; suffix="-aarch64.tar.gz" ;;
                debian:13*) prefix="anland-gnome-debian13-mutter-"; suffix="-arm64.tar.gz" ;;
                ubuntu:26.04*) prefix="anland-gnome-ubuntu2604-mutter-"; suffix="-arm64.tar.gz" ;;
                fedora:43*) prefix="anland-gnome-fedora43-mutter-"; suffix="-aarch64.tar.gz" ;;
                fedora:44*) prefix="anland-gnome-fedora44-mutter-"; suffix="-aarch64.tar.gz" ;;
                *) return 1 ;;
            esac
            ;;
        anland-next)
            tag="anland-session-packages"
            case "$SYSTEM_ID:$SYSTEM_VERSION" in
                arch:*|archarm:*|archlinux:*)
                    prefix="anland-session-arch-anland-session-"
                    suffix="-aarch64.pkg.tar.zst"
                    ;;
                debian:13*)
                    prefix="anland-session-debian13-anland-session_"
                    suffix="_arm64.deb"
                    ;;
                ubuntu:26.04*)
                    prefix="anland-session-ubuntu2604-anland-session_"
                    suffix="_arm64.deb"
                    ;;
                fedora:43*)
                    prefix="anland-session-fedora43-anland-session-"
                    suffix=".aarch64.rpm"
                    ;;
                fedora:44*)
                    prefix="anland-session-fedora44-anland-session-"
                    suffix=".aarch64.rpm"
                    ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
    printf '%s\n%s\n%s\n' "$tag" "$prefix" "$suffix"
}

component_release_manifest_name() {
    case "$1" in
        mesa) printf '%s' 'mesa-distribution-manifest' ;;
        hangover) printf '%s' 'hangover-wine-manifest' ;;
        fonts) printf '%s' 'winefonts-manifest' ;;
        kde) printf '%s' 'anland-kde-manifest' ;;
        gnome) printf '%s' 'anland-gnome-manifest' ;;
        niri|hyprland|mango|denial) printf 'anland-%s-manifest' "$1" ;;
        anland-next) printf '%s' 'anland-session-manifest' ;;
        *) return 1 ;;
    esac
}

component_manifest_asset_names() {
    local manifest="$1"

    awk -F '\t' '
        $0 == "sha256\tsize\tasset" {
            in_assets = 1
            next
        }
        in_assets && NF == 3 {
            print $3
            next
        }
        !in_assets && $0 ~ /^[A-Za-z][A-Za-z0-9_]*=/ {
            value = $0
            sub(/^[^=]*=/, "", value)
            print value
        }
    ' "$manifest"
}

validate_component_manifest() {
    local manifest="$1" expected_tag="$2"

    awk -F '=' -v expected_tag="$expected_tag" '
        $0 == "format=1" {
            format_count += 1
            next
        }
        $1 == "format" {
            invalid = 1
            next
        }
        $1 == "release_tag" {
            release_tag_count += 1
            if ($2 != expected_tag) {
                invalid = 1
            }
        }
        END {
            exit !(format_count == 1 && release_tag_count == 1 && !invalid)
        }
    ' "$manifest"
}

parse_component_manifest_version() {
    local component="$1" manifest="$2"
    local parts prefix suffix name version selected="" count=0

    parts="$(component_release_parts "$component")" || return 1
    parts="${parts#*$'\n'}"
    prefix="${parts%%$'\n'*}"
    suffix="${parts#*$'\n'}"

    while IFS= read -r name; do
        case "$name" in
            "$prefix"*"$suffix")
                version="${name#"$prefix"}"
                version="${version%"$suffix"}"
                valid_component_version "$version" || continue
                selected="$version"
                ((count += 1))
                ;;
        esac
    done < <(component_manifest_asset_names "$manifest")
    ((count == 1)) || return 1
    printf '%s' "$selected"
}

fetch_component_release_version() {
    local component="$1" result_file="$2"
    local parts tag base_url manifest_name manifest manifest_size version temporary_result
    local curl_pid curl_status

    command -v curl >/dev/null 2>&1 || return 1
    parts="$(component_release_parts "$component")" || return 1
    tag="${parts%%$'\n'*}"
    manifest_name="$(component_release_manifest_name "$component")" || return 1
    manifest="$COMPONENT_VERSION_WORK_DIR/$component.manifest"
    temporary_result="$result_file.tmp.$BASHPID"
    case "$DOWNLOAD_SOURCE" in
        2) base_url="$COMPONENT_PROXY_DOWNLOAD_BASE" ;;
        3) base_url="$COMPONENT_CNB_DOWNLOAD_BASE" ;;
        *) base_url="$COMPONENT_GITHUB_DOWNLOAD_BASE" ;;
    esac

    curl --fail --silent --show-error --location \
        --connect-timeout 3 --max-time 9 \
        --header 'User-Agent: droidspaces-tui-components' \
        "${base_url%/}/$tag/$manifest_name" \
        --output "$manifest" >/dev/null 2>&1 &
    curl_pid=$!
    trap 'kill "$curl_pid" 2>/dev/null || true; wait "$curl_pid" 2>/dev/null || true; exit 1' \
        HUP INT TERM
    if wait "$curl_pid"; then
        curl_status=0
    else
        curl_status=$?
    fi
    trap - HUP INT TERM
    ((curl_status == 0)) || return 1

    manifest_size="$(stat -c '%s' "$manifest")" || return 1
    [[ "$manifest_size" =~ ^[0-9]+$ && "$manifest_size" -gt 0 && \
       "$manifest_size" -le "$COMPONENT_MANIFEST_MAX_BYTES" ]] || return 1
    validate_component_manifest "$manifest" "$tag" || return 1
    version="$(parse_component_manifest_version "$component" "$manifest")" || return 1
    printf '%s\n' "$version" > "$temporary_result" || return 1
    mv -f -- "$temporary_result" "$result_file"
}

component_versions_pending() {
    local component
    for component in "${COMPONENT_NAMES[@]}"; do
        [[ "${COMPONENT_UPSTREAM_VERSIONS[$component]:-}" == pending ]] && return 0
    done
    return 1
}

component_visible() {
    case "$1" in
        mesa|hangover|fonts) return 0 ;;
        kde|gnome|niri|hyprland|mango|denial|anland-next)
            [[ "$DESKTOP_COMPONENT_MODE" == choose || "$DESKTOP_COMPONENT" == "$1" ]]
            ;;
        *) return 1 ;;
    esac
}

stop_component_version_workers() {
    local component pid
    for component in "${COMPONENT_NAMES[@]}"; do
        pid="${COMPONENT_VERSION_PIDS[$component]:-}"
        [[ -n "$pid" ]] || continue
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
        wait "$pid" 2>/dev/null || true
        unset 'COMPONENT_VERSION_PIDS[$component]'
    done
    if [[ -n "$COMPONENT_VERSION_WORK_DIR" && -d "$COMPONENT_VERSION_WORK_DIR" ]]; then
        rm -rf -- "$COMPONENT_VERSION_WORK_DIR"
    fi
    COMPONENT_VERSION_WORK_DIR=""
}

start_component_version_checks() {
    local component result_file current_version
    stop_component_version_workers
    COMPONENT_VERSION_WORK_DIR="$(mktemp -d -t droidspaces-component-versions.XXXXXXXX)" || {
        for component in "${COMPONENT_NAMES[@]}"; do
            if ! component_visible "$component"; then
                COMPONENT_INSTALLED[$component]=false
                COMPONENT_CURRENT_VERSIONS[$component]=hidden
                COMPONENT_UPSTREAM_VERSIONS[$component]=hidden
                continue
            fi
            if managed_component_installed "$component"; then
                COMPONENT_INSTALLED[$component]=true
                COMPONENT_CURRENT_VERSIONS[$component]="$(detect_current_component_version "$component")"
            else
                COMPONENT_INSTALLED[$component]=false
                COMPONENT_CURRENT_VERSIONS[$component]="$(msg '未安装' 'not installed')"
            fi
            COMPONENT_UPSTREAM_VERSIONS[$component]="$(msg '超时' 'timeout')"
        done
        return
    }
    chmod 0700 "$COMPONENT_VERSION_WORK_DIR" || true
    COMPONENT_VERSION_DEADLINE=$((SECONDS + COMPONENT_VERSION_TIMEOUT))
    SPINNER_INDEX=0
    for component in "${COMPONENT_NAMES[@]}"; do
        if ! component_visible "$component"; then
            COMPONENT_INSTALLED[$component]=false
            COMPONENT_CURRENT_VERSIONS[$component]=hidden
            COMPONENT_UPSTREAM_VERSIONS[$component]=hidden
            continue
        fi
        if managed_component_installed "$component"; then
            COMPONENT_INSTALLED[$component]=true
            current_version="$(detect_current_component_version "$component")"
            COMPONENT_CURRENT_VERSIONS[$component]="$current_version"
        else
            COMPONENT_INSTALLED[$component]=false
            COMPONENT_CURRENT_VERSIONS[$component]="$(msg '未安装' 'not installed')"
        fi
        COMPONENT_UPSTREAM_VERSIONS[$component]=pending
    done
    for component in "${COMPONENT_NAMES[@]}"; do
        [[ "${COMPONENT_UPSTREAM_VERSIONS[$component]}" == hidden ]] && continue
        result_file="$COMPONENT_VERSION_WORK_DIR/$component.result"
        fetch_component_release_version "$component" "$result_file" &
        COMPONENT_VERSION_PIDS[$component]=$!
    done
}

poll_component_version_checks() {
    local component result_file version pid
    COMPONENT_STATUS_CHANGED=false
    [[ -n "$COMPONENT_VERSION_WORK_DIR" ]] || return
    for component in "${COMPONENT_NAMES[@]}"; do
        [[ "${COMPONENT_UPSTREAM_VERSIONS[$component]:-}" == pending ]] || continue
        result_file="$COMPONENT_VERSION_WORK_DIR/$component.result"
        if [[ -f "$result_file" ]] && IFS= read -r version < "$result_file" && \
            valid_component_version "$version"; then
            COMPONENT_UPSTREAM_VERSIONS[$component]="$version"
            COMPONENT_STATUS_CHANGED=true
            pid="${COMPONENT_VERSION_PIDS[$component]:-}"
            [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
            unset 'COMPONENT_VERSION_PIDS[$component]'
        fi
    done

    if component_versions_pending && ((SECONDS >= COMPONENT_VERSION_DEADLINE)); then
        for component in "${COMPONENT_NAMES[@]}"; do
            if [[ "${COMPONENT_UPSTREAM_VERSIONS[$component]:-}" == pending ]]; then
                COMPONENT_UPSTREAM_VERSIONS[$component]="$(msg '超时' 'timeout')"
                COMPONENT_STATUS_CHANGED=true
            fi
        done
    fi
    component_versions_pending || stop_component_version_workers
}

component_upstream_display() {
    local component="$1" value="${COMPONENT_UPSTREAM_VERSIONS[$1]:-}"
    if [[ "$value" == pending ]]; then
        printf '%b%s%b' "$COLOR_CYAN" \
            "${SPINNER_FRAMES[$((SPINNER_INDEX % ${#SPINNER_FRAMES[@]}))]}" "$COLOR_RESET"
    else
        printf '%s' "$value"
    fi
}

component_status_display() {
    local component="$1" upstream="${COMPONENT_UPSTREAM_VERSIONS[$1]:-}"
    if [[ "${COMPONENT_INSTALLED[$component]:-false}" == false ]]; then
        printf '%b%s%b' "$COLOR_RED" "$(msg '未安装' 'not installed')" "$COLOR_RESET"
    elif [[ "$upstream" == pending ]]; then
        component_upstream_display "$component"
    elif [[ "$upstream" == "$(msg '超时' 'timeout')" ]]; then
        printf '%b%s%b' "$COLOR_YELLOW" "$upstream" "$COLOR_RESET"
    elif component_versions_match "$component"; then
        printf '%b%s%b' "$COLOR_GREEN" \
            "$(msg '当前已是最新版本' 'up to date')" "$COLOR_RESET"
    else
        printf '%b%s%b' "$COLOR_YELLOW" "$(msg '检测到更新' 'update available')" "$COLOR_RESET"
    fi
}

desktop_selection_status_display() {
    local component upstream installed_any=false

    for component in kde gnome niri hyprland mango denial anland-next; do
        if [[ "${COMPONENT_INSTALLED[$component]:-false}" == true ]]; then
            installed_any=true
        fi
    done
    if [[ "$installed_any" == false ]]; then
        printf '%b%s%b' "$COLOR_RED" "$(msg '未安装' 'not installed')" "$COLOR_RESET"
        return
    fi
    for component in kde gnome niri hyprland mango denial anland-next; do
        [[ "${COMPONENT_INSTALLED[$component]:-false}" == true ]] || continue
        upstream="${COMPONENT_UPSTREAM_VERSIONS[$component]:-}"
        if [[ "$upstream" == pending ]]; then
            component_upstream_display "$component"
            return
        fi
    done
    for component in kde gnome niri hyprland mango denial anland-next; do
        [[ "${COMPONENT_INSTALLED[$component]:-false}" == true ]] || continue
        upstream="${COMPONENT_UPSTREAM_VERSIONS[$component]:-}"
        if [[ "$upstream" == "$(msg '超时' 'timeout')" ]]; then
            printf '%b%s%b' "$COLOR_YELLOW" "$upstream" "$COLOR_RESET"
            return
        fi
        if ! component_versions_match "$component"; then
            printf '%b%s%b' "$COLOR_YELLOW" "$(msg '检测到更新' 'update available')" "$COLOR_RESET"
            return
        fi
    done
    printf '%b%s%b' "$COLOR_GREEN" "$(msg '当前已是最新版本' 'up to date')" "$COLOR_RESET"
}

print_component_status() {
    local number="$1" label="$2" component="$3"
    printf '  %b[%s]%b %s - %s\n' \
        "$COLOR_CYAN" "$number" "$COLOR_RESET" "$label" "$(component_status_display "$component")"
}

pause_menu() {
    local unused
    printf '\n%s' "$(msg '按 Enter 返回菜单...' 'Press Enter to return to the menu...')"
    IFS= read -r unused || true
}

confirm_run() {
    local answer
    printf '%s [y/N]: ' "$(msg "确认运行 $1？" "Run $1?")"
    IFS= read -r answer || return 1
    case "${answer,,}" in
        y|yes|1|是) return 0 ;;
        *) return 1 ;;
    esac
}

run_component() {
    local component="$1"
    local label="$2"
    local installer status
    local -a source_argument=()

    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$label" "$COLOR_RESET"

    if ! component_supported "$component"; then
        printf '%b%s%b\n' "$COLOR_YELLOW" \
            "$(msg '当前系统或架构不在该安装器的支持范围内。' \
                'The current system or architecture is not supported by this installer.')" \
            "$COLOR_RESET"
        pause_menu
        return
    fi

    if ! installer="$(resolve_installer "$component")"; then
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '找不到对应的安装脚本。' 'The installer script could not be found.')" \
            "$COLOR_RESET"
        pause_menu
        return
    fi

    printf '%s: %s\n' "$(msg '安装器' 'Installer')" "$installer"
    printf '%s: %s\n\n' "$(msg '下载源' 'Source')" "$(source_label)"
    confirm_run "$label" || return

    case "$DOWNLOAD_SOURCE" in
        1) source_argument=(--1) ;;
        2) source_argument=(--2) ;;
        3) source_argument=(--3) ;;
    esac

    printf '\n%b%s%b\n\n' "$COLOR_BLUE" \
        "$(msg '安装器开始运行。' 'Starting installer.')" "$COLOR_RESET"
    COMPONENT_REFRESH_REQUIRED=true
    if "$installer" "${source_argument[@]}"; then
        status=0
    else
        status=$?
    fi

    printf '\n'
    if ((status == 0)); then
        printf '%b%s%b\n' "$COLOR_GREEN" \
            "$(msg "$label 已完成。" "$label completed.")" "$COLOR_RESET"
    else
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg "$label 失败，退出码：$status。" "$label failed with exit code $status.")" \
            "$COLOR_RESET"
    fi
    pause_menu
}

run_component_uninstall() {
    local component="$1" label="$2" installer status

    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$label" "$COLOR_RESET"
    if [[ "${COMPONENT_INSTALLED[$component]:-false}" == false ]]; then
        printf '%b%s%b\n' "$COLOR_RED" "$(msg '该组件尚未安装。' 'This component is not installed.')" "$COLOR_RESET"
        pause_menu
        return
    fi
    if ! installer="$(resolve_installer "$component")"; then
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '找不到对应的安装脚本。' 'The installer script could not be found.')" "$COLOR_RESET"
        pause_menu
        return
    fi
    printf '%b%s%b\n\n' "$COLOR_YELLOW" \
        "$(msg '替换系统组件将恢复发行版官方包；独立组件将被移除。' \
            'Replaced system components will be restored to distribution packages; standalone components will be removed.')" \
        "$COLOR_RESET"
    confirm_run "$(msg "卸载 $label" "uninstall $label")" || return
    printf '\n'
    COMPONENT_REFRESH_REQUIRED=true
    if "$installer" --uninstall; then
        status=0
    else
        status=$?
    fi
    if ((status == 0)); then
        printf '\n%b%s%b\n' "$COLOR_GREEN" \
            "$(msg "$label 已卸载。" "$label was uninstalled.")" "$COLOR_RESET"
    else
        printf '\n%b%s%b\n' "$COLOR_RED" \
            "$(msg "$label 卸载失败，退出码：$status。" \
                "$label uninstall failed with exit code $status.")" "$COLOR_RESET"
    fi
    pause_menu
}

desktop_component_selection_menu() {
    local choice read_status
    begin_dynamic_menu
    while :; do
        poll_component_version_checks
        if [[ "$DYNAMIC_MENU_DRAWN" == false || "$COMPONENT_STATUS_CHANGED" == true ]] || \
            ! dynamic_ui_supported; then
            draw_dynamic_menu_frame
            draw_header
            printf '\n%b%s%b\n\n' "$COLOR_BOLD" \
                "$(msg '选择桌面组件' 'Select desktop component')" "$COLOR_RESET"
            print_component_status "1" "Anland KDE (KWin/Xwayland)" "kde"
            print_component_status "2" "Anland GNOME (Mutter/Xwayland)" "gnome"
            print_component_status "3" "Anland Niri (Niri/Xwayland)" "niri"
            print_component_status "4" "Anland Next session" "anland-next"
            print_component_status "5" "Anland Hyprland" "hyprland"
            print_component_status "6" "Anland Mango" "mango"
            print_component_status "7" "Anland Denial" "denial"
            printf '  %b[0]%b %s\n\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '返回' 'Back')"
        fi
        draw_dynamic_menu_prompt
        read_dynamic_menu_choice
        read_status=$?
        if ((read_status == 2)); then
            restore_dynamic_menu_echo
            return
        fi
        ((read_status == 0)) || continue
        choice="$MENU_CHOICE"
        [[ -n "$choice" ]] || continue
        case "${choice,,}" in
            1)
                restore_dynamic_menu_echo
                component_menu "kde" "Anland KDE (KWin/Xwayland)"
                return
                ;;
            2)
                restore_dynamic_menu_echo
                component_menu "gnome" "Anland GNOME (Mutter/Xwayland)"
                return
                ;;
            3)
                restore_dynamic_menu_echo
                component_menu "niri" "Anland Niri (Niri/Xwayland)"
                return
                ;;
            4)
                restore_dynamic_menu_echo
                component_menu "anland-next" "Anland Next session"
                return
                ;;
            5|6|7)
                restore_dynamic_menu_echo
                case "$choice" in
                    5) component_menu hyprland "Anland Hyprland" ;;
                    6) component_menu mango "Anland Mango" ;;
                    7) component_menu denial "Anland Denial" ;;
                esac
                return
                ;;
            0|q)
                restore_dynamic_menu_echo
                return
                ;;
        esac
    done
}

component_menu() {
    local component="$1" label="$2" choice read_status
    begin_dynamic_menu
    while :; do
        poll_component_version_checks
        if [[ "$DYNAMIC_MENU_DRAWN" == false || "$COMPONENT_STATUS_CHANGED" == true ]] || \
            ! dynamic_ui_supported; then
            draw_dynamic_menu_frame
            draw_header
            printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$label" "$COLOR_RESET"
            printf '  %s: %s\n' "$(msg '状态' 'Status')" "$(component_status_display "$component")"
            printf '  %s: %s\n' "$(msg '当前版本' 'Installed version')" \
                "${COMPONENT_CURRENT_VERSIONS[$component]}"
            printf '  %s: %s\n\n' "$(msg '上游版本' 'Upstream version')" \
                "$(component_upstream_display "$component")"
            printf '  %b[1]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '更新/安装' 'Update/install')"
            printf '  %b[2]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '卸载' 'Uninstall')"
            printf '  %b[0]%b %s\n\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '返回' 'Back')"
        fi
        draw_dynamic_menu_prompt
        read_dynamic_menu_choice
        read_status=$?
        if ((read_status == 2)); then
            restore_dynamic_menu_echo
            return
        fi
        ((read_status == 0)) || continue
        choice="$MENU_CHOICE"
        [[ -n "$choice" ]] || continue
        case "${choice,,}" in
            1)
                restore_dynamic_menu_echo
                run_component "$component" "$label"
                return
                ;;
            2)
                restore_dynamic_menu_echo
                run_component_uninstall "$component" "$label"
                return
                ;;
            0|q)
                restore_dynamic_menu_echo
                return
                ;;
        esac
    done
}

select_download_source() {
    local choice selected_source
    while :; do
        clear_screen
        draw_header
        printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$(msg '选择下载源' 'Select download source')" "$COLOR_RESET"
        printf '  %b[1]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '自动测速并由安装器提示选择' 'Probe sources and let the installer prompt')"
        printf '  %b[2]%b GitHub\n' "$COLOR_CYAN" "$COLOR_RESET"
        printf '  %b[3]%b gh-proxy.com\n' "$COLOR_CYAN" "$COLOR_RESET"
        printf '  %b[4]%b CNB\n' "$COLOR_CYAN" "$COLOR_RESET"
        printf '  %b[0]%b %s\n\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '返回' 'Back')"
        printf '%s: ' "$(msg '请选择' 'Select')"
        IFS= read -r choice || return
        case "$choice" in
            1) selected_source="auto" ;;
            2) selected_source="1" ;;
            3) selected_source="2" ;;
            4) selected_source="3" ;;
            0|q|Q) return ;;
            *) continue ;;
        esac
        if [[ "$DOWNLOAD_SOURCE" != "$selected_source" ]]; then
            DOWNLOAD_SOURCE="$selected_source"
            COMPONENT_REFRESH_REQUIRED=true
        fi
        return
    done
}

clean_cache_from_menu() {
    local action="$1"
    local label

    case "$action" in
        manifest)
            label="$(msg 'Hangover Release 清单缓存' 'Hangover Release manifest cache')"
            ;;
        all)
            label="$(msg 'Hangover 全部下载缓存' 'all Hangover download cache')"
            ;;
    esac

    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$label" "$COLOR_RESET"
    if [[ "$action" == "all" ]]; then
        printf '%b%s%b\n\n' "$COLOR_YELLOW" \
            "$(msg '这会删除已下载的软件包，下次安装需要重新下载。' \
                'Downloaded package archives will be removed and must be downloaded again.')" \
            "$COLOR_RESET"
    fi
    confirm_run "$(msg "清理 $label" "clean $label")" || return

    printf '\n'
    if "$SCRIPT_PATH" --no-color --clean-cache "$action"; then
        printf '%b%s%b\n' "$COLOR_GREEN" \
            "$(msg "$label 已清理。" "$label cleaned.")" "$COLOR_RESET"
    else
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg "$label 清理失败。" "Failed to clean $label.")" "$COLOR_RESET"
    fi
    pause_menu
}

manage_cache() {
    local choice
    while :; do
        clear_screen
        draw_header
        printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$(msg '缓存管理' 'Cache management')" "$COLOR_RESET"
        printf '  %s: %s\n\n' "$(msg 'Hangover 缓存占用' 'Hangover cache usage')" \
            "$(hangover_cache_size)"
        printf '  %b[1]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '清理 Release 清单缓存（推荐）' 'Clean the Release manifest cache (recommended)')"
        printf '  %b[2]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '清空 Hangover 全部下载缓存' 'Clean all Hangover download cache')"
        printf '  %b[0]%b %s\n\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '返回' 'Back')"
        printf '%s: ' "$(msg '请选择' 'Select')"
        IFS= read -r choice || return
        case "$choice" in
            1) clean_cache_from_menu "manifest" ;;
            2) clean_cache_from_menu "all" ;;
            0|q|Q) return ;;
        esac
    done
}

switch_system_mirrors() {
    local script_path status

    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" \
        "$(msg '切换系统软件源' 'Switch system software mirrors')" "$COLOR_RESET"
    printf '%s\n' "$(msg \
        '此操作使用 LinuxMirrors 为当前容器选择并配置发行版软件源。' \
        'This uses LinuxMirrors to select and configure repositories for the current container.')"
    printf '%s\n' "$(msg \
        '来源脚本：' 'Source script:')"
    printf '  %s\n\n' "$LINUXMIRRORS_SCRIPT_URL"
    printf '%b%s%b\n\n' "$COLOR_YELLOW" \
        "$(msg \
            '远程脚本将以 root 身份运行，并可能修改系统软件源配置。' \
            'The remote script will run as root and may modify system repository configuration.')" \
        "$COLOR_RESET"

    if ((EUID != 0)) && ! command -v sudo >/dev/null 2>&1; then
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '该操作需要 root 权限，且系统未安装 sudo。' \
                'This operation requires root access, and sudo is unavailable.')" "$COLOR_RESET"
        pause_menu
        return
    fi
    command -v curl >/dev/null 2>&1 || {
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '缺少 curl，无法下载 LinuxMirrors 脚本。' \
                'curl is unavailable, so the LinuxMirrors script cannot be downloaded.')" "$COLOR_RESET"
        pause_menu
        return
    }
    confirm_run "$(msg '切换系统软件源' 'switch system software mirrors')" || return 0

    MIRROR_WORK_DIR="$(mktemp -d -t droidspaces-linuxmirrors.XXXXXXXX)" || {
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '无法创建临时目录。' 'Could not create a temporary directory.')" "$COLOR_RESET"
        pause_menu
        return
    }
    chmod 0700 "$MIRROR_WORK_DIR" || true
    script_path="$MIRROR_WORK_DIR/main.sh"
    printf '\n%b%s%b\n' "$COLOR_BLUE" \
        "$(msg '正在下载并检查 LinuxMirrors 脚本。' \
            'Downloading and checking the LinuxMirrors script.')" "$COLOR_RESET"
    if ! curl --fail --silent --show-error --location \
        --retry 2 --retry-all-errors --connect-timeout 15 --max-time 180 \
        "$LINUXMIRRORS_SCRIPT_URL" --output "$script_path" || \
        [[ ! -s "$script_path" ]] || ! bash -n "$script_path"; then
        cleanup_mirror_files
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg 'LinuxMirrors 脚本下载或语法检查失败。' \
                'The LinuxMirrors script failed to download or pass syntax checking.')" "$COLOR_RESET"
        pause_menu
        return
    fi

    printf '\n%b%s%b\n\n' "$COLOR_BLUE" \
        "$(msg 'LinuxMirrors 脚本即将启动。' 'Starting the LinuxMirrors script.')" "$COLOR_RESET"
    if ((EUID == 0)); then
        if bash "$script_path"; then
            status=0
        else
            status=$?
        fi
    else
        if sudo -- bash "$script_path"; then
            status=0
        else
            status=$?
        fi
    fi
    cleanup_mirror_files

    if ((status == 0)); then
        printf '\n%b%s%b\n' "$COLOR_GREEN" \
            "$(msg '系统软件源切换完成。' 'System software mirror switching completed.')" "$COLOR_RESET"
    else
        printf '\n%b%s%b\n' "$COLOR_RED" \
            "$(msg "系统软件源切换失败，退出码：$status。" \
                "System software mirror switching failed with exit code $status.")" "$COLOR_RESET"
    fi
    pause_menu
}

reclaim_sparse_storage() {
    local root_info root_source root_fstype root_options status

    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" \
        "$(msg '回收存储空间（稀疏镜像）' 'Reclaim storage (sparse image)')" "$COLOR_RESET"
    printf '%s\n' "$(msg \
        '此操作用于正常启动的 rootfs.img 稀疏镜像容器。' \
        'This action is for a normally started rootfs.img sparse-image container.')"
    printf '%s\n' "$(msg \
        '只修剪根文件系统中未使用的块，不会删除现有文件。' \
        'Only unused root-filesystem blocks are trimmed; existing files are not deleted.')"
    printf '%s\n\n' "$(msg \
        '宿主端实际占用空间可能减少；镜像的逻辑文件大小通常不变。' \
        'Host-side allocated space may decrease; the image logical size usually stays unchanged.')"

    if ! command -v findmnt >/dev/null 2>&1; then
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '缺少 findmnt，无法确认根文件系统类型。' \
                'findmnt is unavailable, so the root filesystem type cannot be verified.')" "$COLOR_RESET"
        pause_menu
        return
    fi
    if ! command -v fstrim >/dev/null 2>&1; then
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '缺少 fstrim，请先安装 util-linux。' \
                'fstrim is unavailable; install util-linux first.')" "$COLOR_RESET"
        pause_menu
        return
    fi
    if ! root_info="$(findmnt -rnT / -o SOURCE,FSTYPE,OPTIONS 2>/dev/null)" || \
        [[ -z "$root_info" || "$root_info" == *$'\n'* ]]; then
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '无法唯一识别根文件系统挂载。' \
                'The root filesystem mount could not be identified uniquely.')" "$COLOR_RESET"
        pause_menu
        return
    fi
    read -r root_source root_fstype root_options <<< "$root_info"
    if [[ "$root_fstype" != ext4 || \
        ! "$root_source" =~ ^/dev/(block/)?loop[0-9]+(\[[^]]+\])?$ || \
        ",$root_options," != *,rw,* ]]; then
        printf '%b%s%b\n' "$COLOR_YELLOW" \
            "$(msg \
                '根文件系统不是可写的 Ext4 loop 镜像，已取消操作。' \
                'The root filesystem is not a writable Ext4 loop image; the operation was cancelled.')" \
            "$COLOR_RESET"
        printf '%s: %s (%s, %s)\n' "$(msg '检测结果' 'Detected')" \
            "$root_source" "$root_fstype" "$root_options"
        pause_menu
        return
    fi

    printf '%s: %s (%s)\n\n' "$(msg '根镜像设备' 'Root image device')" \
        "$root_source" "$root_fstype"
    confirm_run "$(msg '回收根镜像的未使用空间' \
        'reclaim unused space from the root image')" || return 0

    printf '\n%b%s%b\n\n' "$COLOR_BLUE" \
        "$(msg '正在修剪根文件系统，请勿中断容器。' \
            'Trimming the root filesystem; do not stop the container.')" "$COLOR_RESET"
    if ((EUID == 0)); then
        if fstrim -v /; then
            status=0
        else
            status=$?
        fi
    else
        if ! command -v sudo >/dev/null 2>&1; then
            printf '%b%s%b\n' "$COLOR_RED" \
                "$(msg '该操作需要 root 权限，且系统未安装 sudo。' \
                    'This operation requires root access, and sudo is unavailable.')" "$COLOR_RESET"
            pause_menu
            return
        fi
        if sudo -- fstrim -v /; then
            status=0
        else
            status=$?
        fi
    fi

    printf '\n'
    if ((status == 0)); then
        printf '%b%s%b\n' "$COLOR_GREEN" \
            "$(msg \
                '修剪完成。请在 Android 宿主端查看 rootfs.img 的实际占用空间。' \
                'Trim completed. Check the allocated space used by rootfs.img on the Android host.')" \
            "$COLOR_RESET"
    else
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg \
                "修剪失败，退出码：$status。可能是权限不足、挂载已变为只读，或内核、loop 设备、宿主文件系统不支持 discard。" \
                "Trim failed with exit code $status. Access may be denied, the mount may be read-only, or the kernel, loop device, or host filesystem may not support discard.")" \
            "$COLOR_RESET"
    fi
    pause_menu
}

cleanup_update_files() {
    if [[ -n "$UPDATE_WORK_DIR" && -d "$UPDATE_WORK_DIR" ]]; then
        rm -rf -- "$UPDATE_WORK_DIR"
    fi
    UPDATE_WORK_DIR=""
    UPDATE_UPDATER_PATH=""
}

fetch_tui_release_metadata() {
    local output="$1"
    local -a headers=(
        --header 'Accept: application/vnd.github+json'
        --header 'X-GitHub-Api-Version: 2022-11-28'
        --header 'User-Agent: droidspaces-tui'
    )
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        headers+=(--header "Authorization: Bearer $GITHUB_TOKEN")
    fi
    curl --fail --silent --show-error --location \
        --retry 2 --retry-all-errors --connect-timeout 15 --max-time 60 \
        "${headers[@]}" \
        "$TUI_GITHUB_API_URL/repos/$TUI_RELEASE_REPOSITORY/releases/tags/$TUI_RELEASE_TAG" \
        --output "$output"
}

tui_bootstrap_row() {
    local metadata="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -er --arg tag "$TUI_RELEASE_TAG" --arg name "$TUI_BOOTSTRAP_NAME" '
            if .tag_name != $tag then error("Release tag mismatch")
            elif .draft != false then error("Release is a draft")
            else . end
            | [.assets[] | select(.name == $name)]
            | if length != 1 then error("bootstrap asset is missing or duplicated")
              else .[0] end
            | if (.digest | type) != "string" or
                 (.digest | test("^sha256:[0-9A-Fa-f]{64}$") | not)
              then error("bootstrap asset has no valid SHA-256")
              else [.id, (.digest | ascii_downcase | sub("^sha256:"; "")), .size, .updated_at] | @tsv
              end
        ' "$metadata"
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$metadata" "$TUI_RELEASE_TAG" "$TUI_BOOTSTRAP_NAME" <<'PY'
import json
import re
import sys

path, expected_tag, expected_name = sys.argv[1:]
with open(path, "r", encoding="utf-8") as stream:
    release = json.load(stream)
if release.get("tag_name") != expected_tag or release.get("draft") is not False:
    raise SystemExit("Release tag mismatch or draft Release")
assets = [item for item in release.get("assets", []) if item.get("name") == expected_name]
if len(assets) != 1:
    raise SystemExit("bootstrap asset is missing or duplicated")
asset = assets[0]
digest = asset.get("digest")
if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9A-Fa-f]{64}", digest):
    raise SystemExit("bootstrap asset has no valid SHA-256")
print("\t".join((str(asset["id"]), digest[7:].lower(), str(asset["size"]), asset["updated_at"])))
PY
    else
        printf '%s\n' "$(msg '缺少 JSON 解析器：需要 jq 或 python3。' \
            'A JSON parser is required: install jq or python3.')" >&2
        return 1
    fi
}

download_tui_cnb_manifest() {
    local output="$1" manifest_size

    if ! curl --fail --silent --show-error --location \
        --retry 2 --retry-all-errors --connect-timeout 15 --max-time 120 \
        --output "$output" "$TUI_CNB_DOWNLOAD_BASE/$TUI_RELEASE_TAG/$TUI_MANIFEST_NAME"; then
        return 1
    fi
    manifest_size="$(stat -c '%s' "$output")" || return 1
    [[ "$manifest_size" =~ ^[0-9]+$ && "$manifest_size" -gt 0 && \
       "$manifest_size" -le $((1024 * 1024)) ]]
}

tui_cnb_bootstrap_row() {
    local manifest="$1"

    awk -F '\t' -v expected_tag="$TUI_RELEASE_TAG" -v expected_name="$TUI_BOOTSTRAP_NAME" '
        NR == 1 && $0 == "format=1" { format = 1; next }
        $0 == "release_tag=" expected_tag { tag = 1; next }
        $0 == "sha256\tsize\trole\ttarget\tasset" { header = 1; next }
        header && NF == 5 && $1 ~ /^[0-9a-f]{64}$/ && $2 ~ /^[0-9]+$/ &&
            $3 == "bootstrap" && $4 == "-" && $5 == expected_name {
            digest = $1
            size = $2
            count += 1
        }
        END {
            if (format && tag && header && count == 1 && size > 0) {
                print digest "\t" size
            } else {
                exit 1
            }
        }
    ' "$manifest"
}

download_tui_bootstrap() {
    local expected_sha="$1" expected_size="$2" output="$3"
    local source_name base actual_sha actual_size
    local -a sources=()

    case "$DOWNLOAD_SOURCE" in
        auto) sources=(github proxy cnb) ;;
        1) sources=(github) ;;
        2) sources=(proxy) ;;
        3) sources=(cnb) ;;
    esac
    for source_name in "${sources[@]}"; do
        case "$source_name" in
            github) base="$TUI_GITHUB_DOWNLOAD_BASE" ;;
            proxy) base="$TUI_PROXY_DOWNLOAD_BASE" ;;
            cnb) base="$TUI_CNB_DOWNLOAD_BASE" ;;
        esac
        rm -f -- "$output"
        printf '%s\n' "$(msg "正在从 $source_name 获取一次性安装脚本..." \
            "Downloading the one-time installer from $source_name...")"
        if ! curl --fail --silent --show-error --location \
            --retry 2 --retry-all-errors --connect-timeout 15 --max-time 120 \
            --output "$output" "$base/$TUI_RELEASE_TAG/$TUI_BOOTSTRAP_NAME"; then
            continue
        fi
        actual_size="$(stat -c '%s' "$output")"
        actual_sha="$(sha256sum "$output" | awk '{print $1}')"
        if [[ "$actual_size" == "$expected_size" && "$actual_sha" == "$expected_sha" ]]; then
            chmod 0755 "$output"
            return 0
        fi
        printf '%s\n' "$(msg '一次性安装脚本校验失败。' \
            'The one-time installer failed verification.')" >&2
    done
    return 1
}

prepare_updater() {
    local candidate metadata_before metadata_after row_before row_after metadata_source
    local asset_id expected_sha expected_size updated_at command_name
    local manifest_before_sha manifest_after_sha

    cleanup_update_files
    candidate="$SCRIPT_DIR/install-tui.sh"
    if [[ -x "$candidate" ]]; then
        UPDATE_UPDATER_PATH="$candidate"
        return 0
    fi
    for command_name in awk bash chmod curl mktemp rm sha256sum stat; do
        command -v "$command_name" >/dev/null 2>&1 || {
            printf '%s\n' "$(msg "缺少命令：$command_name" "Required command is missing: $command_name")" >&2
            return 1
        }
    done

    UPDATE_WORK_DIR="$(mktemp -d -t droidspaces-tui-update.XXXXXXXX)" || return 1
    metadata_before="$UPDATE_WORK_DIR/release-before.json"
    metadata_after="$UPDATE_WORK_DIR/release-after.json"
    UPDATE_UPDATER_PATH="$UPDATE_WORK_DIR/$TUI_BOOTSTRAP_NAME"
    metadata_source=github
    if [[ "$DOWNLOAD_SOURCE" == 3 ]]; then
        download_tui_cnb_manifest "$metadata_before" || { cleanup_update_files; return 1; }
        row_before="$(tui_cnb_bootstrap_row "$metadata_before")" || { cleanup_update_files; return 1; }
        metadata_source=cnb
    elif [[ "$DOWNLOAD_SOURCE" == auto ]]; then
        if fetch_tui_release_metadata "$metadata_before" && \
            row_before="$(tui_bootstrap_row "$metadata_before")"; then
            :
        else
            download_tui_cnb_manifest "$metadata_before" || { cleanup_update_files; return 1; }
            row_before="$(tui_cnb_bootstrap_row "$metadata_before")" || { cleanup_update_files; return 1; }
            metadata_source=cnb
            DOWNLOAD_SOURCE=3
        fi
    else
        fetch_tui_release_metadata "$metadata_before" || { cleanup_update_files; return 1; }
        row_before="$(tui_bootstrap_row "$metadata_before")" || { cleanup_update_files; return 1; }
    fi
    if [[ "$metadata_source" == cnb ]]; then
        manifest_before_sha="$(sha256sum "$metadata_before" | awk '{print $1}')" || {
            cleanup_update_files
            return 1
        }
    fi
    if [[ "$metadata_source" == cnb ]]; then
        IFS=$'\t' read -r expected_sha expected_size <<< "$row_before"
    else
        IFS=$'\t' read -r asset_id expected_sha expected_size updated_at <<< "$row_before"
    fi
    download_tui_bootstrap "$expected_sha" "$expected_size" "$UPDATE_UPDATER_PATH" || {
        cleanup_update_files
        return 1
    }
    bash -n "$UPDATE_UPDATER_PATH" || { cleanup_update_files; return 1; }
    if [[ "$metadata_source" == github ]]; then
        fetch_tui_release_metadata "$metadata_after" || { cleanup_update_files; return 1; }
        row_after="$(tui_bootstrap_row "$metadata_after")" || { cleanup_update_files; return 1; }
        if [[ "$row_before" != "$row_after" ]]; then
            printf '%s\n' "$(msg '下载期间 Release 已变化，请重试。' \
                'The Release changed during download; try again.')" >&2
            cleanup_update_files
            return 1
        fi
    else
        download_tui_cnb_manifest "$metadata_after" || { cleanup_update_files; return 1; }
        row_after="$(tui_cnb_bootstrap_row "$metadata_after")" || {
            cleanup_update_files
            return 1
        }
        manifest_after_sha="$(sha256sum "$metadata_after" | awk '{print $1}')" || {
            cleanup_update_files
            return 1
        }
        if [[ "$manifest_before_sha" != "$manifest_after_sha" || \
              "$row_before" != "$row_after" ]]; then
            printf '%s\n' "$(msg '下载期间 CNB Release 清单发生变化，请重试。' \
                'The CNB Release manifest changed during download; please retry.')" >&2
            cleanup_update_files
            return 1
        fi
    fi
    return 0
}

run_update_check() {
    local updater
    local -a source_argument=(--source "$DOWNLOAD_SOURCE")

    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$(msg '检查更新' 'Check for updates')" "$COLOR_RESET"
    if ! prepare_updater; then
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '无法取得经过校验的一次性安装脚本。' \
                'Could not obtain a verified one-time installer.')" "$COLOR_RESET"
        pause_menu
        return
    fi
    updater="$UPDATE_UPDATER_PATH"
    source_argument=(--source "$DOWNLOAD_SOURCE")
    if ! "$updater" "${source_argument[@]}" --check --only all; then
        printf '\n%b%s%b\n' "$COLOR_RED" \
            "$(msg '检查更新失败。' 'The update check failed.')" "$COLOR_RESET"
    fi
    cleanup_update_files
    pause_menu
}

run_update() {
    local scope="$1" label="$2" updater status
    local -a source_argument=(--source "$DOWNLOAD_SOURCE")

    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$label" "$COLOR_RESET"
    confirm_run "$label" || return
    if ! prepare_updater; then
        printf '%b%s%b\n' "$COLOR_RED" \
            "$(msg '无法取得经过校验的一次性安装脚本。' \
                'Could not obtain a verified one-time installer.')" "$COLOR_RESET"
        pause_menu
        return
    fi
    updater="$UPDATE_UPDATER_PATH"
    source_argument=(--source "$DOWNLOAD_SOURCE")
    printf '\n'
    if "$updater" "${source_argument[@]}" --only "$scope" --yes; then
        status=0
    else
        status=$?
    fi
    if ((status != 0)); then
        cleanup_update_files
        printf '\n%b%s%b\n' "$COLOR_RED" \
            "$(msg "更新失败，退出码：$status。" "Update failed with exit code $status.")" "$COLOR_RESET"
        pause_menu
        return
    fi

    if [[ "$scope" == tui || "$scope" == all ]]; then
        if [[ -x "$INSTALLED_TUI_PATH" ]]; then
            printf '\n%s\n' "$(msg 'TUI 已更新，正在重新启动。' 'The TUI was updated and will now restart.')"
            cleanup_update_files
            exec "$INSTALLED_TUI_PATH" --source "$DOWNLOAD_SOURCE"
        fi
    fi
    cleanup_update_files
    printf '\n%b%s%b\n' "$COLOR_GREEN" "$(msg '更新完成。' 'Update completed.')" "$COLOR_RESET"
    pause_menu
}

manage_updates() {
    local choice
    while :; do
        clear_screen
        draw_header
        printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$(msg '更新管理' 'Update management')" "$COLOR_RESET"
        printf '  %b[1]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '检查更新' 'Check for updates')"
        printf '  %b[2]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '更新 TUI' 'Update the TUI')"
        printf '  %b[3]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '更新受管安装脚本' 'Update managed installer scripts')"
        printf '  %b[4]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
            "$(msg '更新全部' 'Update everything')"
        printf '  %b[0]%b %s\n\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '返回' 'Back')"
        printf '%s: ' "$(msg '请选择' 'Select')"
        IFS= read -r choice || return
        case "$choice" in
            1) run_update_check ;;
            2) run_update tui "$(msg '更新 TUI' 'Update the TUI')" ;;
            3) run_update scripts "$(msg '更新受管安装脚本' 'Update managed installer scripts')" ;;
            4) run_update all "$(msg '更新全部' 'Update everything')" ;;
            0|q|Q) return ;;
        esac
    done
}

show_about() {
    clear_screen
    draw_header
    printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$(msg '关于' 'About')" "$COLOR_RESET"
    printf '%s\n' "$(msg \
        '此工具统一调用仓库内的独立安装器；下载、校验、安装和软件包管理仍由各安装器负责。' \
        'This tool dispatches the standalone installers. Each installer owns download, verification, installation, and package management.')"
    printf '\n%s\n' "$(msg \
        'Anland KDE、GNOME、Niri、Hyprland、Mango、Denial 和 Next session 支持 Debian 13、Ubuntu 26.04、Fedora 43/44 与 Arch Linux ARM，均要求 ARM64 架构。' \
        'Anland KDE, GNOME, Niri, Hyprland, Mango, Denial, and Next session support Debian 13, Ubuntu 26.04, Fedora 43/44, and Arch Linux ARM on ARM64.')"
    printf '\n%s\n' "$(msg \
        '桌面更新项根据 /etc/droidspaces-desktop.conf 中的 DESKTOP 字段选择。' \
        'The desktop update entry is selected by the DESKTOP field in /etc/droidspaces-desktop.conf.')"
    pause_menu
}

main_menu() {
    local choice read_status
    start_component_version_checks
    begin_dynamic_menu
    while :; do
        poll_component_version_checks
        if [[ "$DYNAMIC_MENU_DRAWN" == false || "$COMPONENT_STATUS_CHANGED" == true ]] || \
            ! dynamic_ui_supported; then
            draw_dynamic_menu_frame
            draw_header
            printf '\n%b%s%b\n\n' "$COLOR_BOLD" "$(msg '组件管理' 'Component management')" "$COLOR_RESET"
            print_component_status "1" "Mesa + MediaCodec VA-API" "mesa"
            print_component_status "2" "Hangover Wine" "hangover"
            print_component_status "3" "$(msg 'Wine 字体' 'Wine fonts')" "fonts"
            if [[ "$DESKTOP_COMPONENT_MODE" == direct ]]; then
                print_component_status "4" "$DESKTOP_COMPONENT_LABEL" "$DESKTOP_COMPONENT"
            else
                printf '  %b[4]%b %s - %s\n' \
                    "$COLOR_CYAN" "$COLOR_RESET" \
                    "$(msg 'Anland 桌面/会话组件' 'Anland desktop/session components')" \
                    "$(desktop_selection_status_display)"
            fi
            printf '\n'
            printf '  %b[S]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '切换下载源' 'Change download source')"
            printf '  %b[C]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '清理下载缓存' 'Clean download cache')"
            printf '  %b[R]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
                "$(msg '回收存储空间（稀疏镜像）' 'Reclaim storage (sparse image)')"
            printf '  %b[M]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" \
                "$(msg '切换系统软件源' 'Switch system software mirrors')"
            printf '  %b[U]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '检查与安装更新' 'Check for and install updates')"
            printf '  %b[A]%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '关于与支持范围' 'About and support')"
            printf '  %b[Q]%b %s\n\n' "$COLOR_CYAN" "$COLOR_RESET" "$(msg '退出' 'Quit')"
        fi
        draw_dynamic_menu_prompt
        read_dynamic_menu_choice
        read_status=$?
        if ((read_status == 2)); then
            restore_dynamic_menu_echo
            return
        fi
        ((read_status == 0)) || continue
        choice="$MENU_CHOICE"
        [[ -n "$choice" ]] || continue
        case "${choice,,}" in
            0|1|2|3|4|q|s|c|r|m|u|a) restore_dynamic_menu_echo ;;
            *) continue ;;
        esac
        case "${choice,,}" in
            1) component_menu "mesa" "Mesa + MediaCodec VA-API" ;;
            2) component_menu "hangover" "Hangover Wine" ;;
            3) component_menu "fonts" "$(msg 'Wine 字体' 'Wine fonts')" ;;
            4)
                if [[ "$DESKTOP_COMPONENT_MODE" == direct ]]; then
                    component_menu "$DESKTOP_COMPONENT" "$DESKTOP_COMPONENT_LABEL"
                else
                    desktop_component_selection_menu
                fi
                ;;
            s) select_download_source ;;
            c) manage_cache ;;
            r) reclaim_sparse_storage ;;
            m) switch_system_mirrors ;;
            u) manage_updates ;;
            a) show_about ;;
            q|0) return ;;
        esac
        if [[ "$COMPONENT_REFRESH_REQUIRED" == true ]]; then
            COMPONENT_REFRESH_REQUIRED=false
            detect_desktop_component
            start_component_version_checks
        fi
        begin_dynamic_menu
    done
}

handle_signal() {
    restore_dynamic_menu_echo
    stop_component_version_workers
    cleanup_mirror_files
    cleanup_update_files
    printf '\n'
    exit 130
}

cleanup_all() {
    restore_dynamic_menu_echo
    stop_component_version_workers
    cleanup_mirror_files
    cleanup_update_files
}

main() {
    detect_language
    parse_arguments "$@"
    set_default_download_source
    validate_cache_action
    init_colors
    detect_system
    detect_desktop_component
    if [[ -n "$CACHE_ACTION" ]]; then
        clean_cache_as_root "$CACHE_ACTION"
        exit 0
    fi
    [[ -t 0 && -t 1 ]] || die \
        "需要交互式终端，请通过 adb shell -t 或普通终端运行。" \
        "An interactive terminal is required; use adb shell -t or a regular terminal."
    trap handle_signal HUP INT TERM
    trap cleanup_all EXIT
    main_menu
    clear_screen
    printf '%s\n' "$(msg '已退出 Droidspaces 工具箱。' 'Exited Droidspaces Toolkit.')"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
