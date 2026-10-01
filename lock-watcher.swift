// lock-watcher.swift — gocryptfs 自动锁定守护进程
//
// 监听四类事件并卸载所有 gocryptfs 挂载（仅 gocryptfs，不动 sshfs/NTFS-3G 等其他 macFUSE 挂载）：
//   1. 系统睡眠前（IOKit kIOMessageSystemWillSleep，IOAllowPowerChange 保证卸载完成才真正入睡）
//   2. 空闲睡眠征询（kIOMessageCanSystemSleep，按 Apple 文档必须应答，否则系统空等 30 秒）
//   3. 锁屏（DistributedNotificationCenter: com.apple.screenIsLocked）
//   4. 快速切换用户 / 关机重启注销（NSWorkspace sessionDidResignActive / willPowerOff）
//   另：启动时若屏幕已处于锁定状态（如锁屏中崩溃被 launchd 拉起），立即卸载一次。
//
// 卸载逻辑（mount 表解析）与「加密管理.command」中的 list_mounts/do_unmount 等效，
// 内嵌于此是为了让守护进程自包含、不依赖脚本所在路径；如修改解析逻辑请两边同步。
//
// 可选配置：存在文件 ~/.config/gocryptfs-lockwatcher/force 时，
// 优雅卸载失败后追加 diskutil unmount force（有未保存数据丢失风险）。

import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

let forceFlagPath = NSHomeDirectory() + "/.config/gocryptfs-lockwatcher/force"

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardOutput.write(Data("\(ts) \(msg)\n".utf8))
}

func unmountAll(reason: String) {
    let force = FileManager.default.fileExists(atPath: forceFlagPath)
    let forceLine = force ? "diskutil unmount force \"$mp\" >/dev/null 2>&1" : "false"
    // 只卸 gocryptfs 挂载：以加密目录（mount 源）内存在 gocryptfs.conf 为判定
    let shell = """
    mount | grep '(macfuse' | sed -E 's/^(.*) on (.*) \\(macfuse.*/\\1\t\\2/' | while IFS='\t' read -r src mp; do
      [ -n "$mp" ] || continue
      [ -f "$src/gocryptfs.conf" ] || { echo "skip non-gocryptfs: $mp"; continue; }
      umount "$mp" 2>/dev/null || diskutil unmount "$mp" >/dev/null 2>&1 || \(forceLine)
      echo "unmounted: $mp (rc=$?)"
    done
    """
    let p = Process()
    let pipe = Pipe()
    p.launchPath = "/bin/sh"
    p.arguments = ["-c", shell]
    p.standardOutput = pipe
    p.launch()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    if !out.isEmpty { FileHandle.standardOutput.write(Data(out.utf8)) }
    // 幂等：同一事件源（如睡眠同时触发 willSleep + screenIsLocked）重复调用无副作用
    if out.contains("unmounted:") || out.contains("skip ") {
        log("unmount-all finished, reason=\(reason), force=\(force), exit=\(p.terminationStatus)")
    } else {
        log("no gocryptfs mounts (\(reason))")
    }
}

// --- 锁屏 ---
DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.apple.screenIsLocked"),
    object: nil, queue: nil
) { _ in unmountAll(reason: "screenIsLocked") }

// --- 快速切换用户 ---
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.sessionDidResignActiveNotification,
    object: nil, queue: nil
) { _ in unmountAll(reason: "sessionDidResignActive") }

// --- 关机 / 重启 / 注销（IOKit 电源接口不覆盖此路径，需 NSWorkspace 兜底） ---
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.willPowerOffNotification,
    object: nil, queue: nil
) { _ in unmountAll(reason: "willPowerOff") }

// --- 系统睡眠（同步阻塞式：先卸载，再放行睡眠） ---
var rootPort: io_connect_t = 0

// 这两个宏（iokit_common_msg(...)）未导出到 Swift，硬编码值（已用 C 在本机 SDK 验证）
let kIOMessageCanSystemSleepValue: UInt32 = 0xE0000270
let kIOMessageSystemWillSleepValue: UInt32 = 0xE0000280

let powerCallback: @convention(c) (
    UnsafeMutableRawPointer?, io_service_t, UInt32, UnsafeMutableRawPointer?
) -> Void = { _, _, messageType, messageArgument in
    switch messageType {
    case kIOMessageCanSystemSleepValue:
        // 空闲睡眠征询：立即放行（本进程不阻止睡眠）
        if let arg = messageArgument {
            IOAllowPowerChange(rootPort, Int(bitPattern: arg))
        }
    case kIOMessageSystemWillSleepValue:
        unmountAll(reason: "systemWillSleep")
        if let arg = messageArgument {
            IOAllowPowerChange(rootPort, Int(bitPattern: arg))
        }
    default:
        break
    }
}

var notifyPort: IONotificationPortRef?
var notifier: io_object_t = 0
rootPort = IORegisterForSystemPower(nil, &notifyPort, powerCallback, &notifier)
guard rootPort != 0, let notifyPort else {
    log("FATAL: IORegisterForSystemPower failed")
    exit(1)
}
guard let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort)?.takeUnretainedValue() else {
    log("FATAL: IONotificationPortGetRunLoopSource failed")
    exit(1)
}
CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

log("lock-watcher started (pid \(ProcessInfo.processInfo.processIdentifier))")

// 启动时若屏幕已锁定（例如锁屏状态下进程崩溃被 launchd 重新拉起），补一次卸载
if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
   (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
    unmountAll(reason: "startupScreenLocked")
}

RunLoop.main.run()
