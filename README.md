# GocryptfsOnMac — gocryptfs 加密文件夹双击管理工具（macOS）

一个 `.command` 脚本：双击后在终端打开，自动扫描当前目录下的 [gocryptfs](https://github.com/rfjakob/gocryptfs) 加密文件夹，输入序号即可挂载解密 / 卸载，无需记任何命令。

## 功能

- **自动发现**：扫描脚本所在目录的子目录（深度 ≤ 2），以是否存在 `gocryptfs.conf` 判定加密文件夹
- **一键挂载**：选中序号后，在加密文件夹**同级**自动创建 `名字[解密]` 目录并挂载，密码在终端安全输入（不回显、不落盘），成功后自动打开 Finder
- **状态识别**：实时显示每个加密文件夹是 `[未挂载]` 还是 `[已挂载 → 挂载点]`；已挂载的可选择卸载或在 Finder 打开
- **闲置自动卸载**：挂载时可选"N 分钟无文件操作自动卸载"，用完即走不留明文入口
- **全部卸载**：一键 `u`，下班前/合盖前清理所有挂载
- **新建加密文件夹**：菜单 `n`，引导式 `gocryptfs -init`，并提醒抄写 master key
- **修改密码**：菜单 `p`，调用 `gocryptfs -passwd`
- **安全保护**：`[解密]` 目录已存在且里面有真实文件、又不是挂载状态时，拒绝挂载并警告——防止把明文写进普通目录却误以为已解密（Finder 自动生成的 `.DS_Store` 会自动清理，不影响）
- **自动锁定（可选）**：安装守护进程后，**系统睡眠前 / 锁屏 / 快速切换用户** 时自动卸载所有 gocryptfs 挂载，合盖走人无需手动操作

## 系统要求

| 组件 | 版本 | 说明 |
|---|---|---|
| macOS | 12 – 27 | 已在 macOS 27 Golden Gate / Apple Silicon 实测 |
| [macFUSE](https://macfuse.github.io) | **≥ 5.3.3，推荐 5.4.0+** | macOS 26 Tahoe / 27 Golden Gate **必须** ≥ 5.3.3；旧系统可用更早版本 |
| [gocryptfs](https://github.com/rfjakob/gocryptfs) | ≥ 2.x（实测 2.6.1） | |

## 安装步骤

**1. 安装 macFUSE**（gocryptfs 的挂载依赖）：

```bash
brew install --cask macfuse
# 或从官网下载 pkg: https://macfuse.github.io
```

安装后需要到 **系统设置 → 隐私与安全性** 批准 macFUSE 系统扩展，并按提示重启。Apple Silicon 若提示需降低安全策略，在恢复模式下允许内核扩展（仅首次）。

> ⚠️ **升级 macOS 大版本后务必升级 macFUSE**。例如 macOS 27 上旧版 macFUSE 会报
> `The installed version of macFUSE is too old for the operating system`，
> 执行 `brew upgrade --cask macfuse` 并在系统设置重新批准即可。

**2. 安装 gocryptfs**：

```bash
brew install gocryptfs          # Homebrew
sudo port install gocryptfs     # 或 MacPorts
```

**3. 安装本脚本**：

```bash
curl -LO https://raw.githubusercontent.com/Ignareo/GocryptfsOnMac/main/加密管理.command
chmod +x 加密管理.command
```

把 `加密管理.command` 放到任意位置（如 `~/Documents`）。**双击后默认扫描 `~/Documents` 的子目录（深度 ≤ 2）**，与脚本放在哪无关。想扫描其他目录：

```bash
./加密管理.command /path/to/其他目录        # 命令行参数
GOCRYPTFS_BASE_DIR=/path ./加密管理.command   # 或环境变量
```

> 如果 Finder 双击提示无法打开（未公证），在文件上**右键 → 打开**即可。

## 使用方法

**双击 `加密管理.command`**，终端界面：

```
====== gocryptfs 加密管理 ======
目录: /Users/keke/Documents
  1) 加密A   [未挂载]
----------------------------------
输入序号进行挂载/卸载，多个序号用空格分隔
  u) 全部卸载   n) 新建加密文件夹   p) 修改密码
  r) 刷新       q) 退出
>
```

- 输入 `1` → 可选输入闲置自动卸载分钟数（直接回车不启用）→ 输入密码 → 挂载完成并打开 Finder
- 解密后的文件在 `加密A[解密]` 中读写，加密目录 `加密A` 本身始终保持密文，可直接同步到网盘
- 用完输入 `u` 全部卸载（或选中对应序号单独卸载）

## 自动锁定（可选）

双击 **`安装自动锁定.command`**，会编译并安装一个 launchd 守护进程（登录自启、崩溃自动拉起，零第三方依赖）。之后：

- **合盖/系统睡眠前**：守护进程先卸载全部挂载，再放行睡眠（IOKit 同步接口保证顺序）
- **锁屏**（Ctrl+Cmd+Q / 菜单锁屏）：立即卸载
- **快速切换用户 / 关机重启注销**：立即卸载
- 只卸载 gocryptfs 挂载（以加密目录内的 `gocryptfs.conf` 判定），**不影响 sshfs / NTFS-3G 等其他 macFUSE 挂载**

唤醒/解锁后**不会自动重挂**（需要重新输密码，这正是安全意义），双击 `加密管理.command` 一键重挂即可。

其他说明：

- 日志：`~/Library/Logs/GocryptfsLockWatcher.log`
- 若卸载时挂载点正被占用（有程序打开着文件），默认跳过保留挂载；要强制卸载就执行
  `mkdir -p ~/.config/gocryptfs-lockwatcher && touch ~/.config/gocryptfs-lockwatcher/force`
  （注意：强制卸载后，编辑器里未保存的修改将无法写回）
- 卸载守护进程：再次双击 `安装自动锁定.command` 选 `2`
- 命令行也可以手动全部卸载：`加密管理.command --unmount-all`

## 常见问题

**挂载点了没反应 / 卡住**
多半是 macFUSE 系统扩展未批准：系统设置 → 隐私与安全性，看是否有待批准项，批准后重试（必要时重启）。

**提示 `Invalid mountpoint: directory ... not empty`**
脚本已自动清理 `.DS_Store`；若仍报此错，说明 `[解密]` 目录里有真实文件，请手动检查处理（这是防呆设计）。

**忘记密码**
用 `-init` 时保存的 master key 恢复，参见 [gocryptfs 文档](https://github.com/rfjakob/gocryptfs#master-key)。没有 master key 则无法恢复，请务必抄写保存。

## 工作原理（简述）

- 判定：`find` 扫描深度 ≤ 2 的子目录中的 `gocryptfs.conf`
- 已挂载识别：解析 `mount` 输出中 `(macfuse, ...)` 行，其设备名即加密目录、挂载点即解密目录，路径经 `pwd -P` 规范化比对
- 挂载：`gocryptfs <加密目录> <名字[解密]>`，密码由 gocryptfs 进程直接从终端读取，不经过脚本变量

## License

MIT
