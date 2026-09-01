import SwiftUI
import AppKit
import Foundation

// MARK: - 常量
let kHostsBlockStart = "# === WorkBuddy 更新屏蔽器 ==="
let kHostsPath = "/etc/hosts"
let kBlockedDomain = "download.codebuddy.cn"
// WorkBuddy 自动下载更新包落地的本地目录（更新日志已证实）
let kCacheBase = NSHomeDirectory() + "/Library/Caches/com.workbuddy.workbuddy.BundleMigration"
let kDownloadDir = kCacheBase + "/downloads"
let kExtractedDir = kCacheBase + "/extracted"

// MARK: - App 入口
@main
struct WBBlockerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BlockerModel()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { model.refresh(); model.applyPersisted() }
        }
    }
}

// 锁定窗口：禁止手动缩放，固定为「自适应缩放」后的尺寸（不同分辨率机子等比缩小，不出现滚动条）
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 设计基准尺寸（ContentView 与窗口共用）
    static let DESIGN_W: CGFloat = 720
    static let DESIGN_H: CGFloat = 840
    // 根据主屏可见区计算等比缩放比例（最大 1.0，超出则缩小）
    static var adaptiveScale: CGFloat {
        guard let screen = NSScreen.main else { return 1 }
        let vf = screen.visibleFrame
        return min(1.0, (vf.height * 0.90) / DESIGN_H, (vf.width * 0.92) / DESIGN_W)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let win = NSApp.windows.first else { return }
        let s = Self.adaptiveScale
        let w = Self.DESIGN_W * s
        let h = Self.DESIGN_H * s
        win.styleMask.remove(.resizable)
        win.setContentSize(NSSize(width: w, height: h))
        win.contentMinSize = NSSize(width: w, height: h)
        win.contentMaxSize = NSSize(width: w, height: h)
        win.center()
    }
}

// MARK: - 数据模型
final class BlockerModel: ObservableObject {
    @Published var blocked = false
    @Published var statusText = "检测中…"
    @Published var message = ""
    @Published var busy = false
    @Published var checkResult = ""

    // 手动备份 / 禁止下载模式 状态（持久化到 UserDefaults）
    @Published var backupFolder: String = UserDefaults.standard.string(forKey: "wbBackupFolder") ?? ""
    // 禁止下载模式：合并锁定 downloads/ 与 extracted/ 两个目录（与自动备份互斥）
    @Published var downloadBlockMode: Bool = UserDefaults.standard.bool(forKey: "wbDownloadBlockMode")
    @Published var lastBackupLog: String = ""
    @Published var toastText: String = ""          // 1 秒浮窗提示
    private var toastWorkItem: DispatchWorkItem?
    private var backupSource: DispatchSourceFileSystemObject?

    func refresh() {
        let hosts = (try? String(contentsOfFile: kHostsPath, encoding: .utf8)) ?? ""
        blocked = hosts.contains(kHostsBlockStart)
        statusText = blocked
            ? "已启用屏蔽 · \(kBlockedDomain) 已被屏蔽"
            : "未启用屏蔽 · WorkBuddy 仍可连接更新服务器"
    }

    func enable() {
        busy = true; defer { busy = false }
        let body = "#!/bin/bash\n" +
            "cp \(kHostsPath) /tmp/wbupdateblocker_hosts.bak 2>/dev/null\n" +
            "if ! grep -q '\(kHostsBlockStart)' \(kHostsPath); then\n" +
            "  printf '\\n\(kHostsBlockStart)\\n0.0.0.0 \(kBlockedDomain)\\n::1 \(kBlockedDomain)\\n# === end ===\\n' >> \(kHostsPath)\n" +
            "fi\n" +
            "echo done\n"
        let res = runWithAdmin(body)
        refresh()
        message = res.contains("done")
            ? "已启用屏蔽（已请求 sudo 授权写入 /etc/hosts）。更新包下载被阻断，重启 WorkBuddy 后彻底生效。"
            : "启用未能确认完成：\(res)"
    }

