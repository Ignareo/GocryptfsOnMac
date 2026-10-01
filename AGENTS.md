# AGENTS.md — 给 LLM/自动化代理的项目说明

## 项目是什么

单文件 bash 工具 `加密管理.command`：macOS 上双击运行，交互式管理当前目录下的 gocryptfs 加密文件夹（扫描、挂载、卸载、新建、改密码）。无构建系统、无依赖库、无测试框架——端到端验证靠临时目录里真实跑 gocryptfs。

## 文件结构

- `加密管理.command` — 主交互逻辑（约 200 行 bash）。文件名含中文，`[解密]` 后缀约定见下。支持非交互模式 `--unmount-all`（全部卸载后退出）。
- `lock-watcher.swift` — 自动锁定守护进程源码（swiftc 编译）。监听系统睡眠（IOKit，IOAllowPowerChange 保证卸载完成才入睡）、锁屏（`com.apple.screenIsLocked`）、快速切换用户（`NSWorkspace.sessionDidResignActiveNotification`），触发后卸载全部 macFUSE 挂载。
- `安装自动锁定.command` — 编译 watcher、写入 `~/Library/LaunchAgents/com.gocryptfsonmac.lockwatcher.plist` 并 bootstrap；支持重装/卸载。日志在 `~/Library/Logs/GocryptfsLockWatcher.log`。
- `README.md` — 人类用户文档。

## 硬性约束（改动前必读）

1. **必须兼容 macOS 自带 bash 3.2**（`/bin/bash`）。禁止关联数组、`mapfile`、`${var^^}` 等 bash 4+ 特性。索引用普通数组 + `VAULTS[$((i-1))]`。
2. **路径必须全程引用**。真实路径含中文与空格（如 `/Users/keke/Documents/加密A`、挂载点 `加密A[解密]`）。所有 `"$var"`、数组遍历 `"${VAULTS[@]}"`。
3. **密码不进脚本变量**。挂载/初始化/改密码的密码提示由 gocryptfs 进程自己从 tty 读取。非 tty 时 gocryptfs 会从 stdin 读一行（`-init` 在非 tty 下只读一次、不二次确认）——自动化测试靠这个特性。
4. **安全不变量：绝不向非空目录挂载**。`[解密]` 目录存在且含真实文件且不是挂载点时拒绝挂载（防止用户把明文写进普通目录误以为加密）。例外：挂载前自动删除 `.DS_Store` / `.localized`（gocryptfs 要求挂载点完全为空，连 `.DS_Store` 也不行）。
5. **已挂载识别靠解析 `mount`**。格式实测为：
   ```
   <cipherdir> on <mountpoint> (macfuse, nodev, nosuid, synchronous, mounted by <user>)
   ```
   设备名就是加密目录路径。比对前两侧都要 `cd dir && pwd -P` 规范化——`mount` 会解析符号链接（如 `/tmp` → `/private/tmp`）。
6. **主菜单 `read` 必须 `|| break`**。stdin 到 EOF 时 `read` 返回空串，不处理会死循环刷菜单。
7. **卸载逻辑有两份**。`lock-watcher.swift` 内嵌的 shell 卸载片段与 `加密管理.command` 的 `list_mounts`/`do_unmount` 等效——守护进程必须自包含（不能依赖脚本路径，launchd 场景下脚本可能移动）。修改 mount 表解析或卸载策略时**两边同步**。
8. **Swift 与 SDK 的坑**（macOS 27 SDK 实测）：
   - `kIOMessageSystemWillSleep` 宏（`iokit_common_msg(0x280)`）未导出到 Swift，须硬编码 `0xE0000280`。
   - `IONotificationPortGetRunLoopSource` 在新 SDK 返回 `Unmanaged<CFRunLoopSource>?`，需 `.takeUnretainedValue()`。
   - `notifyutil -p com.apple.screenIsLocked` **不能**模拟锁屏通知（送不达 DistributedNotificationCenter）；真实睡眠会同时触发 `systemWillSleep` 和 `screenIsLocked`，用 `pmset sleepnow` 做真实测试即可覆盖两条路径。
   - watcher 的强制卸载开关：`~/.config/gocryptfs-lockwatcher/force` 文件存在即启用 `diskutil unmount force` 兜底。

## 命名约定

- 加密文件夹判定：目录内含 `gocryptfs.conf`，扫描范围为基准目录的子目录、`find -mindepth 2 -maxdepth 3`（即子目录深度 ≤ 2）。
- 基准目录（BASE_DIR）：**默认 `~/Documents`**，可用第一个位置参数（若是目录）或环境变量 `GOCRYPTFS_BASE_DIR` 覆盖。注意 `cd "$BASE_DIR" && pwd -P` 规范化，与 `mount` 表比对时保持一致。
- 挂载点 = `<加密目录路径>[解密]`（同级、同名加后缀）。扫描时跳过名字以 `[解密]` 结尾的目录。

## 环境事实（排障依据，2026-09 实测）

- macFUSE 与 macOS 兼容性：macOS 26/27 需要 macFUSE ≥ 5.3.3（macOS 27 初始支持在 5.3.1 加入，5.4.0 完善了 macOS 27 的 FSKit API）。版本不足时报 `The installed version of macFUSE is too old for the operating system`，挂载表现为进程存活但 `mount` 表无条目、gocryptfs 日志停在 `Decrypting master key`。
- 内核扩展未批准时系统日志（`log show --predicate 'process CONTAINS[c] "macfuse"'`）出现 `KMErrorDomain Code=27 ... not approved to load`，需在系统设置 → 隐私与安全性批准并重启。
- gocryptfs 走 go-fuse 自有挂载路径（macFUSE 内核后端），**不能使用** libfuse3 的 FSKit 后端（`-o backend=fskit` 对它无效）。
- `-fusedebug` 输出中 `".go-fuse-epoll-hack"` 和 `OPCODE-60 ... result too large` 是 go-fuse 内部机制，属正常噪音。

## 测试方法（无测试框架，手工端到端）

```bash
T=/tmp/gctest; rm -rf "$T"; mkdir -p "$T/sub"
printf 'pw111\n' > "$T/pw1"; mkdir -p "$T/vault1" "$T/sub/vault2"
gocryptfs -init -passfile "$T/pw1" "$T/vault1"
# ...
# 以临时目录为参数运行（默认目录是 ~/Documents，测试必须传参覆盖）：
printf '1 2\n\npw222\n\npw111\n' | ./加密管理.command "$T"   # 菜单选择 → 闲置分钟回车 → 密码
```

要点：
- 菜单 `read` 和 gocryptfs 密码都消费同一个 stdin，printf 的行序必须严格对齐。
- 排序是 `sort` 字典序（`sub/vault2` 排在 `vault1` 前），喂密码前先看列表顺序。
- 验证挂载用 `mount | grep macfuse`，读写验证用挂载点内 `echo > file && cat`。
- 测完 `umount` 全部挂载点并 `rm -rf` 临时目录，不要留挂载残留。

## 修改后的同步义务

`加密管理.command` 的"生产副本"可能被用户复制到仓库外（如 `~/Documents/`）。改动功能或行为后：更新 README.md 对应说明，并提醒用户同步外部副本。
