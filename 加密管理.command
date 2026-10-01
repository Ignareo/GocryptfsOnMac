#!/bin/bash
# 加密管理.command —— 双击运行，管理 ~/Documents 下的 gocryptfs 加密文件夹
# 判定依据：~/Documents 的子目录（深度≤2）中存在 gocryptfs.conf
# 挂载点：加密文件夹同级、同名加 [解密] 后缀
# 覆盖扫描目录：加密管理.command <目录>  或  GOCRYPTFS_BASE_DIR=<目录>

# 第一个参数若是目录则作为扫描目录，其次环境变量，默认 ~/Documents
if [ -d "${1:-}" ]; then
    BASE_DIR="$1"
else
    BASE_DIR="${GOCRYPTFS_BASE_DIR:-$HOME/Documents}"
fi
[ -d "$BASE_DIR" ] || { echo "错误：扫描目录不存在: $BASE_DIR"; exit 1; }
BASE_DIR="$(cd "$BASE_DIR" && pwd -P)"
export PATH="/opt/local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

# ---------- 工具函数 ----------

die_no_gocryptfs() {
    echo "错误：找不到 gocryptfs。"
    echo "请先安装：sudo port install gocryptfs   或   brew install --cask macfuse + brew install gocryptfs"
    exit 1
}

# 输出当前所有 macFUSE 挂载，每行: 加密目录<TAB>挂载点（均为规范化路径）
list_mounts() {
    mount | grep '(macfuse' | sed -E 's/^(.*) on (.*) \(macfuse.*/\1\t\2/' | while IFS=$'\t' read -r src dst; do
        # 只认 gocryptfs 挂载（加密目录内有 gocryptfs.conf），不动 sshfs/NTFS-3G 等其他 macFUSE 挂载
        [ -f "$src/gocryptfs.conf" ] || continue
        c_src="$(cd "$src" 2>/dev/null && pwd -P)"
        c_dst="$(cd "$dst" 2>/dev/null && pwd -P)"
        [ -n "$c_src" ] && [ -n "$c_dst" ] && printf '%s\t%s\n' "$c_src" "$c_dst"
    done
}

# 若 $1(规范化路径) 已挂载，输出挂载点；否则输出空
mountpoint_of() {
    list_mounts | awk -F'\t' -v v="$1" '$1 == v {print $2; exit}'
}

# 目录是否"空"（忽略 .DS_Store）
dir_is_empty() {
    [ -z "$(find "$1" -mindepth 1 -maxdepth 1 ! -name '.DS_Store' -print -quit 2>/dev/null)" ]
}

# ---------- 扫描 ----------

scan_vaults() {
    VAULTS=()
    while IFS= read -r conf; do
        v="$(dirname "$conf")"
        cv="$(cd "$v" && pwd -P)"
        case "$(basename "$cv")" in
            *\[解密\]) continue ;;  # 跳过解密挂载目录本身
        esac
        VAULTS+=("$cv")
    done < <(find "$BASE_DIR" -mindepth 2 -maxdepth 3 -name gocryptfs.conf 2>/dev/null | sort)
}

show_vaults() {
    local i=1 v mp
    for v in "${VAULTS[@]}"; do
        mp="$(mountpoint_of "$v")"
        if [ -n "$mp" ]; then
            printf '  %d) %s   [已挂载 → %s]\n' "$i" "${v#"$BASE_DIR"/}" "${mp#"$BASE_DIR"/}"
        else
            printf '  %d) %s   [未挂载]\n' "$i" "${v#"$BASE_DIR"/}"
        fi
        i=$((i+1))
    done
}

# ---------- 挂载 / 卸载 ----------

do_mount() {
    local v="$1"
    local mp="${v}[解密]"
    local name; name="$(basename "$v")"

    if [ -d "$mp" ]; then
        # gocryptfs 要求挂载点完全为空，先清掉 Finder 自动生成的元数据文件
        rm -f "$mp/.DS_Store" "$mp/.localized"
        if ! dir_is_empty "$mp"; then
            echo "⚠️  挂载点已存在且非空：$mp"
            echo "    为防止把明文写入普通目录（误以为已解密），已跳过。"
            echo "    请检查该目录内容后手动处理。"
            return 1
        fi
    else
        mkdir -p "$mp" || { echo "创建挂载点失败：$mp"; return 1; }
    fi

    local idle_opt=()
    local idle_min=""
    read -r -p "「$name」闲置自动卸载分钟数（直接回车 = 不启用）: " idle_min
    if [[ "$idle_min" =~ ^[1-9][0-9]*$ ]]; then
        idle_opt=(-idle "${idle_min}m")
    fi

    echo "正在挂载「$name」，请输入密码（输入时不显示）:"
    if gocryptfs "${idle_opt[@]}" "$v" "$mp"; then
        echo "✅ 已挂载: $mp"
        open "$mp"
    else
        echo "❌ 挂载失败（密码错误或文件系统损坏）"
        # 清理空挂载点，避免下次误判
        dir_is_empty "$mp" && rmdir "$mp" 2>/dev/null
        return 1
    fi
}