    func disable() {
        busy = true; defer { busy = false }
        let body = "#!/bin/bash\n" +
            "cp \(kHostsPath) /tmp/wbupdateblocker_hosts.bak 2>/dev/null\n" +
            "sed -i '' '/\(kHostsBlockStart)/,/# === end ===/d' \(kHostsPath)\n" +
            "echo done\n"
        let res = runWithAdmin(body)
        refresh()
        message = res.contains("done") ? "已禁用屏蔽，/etc/hosts 已还原至启用前状态。" : "禁用未能确认完成：\(res)"
    }

    func restartWorkBuddy() {
        _ = shell("/usr/bin/osascript", ["-e", "tell application \"WorkBuddy\" to quit"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            _ = self.shell("/usr/bin/open", ["-a", "WorkBuddy"])
        }
        message = "已发送重启 WorkBuddy 指令。"
    }

    // MARK: - 自动检查 / 备份（与「禁止读写」互斥）

    // 选择备份目标文件夹
    func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择更新包备份目录"
        if panel.runModal() == .OK, let url = panel.url {
            backupFolder = url.path
            UserDefaults.standard.set(backupFolder, forKey: "wbBackupFolder")
            message = "备份目录已设为：\(backupFolder)"
        }
    }

    // 手动备份一次：检查下载目录，新包备份到 backupFolder、重复包移废纸篓、清理解压暂存（与「禁止下载模式」互斥）
    func manualBackup() {
        if backupFolder.isEmpty {
            message = "请先点击「选择备份目录」设定目标文件夹，再手动备份。"
            return
        }
        // 互斥：执行手动备份则关闭禁止下载模式（同时解锁两个目录，保证能访问 downloads/）
        if downloadBlockMode {
            downloadBlockMode = false
            UserDefaults.standard.set(false, forKey: "wbDownloadBlockMode")
            setLock(false, silent: true)
            setExtractedLock(false, silent: true)
        }
        processDownloads()
        cleanExtractedTemp()
        showToast("请重新开启屏蔽")
        message = "已手动备份：下载目录里的新更新包已备份到\n\(backupFolder)\n与备份目录同名的重复包已移入废纸篓，并清理了解压暂存 extracted/。\n（如需持续屏蔽，请重新开启「禁止下载模式」或「更改域名模式」）"
    }

    // 启动对下载目录的监听（新增文件即触发检查）
    func startBackupWatcher() {
        stopBackupWatcher()
        guard !backupFolder.isEmpty else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: kDownloadDir) {
            try? fm.createDirectory(atPath: kDownloadDir, withIntermediateDirectories: true)
        }
        let fd = open((kDownloadDir as NSString).fileSystemRepresentation, O_EVTONLY)
        guard fd >= 0 else {
            message = "无法监听下载目录（可能被读写锁锁定或目录不存在）。"
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .all,
            queue: DispatchQueue.global(qos: .background))
        src.setEventHandler { [weak self] in
            self?.processDownloads()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        backupSource = src
        processDownloads() // 首次扫描既有包
    }

    func stopBackupWatcher() {
        backupSource?.cancel()
        backupSource = nil
    }

