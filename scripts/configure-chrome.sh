#!/usr/bin/env bash
set -euo pipefail

desktop="${1:-}"
display_backend="${2:-}"
rootfs="${ROOTFS_DIR:-}"
chrome_binary="${rootfs}/opt/google/chrome/google-chrome"
wrapper_dir="${rootfs}/usr/local/bin"
wrapper="${wrapper_dir}/google-chrome"
username="${3:-${USERNAME:-}}"

[[ -z "$rootfs" || "$rootfs" == /* ]] || {
    echo "ROOTFS_DIR 必须为绝对路径" >&2
    exit 1
}
[[ -z "$username" || "$username" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ ]] || {
    echo "无效的 Chrome 桌面用户名：$username" >&2
    exit 1
}

[[ -n "$desktop" ]] || {
    echo "必须指定桌面配置" >&2
    exit 1
}

case "$display_backend" in
    x11|anland-wayland) ;;
    *)
        echo "无效的 Chrome 显示后端：$display_backend" >&2
        exit 1
        ;;
esac

[[ "$desktop" == none ]] && exit 0

install_debian_chrome() {
    install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        -o /etc/apt/keyrings/google-chrome.asc
    grep -q 'BEGIN PGP PUBLIC KEY BLOCK' /etc/apt/keyrings/google-chrome.asc
    printf 'deb [arch=arm64 signed-by=/etc/apt/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main\n' \
        > /etc/apt/sources.list.d/google-chrome.list
    apt-get update
    apt-get install -y --no-install-recommends google-chrome-stable
}

install_fedora_chrome() {
    install -d -m 0755 /etc/pki/rpm-gpg /etc/yum.repos.d
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        -o /etc/pki/rpm-gpg/RPM-GPG-KEY-google-chrome
    grep -q 'BEGIN PGP PUBLIC KEY BLOCK' /etc/pki/rpm-gpg/RPM-GPG-KEY-google-chrome
    printf '%s\n' \
        '[google-chrome]' \
        'name=Google Chrome' \
        'baseurl=https://dl.google.com/linux/chrome/rpm/stable/$basearch' \
        'enabled=1' \
        'gpgcheck=1' \
        'repo_gpgcheck=0' \
        'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-google-chrome' \
        > /etc/yum.repos.d/google-chrome.repo
    dnf install -y --setopt=install_weak_deps=False google-chrome-stable
}

install_arch_chrome() {
    # base-devel 可以是元包；按实际安装变化记录构建依赖，不依赖包组查询。
    pacman -Qq | LC_ALL=C sort -u > /tmp/chrome-packages-before
    pacman -S --noconfirm --needed base-devel git
    pacman -Qq | LC_ALL=C sort -u > /tmp/chrome-packages-after
    LC_ALL=C comm -13 /tmp/chrome-packages-before /tmp/chrome-packages-after \
        > /tmp/chrome-build-packages
    useradd --system --create-home --home-dir /tmp/chrome-build --shell /bin/bash chrome-build
    runuser -u chrome-build -- git clone --depth=1 \
        https://aur.archlinux.org/google-chrome.git /tmp/chrome-build/google-chrome
    grep -Eq '^[[:space:]]*arch = aarch64$' /tmp/chrome-build/google-chrome/.SRCINFO
    grep -Eq '^[[:space:]]*source_aarch64 = https://dl\.google\.com/linux/chrome/deb/.+_arm64\.deb$' \
        /tmp/chrome-build/google-chrome/.SRCINFO
    grep -Eq '^[[:space:]]*sha512sums_aarch64 = [0-9a-fA-F]{128}$' \
        /tmp/chrome-build/google-chrome/.SRCINFO
    CHROME_DEPENDENCIES="$(sed -n 's/^[[:space:]]*depends = //p' \
        /tmp/chrome-build/google-chrome/.SRCINFO | sed 's/[<>=].*$//' | sort -u)"
    [ -n "$CHROME_DEPENDENCIES" ]
    if printf '%s\n' "$CHROME_DEPENDENCIES" | grep -Eqv '^[A-Za-z0-9@._+][A-Za-z0-9@._+:-]*$'; then
        echo "AUR 配方包含无效的 Chrome 依赖" >&2
        exit 1
    fi
    pacman -S --noconfirm --needed --asdeps $CHROME_DEPENDENCIES
    runuser -u chrome-build -- bash -c \
        'cd "$1" && makepkg --cleanbuild --clean --noconfirm' _ \
        /tmp/chrome-build/google-chrome
    CHROME_PACKAGE="$(find /tmp/chrome-build/google-chrome -maxdepth 1 \
        -type f -name 'google-chrome-*.pkg.tar.*' ! -name '*.sig' -print -quit)"
    [ -n "$CHROME_PACKAGE" ]
    [ "$(find /tmp/chrome-build/google-chrome -maxdepth 1 \
        -type f -name 'google-chrome-*.pkg.tar.*' ! -name '*.sig' -print | wc -l)" -eq 1 ]
    sed -e '/^[[:space:]]*LocalFileSigLevel[[:space:]]*=/d' \
        -e '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' \
        /etc/pacman.conf > /tmp/pacman-chrome.conf
    [ "$(pacman --config /tmp/pacman-chrome.conf -Qqp "$CHROME_PACKAGE")" = "google-chrome" ]
    LC_ALL=C pacman --config /tmp/pacman-chrome.conf -Qip "$CHROME_PACKAGE" | \
        grep -Eq '^Architecture[[:space:]]*: aarch64$'
    pacman --config /tmp/pacman-chrome.conf -U --noconfirm "$CHROME_PACKAGE"
    userdel -r chrome-build
    # 仅删除本次新增且已不被其它包依赖的构建包；保留 Chrome 的运行时依赖。
    # 先移除 base-devel 元包，再逐轮处理因此变为未被依赖的新增包。
    local -a removable=()
    while [[ -s /tmp/chrome-build-packages ]]; do
        mapfile -t removable < <(
            LC_ALL=C comm -12 /tmp/chrome-build-packages \
                <( { pacman -Qtq || true; } | LC_ALL=C sort -u)
        )
        (( ${#removable[@]} > 0 )) || break
        pacman -R --noconfirm "${removable[@]}"
    done
    rm -f /tmp/chrome-build-packages /tmp/chrome-packages-before \
        /tmp/chrome-packages-after /tmp/pacman-chrome.conf
}

install_chrome() {
    # ROOTFS_DIR 用于隔离测试；实际 RootFS 构建时为空。
    [[ -n "$rootfs" ]] && return 0

    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) install_debian_chrome ;;
        fedora) install_fedora_chrome ;;
        arch|archarm|archlinux) install_arch_chrome ;;
        *)
            echo "不支持的 Chrome 发行版：${ID:-unknown}" >&2
            exit 1
            ;;
    esac
}

install_chrome
[[ -x "$chrome_binary" ]] || {
    echo "Chrome 安装完成后未找到：$chrome_binary" >&2
    exit 1
}

[[ "$display_backend" == anland-wayland ]] || exit 0

# 原生构建 Chrome 专用兼容库；源码下载和构建包清理都在此子 shell 内完成。
install_chrome_gbm() (
export LC_ALL=C

rootfs="${ROOTFS_DIR:-}"
work_dir=""
install_tmp=""
package_manager=""
packages_changed=false
compiler=()
real_gbm=""

log() { printf '[chrome-gbm] %s\n' "$*"; }
fail() { printf '[chrome-gbm] ERROR: %s\n' "$*" >&2; exit 1; }

snapshot_packages() {
    case "$package_manager" in
        apt)
            dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' |
                # Include unpacked/half-configured additions after a failed
                # install, and protect pre-existing residual config records.
                awk '$2 != "not-installed" { print $1 }' | sort -u
            ;;
        dnf) rpm -qa --qf '%{NAME}.%{ARCH}\n' | sort -u ;;
        pacman) pacman -Qq | sort -u ;;
        *) return 1 ;;
    esac
}

remove_added_packages() {
    local added=()
    snapshot_packages > "$work_dir/packages.after" || return 1
    comm -13 "$work_dir/packages.before" "$work_dir/packages.after" \
        > "$work_dir/packages.added" || return 1
    mapfile -t added < "$work_dir/packages.added"
    ((${#added[@]})) || return 0
    log "Removing only packages added for this build: ${added[*]}"
    # The package database tools below check reverse dependencies and never
    # recursively remove old packages. Do not force dependencies or autoremove.
    case "$package_manager" in
        apt) dpkg --purge -- "${added[@]}" ;;
        dnf) rpm -e -- "${added[@]}" ;;
        pacman) pacman -R --noconfirm -- "${added[@]}" ;;
    esac
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    if [[ "$packages_changed" == true ]]; then
        if ! remove_added_packages; then
            printf '[chrome-gbm] ERROR: could not remove all added build packages; no existing package was selected for removal.\n' >&2
            ((status != 0)) || status=1
        fi
    fi
    [[ -z "$install_tmp" ]] || rm -f -- "$install_tmp"
    [[ -z "$work_dir" ]] || rm -rf -- "$work_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -n "$rootfs" ]]; then
    [[ "$rootfs" == /* && -d "$rootfs" ]] ||
        fail 'ROOTFS_DIR must be an existing absolute directory'
    rootfs="$(readlink -f -- "$rootfs")"
    [[ "$rootfs" != / ]] || fail 'ROOTFS_DIR=/ is not an isolated test prefix'
else
    ((EUID == 0)) || fail 'Run as root, or set ROOTFS_DIR for an isolated build'
fi
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/dmd-chrome-gbm.XXXXXXXX")"
source_dir="$work_dir/source"
install -d -m 0755 "$source_dir/include" "$source_dir/tests"
# 固定源码版本和每个文件的 SHA-256，构建完即清理，不安装 Mesa 开发包。
fetch_source() {
    local url="$1" digest="$2" output="$3"
    curl -fL --retry 3 --connect-timeout 20 --max-time 180 "$url" -o "$output"
    printf '%s  %s\n' "$digest" "$output" | sha256sum --check --status ||
        fail "Source checksum mismatch: $url"
}
media_source="https://raw.githubusercontent.com/Goldzxcbug/droidspaces-media-decode/a4dd277f450eef75331692cc85efa1d492b9f529/vaapi-driver/gbm-compat"
fetch_source "$media_source/Makefile" \
    eaa5f8da48d18e0adaedee95da9608a5ab51e5ccc405655ea9738276ede15899 "$source_dir/Makefile"
fetch_source "$media_source/gbm_compat.c" \
    1a19697d79108e6778e80d4df315387da8698b813a3fc78a2ffb1dc929e73797 "$source_dir/gbm_compat.c"
fetch_source "$media_source/probe_gbm_compat.c" \
    6a9ea8b4ed18707c7a524bc585bd65eb3322adb0d15fc3b4f7bed1b58ebaa61f "$source_dir/probe_gbm_compat.c"
fetch_source "https://raw.githubusercontent.com/Goldzxcbug/droidspaces-media-decode/a4dd277f450eef75331692cc85efa1d492b9f529/LICENSE" \
    3bba83949fe77be5ebcfec2043b1e11839e78254063e23a0c60725717846f612 "$source_dir/LICENSE"
fetch_source "$media_source/tests/fake_gbm.c" \
    c9dbabbae3d51d6ba2c7328dcd1ee4fdfad94d4343338cb85eef3643a590cc9b "$source_dir/tests/fake_gbm.c"
fetch_source "$media_source/tests/fake_gbm.h" \
    fbede874bd12b1fc4fe9b9e1dabb0d59d72ccf1b4e5bc89ab0f6d68fc39d0339 "$source_dir/tests/fake_gbm.h"
fetch_source "$media_source/tests/test_gbm_compat.c" \
    b14c3606460c2b9c30714c139f0bf20ae0b82ae3dea8f694ada553e6c41ce022 "$source_dir/tests/test_gbm_compat.c"
fetch_source "https://gitlab.freedesktop.org/mesa/mesa/-/raw/8e87a503ebd91408c88596d1b9eeb5f4c0b2088d/src/gbm/main/gbm.h" \
    95f3b4a6ee5175c7cc5d47368d4efb100063fe49e5a6f5b19030ac2ceed73b81 "$source_dir/include/gbm.h"

select_compiler() {
    if [[ -n "${CC:-}" ]]; then
        read -r -a compiler <<< "$CC"
    elif command -v cc >/dev/null 2>&1; then
        compiler=(cc)
    else
        compiler=(gcc)
    fi
}

cat > "$work_dir/check.c" <<'EOF'
#define _GNU_SOURCE
#include <gbm.h>
#include <linux/dma-buf.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
int main(void) {
    struct dma_buf_sync sync = { .flags = DMA_BUF_SYNC_READ };
    pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    (void)sync;
    (void)dlerror();
    return pthread_mutex_destroy(&lock);
}
EOF

can_build() {
    select_compiler
    command -v "${compiler[0]}" >/dev/null 2>&1 &&
        command -v make >/dev/null 2>&1 &&
        "${compiler[@]}" -std=c11 -Wall -Wextra -Werror \
            -I"$source_dir/include" "$work_dir/check.c" -ldl -lpthread \
            -o "$work_dir/check" > "$work_dir/compiler.log" 2>&1
}

package_installed() {
    case "$package_manager" in
        apt) [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" == installed ]] ;;
        dnf) rpm -q -- "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Qq -- "$1" >/dev/null 2>&1 ;;
    esac
}

install_build_packages() {
    local required=() missing=() package
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) package_manager=apt; required=(gcc make libc6-dev) ;;
        fedora) package_manager=dnf; required=(gcc make glibc-devel kernel-headers) ;;
        arch|archarm|archlinux) package_manager=pacman; required=(gcc make glibc linux-api-headers) ;;
        *) fail "No build dependency installer for ${ID:-unknown}" ;;
    esac
    for package in "${required[@]}"; do
        package_installed "$package" || missing+=("$package")
    done
    ((${#missing[@]})) || fail 'Compiler/header check failed although build packages are installed'
    snapshot_packages > "$work_dir/packages.before"
    packages_changed=true
    log "Installing missing build packages: ${missing[*]}"
    case "$package_manager" in
        apt)
            apt-get update
            apt-get install -y --no-install-recommends -- "${missing[@]}"
            ;;
        # Fedora 43 的 DNF5 不支持此处的 --；包名均来自上面的固定列表。
        dnf) dnf install -y --setopt=install_weak_deps=False "${missing[@]}" ;;
        pacman) pacman -S --noconfirm --needed --asdeps -- "${missing[@]}" ;;
    esac
}

if ! can_build; then
    if [[ -n "$rootfs" ]]; then
        [[ ! -f "$work_dir/compiler.log" ]] || cat "$work_dir/compiler.log" >&2
        fail 'Isolated build needs a working host CC, make, libc and Linux headers; package installation is disabled'
    fi
    install_build_packages
    if ! can_build; then
        [[ ! -f "$work_dir/compiler.log" ]] || cat "$work_dir/compiler.log" >&2
        fail 'Compiler/header check still fails after installing build packages'
    fi
fi

try_real_library() {
    local candidate="$1" resolved=""
    [[ "$candidate" == /* ]] || return 1
    if [[ -n "$rootfs" && -f "$rootfs$candidate" ]]; then
        resolved="$(readlink -f -- "$rootfs$candidate")" || return 1
        if [[ "$resolved" == "$rootfs/"* ]]; then
            resolved="${resolved#"$rootfs"}"
        fi
    elif [[ -f "$candidate" ]]; then
        # Isolated builds may use the host library's target path. Mock checks
        # override it and never open a real render node.
        resolved="$(readlink -f -- "$candidate")" || return 1
    else
        return 1
    fi
    [[ "$resolved" =~ ^/[A-Za-z0-9_./+:-]+$ ]] || return 1
    [[ "$resolved" != /usr/local/lib/droidspaces-gbm/* ]] || return 1
    real_gbm="$resolved"
}

if [[ -n "${DMD_CHROME_REAL_GBM:-}" ]]; then
    try_real_library "$DMD_CHROME_REAL_GBM" ||
        fail "Invalid real GBM library: $DMD_CHROME_REAL_GBM"
else
    candidates=()
    if [[ -z "$rootfs" ]] && command -v ldconfig >/dev/null 2>&1; then
        # Read the cache only. Do not register the compatibility directory.
        ldconfig -p > "$work_dir/ldconfig.list" 2>/dev/null || true
        mapfile -t candidates < <(awk '$1 == "libgbm.so.1" { print $NF }' "$work_dir/ldconfig.list")
    fi
    candidates+=(/usr/lib/aarch64-linux-gnu/libgbm.so.1 /usr/lib64/libgbm.so.1
                 /usr/lib/libgbm.so.1 /lib/aarch64-linux-gnu/libgbm.so.1
                 /lib64/libgbm.so.1 /lib/libgbm.so.1)
    for candidate in "${candidates[@]}"; do
        if try_real_library "$candidate"; then break; fi
    done
    [[ -n "$real_gbm" ]] || fail 'Cannot locate the real system libgbm.so.1'
fi

log "Building with ${compiler[*]}, forwarding to $real_gbm"
# 上游 Makefile 的立即展开会探测系统 GBM；本次构建只使用已校验的公共头。
sed -i '/^GBM_CFLAGS := /d' "$source_dir/Makefile"
make -C "$source_dir" BUILD="$work_dir/build" CC="${compiler[*]}" \
    GBM_CFLAGS="-I$source_dir/include" REAL_GBM="$real_gbm" all check

destination="$rootfs/usr/local/lib/droidspaces-gbm"
install -d -m 0755 -- "$destination"
install_tmp="$(mktemp "$destination/.libgbm.so.1.XXXXXXXX")"
install -m 0755 -- "$work_dir/build/libgbm.so.1" "$install_tmp"
install -D -m 0644 "$source_dir/LICENSE" "$rootfs/usr/local/share/licenses/droidspaces-chrome-gbm/LICENSE"
mv -fT -- "$install_tmp" "$destination/libgbm.so.1"
install_tmp=""
log "Installed $destination/libgbm.so.1; system GBM and global loader configuration are unchanged"
)

# 隔离测试可提供无副作用的安装器；正常镜像构建始终使用上面的实现。
if [[ -n "$rootfs" && -n "${DMD_CHROME_GBM_INSTALLER:-}" ]]; then
    "$DMD_CHROME_GBM_INSTALLER"
else
    install_chrome_gbm
fi

install -d -m 0755 "$wrapper_dir"
temporary_wrapper="$(mktemp "${wrapper}.tmp.XXXXXXXX")"
trap 'rm -f -- "${temporary_wrapper:-}" "${temporary_desktop:-}"' EXIT
cat > "$temporary_wrapper" <<'CHROME_LAUNCHER'
#!/bin/bash
# One Chrome entrypoint for menus and CLI. No Python or global Mesa changes.
set -euo pipefail
CHROME_LAUNCHER
input_method=
if [[ "${ENABLE_srf_ARG:-false}" == true ]]; then
    case "$desktop" in
        anland-next) input_method=gtk ;;
        *)           input_method=wayland ;;
    esac
fi
printf 'input_method=%q\n' "$input_method" >> "$temporary_wrapper"
cat >> "$temporary_wrapper" <<'CHROME_LAUNCHER'

enabled_keys=(AcceleratedVideoDecoder AcceleratedVideoDecodeLinuxGL AcceleratedVideoEncoder)
enabled_values=("${enabled_keys[@]}")
disabled_keys=()
disabled_values=()
remaining=()
positionals=()
ozone_platform=
ozone_hint=

# Keep order while replacing an existing feature's trial/parameter value.
# Indexed arrays avoid evaluating caller-controlled associative subscripts.
put_feature() {
    local destination=$1 key=$2 value=$3 index
    local -n keys_ref="${destination}_keys" values_ref="${destination}_values"
    for index in "${!keys_ref[@]}"; do
        if [[ ${keys_ref[index]} == "$key" ]]; then
            values_ref[index]=$value
            return 0
        fi
    done
    keys_ref+=("$key")
    values_ref+=("$value")
}

parse_features() {
    local destination=$1 rest=$2 item key more
    while :; do
        item=${rest%%,*}
        more=false
        if [[ $rest == *,* ]]; then
            rest=${rest#*,}
            more=true
        fi
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        if [[ -n $item ]]; then
            key=${item%%[<:]*}
            put_feature "$destination" "$key" "$item"
        fi
        [[ $more == true ]] || break
    done
}

while (($#)); do
    argument=$1
    if [[ $argument == -- ]]; then
        positionals=("$@")
        break
    fi
    case $argument in
        --enable-features|--disable-features)
            value=''
            # Support both switch=value and switch value. Missing values must
            # not consume another switch or the literal -- separator.
            if (($# >= 2)) && [[ $2 != -* ]]; then
                value=$2
                shift
            fi
            if [[ $argument == --enable-features ]]; then
                parse_features enabled "$value"
            else
                parse_features disabled "$value"
            fi
            ;;
        --enable-features=*) parse_features enabled "${argument#*=}" ;;
        --disable-features=*) parse_features disabled "${argument#*=}" ;;
        --ozone-platform=*) ozone_platform=${argument#*=}; remaining+=("$argument") ;;
        --ozone-platform-hint=*) ozone_hint=${argument#*=}; remaining+=("$argument") ;;
        *) remaining+=("$argument") ;;
    esac
    shift
done

supplied() {
    local name=$1 argument
    for argument in "${remaining[@]}"; do
        if [[ $argument == "$name" || $argument == "$name="* ]]; then
            return 0
        fi
    done
    return 1
}

defaults=()
if ! supplied --ozone-platform && ! supplied --ozone-platform-hint; then
    defaults+=(--ozone-platform=wayland)
fi
if [[ -n "$input_method" ]]; then
    if [[ "${ozone_platform:-$ozone_hint}" == x11 ]]; then
        export GTK_IM_MODULE="${GTK_IM_MODULE:-fcitx}"
    elif ! supplied --disable-wayland-ime && ! supplied --gtk-version; then
        if [[ "$input_method" == gtk ]] && ! supplied --enable-wayland-ime && ! supplied --wayland-text-input-version; then
            export GTK_IM_MODULE="${GTK_IM_MODULE:-fcitx}"
            defaults+=(--gtk-version=4)
        else
            supplied --enable-wayland-ime || defaults+=(--enable-wayland-ime)
            supplied --wayland-text-input-version || defaults+=(--wayland-text-input-version=3)
        fi
    fi
fi
if ! supplied --render-node-override; then
    defaults+=(--render-node-override=/dev/dri/renderD128)
fi
if ! supplied --ignore-gpu-blocklist; then
    defaults+=(--ignore-gpu-blocklist)
fi
if [[ ${DMD_VULKAN:-on} != off ]] && ! supplied --use-angle && ! supplied --use-gl; then
    defaults+=(--use-angle=vulkan)
fi
if ! supplied --gmb-readback-from-texture-disabled-for-debugging; then
    defaults+=(--gmb-readback-from-texture-disabled-for-debugging)
fi

enabled_list=''
for index in "${!enabled_keys[@]}"; do
    disabled=false
    for key in "${disabled_keys[@]}"; do
        if [[ ${enabled_keys[index]} == "$key" ]]; then
            disabled=true
            break
        fi
    done
    if [[ $disabled == false ]]; then
        [[ -z $enabled_list ]] || enabled_list+=,
        enabled_list+=${enabled_values[index]}
    fi
done
[[ -z $enabled_list ]] || defaults+=("--enable-features=$enabled_list")
disabled_list=''
for value in "${disabled_values[@]}"; do
    [[ -z $disabled_list ]] || disabled_list+=,
    disabled_list+=$value
done
[[ -z $disabled_list ]] || defaults+=("--disable-features=$disabled_list")

export MESA_LOADER_DRIVER_OVERRIDE=msm
compat=${DMD_GBM_COMPAT_DIR-/usr/local/lib/droidspaces-gbm}
if [[ $compat == /* && $compat != *:* && -r "$compat/libgbm.so.1" ]]; then
    library_path=$compat
    if [[ ${LD_LIBRARY_PATH+x} ]]; then
        rest=$LD_LIBRARY_PATH
        while :; do
            entry=${rest%%:*}
            if [[ $entry != "$compat" ]]; then
                library_path+=:$entry
            fi
            [[ $rest == *:* ]] || break
            rest=${rest#*:}
        done
    fi
    export LD_LIBRARY_PATH=$library_path
fi

# Never resolve this through PATH: aliases can point back at this launcher.
target=${DMD_CHROME_REAL_BINARY-/opt/google/chrome/google-chrome}
if [[ $target != /* ]]; then
    printf '%s\n' 'google-chrome: target must name an absolute vendor executable' >&2
    exit 126
fi
case $target in
    /usr/local/bin/google-chrome|/usr/local/bin/google-chrome-stable|/usr/bin/google-chrome|/usr/bin/google-chrome-stable)
        printf '%s\n' 'google-chrome: target must be the vendor path, not a public PATH alias' >&2
        exit 126 ;;
esac
if [[ $target -ef ${BASH_SOURCE[0]} ]]; then
    printf '%s\n' 'google-chrome: target resolves to this launcher recursively' >&2
    exit 126
fi

# A shell-quoted preview is diagnostic only; it never executes the target.
if [[ ${DMD_CHROME_LAUNCH_DRY_RUN:-} == 1 ]]; then
    printf 'exec env MESA_LOADER_DRIVER_OVERRIDE=%q' "$MESA_LOADER_DRIVER_OVERRIDE"
    if [[ ${LD_LIBRARY_PATH+x} ]]; then
        printf ' LD_LIBRARY_PATH=%q' "$LD_LIBRARY_PATH"
    fi
    if [[ -n "$input_method" && -v GTK_IM_MODULE ]]; then
        printf ' GTK_IM_MODULE=%q' "$GTK_IM_MODULE"
    fi
    printf ' %q' "$target" "${defaults[@]}" "${remaining[@]}" "${positionals[@]}"
    printf '\n'
    exit 0
fi
if [[ ! -f $target || ! -x $target ]]; then
    printf 'google-chrome: vendor executable is missing or not executable: %s\n' "$target" >&2
    exit 126
fi
exec "$target" "${defaults[@]}" "${remaining[@]}" "${positionals[@]}"
CHROME_LAUNCHER
chmod 0755 "$temporary_wrapper"
mv -f -- "$temporary_wrapper" "$wrapper"
temporary_wrapper=""
ln -sfn -- google-chrome "${wrapper_dir}/google-chrome-stable"

# /usr/local/share 优先于包管理的 /usr/share；厂商升级不会覆盖这里。
# 若构建指定了桌面用户，再生成用户级同名覆盖，保持菜单与命令行走同一入口。
local_apps="${rootfs}/usr/local/share/applications"
user_apps=""
user_uid=""
user_gid=""
if [[ -n "$username" ]]; then
    passwd_entry=""
    if [[ -f "${rootfs}/etc/passwd" ]]; then
        passwd_entry="$(awk -F: -v user="$username" '$1 == user { print; exit }' "${rootfs}/etc/passwd")"
    fi
    if [[ -n "$passwd_entry" ]]; then
        IFS=: read -r _ _ user_uid user_gid _ user_home _ <<< "$passwd_entry"
        [[ "$user_home" == /* && "$user_uid" =~ ^[0-9]+$ && "$user_gid" =~ ^[0-9]+$ ]] || {
            echo "无效的 Chrome 桌面用户记录：$username" >&2
            exit 1
        }
    elif [[ -n "$rootfs" ]]; then
        # ROOTFS_DIR 夹具不必创建系统账号；实际构建必须使用已有账号。
        user_home="/home/$username"
    else
        echo "Chrome 桌面用户不存在：$username" >&2
        exit 1
    fi
    user_apps="${rootfs}${user_home}/.local/share/applications"
    install -d -m 0755 "$user_apps"
    if [[ -z "$rootfs" ]]; then
        chown "$user_uid:$user_gid" "${user_home}/.local" "${user_home}/.local/share" "$user_apps"
    fi
fi
install -d -m 0755 "$local_apps"

write_desktop_override() {
    local input="$1" output="$2"
    temporary_desktop="$(mktemp "${output}.tmp.XXXXXXXX")"
    awk -v launcher="/usr/local/bin/google-chrome" '
        /^(Exec|TryExec)=/ {
            # 只替换可执行文件；保留全部参数、URL 占位符、动作及翻译元数据。
            if (match($0, /^(Exec|TryExec)=(\/usr\/(local\/)?bin\/google-chrome(-stable)?|\/opt\/google\/chrome\/(google-chrome|chrome))([[:space:]]|$)/)) {
                sub(/=(\/usr\/(local\/)?bin\/google-chrome(-stable)?|\/opt\/google\/chrome\/(google-chrome|chrome))/, "=" launcher)
            }
        }
        { print }
    ' "$input" > "$temporary_desktop"
    chmod 0644 "$temporary_desktop"
    if [[ -z "$rootfs" && -n "$user_apps" && "$output" == "$user_apps/"* ]]; then
        chown "$user_uid:$user_gid" "$temporary_desktop"
    fi
    mv -f -- "$temporary_desktop" "$output"
    temporary_desktop=""
}

for desktop_name in google-chrome.desktop com.google.Chrome.desktop; do
    vendor_desktop="${rootfs}/usr/share/applications/$desktop_name"
    [[ -f "$vendor_desktop" ]] || continue
    write_desktop_override "$vendor_desktop" "$local_apps/$desktop_name"
    if [[ -n "$user_apps" ]]; then
        # 已有用户覆盖保留其参数、动作和元数据；新用户从厂商文件生成。
        user_desktop="$user_apps/$desktop_name"
        desktop_input="$vendor_desktop"
        [[ ! -f "$user_desktop" ]] || desktop_input="$user_desktop"
        write_desktop_override "$desktop_input" "$user_desktop"
    fi
done
