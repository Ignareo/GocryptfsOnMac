// lock-watcher.swift — gocryptfs 自动锁定守护进程
//
// 监听三类事件并卸载所有 macFUSE(gocryptfs) 挂载：
//   1. 系统睡眠前（IOKit，IOAllowPowerChange 保证卸载完成才真正入睡）
//   2. 锁屏（DistributedNotificationCenter: com.apple.screenIsLocked）
//   3. 快速切换用户（NSWorkspace.sessionDidResignActiveNotification）
//
// 卸载逻辑（mount 表解析）与「加密管理.command」中的 list_mounts/do_unmount 等效，
// 内嵌于此是为了让守护进程自包含、不依赖脚本所在路径；如修改解析逻辑请两边同步。
//
// 可选配置：存在文件 ~/.config/gocryptfs-lockwatcher/force 时，
// 优雅卸载失败后追加 diskutil unmount force（有未保存数据丢失风险）。

import AppKit
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
    let shell = """
    mount | grep '(macfuse' | sed -E 's/^.* on (.*) \\(macfuse.*/\\1/' | while IFS= read -r mp; do
      [ -n "$mp" ] || continue
      umount "$mp" 2>/dev/null || diskutil unmount "$mp" >/dev/null 2>&1 || \(forceLine)
      echo "unmounted: $mp (rc=$?)"
    done
    """
    let p = Process()
    p.launchPath = "/bin/sh"
    p.arguments = ["-c", shell]
    p.launch()
    p.waitUntilExit()
    log("unmount-all finished, reason=\(reason), force=\(force), exit=\(p.terminationStatus)")
}

// --- 锁屏 / 解锁 ---
DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.apple.screenIsLocked"),
    object: nil, queue: nil
) { _ in unmountAll(reason: "screenIsLocked") }

// --- 快速切换用户 ---
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.sessionDidResignActiveNotification,
    object: nil, queue: nil
) { _ in unmountAll(reason: "sessionDidResignActive") }

// --- 系统睡眠（同步阻塞式：先卸载，再放行睡眠） ---
var rootPort: io_connect_t = 0

// kIOMessageSystemWillSleep = iokit_common_msg(0x280)，该宏未导出到 Swift，硬编码其值
let kIOMessageSystemWillSleepValue: UInt32 = 0xE0000280

let powerCallback: @convention(c) (
    UnsafeMutableRawPointer?, io_service_t, UInt32, UnsafeMutableRawPointer?
) -> Void = { _, _, messageType, messageArgument in
    if messageType == kIOMessageSystemWillSleepValue {
        unmountAll(reason: "systemWillSleep")
        if let arg = messageArgument {
            IOAllowPowerChange(rootPort, Int(bitPattern: arg))
        }
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
CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

log("lock-watcher started (pid \(ProcessInfo.processInfo.processIdentifier))")
RunLoop.main.run()