    // 自动检查下载目录：与备份目录对比，新的备份、重复的移入废纸篓
    func processDownloads() {
        guard !downloadBlockMode else { return }   // 禁止下载模式开启时不可访问，跳过
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: kDownloadDir) else { return }
        let zips = items.filter { $0.lowercased().hasSuffix(".zip") }
        if zips.isEmpty {
            DispatchQueue.main.async { self.message = "自动检查：下载缓存中暂无更新包，无需处理。" }
            return
        }
        guard !backupFolder.isEmpty else {
            DispatchQueue.main.async {
                self.message = "自动检查：发现 \(zips.count) 个更新包，但未设置备份目录，请先「选择备份目录」。"
            }
            return
        }
        var backed = 0, removed = 0
        for z in zips {
            let src = (kDownloadDir as NSString).appendingPathComponent(z)
            let dst = (backupFolder as NSString).appendingPathComponent(z)
            if fm.fileExists(atPath: dst) {
                // 与备份目录重复 → 删除下载缓存里的那个（移入废纸篓，可恢复）
                do { try fm.trashItem(at: URL(fileURLWithPath: src), resultingItemURL: nil); removed += 1 }
                catch { /* 权限/占用，跳过 */ }
            } else {
                // 新更新包 → 备份到指定目录
                do { try fm.copyItem(atPath: src, toPath: dst); backed += 1 }
                catch { /* 跳过 */ }
            }
        }
        DispatchQueue.main.async {
            self.lastBackupLog = "自动检查完成：备份 \(backed) 个、移入废纸篓 \(removed) 个重复包"
            self.message = "自动检查完成：备份 \(backed) 个新更新包，将 \(removed) 个与备份目录重复的包移入废纸篓。"
        }
    }

    // 1 秒浮窗提示（自动消失）
    func showToast(_ text: String, seconds: Double = 1.0) {
        DispatchQueue.main.async {
            self.toastText = text
            self.toastWorkItem?.cancel()
            let item = DispatchWorkItem { self.toastText = "" }
            self.toastWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    // 将目录内容整体移入废纸篓（可恢复），返回移走的数量
    private func trashContents(of dir: String) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir) else { return 0 }
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return 0 }
        var n = 0
        for it in items {
            let p = (dir as NSString).appendingPathComponent(it)
            do { try fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil); n += 1 } catch {}
        }
        return n
    }

    // 清理解压暂存目录 extracted/ 的内容（移入废纸篓，可恢复）
    func cleanExtractedTemp() {
        _ = trashContents(of: kExtractedDir)
    }

    // 手动清理：下载缓存 downloads/ 与解压暂存 extracted/（移入废纸篓，可恢复）
    func manualClean() {
        let d = trashContents(of: kDownloadDir)
        let e = trashContents(of: kExtractedDir)
        let total = d + e
        DispatchQueue.main.async {
            self.message = "已清理 downloads/（\(d) 项）与 extracted/（\(e) 项），共 \(total) 项移入废纸篓（可恢复）。"
            self.showToast("已清理下载缓存与解压暂存，请重新开启屏蔽")
        }
    }

    // MARK: - 禁止下载模式（合并锁定 downloads/ 与 extracted/）

    func enableDownloadBlock() {
        guard !downloadBlockMode else { return }
        downloadBlockMode = true
        UserDefaults.standard.set(true, forKey: "wbDownloadBlockMode")
        setLock(true, silent: true)
        setExtractedLock(true, silent: true)
        message = "已启用「禁止下载模式」：downloads/ 与 extracted/ 目录权限均设为 000，WorkBuddy 无法写入更新包或解压暂存，下载与解压安装被双重阻断。"
    }

    func disableDownloadBlock() {
        guard downloadBlockMode else { return }
        downloadBlockMode = false
        UserDefaults.standard.set(false, forKey: "wbDownloadBlockMode")
        setLock(false, silent: true)
        setExtractedLock(false, silent: true)
        processDownloads()
        message = "已关闭「禁止下载模式」，恢复 downloads/ 与 extracted/ 读写权限，并自动检查下载目录（有则备份、重复则移废纸篓）。"
    }

    // 应用启动时恢复之前的持久化状态
    func applyPersisted() {
        if downloadBlockMode {
            setLock(true, silent: true)
            setExtractedLock(true, silent: true)
        } else {
            setLock(false, silent: true)
            setExtractedLock(false, silent: true)
            processDownloads()       // 启动时检查一次
        }
    }

    // 锁定 / 恢复下载缓存文件夹权限
    private func setLock(_ lock: Bool, silent: Bool) {
        let dir = kDownloadDir
        if lock {
            if UserDefaults.standard.string(forKey: "wbOrigMode") == nil {
                let mode = shell("/bin/sh", ["-c", "stat -f %A '\(dir)' 2>/dev/null"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !mode.isEmpty { UserDefaults.standard.set(mode, forKey: "wbOrigMode") }
            }
            _ = shell("/bin/chmod", ["000", dir])
            if !silent { message = "已禁止下载缓存目录读写（chmod 000）。WorkBuddy 无法写入更新包，更新被双重阻断。" }
        } else {
            let mode = UserDefaults.standard.string(forKey: "wbOrigMode") ?? "700"
            _ = shell("/bin/chmod", [mode, dir])
            if !silent { message = "已恢复下载缓存目录读写权限（chmod \(mode)）。" }
        }
    }

    // MARK: - 解压暂存读写锁（extracted/，随「禁止下载模式」一并控制）

    // 锁定 / 恢复解压暂存目录（extracted/）权限
    private func setExtractedLock(_ lock: Bool, silent: Bool) {
        let fm = FileManager.default
        let dir = kExtractedDir
        if lock {
            // 目录不存在则先创建，确保锁在 WorkBuddy 尚未下载时也能生效
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            if UserDefaults.standard.string(forKey: "wbExtractedOrigMode") == nil {
                let mode = shell("/bin/sh", ["-c", "stat -f %A '\(dir)' 2>/dev/null"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                UserDefaults.standard.set(mode.isEmpty ? "700" : mode, forKey: "wbExtractedOrigMode")
            }
            _ = shell("/bin/chmod", ["000", dir])
            if !silent { message = "已禁止解压暂存目录（extracted/）读写（chmod 000）。WorkBuddy 无法写入/读取解压后的待装程序，解压覆盖安装被阻断。" }
        } else {
            let mode = UserDefaults.standard.string(forKey: "wbExtractedOrigMode") ?? "700"
            _ = shell("/bin/chmod", [mode, dir])
            if !silent { message = "已恢复解压暂存目录（extracted/）读写权限（chmod \(mode)）。" }
        }
    }

    // 在 Finder 中打开 WorkBuddy 自动下载更新包落地的本地目录，并逐项说明其中三类内容
    func locateAndCheck() {
        busy = true; defer { busy = false }
        let fm = FileManager.default
        // WorkBuddy 下载更新包的真实本地目录（更新日志已证实）
        let base = NSHomeDirectory() + "/Library/Caches/com.workbuddy.workbuddy.BundleMigration"
        let downloadsDir = base + "/downloads"
        let extractedDir = base + "/extracted"
        let backupsDir = base + "/backups"

        // 在 Finder 中打开该目录
        if fm.fileExists(atPath: base) {
            _ = shell("/usr/bin/open", [base])
        }

        // 文件大小格式化
        func sizeStr(_ path: String) -> String {
            if let a = try? fm.attributesOfItem(atPath: path), let s = a[.size] as? UInt64 {
                return ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)
            }
            return "未知大小"
        }

        // ① downloads/ 下的 .zip 更新包
        var dlLines: [String] = []
        if let items = try? fm.contentsOfDirectory(atPath: downloadsDir) {
            let zips = items.filter { $0.lowercased().hasSuffix(".zip") }
            for z in zips { dlLines.append("   • \(z)  （\(sizeStr(downloadsDir + "/" + z))）") }
        }
        // ② extracted/ 下的待安装版本
        var exLines: [String] = []
        if let items = try? fm.contentsOfDirectory(atPath: extractedDir) {
            for v in items where !v.hasPrefix(".") {
                let appPath = extractedDir + "/" + v + "/WorkBuddy.app"
                let ok = fm.fileExists(atPath: appPath)
                exLines.append("   • \(v)  →  \(ok ? "内含 WorkBuddy.app（待覆盖安装到 /Applications）" : "（未找到 WorkBuddy.app）")")
            }
        }
        // ③ backups/ 备份
        var bkLines: [String] = []
        if let items = try? fm.contentsOfDirectory(atPath: backupsDir) {
            for b in items where !b.hasPrefix(".") {
                bkLines.append("   • \(b)")
            }
        }

        // 检查屏蔽状态
        let hosts = (try? String(contentsOfFile: kHostsPath, encoding: .utf8)) ?? ""
        let blockedNow = hosts.contains(kHostsBlockStart)
        let resolved = hosts.contains("0.0.0.0 \(kBlockedDomain)")
        let shieldLine = blockedNow
            ? (resolved ? "已启用 · \(kBlockedDomain) 解析到 0.0.0.0（下载被阻断，更新包不会落地）" : "已启用标记但解析行缺失（异常，建议重新启用）")
            : "未启用 · 更新包仍可下载并落到该目录"

        let dlBlock = dlLines.isEmpty
            ? "   （空 · 屏蔽已生效时不应出现新包）"
            : dlLines.joined(separator: "\n")
        let exBlock = exLines.isEmpty
            ? "   （空 · 暂无可安装版本）"
            : exLines.joined(separator: "\n")
        let bkBlock = bkLines.isEmpty
            ? "   （空 · 尚无备份）"
            : bkLines.joined(separator: "\n")

        if !fm.fileExists(atPath: base) {
            checkResult = "未找到更新下载目录：\n\(base)\n（说明 WorkBuddy 从未下载过更新包。）\n\n屏蔽状态：\(shieldLine)"
        } else {
            checkResult = """
            已在 Finder 打开更新下载目录：
            \(base)

            ① downloads/（下载缓存）
                WorkBuddy 从 \(kBlockedDomain) 拉回的更新安装包（.zip）
            \(dlBlock)

            ② extracted/（解压暂存）
                下载完成后自动解压、即将覆盖安装到 /Applications 的待装程序
            \(exBlock)

            ③ backups/（安全备份）
                覆盖安装前对当前旧版的备份，便于回退
            \(bkBlock)

            屏蔽状态：\(shieldLine)
            """
        }
        message = "已在 Finder 中打开更新下载目录，并逐项说明了其中三类内容。"
    }

    // 以管理员权限执行一段 shell 脚本（会弹出系统密码框）
    private func runWithAdmin(_ scriptBody: String) -> String {
        let tmp = "/tmp/wbupdateblocker_\(Int(Date().timeIntervalSince1970)).sh"
        try? scriptBody.write(toFile: tmp, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"bash \(tmp)\" with administrator privileges"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "err:\(error)" }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        try? FileManager.default.removeItem(atPath: tmp)
        return out
    }

    func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

// MARK: - 主界面
struct ContentView: View {
    @EnvironmentObject var model: BlockerModel
    @State private var showAbout = false
    // 固定设计尺寸 + 自适应缩放（不同分辨率机子等比缩小，无滚动条）
    private let DESIGN_W: CGFloat = AppDelegate.DESIGN_W
    private let DESIGN_H: CGFloat = AppDelegate.DESIGN_H
    private var scale: CGFloat { AppDelegate.adaptiveScale }

    // 单个模式的状态徽标
    private func modeStatusBadge(_ title: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(on ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            Text("\(title)：").font(.subheadline)
            Text(on ? "已启用" : "未启用")
                .font(.subheadline.bold())
                .foregroundStyle(on ? .green : .red)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            // 标题栏
            HStack {
                if let img = NSImage(named: "AppIcon") {
                    Image(nsImage: img).resizable().frame(width: 50, height: 50)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("WorkBuddy 更新屏蔽器").font(.title2.bold())
                    Text("两种模式，任选其一或组合，阻断强制更新").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关于") { showAbout = true }
            }
            Divider()
            // 顶部：两个模式分别的开启状态 + 总体提示
            VStack(alignment: .leading, spacing: 8) {
                Text("模式状态").font(.headline)
                HStack(spacing: 20) {
                    modeStatusBadge("更改域名模式", on: model.blocked)
                    modeStatusBadge("禁止下载模式", on: model.downloadBlockMode)
                }
                let overallOn = model.blocked || model.downloadBlockMode
                Text(overallOn
                    ? "已启用屏蔽，请打开 workbuddy 检测更新 查看效果"
                    : "未启用屏蔽：WorkBuddy 仍可直接更新服务")
                    .font(.headline)
                    .foregroundStyle(overallOn ? .green : .red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)

            // 共享上下文：更新下载目录的三类内容
            VStack(alignment: .leading, spacing: 5) {
                Text("更新下载目录里包含的三类内容").font(.subheadline.bold())
                Label("downloads/：下载缓存 — 从更新服务器拉回的更新包 .zip", systemImage: "tray.and.arrow.down")
                    .font(.caption)
                Label("extracted/：解压暂存 — 待安装的 WorkBuddy.app（目录名即版本号）", systemImage: "archivebox")
                    .font(.caption)
                Label("backups/：安全备份 — 覆盖安装前的旧版备份，可回退", systemImage: "shield.lefthalf.filled")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.10)))

            // 左右分屏：两个模式
            HStack(alignment: .top, spacing: 14) {
                // 左：更改域名模式
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe").font(.title3)
                        Text("更改域名模式").font(.headline)
                    }
                    Text("原理：更新包下载域名为 \(kBlockedDomain)（更新日志证实）。将其解析到 0.0.0.0 即可阻断更新安装，不影响 AI / 核心功能。\n副作用：技能市场、头像等走同一 CDN 的资源可能无法加载（非核心功能）。")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Button(action: { model.enable() }) { Label("启用屏蔽", systemImage: "shield.fill") }
                        .controlSize(.large).disabled(model.blocked || model.busy).frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { model.disable() }) { Label("禁用屏蔽", systemImage: "shield.slash") }
                        .controlSize(.large).disabled(!model.blocked || model.busy).frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { model.restartWorkBuddy() }) { Label("重启 WorkBuddy", systemImage: "arrow.clockwise") }
                        .controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { model.locateAndCheck() }) { Label("检查更新下载目录", systemImage: "magnifyingglass") }
                        .controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.10)))

                // 右：禁止下载模式
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.shield").font(.title3)
                        Text("禁止下载模式").font(.headline)
                    }
                    Text("锁定 downloads/ 与 extracted/ 两个目录权限为 000，使 WorkBuddy 无法写入更新包或解压暂存，从源头阻断更新。")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Button(action: { model.enableDownloadBlock() }) { Label("启用屏蔽", systemImage: "shield.fill") }
                        .controlSize(.large).disabled(model.downloadBlockMode).frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { model.disableDownloadBlock() }) { Label("禁用屏蔽", systemImage: "shield.slash") }
                        .controlSize(.large).disabled(!model.downloadBlockMode).frame(maxWidth: .infinity, alignment: .leading)
                    Text("同时锁定 downloads/ 与 extracted/（chmod 000）。与「手动备份」互斥。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    Button(action: { model.manualBackup() }) { Label("手动备份更新包", systemImage: "arrow.down.doc") }
                        .controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Button("选择备份目录") { model.chooseBackupFolder() }
                        if !model.backupFolder.isEmpty {
                            Text(model.backupFolder)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if !model.lastBackupLog.isEmpty {
                        Text(model.lastBackupLog).font(.caption2).foregroundStyle(.green)
                    }
                    Text("点击后立即执行：检查下载目录，新的 .zip 备份到上方文件夹；与备份目录同名的重复包移入废纸篓，并清理解压暂存 extracted/。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    Button(action: { model.manualClean() }) {
                        Label("手动清理下载缓存与解压暂存", systemImage: "trash")
                    }
                    .controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
                    Text("立即将 downloads/ 与 extracted/ 内的更新包 / 解压暂存全部移入废纸篓（可恢复），不影响当前屏蔽设置。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.10)))
            }

            // message 区：仅非空时显示（空时不占位，避免底部留白）
            if !model.message.isEmpty {
                Text(model.message)
                    .font(.callout).foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38, alignment: .topLeading)
                    .lineLimit(2)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.1)))
            }

            // checkResult 区：仅非空时显示（按「检查更新下载目录」后才有内容）
            if !model.checkResult.isEmpty {
                Text(model.checkResult)
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .topLeading)
                    .lineLimit(3)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
            }

            Spacer(minLength: 0)
            Text("Copyright © 2026 banqiu. Released under the MIT License.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: DESIGN_W, height: DESIGN_H)
        .scaleEffect(scale)
        .frame(width: DESIGN_W * scale, height: DESIGN_H * scale)
        .overlay(alignment: .top) {
            if !model.toastText.isEmpty {
                Text(model.toastText)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.82)))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                    .offset(y: 56)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toastText)
        .animation(.easeInOut(duration: 0.2), value: model.message)
        .animation(.easeInOut(duration: 0.2), value: model.checkResult)
        .sheet(isPresented: $showAbout) { AboutView() }
    }
}

// MARK: - 关于界面
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            if let img = NSImage(named: "AppIcon") {
                Image(nsImage: img).resizable().frame(width: 72, height: 72)
            }
            Text("WorkBuddy 更新屏蔽器").font(.title3.bold())
            Text("版本 1.17").font(.caption).foregroundStyle(.secondary)
            Text("通过 /etc/hosts 屏蔽 \(kBlockedDomain)，阻断 WorkBuddy 自动更新下载。\n不修改 WorkBuddy 应用本体，可随时还原。")
                .font(.callout).multilineTextAlignment(.center).frame(maxWidth: 320)
            Divider()
            Text("Copyright © 2026 banqiu. Released under the MIT License.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 380, height: 300)
    }
}
