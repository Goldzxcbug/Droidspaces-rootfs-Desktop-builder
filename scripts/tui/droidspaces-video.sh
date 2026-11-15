#!/usr/bin/env bash
# Read-only dmd-video-v1 telemetry. No daemon, Python or automatic privilege change.
set -uo pipefail
export LC_ALL=C.UTF-8

INTERVAL=1
ONCE=false
JSON=false
INTERACTIVE=false
STOP=false
WORK=""
SAVED_TERMINAL=""
TTY_FD=0
COLOR=""
RESET=""
LINES_WRITTEN=0
WIDTH=119
HEIGHT=24

fail() { printf '视频监控：%s\n' "$*" >&2; exit 2; }
cleanup() {
    if [[ -n "$SAVED_TERMINAL" ]]; then
        stty "$SAVED_TERMINAL" <&"$TTY_FD" 2>/dev/null || true
        printf '\033[?25h\033[?1049l'
    fi
    [[ -z "$WORK" ]] || rm -rf -- "$WORK"
}

while (($#)); do
    case "$1" in
        --once) ONCE=true ;;
        --json) JSON=true; ONCE=true ;;
        --no-color) export NO_COLOR=1 ;;
        --interval)
            (($# >= 2)) || fail '--interval 缺少秒数。'
            INTERVAL="$2"; shift
            [[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
                awk -v n="$INTERVAL" 'BEGIN { exit !(n >= 0.2 && n <= 60) }' ||
                fail '刷新间隔应为 0.2 至 60 秒。'
            ;;
        -h|--help)
            printf '%s\n' '用法：droidspaces-video.sh [--once | --json] [--interval 秒数] [--no-color]' \
                '读取可访问进程的视频驱动遥测；q、Esc 或 Ctrl+C 返回。' \
                '需要 Bash、jq 和 GNU coreutils/findutils；没有遥测时状态为未知。'
            exit 0 ;;
        *) fail "未知参数：$1" ;;
    esac
    shift
done
for tool in awk cat cp find getconf jq mktemp readlink rm stat timeout; do
    command -v "$tool" >/dev/null 2>&1 || fail "缺少命令 $tool，请安装后重试。"
done
CLOCK_TICKS="$(getconf CLK_TCK)"
[[ "$CLOCK_TICKS" =~ ^[0-9]+$ ]] && ((CLOCK_TICKS > 0 && CLOCK_TICKS <= 1000000)) || fail '无法读取内核时钟频率。'
WORK="$(mktemp -d -t droidspaces-video.XXXXXXXX)" || fail '无法创建临时目录。'
trap cleanup EXIT
trap 'STOP=true' INT TERM HUP
printf '{"sessions":[]}\n' > "$WORK/previous.json"

# status defines real/fs UID and explicitly maps nested PID namespaces. stat
# starttime prevents a reused PID from inheriting another process's counters.
process_identity() {
    local path="$1" pid="${1##*/}"
    awk -v pid="$pid" '
        FNR == NR {
            if ($1 == "Pid:") actual=$2
            if ($1 == "Uid:") { uid=$2; effective=$3; fsuid=$5 }
            if ($1 == "NSpid:") {
                mapped=$2
                for (i=3; i<=NF; i++) mapped=mapped "," $i
            }
            next
        }
        { sub(/^.*\) /, ""); start=$20 }
        END {
            if (mapped == "") mapped=pid
            split(mapped, ns, ",")
            if (actual != pid || ns[1] != pid || uid !~ /^[0-9]+$/ ||
                effective !~ /^[0-9]+$/ || fsuid !~ /^[0-9]+$/ || start !~ /^[0-9]+$/) exit 1
            print uid "|" effective "|" fsuid "|" start "|" mapped
        }
    ' "$path/status" "$path/stat" 2>/dev/null
}

cat > "$WORK/validate.jq" <<'JQ'
if length != 1 then error("one record required") else .[0] end
| def uint: type == "number" and . >= 0 and . <= 18446744073709551615 and floor == .;
def codec_label: type == "string" and test("^[A-Za-z0-9_.:+-]{1,64}$");
if type != "object" or
   ([.pid,.context,.width,.height,.hw_completed,.output_frames,.errors,.updated_ns,.last_frame_ns] | all(uint) | not) or
   (.pid as $p | $ns | index($p)) == null or
   (has("uid") and .uid != $uid) or
   (.direction != "decode" and .direction != "encode") or
   (.codec | codec_label | not) or (has("target_fps") | not) or
   .width > 4294967295 or .height > 4294967295
then error("invalid telemetry") else . end
| if (.state != "created" and .state != "active" and .state != "error" and .state != "closed")
     or (.target_fps != null and (.target_fps | type != "number" or . < 0 or . > 1000000))
  then error("invalid state or target FPS") else . end
| {pid:$pid, reported_pid:.pid, uid:$uid, effective_uid:$effective,
   process_start_ticks:$start, memfd_inode:$inode, namespace_pids:$ns,
   context, direction, codec, width, height, hw_completed, output_frames, errors,
   updated_ns, last_frame_ns, target_fps, state,
   identity:([$pid,$start,$device,$inode,.context] | map(tostring) | join(":")),
   comm:($comm | gsub("[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u206f]"; " ")
       | if ascii_downcase == "vlc" then "VLC" elif (ascii_downcase == "obs" or ascii_downcase == "obs64") then "OBS" else . end)}
JQ

read_session() {
    local path="$1" process="/proc/$2" pid="$2" before after uid effective fsuid start mapped
    local file_state kind owner size device inode status
    before="$(process_identity "$process")" || { raced=$((raced + 1)); return; }
    IFS='|' read -r uid effective fsuid start mapped <<< "$before"
    file_state="$(LC_ALL=C stat -Lc '%F|%u|%s|%d|%i' -- "$path" 2>/dev/null)" || { raced=$((raced + 1)); return; }
    IFS='|' read -r kind owner size device inode <<< "$file_state"
    [[ "$kind" == 'regular file' && "$owner" == "$fsuid" && "$size" == 4096 ]] || { invalid=$((invalid + 1)); return; }
    # Keep both seqlock reads in one process: launching separate readers can
    # take longer than a frame on Android and reject every active session.
    LC_ALL=C timeout -k 0.1 0.4 awk -v path="$path" '
        function byte(s,n) { return ord[substr(s,n,1)] }
        function u32(s,n) { return byte(s,n)+256*byte(s,n+1)+65536*byte(s,n+2)+16777216*byte(s,n+3) }
        BEGIN {
            for (i=0; i<256; i++) ord[sprintf("%c",i)]=i
            RS="^$"
            for (attempt=0; attempt<4; attempt++) {
                if ((getline first < path) <= 0) exit 3
                close(path)
                if (length(first) != 4096 || substr(first,1,7) != "DMDVID1" || byte(first,8) != 0 ||
                    u32(first,9) != 1 || u32(first,13) != 4096) exit 2
                if (byte(first,17) % 2) continue
                length_json=u32(first,25)
                if (length_json < 1 || length_json > 4064) exit 2
                if ((getline second < path) <= 0) exit 3
                close(path)
                if (length(second) != 4096 || substr(first,17,8) != substr(second,17,8)) continue
                printf "%s",substr(first,33,length_json)
                exit 0
            }
            exit 4
        }
    ' > "$WORK/payload" 2>/dev/null
    status=$?
    case "$status" in 0) ;; 2) invalid=$((invalid + 1)); return ;; 4) busy=$((busy + 1)); return ;; *) raced=$((raced + 1)); return ;; esac
    after="$(LC_ALL=C stat -Lc '%F|%u|%s|%d|%i' -- "$path" 2>/dev/null)"
    [[ "$after" == "$file_state" && "$(readlink -- "$path" 2>/dev/null)" == '/memfd:dmd-video-v1 (deleted)' &&
       "$(process_identity "$process")" == "$before" ]] || { raced=$((raced + 1)); return; }
    local comm='?'
    IFS= read -r comm < "$process/comm" 2>/dev/null || true
    if ! jq -cse --argjson pid "$pid" --argjson uid "$uid" --argjson effective "$effective" \
        --argjson start "$start" --arg device "$device" --arg inode "$inode" --arg comm "$comm" \
        --argjson ns "[$mapped]" -f "$WORK/validate.jq" "$WORK/payload" >> "$WORK/records" 2>/dev/null; then
        invalid=$((invalid + 1))
    fi
}

