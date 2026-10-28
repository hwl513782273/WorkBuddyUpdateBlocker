import SwiftUI
import AppKit
import Foundation

// MARK: - 常量
let kHostsPath = "/etc/hosts"
let kHostsBlockStart = "# === WorkBuddy 更新屏蔽器 ==="
let kHostsBlockEnd = "# === end ==="
// 更新包下载域（2026-10 实测：feed 走主站 /v2/update，安装包仍从该域拉取）
let kPrimaryDomain = "download.codebuddy.cn"
let kGuardLabel = "com.banqiu.wbupdateblocker.guard"
let kGuardPlist = "/Library/LaunchDaemons/" + kGuardLabel + ".plist"
let kGuardScript = "/usr/local/libexec/wbupdateblocker-guard.sh"
// 已知 bundle id（5.9.x 起改为 com.tencent.workbuddy.mac）
let kKnownBundleIds = ["com.tencent.workbuddy.mac", "com.workbuddy.workbuddy"]

// MARK: - WorkBuddy 安装探测
struct WBInfo {
    var appPath: String
    var bundleId: String
    var version: String
    var cacheBase: String

    var downloadsDir: String { cacheBase + "/downloads" }
    var extractedDir: String { cacheBase + "/extracted" }
    var backupsDir: String { cacheBase + "/backups" }
    var pendingJSON: String { cacheBase + "/pending-update.json" }
    var lockJSON: String { cacheBase + "/install-in-progress.json" }

    static func detect() -> WBInfo {
        let fm = FileManager.default
        let homes = ["/Applications/WorkBuddy.app",
                     NSHomeDirectory() + "/Applications/WorkBuddy.app"]
        for p in homes {
            let plist = p + "/Contents/Info.plist"
            if let d = NSDictionary(contentsOfFile: plist) {
                let bid = (d["CFBundleIdentifier"] as? String) ?? kKnownBundleIds[0]
                let ver = (d["CFBundleShortVersionString"] as? String) ?? "未知"
                return WBInfo(appPath: p, bundleId: bid, version: ver,
                              cacheBase: NSHomeDirectory() + "/Library/Caches/\(bid).BundleMigration")
            }
        }
        // 未安装：退化为「缓存目录实际存在」的那个 bundle id
        for bid in kKnownBundleIds {
            let base = NSHomeDirectory() + "/Library/Caches/\(bid).BundleMigration"
            if fm.fileExists(atPath: base) {
                return WBInfo(appPath: "", bundleId: bid, version: "未安装",
                              cacheBase: base)
            }
        }
        let bid = kKnownBundleIds[0]
        return WBInfo(appPath: "", bundleId: bid, version: "未安装",
                      cacheBase: NSHomeDirectory() + "/Library/Caches/\(bid).BundleMigration")
    }
}

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

