# Docker 辅助命令
# 以表格显示正在运行的容器
alias dps="docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"

# 显示全部容器
alias dpsa="docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"

# 显示全部镜像
alias dim="docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}'"

# 交互运行镜像并在退出后自动删除容器
alias drun="docker run -it --rm"

# 按名称停止容器
alias dstop="docker stop"

# 按名称删除容器
alias drm="docker rm"

# 按名称或 ID 删除镜像
alias drmi="docker rmi"

# 持续显示容器日志
alias dlog="docker logs -f"

# 删除全部已停止的容器
alias drmc="docker ps -a -q -f status=exited | xargs -r docker rm"

# 删除全部悬空镜像
alias drmid="docker images -f dangling=true -q | xargs -r docker rmi"

check_temps() {
    if [ ! -d /sys/class/thermal ]; then
        echo "错误：/sys/class/thermal 未挂载或不可用。"
        return 1
    fi

    echo "==== 温度区域 ===="
    for zone in /sys/class/thermal/thermal_zone*; do
        # 获取温度区域类型
        type_file="$zone/type"
        if [ -f "$type_file" ]; then
            type=$(cat "$type_file")
        else
            type="未知"
        fi

        # 读取千分之一摄氏度并转换为摄氏度
        temp_file="$zone/temp"
        if [ -f "$temp_file" ]; then
            temp=$(cat "$temp_file")
            temp_c=$((temp / 1000))
            temp_milli=$((temp % 1000))
            printf "%-20s : %3d.%03d°C\n" "$type" "$temp_c" "$temp_milli"
        fi
    done
    echo "================================="
}

check_temp_rt() {
    # 确认 check_temps 函数已经加载
    if ! declare -f check_temps > /dev/null; then
        echo "错误：找不到 check_temps 函数！"
        return 1
    fi

    echo "按 Ctrl+C 停止实时温度监控。"
    while true; do
        clear                # 清除上一次输出
        check_temps          # 重新显示温度
        sleep 1              # 等待 1 秒
    done
}

# 通过 SSH 传输文件或目录
# 用法：transfer /本地/文件或目录 用户名@IP /远程/保存路径
transfer() {
    if [ $# -ne 3 ]; then
        echo "用法：transfer /本地/文件或目录 用户名@IP /远程/保存路径"
        return 1
    fi

    local SRC="$1"
    local DEST="$2"
    local REMOTE_PATH="$3"

    # 检查源文件或目录是否存在
    if [ ! -e "$SRC" ]; then
        echo "错误：源路径 '$SRC' 不存在！"
        return 1
    fi

    # 递归传输，兼容文件和目录
    scp -r "$SRC" "$DEST":"$REMOTE_PATH"
    if [ $? -eq 0 ]; then
        echo "传输完成：$SRC -> $DEST:$REMOTE_PATH"
    else
        echo "传输失败！"
    fi
}