collect() {
    local process pid path comm identity uid effective fsuid start mapped application now
    local scanned=0 denied=0 invalid=0 busy=0 raced=0
    local -a directories=()
    : > "$WORK/records"; : > "$WORK/apps"
    for process in /proc/[0-9]*; do
        [[ -d "$process" ]] || continue
        scanned=$((scanned + 1))
        directories+=("$process/fd")
    done
    LC_ALL=C find "${directories[@]}" -mindepth 1 -maxdepth 1 -lname '/memfd:dmd-video-v1 (deleted)' -print \
        > "$WORK/candidates" 2> "$WORK/scan-errors" || true
    denied="$(awk '/Permission denied|Operation not permitted/ {n++} END {print n+0}' "$WORK/scan-errors")"
    while IFS= read -r path; do
        [[ "$path" =~ ^/proc/([0-9]+)/fd/[0-9]+$ ]] || continue
        pid="${BASH_REMATCH[1]}"
        read_session "$path" "$pid"
    done < "$WORK/candidates"
    for process in /proc/[0-9]*; do
        [[ -r "$process/comm" ]] || continue
        comm=''; IFS= read -r comm < "$process/comm" 2>/dev/null || continue
        case "${comm,,}" in mpv) application=mpv ;; vlc) application=VLC ;; obs|obs64) application=OBS ;; *) continue ;; esac
        identity="$(process_identity "$process")" || continue
        IFS='|' read -r uid effective fsuid start mapped <<< "$identity"
        pid="${process##*/}"
        printf '{"pid":%s,"uid":%s,"process_start_ticks":%s,"comm":"%s","application":"%s"}\n' \
            "$pid" "$uid" "$start" "${comm,,}" "$application" >> "$WORK/apps"
    done
    # Android containers can virtualize /proc/uptime. A fresh sampler task
    # provides a stable kernel tick clock without Python or wall-clock jumps.
    now="$(awk -v hz="$CLOCK_TICKS" 'BEGIN {
        if ((getline s < "/proc/self/stat") <= 0) exit 1
        sub(/^.*\) /,"",s); split(s,fields," ")
        if (fields[20] !~ /^[0-9]+$/) exit 1
        printf "%.6f\n",fields[20]/hz
    }')" || return 1
    jq -n --argjson now "$now" --argjson uid "$EUID" --argjson scanned "$scanned" --argjson denied "$denied" \
        --argjson invalid "$invalid" --argjson busy "$busy" --argjson raced "$raced" \
        --slurpfile rows "$WORK/records" --slurpfile apps "$WORK/apps" --slurpfile previous "$WORK/previous.json" '
        ($previous[0].sessions | map({key:.identity,value:.}) | from_entries) as $old
        | ($rows | unique_by(.identity) | map(
            . as $row | $old[.identity] as $before
            | .sampled_seconds=$now
            | .counter_reset=($before != null and
                (.output_frames < $before.output_frames or .hw_completed < $before.hw_completed or .errors < $before.errors))
            | .observed_output_fps=(if $before == null or .counter_reset or $now <= $before.sampled_seconds then null
                else (.output_frames - $before.output_frames) / ($now - $before.sampled_seconds) end)
            | .hardware_status=(if .hw_completed > 0 then "confirmed" else "pending" end)
            | .activity=(if .state == "error" then "error" elif .state == "closed" then "closed"
                elif .output_frames == 0 then "waiting" elif .observed_output_fps == null then "sampling"
                elif .observed_output_fps == 0 then "idle" else "active" end))) as $sessions
        | {schema_version:1, sampled_seconds:$now, sample_clock:"kernel-start-ticks", collector_uid:$uid,
           software_visibility:"unknown", collection:{processes_scanned:$scanned,permission_denied:$denied,
               invalid_records:$invalid,busy_records:$busy,raced_records:$raced}, sessions:$sessions,
           applications:($apps | map(. as $app | .driver_sessions=([$sessions[] |
               select(.pid == $app.pid and .process_start_ticks == $app.process_start_ticks)] | length)
               | .hardware_status=(if .driver_sessions > 0 then "see-driver-sessions" else "unknown" end)))}
    ' > "$WORK/snapshot.json" || return 1
    cp -- "$WORK/snapshot.json" "$WORK/previous.json"
}