// 锁定窗口：禁止手动缩放，固定为「自适应缩放」后的尺寸
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let DESIGN_W: CGFloat = 720
    // 名义高度：仅用于小屏等比缩放的参考值，实际窗口高度按内容实测自适应
    static let DESIGN_H: CGFloat = 618
    static var adaptiveScale: CGFloat {
        guard let screen = NSScreen.main else { return 1 }
        let vf = screen.visibleFrame
        return min(1.0, (vf.height * 0.92) / DESIGN_H, (vf.width * 0.92) / DESIGN_W)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let win = NSApp.windows.first else { return }
        let s = Self.adaptiveScale
        win.styleMask.remove(.resizable)
        // 初始尺寸先给个参考值，真实高度由 ContentView 实测后回调调整
        win.setContentSize(NSSize(width: (Self.DESIGN_W * s).rounded(), height: (Self.DESIGN_H * s).rounded()))
        win.title = "WorkBuddy 更新屏蔽器"
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

    @Published var backupFolder: String = UserDefaults.standard.string(forKey: "wbBackupFolder") ?? ""
    @Published var downloadBlockMode: Bool = UserDefaults.standard.bool(forKey: "wbDownloadBlockMode")
    @Published var lastBackupLog: String = ""
    @Published var toastText: String = ""

    // 新增：WorkBuddy 探测信息 / 守护 / 待装包
    @Published var wbVersion = "检测中"
    @Published var wbBundleId = "-"
    @Published var cacheBase = ""
    @Published var guardInstalled = false
    @Published var guardRunning = false
    @Published var pendingInfo = ""
    @Published var hasPending = false
    @Published var lockDetail = "检测中…"
    @Published var domains: [String] = [kPrimaryDomain]

    private var toastWorkItem: DispatchWorkItem?
    private var backupSource: DispatchSourceFileSystemObject?
    private var statusTimer: Timer?
    private var wb = WBInfo.detect()

    // MARK: 状态刷新

    func refresh() {
        wb = WBInfo.detect()
        wbVersion = wb.version
        wbBundleId = wb.bundleId
        cacheBase = wb.cacheBase

        let hosts = hostsText()
        blocked = hosts.contains(kHostsBlockStart)
        let active = activeDomains()
        domains = active
        statusText = blocked
            ? "已启用屏蔽 · " + active.joined(separator: "、") + " 已被屏蔽"
            : "未启用屏蔽 · WorkBuddy 仍可连接更新服务器"

        guardInstalled = FileManager.default.fileExists(atPath: kGuardPlist)
        guardRunning = guardInstalled && guardIsRunning()

        refreshPending()

        // 目录锁真实状态（按两个目录回读，不再只信 UserDefaults）
        let dlM = dirMode(wb.downloadsDir)
        let exM = dirMode(wb.extractedDir)
        let dlLocked = isLockedMode(dlM)
        let exLocked = isLockedMode(exM)
        if dlLocked || exLocked {
            if !downloadBlockMode { downloadBlockMode = true; UserDefaults.standard.set(true, forKey: "wbDownloadBlockMode") }
        }
        if dlM.isEmpty || exM.isEmpty {
            lockDetail = "缓存子目录尚未创建 · 启用目录锁时会自动建好再锁"
        } else if dlLocked && exLocked {
            lockDetail = "downloads/ 000 · extracted/ 000（已锁定，WorkBuddy 写不进也解不开）"
        } else {
            lockDetail = "downloads/ \(dlLocked ? "000" : dlM) · extracted/ \(exLocked ? "000" : exM)（未完全锁定）"
        }
    }

    private func hostsText() -> String {
        (try? String(contentsOfFile: kHostsPath, encoding: .utf8)) ?? ""
    }

    // 当前 hosts 段内实际生效的域名
    private func activeDomains() -> [String] {
        let text = hostsText()
        guard let s = text.range(of: kHostsBlockStart),
              let e = text.range(of: kHostsBlockEnd, range: s.upperBound..<text.endIndex) else {
            return [kPrimaryDomain]
        }
        let block = String(text[s.upperBound..<e.lowerBound])
        var found: [String] = []
        for line in block.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let host = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if !host.isEmpty && !found.contains(host) { found.append(host) }
        }
        return found.isEmpty ? [kPrimaryDomain] : found
    }

    // 待装包状态：downloads / extracted / pending-update.json / install-in-progress.json
    private func refreshPending() {
        let fm = FileManager.default
        var parts: [String] = []
        var bytes: UInt64 = 0
        var count = 0

        func addDir(_ dir: String, label: String) {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for it in items where !it.hasPrefix(".") {
                let p = (dir as NSString).appendingPathComponent(it)
                if let a = try? fm.attributesOfItem(atPath: p), let s = a[.size] as? UInt64 { bytes += s }
                count += 1
                parts.append("\(label)/\(it)")
            }
        }
        addDir(wb.downloadsDir, label: "downloads")
        addDir(wb.extractedDir, label: "extracted")

        var phase = ""
        if let d = readJSON(wb.lockJSON), let ph = d["phase"] as? String { phase = ph }
        let hasJSON = fm.fileExists(atPath: wb.pendingJSON) || fm.fileExists(atPath: wb.lockJSON)
        if hasJSON { count += 1 }

        // /Applications 里的 staged 目录
        var staged = 0
        if let items = try? fm.contentsOfDirectory(atPath: "/Applications") {
            staged = items.filter { $0.hasPrefix(".WorkBuddy.app.installing") }.count
            if staged > 0 { count += staged; parts.append("staged×\(staged)") }
        }

        hasPending = count > 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let lockedNow = isLockedMode(dirMode(wb.downloadsDir)) || isLockedMode(dirMode(wb.extractedDir))
        if count == 0 {
            pendingInfo = lockedNow
                ? "无待装更新包（目录已锁，内容不可读属正常）"
                : "无待装更新包"
        } else {
            pendingInfo = "发现 \(count) 项待装内容（约 \(size)）"
                + (staged > 0 ? " · 已 staging 到 /Applications" : "")
                + (phase.isEmpty ? "" : " · phase=\(phase)")
        }
    }

    private func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func guardIsRunning() -> Bool {
        let out = shell("/bin/launchctl", ["print", "system/" + kGuardLabel])
        return out.contains("state = running")
    }

    // MARK: 域名屏蔽

    func enable() {
        busy = true; defer { busy = false }
        let body = """
        #!/bin/bash
        cp \(kHostsPath) /tmp/wbupdateblocker_hosts.bak 2>/dev/null
        if ! /usr/bin/grep -qF '\(kHostsBlockStart)' \(kHostsPath); then
          /usr/bin/printf '\\n%s\\n' '\(kHostsBlockStart)' >> \(kHostsPath)
          /usr/bin/printf '0.0.0.0 %s\\n' '\(kPrimaryDomain)' >> \(kHostsPath)
          /usr/bin/printf '::1 %s\\n' '\(kPrimaryDomain)' >> \(kHostsPath)
          /usr/bin/printf '%s\\n' '\(kHostsBlockEnd)' >> \(kHostsPath)
        fi
        /usr/bin/dscacheutil -flushcache 2>/dev/null
        /bin/echo done
        """
        let res = runWithAdmin(body)
        refresh()
        message = res.contains("done")
            ? "已启用屏蔽：\(kPrimaryDomain) 解析到 0.0.0.0，更新包无法下载。重启 WorkBuddy 后彻底生效。"
            : "启用未能确认完成：\(res)"
    }

    func disable() {
        busy = true; defer { busy = false }
        let body = """
        #!/bin/bash
        cp \(kHostsPath) /tmp/wbupdateblocker_hosts.bak 2>/dev/null
        /usr/bin/sed -i '' '/\(kHostsBlockStart)/,/\(kHostsBlockEnd)/d' \(kHostsPath)
        /usr/bin/dscacheutil -flushcache 2>/dev/null
        /bin/echo done
        """
        let res = runWithAdmin(body)
        refresh()
        message = res.contains("done")
            ? "已禁用屏蔽，/etc/hosts 已还原。"
            : "禁用未能确认完成：\(res)"
    }

    func restartWorkBuddy() {
        _ = shell("/usr/bin/osascript", ["-e", "tell application \"WorkBuddy\" to quit"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            _ = self.shell("/usr/bin/open", ["-a", "WorkBuddy"])
        }
        message = "已发送重启 WorkBuddy 指令。"
    }

    // MARK: 开机守护（LaunchDaemon）

    func enableGuard() {
        busy = true; defer { busy = false }
        let script = """
        #!/bin/sh
        # WorkBuddy 更新屏蔽器 · hosts 守护（每 5 分钟检查一次）
        HOSTS=/etc/hosts
        MARK='\(kHostsBlockStart)'
        END='\(kHostsBlockEnd)'
        DOMAIN='\(kPrimaryDomain)'
        if ! /usr/bin/grep -qF "$MARK" "$HOSTS"; then
          cp "$HOSTS" /tmp/wbupdateblocker_hosts.bak 2>/dev/null
          /usr/bin/printf '\\n%s\\n' "$MARK" >> "$HOSTS"
          /usr/bin/printf '0.0.0.0 %s\\n::1 %s\\n' "$DOMAIN" "$DOMAIN" >> "$HOSTS"
          /usr/bin/printf '%s\\n' "$END" >> "$HOSTS"
          /usr/bin/dscacheutil -flushcache 2>/dev/null
        elif ! /usr/bin/grep -qF "$DOMAIN" "$HOSTS"; then
          /usr/bin/sed -i '' "/$MARK/,/$END/d" "$HOSTS"
          /usr/bin/printf '\\n%s\\n' "$MARK" >> "$HOSTS"
          /usr/bin/printf '0.0.0.0 %s\\n::1 %s\\n' "$DOMAIN" "$DOMAIN" >> "$HOSTS"
          /usr/bin/printf '%s\\n' "$END" >> "$HOSTS"
          /usr/bin/dscacheutil -flushcache 2>/dev/null
        fi
        """
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(kGuardLabel)</string>
          <key>ProgramArguments</key>
          <array><string>/bin/sh</string><string>\(kGuardScript)</string></array>
          <key>RunAtLoad</key><true/>
          <key>StartInterval</key><integer>300</integer>
          <key>StandardOutPath</key><string>/var/log/wbupdateblocker-guard.log</string>
          <key>StandardErrorPath</key><string>/var/log/wbupdateblocker-guard.log</string>
        </dict>
        </plist>
        """
        let body = """
        #!/bin/bash
        /bin/mkdir -p /usr/local/libexec
        /bin/cat > \(kGuardScript) <<'WBGUARD_EOF'
        \(script)
        WBGUARD_EOF
        /bin/chmod 755 \(kGuardScript)
        /usr/sbin/chown root:wheel \(kGuardScript)
        /bin/cat > \(kGuardPlist) <<'WBPLIST_EOF'
        \(plist)
        WBPLIST_EOF
        /bin/chmod 644 \(kGuardPlist)
        /usr/sbin/chown root:wheel \(kGuardPlist)
        /bin/launchctl bootout system/\(kGuardLabel) 2>/dev/null
        /bin/launchctl bootstrap system \(kGuardPlist) 2>/dev/null
        /bin/launchctl enable system/\(kGuardLabel) 2>/dev/null
        /bin/sh \(kGuardScript)
        /bin/echo done
        """
        let res = runWithAdmin(body)
        refresh()
        message = res.contains("done")
            ? "已安装开机守护：每 5 分钟检查 hosts，被其他工具冲掉会自动补回。"
            : "守护未能确认完成：\(res)"
    }

    func disableGuardAndRestore() {
        let alert = NSAlert()
        alert.messageText = "关闭开机守护并还原 hosts？"
        alert.informativeText = "将卸载守护进程、删除守护脚本，并移除 /etc/hosts 里的 WorkBuddy 屏蔽段。此后 WorkBuddy 可正常检查并下载更新。"
        alert.addButton(withTitle: "关闭并还原")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        if alert.runModal() != .alertFirstButtonReturn { return }

        busy = true; defer { busy = false }
        let body = """
        #!/bin/bash
        /bin/launchctl bootout system/\(kGuardLabel) 2>/dev/null
        /bin/rm -f \(kGuardPlist)
        /bin/rm -f \(kGuardScript)
        cp \(kHostsPath) /tmp/wbupdateblocker_hosts.bak 2>/dev/null
        /usr/bin/sed -i '' '/\(kHostsBlockStart)/,/\(kHostsBlockEnd)/d' \(kHostsPath)
        /usr/bin/dscacheutil -flushcache 2>/dev/null
        /bin/echo done
        """
        let res = runWithAdmin(body)
        UserDefaults.standard.set(false, forKey: "wbDownloadBlockMode")
        downloadBlockMode = false
        setLock(false, silent: true)
        setExtractedLock(false, silent: true)
        refresh()
        message = res.contains("done")
            ? "已关闭守护并还原 /etc/hosts，WorkBuddy 可正常更新。"
            : "关闭未能确认完成：\(res)"
    }

    // MARK: 待装包清理

    // 把 downloads / extracted / 状态 json / /Applications staged 全部移入废纸篓
    func purgePending() {
        busy = true; defer { busy = false }
        let fm = FileManager.default
        // 正在安装时不动
        if let d = readJSON(wb.lockJSON),
           let phase = d["phase"] as? String, phase == "installing",
           let pid = d["currentPid"] as? Int32, pid > 0, kill(pid, 0) == 0 {
            message = "检测到 WorkBuddy 正在安装更新（pid=\(pid)），请先完全退出 WorkBuddy 再清理。"
            return
        }

        var moved = 0
        var failed = 0
        func trash(_ path: String) {
            guard fm.fileExists(atPath: path) else { return }
            do { try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil); moved += 1 }
            catch { failed += 1 }
        }
        func trashContents(_ dir: String) {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for it in items { trash((dir as NSString).appendingPathComponent(it)) }
        }

        // 目录锁生效时目录不可读 → 先临时解锁，清完再自动锁回
        let wasLocked = downloadBlockMode
        if wasLocked {
            _ = setLock(false, silent: true)
            _ = setExtractedLock(false, silent: true)
        }

        trashContents(wb.downloadsDir)
        trashContents(wb.extractedDir)
        trash(wb.pendingJSON)
        trash(wb.lockJSON)
        trash(wb.cacheBase + "/last-install-result.json")
        if let items = try? fm.contentsOfDirectory(atPath: "/Applications") {
            for it in items where it.hasPrefix(".WorkBuddy.app.installing") {
                trash("/Applications/" + it)
            }
        }

        if wasLocked {
            _ = setLock(true, silent: true)
            _ = setExtractedLock(true, silent: true)
        }

        refresh()
        message = "已清理待装更新：\(moved) 项移入废纸篓（可恢复）"
            + (failed > 0 ? "，\(failed) 项失败（可能被占用）" : "")
            + "。本次更新不会再被安装。"
    }

    // MARK: 备份 / 目录

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

    func manualBackup() {
        if backupFolder.isEmpty {
            message = "请先点击「选择备份目录」设定目标文件夹，再手动备份。"
            return
        }
        if downloadBlockMode {
            downloadBlockMode = false
            UserDefaults.standard.set(false, forKey: "wbDownloadBlockMode")
            setLock(false, silent: true)
            setExtractedLock(false, silent: true)
        }
        processDownloads()
        cleanExtractedTemp()
        showToast("请重新开启屏蔽")
        message = "已手动备份：下载目录里的新更新包已备份到\n\(backupFolder)\n重复包移入废纸篓，并清理了解压暂存。\n（如需持续屏蔽，请重新「启用目录锁」）"
    }

    func startBackupWatcher() {
        stopBackupWatcher()
        guard !backupFolder.isEmpty else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: wb.downloadsDir) {
            try? fm.createDirectory(atPath: wb.downloadsDir, withIntermediateDirectories: true)
        }
        let fd = open((wb.downloadsDir as NSString).fileSystemRepresentation, O_EVTONLY)
        guard fd >= 0 else {
            message = "无法监听下载目录（可能被读写锁锁定或目录不存在）。"
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .all,
            queue: DispatchQueue.global(qos: .background))
        src.setEventHandler { [weak self] in self?.processDownloads() }
        src.setCancelHandler { close(fd) }
        src.resume()
        backupSource = src
        processDownloads()
    }

    func stopBackupWatcher() {
        backupSource?.cancel()
        backupSource = nil
    }

    func processDownloads() {
        guard !downloadBlockMode else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: wb.downloadsDir) else { return }
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
            let src = (wb.downloadsDir as NSString).appendingPathComponent(z)
            let dst = (backupFolder as NSString).appendingPathComponent(z)
            if fm.fileExists(atPath: dst) {
                do { try fm.trashItem(at: URL(fileURLWithPath: src), resultingItemURL: nil); removed += 1 }
                catch {}
            } else {
                do { try fm.copyItem(atPath: src, toPath: dst); backed += 1 }
                catch {}
            }
        }
        DispatchQueue.main.async {
            self.lastBackupLog = "自动检查完成：备份 \(backed) 个、移入废纸篓 \(removed) 个重复包"
            self.message = "自动检查完成：备份 \(backed) 个新更新包，将 \(removed) 个与备份目录重复的包移入废纸篓。"
        }
    }

    func showToast(_ text: String, seconds: Double = 1.0) {
        DispatchQueue.main.async {
            self.toastText = text
            self.toastWorkItem?.cancel()
            let item = DispatchWorkItem { self.toastText = "" }
            self.toastWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

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

    func cleanExtractedTemp() { _ = trashContents(of: wb.extractedDir) }

    func manualClean() {
        let d = trashContents(of: wb.downloadsDir)
        let e = trashContents(of: wb.extractedDir)
        let total = d + e
        DispatchQueue.main.async {
            self.message = "已清理 downloads/（\(d) 项）与 extracted/（\(e) 项），共 \(total) 项移入废纸篓（可恢复）。"
            self.showToast("已清理下载缓存与解压暂存，请重新开启屏蔽")
        }
    }

    // MARK: 禁止下载模式

    func enableDownloadBlock() {
        guard !downloadBlockMode else { return }
        // 首次安装（从未更新过）时缓存目录可能整个不存在 → 先建再锁
        let created = ensureCacheDirs()
        downloadBlockMode = true
        UserDefaults.standard.set(true, forKey: "wbDownloadBlockMode")
        let dl = setLock(true, silent: true)
        let ex = setExtractedLock(true, silent: true)
        refresh()
        let createdNote = created.isEmpty ? "" : "\n已先创建缺失目录：\(created.joined(separator: "、"))（首次安装的机器通常为空）"
        if dl && ex {
            message = "已启用「目录锁」：downloads/ 与 extracted/ 权限设为 000，WorkBuddy 无法写入更新包或解压暂存。\(createdNote)"
        } else {
            message = "目录锁未能完全生效（downloads:\(dl ? "OK" : "失败") · extracted:\(ex ? "OK" : "失败")）。\(createdNote)\n请确认 WorkBuddy 已退出后重试。"
        }
    }

    func disableDownloadBlock() {
        guard downloadBlockMode else { return }
        downloadBlockMode = false
        UserDefaults.standard.set(false, forKey: "wbDownloadBlockMode")
        setLock(false, silent: true)
        setExtractedLock(false, silent: true)
        processDownloads()
        message = "已解除「目录锁」，downloads/ 与 extracted/ 恢复读写权限。"
    }

    func applyPersisted() {
        if downloadBlockMode {
            setLock(true, silent: true)
            setExtractedLock(true, silent: true)
        } else {
            setLock(false, silent: true)
            setExtractedLock(false, silent: true)
            processDownloads()
        }
        startStatusTimer()
    }

    // 每 5 秒静默刷新一次状态（bundle id 变更 / hosts 被冲掉 / 新包落地都能即时反映）
    func startStatusTimer() {
        guard statusTimer == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
    }

    // 读取目录真实权限位（000 → "0"）
    private func dirMode(_ path: String) -> String {
        shell("/bin/sh", ["-c", "stat -f %A '\(path)' 2>/dev/null"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isLockedMode(_ m: String) -> Bool { m == "0" || m == "000" }

    // 首次安装 WorkBuddy 的机器上，缓存目录可能整个都不存在：
    // 先按需创建 cacheBase/downloads/extracted 再上锁，否则 chmod 打在空气上（旧版静默失效的根因之一）
    @discardableResult
    func ensureCacheDirs() -> [String] {
        let fm = FileManager.default
        var created: [String] = []
        for dir in [wb.cacheBase, wb.downloadsDir, wb.extractedDir] {
            if !fm.fileExists(atPath: dir) {
                if (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil {
                    created.append((dir as NSString).lastPathComponent)
                }
            }
        }
        return created
    }

    @discardableResult
    private func setLock(_ lock: Bool, silent: Bool) -> Bool {
        let dir = wb.downloadsDir
        if lock {
            if !FileManager.default.fileExists(atPath: dir) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            if UserDefaults.standard.string(forKey: "wbOrigMode") == nil {
                let mode = dirMode(dir)
                if !mode.isEmpty && !isLockedMode(mode) {
                    UserDefaults.standard.set(mode, forKey: "wbOrigMode")
                }
            }
            _ = shell("/bin/chmod", ["000", dir])
            let ok = isLockedMode(dirMode(dir))
            if !silent { message = ok ? "已禁止下载缓存目录读写（chmod 000）。" : "下载缓存目录锁定失败（权限未变为 000）。" }
            return ok
        } else {
            let mode = UserDefaults.standard.string(forKey: "wbOrigMode") ?? "700"
            guard FileManager.default.fileExists(atPath: dir) else { return true }
            _ = shell("/bin/chmod", [mode, dir])
            if !silent { message = "已恢复下载缓存目录读写权限（chmod \(mode)）。" }
            return !isLockedMode(dirMode(dir))
        }
    }

    @discardableResult
    private func setExtractedLock(_ lock: Bool, silent: Bool) -> Bool {
        let fm = FileManager.default
        let dir = wb.extractedDir
        if lock {
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            if UserDefaults.standard.string(forKey: "wbExtractedOrigMode") == nil {
                let mode = dirMode(dir)
                UserDefaults.standard.set(mode.isEmpty || isLockedMode(mode) ? "700" : mode, forKey: "wbExtractedOrigMode")
            }
            _ = shell("/bin/chmod", ["000", dir])
            let ok = isLockedMode(dirMode(dir))
            if !silent { message = ok ? "已禁止解压暂存目录（extracted/）读写（chmod 000）。" : "解压暂存目录锁定失败（权限未变为 000）。" }
            return ok
        } else {
            let mode = UserDefaults.standard.string(forKey: "wbExtractedOrigMode") ?? "700"
            guard fm.fileExists(atPath: dir) else { return true }
            _ = shell("/bin/chmod", [mode, dir])
            if !silent { message = "已恢复解压暂存目录（extracted/）读写权限（chmod \(mode)）。" }
            return !isLockedMode(dirMode(dir))
        }
    }

    // MARK: 检查目录

    func locateAndCheck() {
        busy = true; defer { busy = false }
        let fm = FileManager.default
        let base = wb.cacheBase
        if fm.fileExists(atPath: base) { _ = shell("/usr/bin/open", [base]) }

        func sizeStr(_ path: String) -> String {
            if let a = try? fm.attributesOfItem(atPath: path), let s = a[.size] as? UInt64 {
                return ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)
            }
            return "未知大小"
        }

        var dlLines: [String] = []
        if let items = try? fm.contentsOfDirectory(atPath: wb.downloadsDir) {
            for z in items where z.lowercased().hasSuffix(".zip") {
                dlLines.append("   • \(z)  （\(sizeStr(wb.downloadsDir + "/" + z))）")
            }
        }
        var exLines: [String] = []
        if let items = try? fm.contentsOfDirectory(atPath: wb.extractedDir) {
            for v in items where !v.hasPrefix(".") {
                let ok = fm.fileExists(atPath: wb.extractedDir + "/" + v + "/WorkBuddy.app")
                exLines.append("   • \(v)  →  \(ok ? "内含 WorkBuddy.app（待覆盖安装）" : "（未找到 WorkBuddy.app）")")
            }
        }
        var bkLines: [String] = []
        if let items = try? fm.contentsOfDirectory(atPath: wb.backupsDir) {
            for b in items where !b.hasPrefix(".") { bkLines.append("   • \(b)") }
        }

        let hosts = hostsText()
        let blockedNow = hosts.contains(kHostsBlockStart)
        let resolved = hosts.contains("0.0.0.0 \(kPrimaryDomain)")
        let shieldLine = blockedNow
            ? (resolved ? "已启用 · \(kPrimaryDomain) 解析到 0.0.0.0（下载被阻断）" : "已启用标记但解析行缺失（异常，建议重新启用）")
            : "未启用 · 更新包仍可下载并落到该目录"

        let dlBlock = dlLines.isEmpty ? "   （空 · 屏蔽生效时不应出现新包）" : dlLines.joined(separator: "\n")
        let exBlock = exLines.isEmpty ? "   （空 · 暂无可安装版本）" : exLines.joined(separator: "\n")
        let bkBlock = bkLines.isEmpty ? "   （空 · 尚无备份）" : bkLines.joined(separator: "\n")

        checkResult = """
        更新缓存目录（bundle id = \(wb.bundleId)）：
        \(base)

        ① downloads/（下载缓存）
        \(dlBlock)

        ② extracted/（解压暂存）
        \(exBlock)

        ③ backups/（覆盖前备份）
        \(bkBlock)

        屏蔽状态：\(shieldLine)
        开机守护：\(guardInstalled ? (guardRunning ? "已安装并运行" : "已安装未运行") : "未安装")
        """
        message = "已在 Finder 中打开更新缓存目录。"
    }

    // MARK: 工具

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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // 先读完再等，防 >64KB 死锁
        p.waitUntilExit()
        try? FileManager.default.removeItem(atPath: tmp)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - 主界面
struct ContentView: View {
    @EnvironmentObject var model: BlockerModel
    @State private var showAbout = false
    private let DESIGN_W: CGFloat = AppDelegate.DESIGN_W
    private let DESIGN_H: CGFloat = AppDelegate.DESIGN_H
    private var scale: CGFloat { AppDelegate.adaptiveScale }

    private func modeStatusBadge(_ title: String, on: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Color.green : Color.red).frame(width: 9, height: 9)
            Text("\(title)：").font(.subheadline)
            Text(on ? "已启用" : "未启用")
                .font(.subheadline.bold())
                .foregroundStyle(on ? .green : .red)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            // 标题
            HStack {
                if let img = NSImage(named: "AppIcon") {
                    Image(nsImage: img).resizable().frame(width: 46, height: 46)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("WorkBuddy 更新屏蔽器").font(.title2.bold())
                    Text("优先推荐：目录锁 + 待装包清理（不改 hosts、无副作用）")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关于") { showAbout = true }
            }
            Divider()

            // 状态区
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 16) {
                    modeStatusBadge("目录锁", on: model.downloadBlockMode)
                    modeStatusBadge("域名屏蔽", on: model.blocked)
                    modeStatusBadge("开机守护", on: model.guardRunning)
                }
                Text("WorkBuddy \(model.wbVersion) · \(model.wbBundleId)")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(model.lockDetail)
                    .font(.caption2).foregroundStyle(.secondary)
                Text(model.hasPending ? "⚠️ " + model.pendingInfo : "✅ " + model.pendingInfo)
                    .font(.caption).foregroundStyle(model.hasPending ? .orange : .green)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 左右分栏：左 = 主推方案（目录锁 + 清理），右 = 备用方案（域名 + 守护）
            HStack(alignment: .top, spacing: 12) {
                // 左：目录锁 + 待装包清理（优先推荐）
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill").font(.title3).foregroundStyle(.green)
                        Text("目录锁 + 待装包清理").font(.headline)
                        Text("优先推荐")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.20)))
                            .foregroundStyle(.green)
                    }
                    Text("不改 hosts、不装守护、无副作用。自动定位当前 WorkBuddy 的缓存目录（跟随 bundle id，5.9.x 起为 com.tencent.workbuddy.mac）；首次安装、目录还不存在的机器会先自动建好再锁。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Button(action: { model.enableDownloadBlock() }) { Label("① 启用目录锁（首选）", systemImage: "lock.fill") }
                        .controlSize(.large).disabled(model.downloadBlockMode || model.busy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { model.disableDownloadBlock() }) { Label("解除目录锁", systemImage: "lock.open") }
                        .controlSize(.large).disabled(!model.downloadBlockMode || model.busy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    Button(action: { model.purgePending() }) { Label("② 清理待装更新包", systemImage: "trash.slash.fill") }
                        .controlSize(.large).disabled(model.busy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("清空 downloads/ 与 extracted/，删掉 pending-update.json、install-in-progress.json，并移除 /Applications 里的 .WorkBuddy.app.installing.* 暂存目录。全部移入废纸篓，可恢复。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.green.opacity(0.38), lineWidth: 1))

                // 右：域名屏蔽 + 开机守护（备用，视觉弱化）
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe").font(.subheadline)
                        Text("域名屏蔽 + 守护").font(.subheadline.weight(.semibold))
                        Text("备用")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                    Text("仅当上面的目录锁失效时再用。把 \(kPrimaryDomain) 解析到 0.0.0.0，可选装 LaunchDaemon 每 5 分钟补回 hosts。副作用：技能市场图标等同一 CDN 资源可能加载不出。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Button(action: { model.enable() }) { Label("启用域名屏蔽", systemImage: "shield") }
                        .controlSize(.regular).disabled(model.blocked || model.busy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { model.disable() }) { Label("禁用域名屏蔽", systemImage: "shield.slash") }
                        .controlSize(.regular).disabled(!model.blocked || model.busy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { model.enableGuard() }) { Label("安装开机守护", systemImage: "lock.shield") }
                        .controlSize(.regular).disabled(model.guardInstalled || model.busy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { model.disableGuardAndRestore() }) { Label("关闭守护并还原", systemImage: "arrow.uturn.backward") }
                        .controlSize(.regular).disabled(!model.guardInstalled || model.busy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
            }

            // 备份 + 工具区（压缩成两行）
            HStack(spacing: 8) {
                Button("选择备份目录") { model.chooseBackupFolder() }
                Text(model.backupFolder.isEmpty ? "未设置（用于备份已下载的更新包）" : model.backupFolder)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("手动备份") { model.manualBackup() }
            }
            HStack(spacing: 8) {
                Button(action: { model.locateAndCheck() }) { Label("检查更新缓存目录", systemImage: "magnifyingglass") }
                    .disabled(model.busy)
                Button(action: { model.restartWorkBuddy() }) { Label("重启 WorkBuddy", systemImage: "arrow.clockwise") }
                Spacer()
            }

            // 提示区常驻（占位固定高度，避免内容高度随操作结果跳动导致窗口留白/裁切）
            Text(model.message.isEmpty ? "操作结果会显示在这里（例如：已启用目录锁 / 已清理 N 项）" : model.message)
                .font(.callout)
                .foregroundStyle(model.message.isEmpty ? Color.secondary : Color.blue)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
                .lineLimit(2)
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(model.message.isEmpty ? Color.gray.opacity(0.10) : Color.blue.opacity(0.10)))

            Text("Copyright © 2026 banqiu. Released under the MIT License.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: DESIGN_W, height: DESIGN_H, alignment: .top)
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
        .sheet(isPresented: Binding(get: { !model.checkResult.isEmpty },
                                    set: { if !$0 { model.checkResult = "" } })) {
            CheckResultView(text: model.checkResult)
        }
    }
}

// MARK: - 检查结果
struct CheckResultView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("更新缓存目录检查结果").font(.headline)
            Divider()
            ScrollView {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
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
            Text("版本 1.19").font(.caption).foregroundStyle(.secondary)
            Text("首选方案：缓存目录权限锁（downloads/、extracted/ 设为 000）+ 待装包清理。\n备用方案：/etc/hosts 屏蔽 \(kPrimaryDomain) + LaunchDaemon 开机守护。\n自动识别 bundle id（5.9.x 为 com.tencent.workbuddy.mac），首次安装会自动创建缺失目录再上锁；不改应用本体，可一键还原。")
                .font(.callout).multilineTextAlignment(.center).frame(maxWidth: 360)
            Divider()
            Text("Copyright © 2026 banqiu. Released under the MIT License.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 420, height: 330)
    }
}
