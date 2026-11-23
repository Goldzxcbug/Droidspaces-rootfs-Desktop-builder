#!/bin/bash
# sshfs 默认补充 -o umask=022，避免远程复制目录权限变为 000
REAL=/usr/bin/sshfs.real
[ -x "$REAL" ] || { echo "sshfs wrapper: $REAL not found" >&2; exit 127; }

ARGS=()
HAS_UMASK=0
for a in "$@"; do
    case "$a" in
        *umask*) HAS_UMASK=1 ;;
    esac
    ARGS+=("$a")
done

EXTRA=()
[ "$HAS_UMASK" = 0 ] && EXTRA+=("-o" "umask=022")
exec "$REAL" "${EXTRA[@]}" "${ARGS[@]}"