# Limit by terminal cells, including Chinese labels, before adding our own SGR.
fit() {
    local value="$1" char code used=0 size i out=''
    for ((i=0; i<${#value}; i++)); do
        char="${value:i:1}"; printf -v code '%d' "'$char"; size=1
        if ((code < 32 || (code >= 127 && code < 160) || (code >= 0x200b && code <= 0x200f) ||
             (code >= 0x202a && code <= 0x202e) || (code >= 0x2060 && code <= 0x206f))); then continue; fi
        if (( (code >= 0x1100 && code <= 0x115f) || (code >= 0x2e80 && code <= 0xa4cf) ||
              (code >= 0xac00 && code <= 0xd7a3) || (code >= 0xf900 && code <= 0xfaff) ||
              (code >= 0xfe10 && code <= 0xfe6f) || (code >= 0xff01 && code <= 0xff60) ||
              (code >= 0x1f300 && code <= 0x1faff) )); then size=2; fi
        ((used + size <= WIDTH)) || break
        out+="$char"; used=$((used + size))
    done
    printf '%s' "$out"
}

line() {
    local text="$1" tone="${2:-}" escape=''
    if [[ "$INTERACTIVE" == true ]]; then
        ((LINES_WRITTEN == 0)) || printf '\r\n'
        if [[ -n "$COLOR" ]]; then
            case "$tone" in title) escape=$'\033[36m' ;; muted) escape=$'\033[90m' ;;
                hardware) escape=$'\033[32m' ;; unknown) escape=$'\033[33m' ;; error) escape=$'\033[31m' ;; esac
        fi
        printf '%s%s%s\033[K' "$escape" "$(fit "$text")" "$RESET"
    else
        printf '%s\n' "$(fit "$text")"
    fi
    LINES_WRITTEN=$((LINES_WRITTEN + 1))
}

