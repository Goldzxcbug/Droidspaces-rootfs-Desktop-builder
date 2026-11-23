#!/bin/bash
# fnos-db-selfheal.sh — Droidspaces 容器内 fnOS 数据库开机自愈
#
# 背景（实测根因）：
#   容器首次开机时，systemd 的 postgresql@15-main.service 会与 fnOS 自身的
#   triminit 抢跑，偶尔在 60ms 内静默失败（pg_ctlcluster 无任何输出、
#   PostgreSQL 日志 0 字节）。PG 一旦没起来，triminit 就连不上
#   /var/run/postgresql/.s.PGSQL.5432，fnOS 主库 trim 建不出来，
#   随后 trim / accountsrv / cloud_storage_dav 等全部报
#   FATAL: database "trim" does not exist (SQLSTATE 3D000)，
#   在 Web UI 上表现为「初始化数据库失败」，并陷入无限重启循环。
#
# 本脚本在开机后做三件事（幂等，失败不影响开机）：
#   1. 等 PostgreSQL 接受连接，必要时主动拉起并重试
#   2. 轮询等 fnOS 主库 trim 出现（正常 triminit 在建库时也走这条路）
#   3. 若 PG 已就绪但 trim 仍缺失，重跑 fnOS 自己的 trim_init.service
set -u

PG_SOCKET_DIR="/var/run/postgresql"
PG_PORT=5432
PG_UNIT="postgresql@15-main.service"
INIT_UNIT="trim_init.service"
PSQL="/usr/bin/psql"

WAIT_PG="${FNOS_DB_WAIT_PG:-60}"        # 等 PG 就绪的秒数
WAIT_DB="${FNOS_DB_WAIT_DB:-90}"        # 等 triminit 建库的秒数
WAIT_DB_AFTER="${FNOS_DB_WAIT_AFTER:-60}"  # 重跑 triminit 后再等的秒数

log() { echo "[fnos-db-selfheal] $*"; }

wait_postgresql() {
    local start=$SECONDS
    while [ "$((SECONDS - start))" -lt "$WAIT_PG" ]; do
        if [ -S "$PG_SOCKET_DIR/.s.PGSQL.$PG_PORT" ] &&
            runuser -u postgres -- /usr/bin/pg_isready -q -t 1 \
                -h "$PG_SOCKET_DIR" -p "$PG_PORT" -U postgres -d postgres; then
            return 0
        fi
        sleep 1
    done
    return 1
}

trim_db_exists() {
    su -s /bin/sh postgres -c "$PSQL -lqt" 2>/dev/null |
        cut -d'|' -f1 | tr -d ' \t' | grep -qx 'trim'
}

wait_trim_db() {
    local limit="$1" i=0
    while [ "$i" -lt "$limit" ]; do
        trim_db_exists && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# trim_init 只等数据库就绪，建库和重启服务仍由各自的启动流程负责。
if [ "${1:-}" = "--wait-postgresql" ]; then
    wait_postgresql && exit 0
    log "PostgreSQL 未接受连接，无法启动 trim_init"
    exit 1
fi

# 1. 确保 PostgreSQL 在跑
if ! wait_postgresql; then
    log "PostgreSQL 未就绪，尝试启动 $PG_UNIT"
    systemctl reset-failed "$PG_UNIT" 2>/dev/null || true
    systemctl start "$PG_UNIT" 2>/dev/null || true
    if ! wait_postgresql; then
        log "启动后仍未接受连接，重启 $PG_UNIT"
        systemctl restart "$PG_UNIT" 2>/dev/null || true
        if ! wait_postgresql; then
            log "PostgreSQL 仍不可用，跳过自愈（请检查 $PG_UNIT 的 journal）"
            exit 0
        fi
    fi
fi

log "PostgreSQL 已就绪"

# 2. 正常路径：triminit 正在建库时，这里会等到 trim 出现
if wait_trim_db "$WAIT_DB"; then
    log "主库 trim 已存在"
    exit 0
fi

# 3. 兜底：PG 就绪但主库缺失，重跑 fnOS 自己的初始化
log "主库 trim 缺失，重跑 fnOS 初始化（$INIT_UNIT）"
systemctl reset-failed "$INIT_UNIT" 2>/dev/null || true
systemctl restart "$INIT_UNIT" 2>/dev/null || true

if wait_trim_db "$WAIT_DB_AFTER"; then
    log "主库 trim 已补建成功"
    exit 0
fi

log "警告：重跑 $INIT_UNIT 后主库 trim 仍缺失，请手动检查 PostgreSQL 与 triminit 日志"
exit 0
