#!/usr/bin/env bash
set -uo pipefail

GPU_ENV_FILE="${DROIDSPACES_GPU_ENV_FILE:-/etc/environment}"
GPU_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
GPU_LANG="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
GPU_GREEN='' GPU_YELLOW='' GPU_RESET=''
if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
    GPU_GREEN=$'\033[32m' GPU_YELLOW=$'\033[93m' GPU_RESET=$'\033[0m'
fi
gpu_msg() { if [[ "${GPU_LANG,,}" == zh* ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

gpu_gl_label() {
    case "$1" in
        kgsl) printf 'OpenGL → Freedreno KGSL → GPU' ;;
        zink) printf 'OpenGL → Zink → Vulkan' ;;
        llvmpipe|softpipe) printf 'OpenGL → %s → CPU' "$1" ;;
        '') gpu_msg '未指定' 'Not specified' ;;
        *) printf '%s' "$1" ;;
    esac
}
gpu_vk_label() {
    if [[ -f "$1" ]]; then
        if gpu_manifest_matches "$1" turnip; then printf 'Vulkan → Turnip → GPU'; return; fi
        if gpu_manifest_matches "$1" lavapipe; then printf 'Vulkan → Lavapipe → CPU'; return; fi
    fi
    case "$1" in
        *freedreno*) printf 'Vulkan → Turnip → GPU' ;;
        *lvp*) printf 'Vulkan → Lavapipe → CPU' ;;
        '') gpu_msg '未指定' 'Not specified' ;;
        *) printf '%s' "$1" ;;
    esac
}

gpu_read_saved() {
    local line key value
    GPU_LOADER='' GPU_GALLIUM='' GPU_SOFTWARE='' GPU_ICD='' GPU_OLD_ICD=''
    [[ ! -e "$GPU_ENV_FILE" || -r "$GPU_ENV_FILE" ]] || return 1
    [[ -r "$GPU_ENV_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[2]}" value="${BASH_REMATCH[3]}"
            value="${value%"${value##*[![:space:]]}"}"
            value="${value#\"}"; value="${value%\"}"
            value="${value#\'}"; value="${value%\'}"
            case "$key" in
                MESA_LOADER_DRIVER_OVERRIDE) GPU_LOADER="$value" ;;
                GALLIUM_DRIVER) GPU_GALLIUM="$value" ;;
                LIBGL_ALWAYS_SOFTWARE) GPU_SOFTWARE="$value" ;;
                VK_DRIVER_FILES) GPU_ICD="$value" ;;
                VK_ICD_FILENAMES) GPU_OLD_ICD="$value" ;;
            esac
        fi
    done < "$GPU_ENV_FILE"
}

gpu_status() {
    local scope="$1" api="$2" loader gallium software icd
    if [[ "$scope" == saved ]]; then
        gpu_read_saved || { gpu_msg '无法读取配置' 'Configuration unreadable'; return 1; }
        loader="$GPU_LOADER" gallium="$GPU_GALLIUM" software="$GPU_SOFTWARE" icd="${GPU_ICD:-$GPU_OLD_ICD}"
    else
        loader="${MESA_LOADER_DRIVER_OVERRIDE:-}" gallium="${GALLIUM_DRIVER:-}" software="${LIBGL_ALWAYS_SOFTWARE:-}" icd="${VK_DRIVER_FILES:-${VK_ICD_FILENAMES:-}}"
    fi
    if [[ "$api" == opengl ]]; then
        if [[ "$software" == true || "$software" == 1 ]]; then
            gpu_gl_label "${gallium:-llvmpipe}"
        else
            gpu_gl_label "${gallium:-$loader}"
        fi
    else
        gpu_vk_label "$icd"
    fi
}

