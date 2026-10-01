#!/bin/bash
# 安装自动锁定.command —— 安装/卸载 gocryptfs 自动锁定守护进程
# 双击运行。守护进程在 睡眠前 / 锁屏 / 快速切换用户 时自动卸载所有 gocryptfs 挂载。

cd "$(dirname "$0")" || exit 1

LABEL="com.gocryptfsonmac.lockwatcher"
APP_DIR="$HOME/Library/Application Support/GocryptfsOnMac"
BIN="$APP_DIR/lock-watcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/GocryptfsLockWatcher.log"

is_loaded() { launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; }

do_install() {
    command -v swiftc >/dev/null 2>&1 || {
        echo "错误：需要 Xcode 命令行工具（swiftc）。请先运行: xcode-select --install"
        exit 1
    }
    mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents"
    echo "编译守护进程..."
    swiftc -O -o "$BIN" lock-watcher.swift || { echo "编译失败"; exit 1; }

    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

    is_loaded && launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"

    sleep 1
    if is_loaded; then
        echo "✅ 安装完成，守护进程已运行（登录时自动启动）。"
        echo "   日志: $LOG"
        echo ""
        echo "可选：若希望卸载失败时强制卸载（有未保存数据丢失风险），执行："
        echo "   mkdir -p ~/.config/gocryptfs-lockwatcher && touch ~/.config/gocryptfs-lockwatcher/force"
    else
        echo "❌ 安装失败，请查看日志: $LOG"
        exit 1
    fi
}

do_uninstall() {
    is_loaded && launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    rm -f "$PLIST" "$BIN"
    echo "✅ 已卸载自动锁定守护进程（已有挂载不受影响）。"
}

echo "====== gocryptfs 自动锁定守护进程 ======"
if is_loaded; then
    echo "状态：已安装并运行中"
    echo "  1) 重新安装/升级   2) 卸载   q) 退出"
    read -r -p "> " c
    case "$c" in
        1) do_install ;;
        2) do_uninstall ;;
    esac
else
    echo "状态：未安装"
    read -r -p "现在安装？(Y/n): " c
    case "$c" in
        n|N) echo "已取消" ;;
        *) do_install ;;
    esac
fi