do_unmount() {
    local mp="$1"
    if umount "$mp" 2>/dev/null || diskutil unmount "$mp" >/dev/null 2>&1; then
        echo "✅ 已卸载: $mp"
    else
        echo "❌ 卸载失败：可能有程序正在使用该目录（请先关闭相关窗口/文件），或尝试强制: diskutil unmount force \"$mp\""
    fi
}

handle_vault() {
    local v="$1"
    local mp; mp="$(mountpoint_of "$v")"
    if [ -n "$mp" ]; then
        echo "「$(basename "$v")」已挂载于: $mp"
        read -r -p "输入 u 卸载，o 在 Finder 打开，直接回车返回: " act
        case "$act" in
            u|U) do_unmount "$mp" ;;
            o|O) open "$mp" ;;
        esac
    else
        do_mount "$v"
    fi
}

# ---------- 附加功能 ----------

new_vault() {
    read -r -p "新加密文件夹名称（将创建于 $BASE_DIR 下）: " name
    [ -z "$name" ] && { echo "已取消"; return; }
    case "$name" in */*|*\[解密\]*) echo "名称不能包含 / 或 [解密]"; return ;; esac
    local v="$BASE_DIR/$name"
    [ -e "$v" ] && { echo "已存在: $v"; return; }
    mkdir -p "$v" || return 1
    echo "初始化「$name」，请设置密码（输入时不显示）:"
    if gocryptfs -init "$v"; then
        echo ""
        echo "⚠️  上方显示的 master key 请务必抄写保存！密码丢失时它是唯一的恢复手段。"
        read -r -p "是否立即挂载？(y/N): " yn
        case "$yn" in y|Y) do_mount "$v" ;; esac
    else
        echo "初始化失败"
        dir_is_empty "$v" && rmdir "$v" 2>/dev/null
    fi
}

change_password() {
    [ ${#VAULTS[@]} -eq 0 ] && { echo "没有加密文件夹"; return; }
    show_vaults
    read -r -p "选择要修改密码的序号: " idx
    [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le ${#VAULTS[@]} ] || { echo "无效序号"; return; }
    gocryptfs -passwd "${VAULTS[$((idx-1))]}"
}

unmount_all() {
    local found=0
    while IFS=$'\t' read -r src dst; do
        do_unmount "$dst"
        found=1
    done < <(list_mounts)
    [ "$found" -eq 0 ] && echo "当前没有已挂载的加密文件夹"
}

# ---------- 非交互模式（供自动锁定守护进程 / 命令行调用） ----------

if [ "${1:-}" = "--unmount-all" ]; then
    unmount_all
    exit 0
fi

# ---------- 主循环 ----------

command -v gocryptfs >/dev/null 2>&1 || die_no_gocryptfs

while true; do
    echo ""
    echo "====== gocryptfs 加密管理 ======"
    echo "目录: $BASE_DIR"
    scan_vaults
    if [ ${#VAULTS[@]} -eq 0 ]; then
        echo "（未发现加密文件夹）"
    else
        show_vaults
    fi
    echo "----------------------------------"
    echo "输入序号进行挂载/卸载，多个序号用空格分隔"
    echo "  u) 全部卸载   n) 新建加密文件夹   p) 修改密码"
    echo "  r) 刷新       q) 退出"
    read -r -p "> " choice || break

    case "$choice" in
        q|Q) break ;;
        r|R|"") continue ;;
        u|U) unmount_all; continue ;;
        n|N) new_vault; continue ;;
        p|P) change_password; continue ;;
    esac

    for tok in $choice; do
        if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le ${#VAULTS[@]} ]; then
            handle_vault "${VAULTS[$((tok-1))]}"
        else
            echo "无效输入: $tok"
        fi
    done
done

echo "再见。可直接关闭本窗口。"