gpu_driver_file() {
    local name="$1" file
    for file in /usr/lib/aarch64-linux-gnu/dri/$name /usr/lib64/dri/$name /usr/lib/dri/$name; do
        [[ -f "$file" ]] && return 0
    done
    return 1
}
gpu_manifest_matches() {
    local path="$1" mode="$2" driver
    case "$mode" in turnip) driver=freedreno ;; lavapipe) driver=lvp ;; *) return 1 ;; esac
    [[ "$path" == /* && -f "$path" && -r "$path" ]] || return 1
    # Colon separates paths in Vulkan and the remaining characters cannot be
    # represented safely in /etc/environment without shell-like expansion.
    [[ "$path" != *:* && "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *'"'* && "$path" != *'\'* && "$path" != *'$'* && "$path" != *'`'* ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$path" "$driver" <<'PY'
import json, os, sys
try:
    with open(sys.argv[1], encoding='utf-8') as source:
        icd = json.load(source)['ICD']
    library = os.path.basename(icd['library_path'])
    arch = str(icd.get('library_arch', '64'))
    prefix = 'libvulkan_' + sys.argv[2] + '.so'
    ok = (library == prefix or library.startswith(prefix + '.')) and arch == '64'
except (OSError, ValueError, TypeError, KeyError, AttributeError):
    ok = False
sys.exit(0 if ok else 1)
PY
    elif command -v jq >/dev/null 2>&1; then
        jq -e --arg driver "$driver" '
            .ICD as $i | ($i.library_path | type == "string") and
            (($i.library_path | split("/") | last) | startswith("libvulkan_" + $driver + ".so")) and
            (($i.library_arch // "64" | tostring) == "64")
        ' "$path" >/dev/null 2>&1
    else
        printf '%s\n' "$(gpu_msg '需要 python3 或 jq 来检查 Vulkan 清单。' 'python3 or jq is required to validate Vulkan manifests.')" >&2
        return 1
    fi
}

gpu_find_manifests() {
    local mode="$1" directory file base group
    local -a directories=() bases=()
    local -A seen=()
    GPU_MANIFESTS=()
    # Follow the loader's XDG order, plus common build/install prefixes.
    bases+=("${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}")
    IFS=: read -r -a group <<< "${XDG_CONFIG_DIRS:-/etc/xdg}"
    bases+=("${group[@]}" /etc /usr/local/etc "${XDG_DATA_HOME:-${HOME:-/nonexistent}/.local/share}")
    IFS=: read -r -a group <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    bases+=("${group[@]}" /usr/local/share /usr/share)
    for base in "${bases[@]}"; do
        [[ "$base" == /* ]] || continue
        directory="${base%/}/vulkan/icd.d"
        [[ -d "$directory" ]] || continue
        for file in "$directory"/*.json; do
            [[ -f "$file" ]] || continue
            file="$(readlink -f -- "$file")" || continue
            [[ -z "${seen[$file]:-}" ]] || continue
            seen["$file"]=1
            gpu_manifest_matches "$file" "$mode" && GPU_MANIFESTS+=("$file")
        done
    done
    return 0
}

gpu_choose_manifest() {
    local mode="$1" choice path index
    GPU_SELECTED_ICD=''
    gpu_find_manifests "$mode"
    if ((${#GPU_MANIFESTS[@]} == 1)); then
        GPU_SELECTED_ICD="${GPU_MANIFESTS[0]}"
        printf '%s: %s\n' "$(gpu_msg '找到 Vulkan 清单' 'Found Vulkan manifest')" "$GPU_SELECTED_ICD"
        return 0
    fi
    if ((${#GPU_MANIFESTS[@]} > 1)); then
        printf '%s\n' "$(gpu_msg '发现多个 Vulkan 清单，请选择：' 'Multiple Vulkan manifests found; select one:')"
        for index in "${!GPU_MANIFESTS[@]}"; do
            printf '  [%s] %s\n' "$((index + 1))" "${GPU_MANIFESTS[$index]}"
        done
    else
        printf '%s\n' "$(gpu_msg '标准目录中没有找到匹配的 Vulkan 清单。' 'No matching Vulkan manifest found in standard directories.')"
    fi
    printf '%s\n' "$(gpu_msg '输入编号，或输入自定义 JSON 文件的绝对路径；输入 0 返回。' 'Enter a number or an absolute path to a custom JSON file; enter 0 to go back.')"
    printf '%s: ' "$(gpu_msg '请选择' 'Select')"
    IFS= read -r choice || return 1
    [[ "$choice" != 0 && -n "$choice" ]] || return 1
    if [[ "$choice" =~ ^[0-9]+$ && ${#choice} -le 6 ]] && ((10#$choice > 0 && 10#$choice <= ${#GPU_MANIFESTS[@]})); then
        path="${GPU_MANIFESTS[$((10#$choice - 1))]}"
    else
        path="$choice"
    fi
    if ! gpu_manifest_matches "$path" "$mode"; then
        printf '%s\n' "$(gpu_msg '清单无效或驱动类型不匹配。' 'Invalid manifest or incorrect driver type.')" >&2
        return 1
    fi
    GPU_SELECTED_ICD="$(readlink -f -- "$path")" || return 1
}

gpu_save() {
    local api="$1" mode="$2" icd="${3:-}" temporary pattern
    case "$api:$mode" in
        opengl:kgsl) gpu_driver_file kgsl_dri.so || return 1 ;;
        opengl:zink) gpu_driver_file zink_dri.so || return 1 ;;
        opengl:llvmpipe|opengl:softpipe) gpu_driver_file swrast_dri.so || return 1 ;;
        vulkan:turnip|vulkan:lavapipe) gpu_manifest_matches "$icd" "$mode" || return 1 ;;
        vulkan:auto) : ;;
        *) return 1 ;;
    esac
    [[ ! -L "$GPU_ENV_FILE" && ( ! -e "$GPU_ENV_FILE" || -f "$GPU_ENV_FILE" ) ]] || return 1
    temporary="$(mktemp "${GPU_ENV_FILE}.tmp.XXXXXXXX")" || return 1
    if [[ -f "$GPU_ENV_FILE" ]]; then
        if ! cp -p -- "$GPU_ENV_FILE" "$temporary" || ! cp -p -- "$GPU_ENV_FILE" "${GPU_ENV_FILE}.droidspaces-gpu.bak"; then
            rm -f -- "$temporary"; return 1
        fi
    else
        chmod 0644 "$temporary" || { rm -f -- "$temporary"; return 1; }
    fi
    if [[ "$api" == opengl ]]; then
        pattern='MESA_LOADER_DRIVER_OVERRIDE|GALLIUM_DRIVER|LIBGL_ALWAYS_SOFTWARE'
    else
        pattern='VK_DRIVER_FILES|VK_ICD_FILENAMES'
    fi
    if [[ -f "$GPU_ENV_FILE" ]] && ! awk -v keys="$pattern" '
        $0 ~ "^[[:space:]]*(export[[:space:]]+)?(" keys ")[[:space:]]*=" { next }
        { print }
    ' "$GPU_ENV_FILE" > "$temporary"; then
        rm -f -- "$temporary"; return 1
    fi
    if ! {
        case "$api:$mode" in
            opengl:kgsl|opengl:zink) printf 'MESA_LOADER_DRIVER_OVERRIDE=%s\nGALLIUM_DRIVER=%s\n' "$mode" "$mode" ;;
            opengl:llvmpipe|opengl:softpipe) printf 'LIBGL_ALWAYS_SOFTWARE=true\nGALLIUM_DRIVER=%s\n' "$mode" ;;
            vulkan:auto) : ;;
            vulkan:*) printf 'VK_DRIVER_FILES="%s"\n' "$icd" ;;
        esac
    } >> "$temporary"; then
        rm -f -- "$temporary"; return 1
    fi
    mv -f -- "$temporary" "$GPU_ENV_FILE" || { rm -f -- "$temporary"; return 1; }
}

gpu_option() {
    local number="$1" label="$2" description="$3" color="$GPU_YELLOW"
    [[ "$label" != "$GPU_CURRENT" ]] || color="$GPU_GREEN"
    printf '  %b[%s] %s%b\n      %s\n' "$color" "$number" "$label" "$GPU_RESET" "$description"
}

gpu_menu() {
    local api choice mode status icd GPU_CURRENT
    while :; do
        [[ ! -t 1 ]] || printf '\033[2J\033[H'
        printf '\n%s\n\n' "$(gpu_msg '切换 OpenGL / Vulkan 路径' 'Switch OpenGL / Vulkan paths')"
        printf '  OpenGL — %s: %s\n' "$(gpu_msg '下次启动' 'Next start')" "$(gpu_status saved opengl)"
        GPU_CURRENT="$(gpu_status current opengl)"
        gpu_option 1 "$(gpu_gl_label kgsl)" "$(gpu_msg 'Freedreno 使用 KGSL 后端访问 GPU。' 'Freedreno accesses the GPU through KGSL.')"
        gpu_option 2 "$(gpu_gl_label zink)" "$(gpu_msg '将 OpenGL 转为 Vulkan，使用所选的 Vulkan 驱动。' 'Translate OpenGL to Vulkan using the selected Vulkan driver.')"
        printf '      %s\n' "$(gpu_msg '通常效率可能较低，但兼容性可能更好；具体取决于应用和驱动。' 'Performance may be lower and compatibility may be better, depending on the application and drivers.')"
        gpu_option 3 "$(gpu_gl_label llvmpipe)" "$(gpu_msg 'CPU 软件渲染，可用于排查问题。' 'CPU software rendering for troubleshooting.')"
        gpu_option 4 "$(gpu_gl_label softpipe)" "$(gpu_msg 'CPU 参考软件渲染，主要用于调试。' 'CPU reference renderer, primarily for debugging.')"
        printf '\n  Vulkan — %s: %s\n' "$(gpu_msg '下次启动' 'Next start')" "$(gpu_status saved vulkan)"
        GPU_CURRENT="$(gpu_status current vulkan)"
        gpu_option 5 "$(gpu_vk_label freedreno)" "$(gpu_msg '使用 Turnip Vulkan 驱动访问 Adreno GPU。' 'Use Turnip Vulkan to access the Adreno GPU.')"
        gpu_option 6 "$(gpu_vk_label lvp)" "$(gpu_msg 'Lavapipe 使用 CPU 软件渲染 Vulkan。' 'Lavapipe renders Vulkan on the CPU.')"
        printf '  %b[7] %s%b\n      %s\n' "$GPU_YELLOW" "$(gpu_msg '清除 Vulkan 驱动指定（自动发现）' 'Clear Vulkan driver override (automatic discovery)')" "$GPU_RESET" \
            "$(gpu_msg '清除本配置中的驱动指定，其他环境设置仍可能影响结果。' 'Clear driver overrides from this configuration; other environment settings may still affect discovery.')"
        printf '  [0] %s\n\n' "$(gpu_msg '返回' 'Back')"
        printf '%s\n' "$(gpu_msg '保存后请重启容器。已安装驱动不代表硬件一定支持。' 'Restart the container after saving. Installed drivers may not support this hardware.')"
        printf '%s: ' "$(gpu_msg '请选择' 'Select')"
        IFS= read -r choice || return
        case "$choice" in
            1) api=opengl; mode=kgsl ;; 2) api=opengl; mode=zink ;;
            3) api=opengl; mode=llvmpipe ;; 4) api=opengl; mode=softpipe ;;
            5) api=vulkan; mode=turnip ;; 6) api=vulkan; mode=lavapipe ;; 7) api=vulkan; mode=auto ;;
            0|q|Q) return ;; *) continue ;;
        esac
        icd=''
        if [[ "$api" == vulkan && "$mode" != auto ]]; then
            gpu_choose_manifest "$mode" || continue
            icd="$GPU_SELECTED_ICD"
        fi
        if ((EUID == 0)); then
            gpu_save "$api" "$mode" "$icd"; status=$?
        elif command -v sudo >/dev/null 2>&1; then
            sudo -- env "DROIDSPACES_GPU_ENV_FILE=$GPU_ENV_FILE" bash "$GPU_SCRIPT" --set "$api" "$mode" "$icd"; status=$?
        else
            status=1
        fi
        if ((status == 0)); then
            printf '\n%s\n' "$(gpu_msg '配置已保存，请重启容器后使用。' 'Configuration saved. Restart the container to apply it.')"
        else
            printf '\n%s\n' "$(gpu_msg '保存失败：请检查 root 权限、驱动文件和配置文件。' 'Save failed: check root access, driver files and configuration.')"
        fi
        printf '%s' "$(gpu_msg '按 Enter 继续...' 'Press Enter to continue...')"
        IFS= read -r choice || return
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --status)
            [[ $# == 3 && ( "$2" == current || "$2" == saved ) && ( "$3" == opengl || "$3" == vulkan ) ]] || exit 2
            gpu_status "$2" "$3" ;;
        --set)
            [[ ( $# == 3 || $# == 4 ) && $EUID == 0 ]] || exit 2
            gpu_save "$2" "$3" "${4:-}" ;;
        ""|opengl|vulkan) [[ $# -le 1 ]] || exit 2; gpu_menu ;;
        *) printf '%s\n' 'Usage: droidspaces-gpu | --status current|saved opengl|vulkan | --set opengl|vulkan MODE [ICD_JSON]' >&2; exit 2 ;;
    esac
fi
