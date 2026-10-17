#!/usr/bin/env bash
set -euo pipefail

readonly RELEASE_REPOSITORY="${DROIDSPACES_TUI_REPOSITORY:-Goldzxcbug/droidspaces-package}"
readonly RELEASE_TAG="Gold-bug-tui"
readonly MANIFEST_NAME="Gold-bug-tui-manifest"
readonly GITHUB_API_URL="${DROIDSPACES_TUI_API_URL:-https://api.github.com}"
readonly GITHUB_DOWNLOAD_BASE="${DROIDSPACES_TUI_GITHUB_BASE:-https://github.com/$RELEASE_REPOSITORY/releases/download}"
readonly GITHUB_PROXY_BASE="${DROIDSPACES_TUI_PROXY_BASE:-https://gh-proxy.com/https://github.com/$RELEASE_REPOSITORY/releases/download}"
readonly CNB_DOWNLOAD_BASE="${DROIDSPACES_TUI_CNB_BASE:-https://cnb.cool/goldzxcbug/droidspaces-package/-/releases/download}"
readonly TUI_TARGET="/usr/local/bin/droidspaces-tui"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
DOWNLOAD_SOURCE="auto"
UPDATE_SCOPE="all"
CHECK_ONLY=false
ASSUME_YES=false
WORK_DIR=""
API_BEFORE=""
API_AFTER=""
MANIFEST_PATH=""
METADATA_SOURCE=""
CHANGED_COUNT=0

declare -a ORIGINAL_ARGUMENTS=("$@")
declare -a ASSET_NAMES=()
declare -a ASSET_SHA256=()
declare -a ASSET_SIZES=()
declare -a ASSET_ROLES=()
declare -a ASSET_TARGETS=()
declare -a SELECTED_INDEXES=()

die() {
    printf 'install-tui: %s\n' "$1" >&2
    exit 1
}

log() {
    printf '[droidspaces-tui] %s\n' "$1"
}

usage() {
    cat <<'EOF'
用法: install-tui.sh [选项]

安装或更新 Droidspaces TUI 及其管理的安装脚本。

  --source auto|github|proxy|cnb  选择附件下载源（默认：auto）
  --only tui|scripts|all         只更新 TUI、受管脚本或全部（默认：all）
  --check                        只检查，不写入系统
  -y, --yes                      不询问，直接安装
  -h, --help                     显示帮助

固定 Release：
  https://github.com/Goldzxcbug/droidspaces-package/releases/tag/Gold-bug-tui
EOF
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --source)
                (($# >= 2)) || die '--source 缺少参数。'
                DOWNLOAD_SOURCE="${2,,}"
                shift 2
                ;;
            --source=*)
                DOWNLOAD_SOURCE="${1#*=}"
                DOWNLOAD_SOURCE="${DOWNLOAD_SOURCE,,}"
                shift
                ;;
            --only)
                (($# >= 2)) || die '--only 缺少参数。'
                UPDATE_SCOPE="${2,,}"
                shift 2
                ;;
            --only=*)
                UPDATE_SCOPE="${1#*=}"
                UPDATE_SCOPE="${UPDATE_SCOPE,,}"
                shift
                ;;
            --check)
                CHECK_ONLY=true
                shift
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *) die "不支持的参数：$1" ;;
        esac
    done

    case "$DOWNLOAD_SOURCE" in
        1) DOWNLOAD_SOURCE=github ;;
        2) DOWNLOAD_SOURCE=proxy ;;
        3) DOWNLOAD_SOURCE=cnb ;;
    esac
    case "$DOWNLOAD_SOURCE" in
        auto|github|proxy|cnb) ;;
        *) die "不支持的下载源：$DOWNLOAD_SOURCE" ;;
    esac
    case "$UPDATE_SCOPE" in
        tui|scripts|all) ;;
        *) die "不支持的更新范围：$UPDATE_SCOPE" ;;
    esac
}

require_commands() {
    local command_name
    for command_name in awk bash chmod cp curl date dirname install ln mkdir mktemp mv readlink rm rmdir sha256sum stat; do
        command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
    done
}

json_parser_available() {
    command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1
}

ensure_root() {
    ((EUID == 0)) && return
    command -v sudo >/dev/null 2>&1 || die '安装需要 root 权限，且系统未安装 sudo。'
    exec sudo --preserve-env=LANG,LC_ALL,LC_MESSAGES -- bash "$SCRIPT_PATH" "${ORIGINAL_ARGUMENTS[@]}"
}