render() {
    local columns="${COLUMNS:-120}" rows=24 decoding encoding groups total uid denied invalid busy
    local name pid context direction codec width height fps hardware activity errors label size tone row last_group=''
    local shown=0 capacity needed group
    if [[ "$INTERACTIVE" == true ]]; then
        read -r rows columns < <(stty size <&"$TTY_FD") || true
    fi
    [[ "$columns" =~ ^[0-9]+$ ]] && ((columns >= 12)) || columns=80
    [[ "$rows" =~ ^[0-9]+$ ]] && ((rows >= 9)) || rows=24
    WIDTH=$((columns - 1)); HEIGHT="$rows"; LINES_WRITTEN=0
    read -r decoding encoding groups total uid denied invalid busy < <(jq -r '
        [([.sessions[] | select(.direction == "decode")] | length),
           ([.sessions[] | select(.direction == "encode")] | length),
           ([.sessions[] | [.comm,.uid]] + [.applications[] | select(.driver_sessions == 0) | [.application,.uid]] | unique | length),
           ((.sessions | length) + ([.applications[] | select(.driver_sessions == 0)] | length)),
           .collector_uid,.collection.permission_denied,.collection.invalid_records,.collection.busy_records] | @tsv
    ' "$WORK/snapshot.json")
    [[ "$INTERACTIVE" != true ]] || printf '\033[H'
    line '视频编解码监控  DROIDSPACES' title
    line "解码 $decoding   编码 $encoding   应用 $groups   ·   采集 UID $uid"
    printf -v row '%*s' "$WIDTH" ''; line "${row// /─}" muted
    jq -r '
        ([.sessions[] | {name:.comm,uid,pid,context,direction,codec,width,height,
            fps:(if .observed_output_fps == null then "--" else ((.observed_output_fps * 10 | round) / 10 | tostring) end),
            hardware:.hardware_status,activity,errors}] +
         [.applications[] | select(.driver_sessions == 0) | {name:.application,uid,pid,context:"--",direction:"unknown",
            codec:"--",width:0,height:0,fps:"--",hardware:"unknown",activity:"unknown",errors:0}])
        | group_by([.name,.uid]) | sort_by((if any(.[]; .activity == "error") then 0 else 1 end),.[0].name,.[0].uid)
        | .[] | sort_by((if .activity == "error" then 0 else 1 end),.pid,.context)[]
        | [.name,.uid,.pid,.context,.direction,.codec,.width,.height,.fps,.hardware,.activity,.errors] | @tsv
    ' "$WORK/snapshot.json" > "$WORK/view"
    capacity=$((HEIGHT - 7))
    [[ "$INTERACTIVE" == true ]] || capacity=1000000
    if ((columns >= 80 && total > 0 && capacity > 0)); then
        line '  PID/ID      方向  格式      处理尺寸       输出FPS  硬件/状态' muted
    fi
    while IFS=$'\t' read -r name uid pid context direction codec width height fps hardware activity errors; do
        needed=1; ((columns >= 80)) || needed=2
        group="$name/$uid"
        [[ "$group" == "$last_group" ]] || needed=$((needed + 1))
        ((LINES_WRITTEN + needed <= capacity + 3)) || continue
        if [[ "$group" != "$last_group" ]]; then line "$name  ·  UID $uid" title; last_group="$group"; fi
        case "$activity" in active) label=活动 ;; idle) label=空闲 ;; waiting) label=等待 ;; sampling) label=待采样 ;; error) label="错误 $errors" ;; closed) label=关闭 ;; *) label=状态未知 ;; esac
        tone=unknown
        [[ "$hardware" != confirmed ]] || tone=hardware
        if ((errors > 0)); then
            [[ "$activity" == error ]] || label+=" · 错误 $errors"
            tone=error
        fi
        size='--'; ((width == 0 || height == 0)) || size="${width}×${height}"
        if [[ "$direction" == unknown ]]; then
            line "  PID $pid  未见驱动会话；状态未知" unknown
            ((columns >= 80)) || line '  格式 --  处理尺寸 --  输出 -- fps' muted
        else
            [[ "$direction" != decode ]] && direction=编码 || direction=解码
            [[ "$hardware" == confirmed ]] && hardware=硬件 || hardware=待确认
            if ((columns >= 80)); then
                printf -v row '  %-10s  %s  %-8s  %-13s  %6s  %s/%s' "$pid/$context" "$direction" "${codec^^}" "$size" "$fps" "$hardware" "$label"
                line "$row" "$tone"
            else
                line "  $direction ${codec^^}  ·  处理尺寸 $size"
                line "  $fps fps · $hardware/$label · PID $pid/$context" "$tone"
            fi
        fi
        shown=$((shown + 1))
    done < "$WORK/view"
    if ((total == 0)); then line '暂无可读驱动会话；等待应用建立会话。' unknown; fi
    if [[ "$INTERACTIVE" == true ]]; then
        while ((LINES_WRITTEN < HEIGHT - 4)); do line ''; done
    fi
    line "权限不足 $denied  ·  无效 $invalid  ·  更新中 $busy  ·  未显示 $((total - shown)) 项" muted
    line '软件编解码：未知；未见遥测不能证明使用软件。' unknown
    line '处理尺寸以驱动为准；输出 FPS ≠ 播放 FPS。' muted
    line 'q / Esc / Ctrl+C 返回  ·  自动刷新' title
    [[ "$INTERACTIVE" != true ]] || printf '\033[J'
}

if [[ "$ONCE" == false && -t 0 && -t 1 && "${TERM:-dumb}" != dumb ]]; then
    command -v stty >/dev/null 2>&1 || fail '缺少 stty。'
    INTERACTIVE=true
    exec {TTY_FD}</dev/tty || fail '无法打开控制终端。'
    SAVED_TERMINAL="$(stty -g <&"$TTY_FD")" || fail '无法读取终端设置。'
    stty -echo -icanon min 1 time 0 <&"$TTY_FD" || fail '无法设置终端输入模式。'
    printf '\033[?1049h\033[?25l'
    if [[ ! -v NO_COLOR ]]; then COLOR=1; RESET=$'\033[0m'; fi
fi
while :; do
    collect || { [[ "$STOP" != true ]] || break; fail '读取驱动统计失败。'; }
    [[ "$STOP" != true ]] || break
    if [[ "$JSON" == true ]]; then cat "$WORK/snapshot.json"; break; fi
    render
    [[ "$INTERACTIVE" == true ]] || break
    key=''
    IFS= read -rsn1 -t "$INTERVAL" key || true
    [[ "$STOP" != true ]] || break
    case "$key" in q|Q|$'\033') break ;; esac
done