fetch_release_metadata() {
    local output="$1"
    local -a headers=(
        --header 'Accept: application/vnd.github+json'
        --header 'X-GitHub-Api-Version: 2022-11-28'
        --header 'User-Agent: droidspaces-tui-installer'
    )
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        headers+=(--header "Authorization: Bearer $GITHUB_TOKEN")
    fi
    curl --fail --silent --show-error --location \
        --retry 2 --retry-all-errors --connect-timeout 15 --max-time 60 \
        "${headers[@]}" \
        "$GITHUB_API_URL/repos/$RELEASE_REPOSITORY/releases/tags/$RELEASE_TAG" \
        --output "$output"
}

release_asset_row() {
    local metadata="$1" asset_name="$2"
    if command -v jq >/dev/null 2>&1; then
        jq -er --arg tag "$RELEASE_TAG" --arg name "$asset_name" '
            if .tag_name != $tag then error("Release tag 不匹配")
            elif .draft != false then error("Release 仍是草稿")
            else . end
            | [.assets[] | select(.name == $name)]
            | if length != 1 then error("附件缺失或不唯一: " + $name)
              else .[0] end
            | if (.digest | type) != "string" or
                 (.digest | test("^sha256:[0-9A-Fa-f]{64}$") | not)
              then error("附件缺少有效的 SHA-256: " + $name)
              else [.id, (.digest | ascii_downcase | sub("^sha256:"; "")), .size, .updated_at] | @tsv
              end
        ' "$metadata"
    else
        python3 - "$metadata" "$RELEASE_TAG" "$asset_name" <<'PY'
import json
import re
import sys

path, expected_tag, expected_name = sys.argv[1:]
with open(path, "r", encoding="utf-8") as stream:
    release = json.load(stream)
if release.get("tag_name") != expected_tag or release.get("draft") is not False:
    raise SystemExit("Release tag 不匹配或仍是草稿")
assets = [item for item in release.get("assets", []) if item.get("name") == expected_name]
if len(assets) != 1:
    raise SystemExit("附件缺失或不唯一: " + expected_name)
asset = assets[0]
digest = asset.get("digest")
if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9A-Fa-f]{64}", digest):
    raise SystemExit("附件缺少有效的 SHA-256: " + expected_name)
print("\t".join((str(asset["id"]), digest[7:].lower(), str(asset["size"]), asset["updated_at"])))
PY
    fi
}

download_cnb_manifest_to() {
    local output="$1" manifest_size

    log "从 CNB 下载 $MANIFEST_NAME"
    download_from_url "$CNB_DOWNLOAD_BASE/$RELEASE_TAG/$MANIFEST_NAME" "$output" || return 1
    manifest_size="$(stat -c '%s' "$output")" || return 1
    [[ "$manifest_size" =~ ^[0-9]+$ && "$manifest_size" -gt 0 && \
       "$manifest_size" -le $((1024 * 1024)) ]]
}

download_cnb_manifest() {
    download_cnb_manifest_to "$MANIFEST_PATH"
}

safe_asset_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$1" != *..* ]]
}

safe_target_path() {
    local target="$1" base
    case "$target" in
        /usr/local/bin/*|/usr/local/sbin/*) ;;
        *) return 1 ;;
    esac
    base="${target##*/}"
    [[ -n "$base" && "$base" != . && "$base" != .. && "$target" != *//* ]] || return 1
    case "/${target#/}/" in
        */./*|*/../*) return 1 ;;
    esac
    return 0
}

download_from_url() {
    local url="$1" output="$2"
    curl --fail --silent --show-error --location \
        --retry 2 --retry-all-errors --connect-timeout 15 --max-time 120 \
        --output "$output" "$url"
}

download_asset() {
    local asset_name="$1" expected_sha="$2" expected_size="$3" output="$4"
    local source_name base url actual_sha actual_size
    local -a sources=()

    case "$DOWNLOAD_SOURCE" in
        auto) sources=(github proxy cnb) ;;
        github|1) sources=(github) ;;
        proxy|2) sources=(proxy) ;;
        cnb|3) sources=(cnb) ;;
    esac

    for source_name in "${sources[@]}"; do
        case "$source_name" in
            github) base="$GITHUB_DOWNLOAD_BASE" ;;
            proxy) base="$GITHUB_PROXY_BASE" ;;
            cnb) base="$CNB_DOWNLOAD_BASE" ;;
        esac
        url="$base/$RELEASE_TAG/$asset_name"
        rm -f -- "$output"
        log "从 $source_name 下载 $asset_name"
        if ! download_from_url "$url" "$output"; then
            continue
        fi
        actual_size="$(stat -c '%s' "$output")"
        actual_sha="$(sha256sum "$output" | awk '{print $1}')"
        if [[ "$actual_size" == "$expected_size" && "$actual_sha" == "$expected_sha" ]]; then
            return 0
        fi
        printf '附件校验失败：%s（来源：%s）\n' "$asset_name" "$source_name" >&2
    done
    return 1
}

parse_manifest() {
    local line sha size role target asset extra
    local seen_header=false format='' tag=''
    declare -A seen_assets=() seen_targets=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$seen_header" == false ]]; then
            case "$line" in
                format=*) format="${line#*=}" ;;
                release_tag=*) tag="${line#*=}" ;;
                $'sha256\tsize\trole\ttarget\tasset') seen_header=true ;;
            esac
            continue
        fi
        [[ -n "$line" ]] || continue
        IFS=$'\t' read -r sha size role target asset extra <<< "$line"
        [[ -z "${extra:-}" && "$sha" =~ ^[0-9a-f]{64}$ && "$size" =~ ^[0-9]+$ ]] || \
            die 'TUI 清单包含无效记录。'
        case "$role" in tui|bootstrap|installer) ;; *) die "TUI 清单包含无效类型：$role" ;; esac
        safe_asset_name "$asset" || die "TUI 清单包含不安全的附件名：$asset"
        case "$asset:$role:$target" in
            "droidspaces-tui.sh:tui:$TUI_TARGET"|"install-tui.sh:bootstrap:-") ;;
            install-*.sh:installer:/usr/local/sbin/install-*)
                [[ "$target" == "/usr/local/sbin/${asset%.sh}" ]] || \
                    die "安装脚本与目标路径不匹配：$asset"
                ;;
            *) die "TUI 清单包含不允许的安装映射：$asset" ;;
        esac
        if [[ "$role" != bootstrap ]]; then
            safe_target_path "$target" || die "TUI 清单包含不安全的目标路径：$target"
        fi
        [[ -z "${seen_assets[$asset]:-}" ]] || die "TUI 清单重复附件：$asset"
        [[ -z "${seen_targets[$target]:-}" ]] || die "TUI 清单重复目标：$target"
        seen_assets["$asset"]=1
        seen_targets["$target"]=1
        ASSET_SHA256+=("$sha")
        ASSET_SIZES+=("$size")
        ASSET_ROLES+=("$role")
        ASSET_TARGETS+=("$target")
        ASSET_NAMES+=("$asset")
    done < "$MANIFEST_PATH"

    [[ "$format" == 1 && "$tag" == "$RELEASE_TAG" && "$seen_header" == true ]] || \
        die 'TUI 清单格式或 Release tag 无效。'
    ((${#ASSET_NAMES[@]} >= 3)) || die 'TUI 清单没有包含必要脚本。'
    [[ "${seen_assets[droidspaces-tui.sh]:-}" == 1 && \
       "${seen_assets[install-tui.sh]:-}" == 1 ]] || die 'TUI 清单缺少核心脚本。'
}

reset_manifest_state() {
    ASSET_NAMES=()
    ASSET_SHA256=()
    ASSET_SIZES=()
    ASSET_ROLES=()
    ASSET_TARGETS=()
    SELECTED_INDEXES=()
    CHANGED_COUNT=0
}

load_github_manifest() {
    local manifest_row manifest_id manifest_sha manifest_size manifest_updated
    local index row asset_id asset_sha asset_size asset_updated

    reset_manifest_state
    json_parser_available || return 1
    log "读取 GitHub Release：$RELEASE_TAG"
    fetch_release_metadata "$API_BEFORE" || return 1
    manifest_row="$(release_asset_row "$API_BEFORE" "$MANIFEST_NAME")" || return 1
    IFS=$'\t' read -r manifest_id manifest_sha manifest_size manifest_updated <<< "$manifest_row"
    download_asset "$MANIFEST_NAME" "$manifest_sha" "$manifest_size" "$MANIFEST_PATH" || return 1
    parse_manifest
    select_updates

    for index in "${SELECTED_INDEXES[@]}"; do
        row="$(release_asset_row "$API_BEFORE" "${ASSET_NAMES[$index]}")" || return 1
        IFS=$'\t' read -r asset_id asset_sha asset_size asset_updated <<< "$row"
        [[ "$asset_sha" == "${ASSET_SHA256[$index]}" && \
           "$asset_size" == "${ASSET_SIZES[$index]}" ]] || \
            die "Release API 与 TUI 清单不一致：${ASSET_NAMES[$index]}"
    done
    METADATA_SOURCE=github
}

load_cnb_manifest() {
    reset_manifest_state
    download_cnb_manifest || return 1
    parse_manifest
    select_updates
    METADATA_SOURCE=cnb
}

asset_selected() {
    local role="$1"
    case "$UPDATE_SCOPE:$role" in
        all:tui|all:installer|tui:tui|scripts:installer) return 0 ;;
        *) return 1 ;;
    esac
}

aliases_need_update() {
    [[ "$UPDATE_SCOPE" != scripts ]] || return 1
    [[ -L /usr/local/bin/dstui && "$(readlink /usr/local/bin/dstui)" == droidspaces-tui && \
       -L /usr/local/bin/ds-tui && "$(readlink /usr/local/bin/ds-tui)" == droidspaces-tui ]] || return 0
    return 1
}

select_updates() {
    local index target actual_sha
    for index in "${!ASSET_NAMES[@]}"; do
        asset_selected "${ASSET_ROLES[$index]}" || continue
        target="${ASSET_TARGETS[$index]}"
        if [[ -f "$target" && ! -L "$target" ]]; then
            actual_sha="$(sha256sum "$target" | awk '{print $1}')"
            [[ "$actual_sha" == "${ASSET_SHA256[$index]}" ]] && continue
        fi
        SELECTED_INDEXES+=("$index")
    done
    CHANGED_COUNT="${#SELECTED_INDEXES[@]}"
    if aliases_need_update; then
        CHANGED_COUNT=$((CHANGED_COUNT + 1))
    fi
}

verify_release_unchanged() {
    local index before after
    for index in "$@"; do
        before="$(release_asset_row "$API_BEFORE" "${ASSET_NAMES[$index]}")"
        after="$(release_asset_row "$API_AFTER" "${ASSET_NAMES[$index]}")"
        [[ "$before" == "$after" ]] || die "下载期间 Release 附件发生变化：${ASSET_NAMES[$index]}"
    done
    before="$(release_asset_row "$API_BEFORE" "$MANIFEST_NAME")"
    after="$(release_asset_row "$API_AFTER" "$MANIFEST_NAME")"
    [[ "$before" == "$after" ]] || die '下载期间 TUI 清单发生变化，请重试。'
}

confirm_install() {
    local answer
    [[ "$ASSUME_YES" == true ]] && return
    [[ -t 0 ]] || die '非交互环境请使用 --yes。'
    printf '将更新 %s 项，是否继续？ [y/N]: ' "$CHANGED_COUNT"
    IFS= read -r answer || exit 1
    case "${answer,,}" in y|yes|1|是) ;; *) exit 0 ;; esac
}

install_updates() {
    local index asset target staged target_dir backup_dir backup_path transaction_id
    local aliases_changed=false
    local transaction_started=false
    declare -a prepared_targets=() backup_targets=() backup_paths=()

    transaction_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    backup_dir="/var/backups/droidspaces-tui/$transaction_id"
    mkdir -p -- "$backup_dir"

    for index in "${SELECTED_INDEXES[@]}"; do
        asset="${ASSET_NAMES[$index]}"
        target="${ASSET_TARGETS[$index]}"
        staged="$WORK_DIR/assets/$asset"
        target_dir="${target%/*}"
        mkdir -p -- "$target_dir"
        install -o root -g root -m 0755 -- "$staged" "$target.droidspaces-new-$$"
        prepared_targets+=("$target")
        if [[ -e "$target" || -L "$target" ]]; then
            backup_path="$backup_dir/${target#/}"
            backup_targets+=("$target")
            backup_paths+=("$backup_path")
            mkdir -p -- "${backup_path%/*}"
            cp -a -- "$target" "$backup_path"
        fi
    done

    if aliases_need_update; then
        aliases_changed=true
        for target in /usr/local/bin/dstui /usr/local/bin/ds-tui; do
            if [[ -e "$target" || -L "$target" ]]; then
                backup_path="$backup_dir/${target#/}"
                backup_targets+=("$target")
                backup_paths+=("$backup_path")
                mkdir -p -- "${backup_path%/*}"
                cp -a -- "$target" "$backup_path"
            fi
        done
    fi

    rollback_transaction() {
        local rollback_target backup_index
        for rollback_target in "${prepared_targets[@]}"; do
            rm -f -- "$rollback_target.droidspaces-new-$$"
            if [[ "$transaction_started" == true ]]; then
                rm -f -- "$rollback_target"
            fi
        done
        if [[ "$transaction_started" == true ]]; then
            rm -f -- /usr/local/bin/dstui.new-$$ /usr/local/bin/ds-tui.new-$$
            [[ "$aliases_changed" == false ]] || rm -f -- /usr/local/bin/dstui /usr/local/bin/ds-tui
        fi
        for backup_index in "${!backup_targets[@]}"; do
            rollback_target="${backup_targets[$backup_index]}"
            if [[ "$transaction_started" == true ]]; then
                cp -a -- "${backup_paths[$backup_index]}" "$rollback_target"
            fi
        done
    }
    trap 'rollback_transaction; cleanup' ERR

    transaction_started=true
    for target in "${prepared_targets[@]}"; do
        mv -f -- "$target.droidspaces-new-$$" "$target"
    done
    if [[ "$aliases_changed" == true ]]; then
        ln -sfn -- droidspaces-tui /usr/local/bin/dstui.new-$$
        mv -f -- /usr/local/bin/dstui.new-$$ /usr/local/bin/dstui
        ln -sfn -- droidspaces-tui /usr/local/bin/ds-tui.new-$$
        mv -f -- /usr/local/bin/ds-tui.new-$$ /usr/local/bin/ds-tui
    fi
    trap - ERR
    trap cleanup EXIT

    if ((${#backup_targets[@]} == 0)); then
        rmdir --ignore-fail-on-non-empty "$backup_dir" 2>/dev/null || true
    else
        log "旧文件已备份到 $backup_dir"
    fi
}

main() {
    local index asset_sha asset_size manifest_after before_sha after_sha

    parse_arguments "$@"
    require_commands
    if [[ "$CHECK_ONLY" == false ]]; then
        ensure_root
    fi

    WORK_DIR="$(mktemp -d -t droidspaces-tui.XXXXXXXX)"
    mkdir -p "$WORK_DIR/assets"
    API_BEFORE="$WORK_DIR/release-before.json"
    API_AFTER="$WORK_DIR/release-after.json"
    MANIFEST_PATH="$WORK_DIR/$MANIFEST_NAME"

    case "$DOWNLOAD_SOURCE" in
        cnb)
            load_cnb_manifest || die '无法从 CNB 下载并解析 TUI 清单。'
            ;;
        auto)
            if ! load_github_manifest; then
                log 'GitHub Release 元数据不可用，改用 CNB 清单。'
                DOWNLOAD_SOURCE=cnb
                load_cnb_manifest || die '无法从 GitHub 或 CNB 取得 TUI 清单。'
            fi
            ;;
        github|proxy)
            load_github_manifest || die '无法取得经过 GitHub Release API 校验的 TUI 清单。'
            ;;
    esac

    if ((CHANGED_COUNT == 0)); then
        log "所选范围已经是 $RELEASE_TAG 的最新版本。"
        exit 0
    fi
    log "发现 $CHANGED_COUNT 项需要安装或更新。"
    if [[ "$CHECK_ONLY" == true ]]; then
        for index in "${SELECTED_INDEXES[@]}"; do
            printf '  %s -> %s\n' "${ASSET_NAMES[$index]}" "${ASSET_TARGETS[$index]}"
        done
        aliases_need_update && printf '  %s\n' '命令别名 dstui / ds-tui'
        exit 0
    fi
    confirm_install

    for index in "${SELECTED_INDEXES[@]}"; do
        asset_sha="${ASSET_SHA256[$index]}"
        asset_size="${ASSET_SIZES[$index]}"
        download_asset "${ASSET_NAMES[$index]}" "$asset_sha" "$asset_size" \
            "$WORK_DIR/assets/${ASSET_NAMES[$index]}" || \
            die "无法下载并校验附件：${ASSET_NAMES[$index]}"
        bash -n "$WORK_DIR/assets/${ASSET_NAMES[$index]}" || \
            die "脚本语法检查失败：${ASSET_NAMES[$index]}"
    done

    if [[ "$METADATA_SOURCE" == github ]]; then
        fetch_release_metadata "$API_AFTER"
        verify_release_unchanged "${SELECTED_INDEXES[@]}"
    else
        manifest_after="$WORK_DIR/${MANIFEST_NAME}.after"
        download_cnb_manifest_to "$manifest_after" || \
            die '无法重新读取 CNB TUI 清单。'
        before_sha="$(sha256sum "$MANIFEST_PATH" | awk '{print $1}')"
        after_sha="$(sha256sum "$manifest_after" | awk '{print $1}')"
        [[ "$before_sha" == "$after_sha" ]] || \
            die '下载期间 CNB TUI 清单发生变化，请重试。'
    fi
    install_updates
    log "安装完成。运行 dstui 或 ds-tui 即可打开工具箱。"
}

main "$@"
