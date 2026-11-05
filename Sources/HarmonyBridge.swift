import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct CompanionFile: Codable, Identifiable {
    var id: String
    var name: String
    var size: Int64
    var received: Bool
    var ready: Bool
}
struct CompanionReply: Codable {
    var ok: Bool
    var error: String
    var files: [CompanionFile]
    var id: String
    var data: String
    var size: Int64
    var eof: Bool
    var video: CaptureStatus?
}
struct CaptureStatus: Codable {
    var stage: Int
    var state: Int
    var error: Int
    var frames: Int64
    var bytes: Int64
}
struct CompanionRequest: Encodable {
    var id = ""
    var name = ""
    var offset: Int64 = 0
    var data = ""
    var final = false
    var transport = ""
}

struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Process arguments never pass through a host shell. Device shell arguments are quoted.
func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

enum HDC {
    static let bundled = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
    static func run(_ args: [String], timeout: Double = 15) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                let pipe = Pipe()
                let override = UserDefaults.standard.string(forKey: "hdcPath")
                task.executableURL = URL(fileURLWithPath: override ?? bundled)
                task.arguments = args
                task.standardOutput = pipe
                task.standardError = pipe
                do {
                    try task.run()
                    let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    watchdog.cancel()
                    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard task.terminationStatus == 0, !output.contains("[Fail]"), !output.contains("Permission denied"), !output.contains("Connect failed") else {
                        throw BridgeError(message: output.isEmpty ? "命令失败或超时" : output)
                    }
                    continuation.resume(returning: output)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor final class Bridge: ObservableObject {
    @Published var devices: [String] = []
    @Published var target = ""
    @Published var image: NSImage?
    @Published var status = "正在查找手机…"
    @Published var streaming = false
    @Published var busy = false
    @Published var fps = "尚未开始"
    @Published var error: String?
    @Published var wifiAddress = ""
    @Published var inputText = ""
    @Published var remotePath = "/data/local/tmp/HarmonyBridge/"
    @Published var localFiles: [String] = []
    @Published var selectedFile: String?
    private var sessionToken = ""
    @Published var pairedDevice = ""
    @Published var phoneFiles: [CompanionFile] = []
    @Published var transferProgress = ""
    @Published var videoActive = false
    @Published var userPaused = false
    let videoSurface = VideoSurface()
    private var videoReceiver: VideoReceiver?
    private var companionPort = 0
    private var forwardingDevice = ""
    private var lastWiFiRetry = Date.distantPast
    private var monitorTask: Task<Void, Never>?
    private var activeStreamID: UUID?
    private var videoForward: (device: String, port: Int)?
    var companionConnected: Bool { !target.isEmpty && pairedDevice == target && companionPort != 0 }
    var transportName: String { target.isEmpty ? "未连接" : (target.contains(":") ? "Wi-Fi" : "USB") }
    private var streamTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var pendingScroll = 0.0
    private var scrollTask: Task<Void, Never>?
    private let temp = FileManager.default.temporaryDirectory.appendingPathComponent("HarmonyBridge-" + UUID().uuidString)

    init() {
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        wifiAddress = UserDefaults.standard.string(forKey: "lastWiFiAddress") ?? ""
        if let flag = CommandLine.arguments.firstIndex(of: "--usb-video"), CommandLine.arguments.count > flag+1 {
            sessionToken = ((try? String(contentsOfFile: CommandLine.arguments[flag+1], encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    func command(_ shell: String, target device: String? = nil) async throws -> String {
        let device = device ?? target
        guard !device.isEmpty else { throw BridgeError(message: "请先连接并选择手机") }
        return try await HDC.run(["-t", device, "shell", shell])
    }
    func refreshDevices(silent: Bool = false) async {
        do {
            let output = try await HDC.run(["list", "targets"])
            devices = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("[") }
            if !devices.contains(target) {
                let preferred = UserDefaults.standard.string(forKey: "preferredTarget") ?? ""
                stop(); target = devices.contains(preferred) ? preferred : (devices.first ?? ""); image = nil; sessionToken = ""; pairedDevice = ""; companionPort = 0; userPaused = false
            }
            if !videoActive { status = target.isEmpty ? "未发现手机，请连接数据线或无线调试" : "\(target.contains(":") ? "Wi-Fi" : "USB") 已连接，请在手机开启屏幕共享" }
        } catch { if !silent { self.error = "未能运行 HDC：\(error.localizedDescription)" }; status = "正在等待手机连接" }
    }
    func beginMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task {
            var iteration = 0
            while !Task.isCancelled {
                if !busy {
                    if !videoActive || iteration % 3 == 0 { await refreshDevices(silent: true) }
                    if target.isEmpty, !wifiAddress.isEmpty, Date().timeIntervalSince(lastWiFiRetry) > 8 {
                        lastWiFiRetry = Date()
                        _ = try? await HDC.run(["tconn", wifiAddress], timeout: 5)
                        await refreshDevices(silent: true)
                    }
                    if !target.isEmpty {
                        do {
                            if !companionConnected { try await connectHDCSession() }
                            if Task.isCancelled { break }
                            let reply = try await companion("video-status")
                            if let capture = reply.video {
                                let running = [0, 5, 6, 7, 8, 9, 12, 14].contains(capture.state) && capture.error == 0
                                if running && !videoActive && !userPaused { await startVideo(silent: true) }
                                else if !running && videoActive { stop(); status = "屏幕共享已结束，等待手机重新开启" }
                            }
                            if iteration % 3 == 0 { phoneFiles = try await companion("list").files }
                        } catch {
                            if !videoActive { status = "\(target.contains(":") ? "Wi-Fi" : "USB") 已连接，等待手机端开启屏幕共享" }
                            pairedDevice = ""; sessionToken = ""
                        }
                    }
                }
                iteration += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func endMonitoring() { monitorTask?.cancel(); monitorTask = nil; stop() }
    func pause() { userPaused = true; stop(); status = "已暂停接收画面" }
    func resume() { userPaused = false }
    func selectDevice(_ device: String) {
        stop(); target = device; sessionToken = ""; pairedDevice = ""; companionPort = 0; image = nil; userPaused = false
        UserDefaults.standard.set(device, forKey: "preferredTarget")
    }
    func connectHDCSession() async throws {
        guard !target.isEmpty else { throw BridgeError(message: "请先连接手机") }
        let device = target
        let local = temp.appendingPathComponent("usb-session")
        _ = try await HDC.run(["-t", device, "file", "recv", "-b", "com.harmonybridge.phone", "/data/storage/el2/base/haps/entry/files/bridge/usb-session", local.path], timeout: 5)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
        let token = try String(contentsOf: local, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else { throw BridgeError(message: "等待手机端初始化连接") }
        guard target == device else { throw BridgeError(message: "设备已切换") }
        sessionToken = token
        if forwardingDevice != device { companionPort = 0; forwardingDevice = device }
        if companionPort == 0 {
            var connected = false
            for _ in 0..<5 {
                let port = Int.random(in: 20000...60000)
                do {
                    _ = try await HDC.run(["-t", device, "fport", "tcp:\(port)", "tcp:28765"])
                    companionPort = port; connected = true; break
                } catch { continue }
            }
            guard connected else { throw BridgeError(message: "等待手机连接就绪") }
        }
        phoneFiles = try await companion("list").files
        pairedDevice = device; transferProgress = "文件传输已就绪"
        if CommandLine.arguments.contains("--usb-auto-debug") { print("USB_SESSION_READY automatic=true manual_code=false"); fflush(stdout) }
    }
    func start() {
        guard !streaming, !target.isEmpty else { return }
        streaming = true
        let device = target
        let remoteScreen = "/data/local/tmp/harmonybridge-\(UUID().uuidString).jpeg"
        streamTask = Task {
            var failures = 0
            while !Task.isCancelled && streaming && target == device {
                let begin = Date()
                do {
                    _ = try await command("snapshot_display -f \(quote(remoteScreen))", target: device)
                    if Task.isCancelled { break }
                    let local = temp.appendingPathComponent("frame.jpeg")
                    _ = try await HDC.run(["-t", device, "file", "recv", remoteScreen, local.path])
                    let data = try Data(contentsOf: local)
                    guard let frame = NSImage(data: data) else { throw BridgeError(message: "无法解码手机画面") }
                    if Task.isCancelled || target != device { break }
                    image = frame
                    failures = 0
                    fps = String(format: "%.1f 帧/秒 · 截图预览", 1 / max(Date().timeIntervalSince(begin), 0.01))
                    status = "画面更新中 · \(device.contains(":") ? "网络调试" : "USB")"
                } catch {
                    if Task.isCancelled { break }
                    failures += 1
                    status = "画面读取失败，正在重试（\(failures)/3）"
                    if failures >= 3 { self.error = error.localizedDescription; streaming = false; break }
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            _ = try? await command("rm -f \(quote(remoteScreen))", target: device)
        }
    }
    func stop() {
        streaming = false; streamTask?.cancel(); streamTask = nil
        activeStreamID = nil
        videoReceiver?.stop(); videoReceiver = nil; videoActive = false; fps = "已暂停"
        if let forward = videoForward {
            videoForward = nil
            Task { _ = try? await HDC.run(["-t", forward.device, "fport", "rm", "tcp:\(forward.port)", "tcp:28766"]) }
        }
    }
    func startVideo(silent: Bool = false) async {
        guard !target.isEmpty else { error = "请先连接手机"; return }
        stop()
        do {
            if !companionConnected { try await connectHDCSession() }
            let token = sessionToken
            if Task.isCancelled { return }
            let port = Int.random(in: 20000...60000)
            _ = try await HDC.run(["-t", target, "fport", "tcp:\(port)", "tcp:28766"])
            videoForward = (target, port)
            let identity = UUID(); activeStreamID = identity
            let receiver = VideoReceiver()
            receiver.onFrame = { [surface = videoSurface] frame in surface.enqueue(frame) }
            receiver.onStats = { [weak self] stats in
                self?.fps = stats
                if CommandLine.arguments.contains("--usb-video") || CommandLine.arguments.contains("--usb-auto-debug") { print(stats); fflush(stdout) }
            }
            receiver.onError = { [weak self] message in
                guard let self, self.activeStreamID == identity else { return }
                self.stop(); self.status = "投屏连接已断开，正在自动重连"; self.fps = message
            }
            videoReceiver = receiver; videoActive = true; fps = "等待手机视频数据…"
            status = "正在通过 \(target.contains(":") ? "Wi-Fi" : "USB") 投屏"
            if CommandLine.arguments.contains("--usb-auto-debug") { print("USB_VIDEO_CONNECTED automatic=true"); fflush(stdout) }
            receiver.start(port: UInt16(port), token: token)
        } catch { if !silent { self.error = "视频连接失败：" + error.localizedDescription }; status = "等待手机开启屏幕共享" }
    }
    func control(_ args: String) {
        guard controlTask == nil, !target.isEmpty else { return }
        controlTask = Task {
            defer { controlTask = nil }
            do {
                let output = try await command("uitest uiInput " + args)
                guard output.contains("No Error") else { throw BridgeError(message: output.isEmpty ? "控制未得到确认" : output) }
            } catch { self.error = "控制失败：" + error.localizedDescription }
        }
    }
    func gesture(_ from: CGPoint, _ to: CGPoint, _ duration: Double) {
        let a = "\(Int(from.x)) \(Int(from.y))"
        if hypot(from.x-to.x, from.y-to.y) < 16 {
            control("\(duration > 0.55 ? "longClick" : "click") \(a)")
        } else {
            let velocity = Int(min(40000, max(200, hypot(from.x-to.x, from.y-to.y) / max(duration, 0.08))))
            control("swipe \(a) \(Int(to.x)) \(Int(to.y)) \(velocity)")
        }
    }
    func scroll(_ delta: Double) {
        pendingScroll += delta
        guard scrollTask == nil else { return }
        scrollTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            let movement = pendingScroll
            pendingScroll = 0; scrollTask = nil
            guard abs(movement) > 1, image != nil || videoActive else { return }
            let size = image?.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? CGSize(width: 1320, height: 2848)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let distance = min(size.height * 0.3, max(120, abs(movement) * 8))
            gesture(center, CGPoint(x: center.x, y: center.y + (movement > 0 ? distance : -distance)), 0.3)
        }
    }
    func sendText() {
        guard !inputText.isEmpty, controlTask == nil else { return }
        // User explicitly sends the text, never automatically reads the clipboard.
        control("text " + quote(inputText))
    }
    func connectWiFi() async {
        let address = wifiAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.range(of: #"^[A-Za-z0-9.\-]+:[0-9]{1,5}$"#, options: .regularExpression) != nil,
              let port = Int(address.split(separator: ":").last ?? ""), (1...65535).contains(port) else {
            error = "填写手机无线调试页面的 IP:端口，例如 192.168.1.8:12345"; return
        }
        do {
            _ = try await HDC.run(["tconn", address], timeout: 8)
            await refreshDevices()
            guard devices.contains(address) else { throw BridgeError(message: "手机未出现在无线调试设备列表中") }
            selectDevice(address)
            wifiAddress = address
            UserDefaults.standard.set(address, forKey: "lastWiFiAddress")
            status = "Wi-Fi 已连接，正在接入屏幕共享"
        } catch { self.error = "无线连接失败：" + error.localizedDescription }
    }
    func chooseHDC() {
        let panel = NSOpenPanel(); panel.message = "选择 DevEco Studio SDK 中的 hdc 可执行文件"; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { UserDefaults.standard.set(url.path, forKey: "hdcPath"); Task { await refreshDevices() } }
    }
    func listFiles() async {
        do {
            _ = try await command("mkdir -p /data/local/tmp/HarmonyBridge")
            let result = try await command("ls -1 /data/local/tmp/HarmonyBridge")
            if result.contains("No such") || result.contains("ls:") { throw BridgeError(message: result) }
            localFiles = result.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.contains("/") && !$0.contains("\r") }
        } catch { self.error = error.localizedDescription }
    }
    func sendFiles(_ urls: [URL]) async {
        guard !busy, !target.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await command("mkdir -p /data/local/tmp/HarmonyBridge")
            for url in urls {
                guard url.isFileURL else { continue }
                let name = url.lastPathComponent
                guard !name.contains("\n"), !name.contains("\r") else { throw BridgeError(message: "文件名不能包含换行") }
                // Unique names avoid silently overwriting previously sent files.
                let remote = "/data/local/tmp/HarmonyBridge/" + String(UUID().uuidString.prefix(8)) + "-" + name
                _ = try await HDC.run(["-t", target, "file", "send", url.path, remote], timeout: 300)
                status = "已发送到手机调试暂存区：" + name
            }
            await listFiles()
        } catch { self.error = "发送失败：" + error.localizedDescription }
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await uploadCompanion(urls) }
        }
    }
    func receiveFile() {
        let remote = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remote.hasPrefix("/"), !remote.hasSuffix("/"), !remote.contains("\n") else { error = "请填写完整的手机文件路径，或选择一个暂存文件"; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = (remote as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard !busy else { return }; busy = true; defer { busy = false }
            do {
                _ = try await HDC.run(["-t", target, "file", "recv", remote, url.path], timeout: 300)
                status = "已接收到 Mac：" + url.lastPathComponent
            } catch { self.error = "接收失败：" + error.localizedDescription }
        }
    }

    func companion(_ route: String, _ body: CompanionRequest = CompanionRequest()) async throws -> CompanionReply {
        guard companionPort != 0 else { throw BridgeError(message: "等待手机自动连接") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(companionPort)/\(route)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = ["video-status", "list"].contains(route) ? 4 : 30
        request.setValue("Bearer " + sessionToken.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload = body
        payload.transport = target.contains(":") ? "Wi-Fi" : "USB"
        let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        // Device parser uses ASCII JSON framing; escape non-ASCII file names, including surrogate pairs.
        var ascii = ""
        for unit in encoded.utf16 {
            if unit > 127 { ascii += String(format: "\\u%04x", unit) }
            else { ascii.append(Character(UnicodeScalar(unit)!)) }
        }
        request.httpBody = ascii.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let reply = try JSONDecoder().decode(CompanionReply.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, reply.ok else { throw BridgeError(message: reply.error) }
        return reply
    }
    func connectCompanion() async {
        do { try await connectHDCSession() }
        catch { status = "等待手机端准备就绪" }
    }
    func refreshCompanion() async {
        guard companionConnected else { return }
        do { phoneFiles = try await companion("list").files }
        catch { self.error = "刷新失败：" + error.localizedDescription }
    }
    func uploadCompanion(_ urls: [URL]) async {
        guard companionConnected, !busy else { return }
        let originalDevice = target
        busy = true; defer { busy = false }
        do {
            for url in urls {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                var id = "", offset: Int64 = 0
                repeat {
                    guard target == originalDevice else { throw BridgeError(message: "设备已切换，传输中止") }
                    let chunk = try handle.read(upToCount: 196608) ?? Data()
                    let final = offset + Int64(chunk.count) >= Int64(size)
                    let body = CompanionRequest(id: id, name: url.lastPathComponent, offset: offset, data: chunk.base64EncodedString(), final: final)
                    let reply = try await companion("upload", body)
                    guard reply.size == offset + Int64(chunk.count) else { throw BridgeError(message: "手机写入长度不一致") }
                    id = reply.id; offset = reply.size
                    transferProgress = "发送 \(url.lastPathComponent)：\(offset * 100 / max(1, Int64(size)))%"
                    if final { break }
                    if chunk.isEmpty { throw BridgeError(message: "源文件长度发生变化") }
                } while true
            }
            transferProgress = "发送完成，在手机端点击“保存到文件管理”即可保存"
            await refreshCompanion()
        } catch { self.error = "发送失败：" + error.localizedDescription }
    }
    func receiveCompanion(_ file: CompanionFile) {
        guard companionConnected, !busy else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            busy = true; defer { busy = false }
            let partial = destination.deletingLastPathComponent().appendingPathComponent(".harmonybridge-" + UUID().uuidString + ".part")
            defer { try? FileManager.default.removeItem(at: partial) }
            do {
                guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw BridgeError(message: "无法创建接收文件") }
                let handle = try FileHandle(forWritingTo: partial)
                defer { try? handle.close() }
                var offset: Int64 = 0
                repeat {
                    let reply = try await companion("download", CompanionRequest(id: file.id, offset: offset))
                    guard let chunk = Data(base64Encoded: reply.data), reply.size == file.size, offset + Int64(chunk.count) <= file.size else { throw BridgeError(message: "文件分块校验失败") }
                    try handle.write(contentsOf: chunk); offset += Int64(chunk.count)
                    transferProgress = "接收 \(file.name)：\(offset * 100 / max(1, file.size))%"
                    if reply.eof { break }
                    guard !chunk.isEmpty else { throw BridgeError(message: "收到空分块") }
                } while true
                guard offset == file.size else { throw BridgeError(message: "文件总长度不一致") }
                try handle.synchronize(); try handle.close()
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
                } else { try FileManager.default.moveItem(at: partial, to: destination) }
                transferProgress = "已接收到 Mac：" + destination.lastPathComponent
            } catch { self.error = "接收失败：" + error.localizedDescription }
        }
    }
}

@MainActor final class PhoneCanvas: NSView {
    let videoSurface: VideoSurface
    var videoLayer: AVSampleBufferDisplayLayer { videoSurface.layer }
    var videoMode = false { didSet { videoLayer.isHidden = !videoMode; needsDisplay = true; needsLayout = true } }
    var videoSize = CGSize(width: 720, height: 1552)
    var frameImage: NSImage? { didSet { needsDisplay = true } }
    var onGesture: ((CGPoint, CGPoint, Double) -> Void)?
    var onScroll: ((Double) -> Void)?
    var onDrop: (([URL]) -> Void)?
    private var startPoint: CGPoint?
    private var startTime = Date()
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    init(frame: NSRect, videoSurface: VideoSurface) {
        self.videoSurface = videoSurface
        super.init(frame: frame); registerForDraggedTypes([.fileURL])
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect; videoLayer.isHidden = true; layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); videoLayer.frame = bounds; CATransaction.commit() }
    var imageRect: CGRect {
        guard videoMode || frameImage != nil else { return .zero }
        let original = videoMode ? videoSize : frameImage!.size
        let ratio = min(bounds.width / original.width, bounds.height / original.height)
        let size = CGSize(width: original.width * ratio, height: original.height * ratio)
        return CGRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        if !videoMode { frameImage?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high]) }
    }
    func phonePoint(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        guard rect.width > 0, clamp || rect.contains(point) else { return nil }
        let rep = frameImage?.representations.first
        let width = CGFloat(rep?.pixelsWide ?? 1320), height = CGFloat(rep?.pixelsHigh ?? 2848)
        return CGPoint(x: min(width-1, max(0, (point.x-rect.minX)/rect.width*width)), y: min(height-1, max(0, (point.y-rect.minY)/rect.height*height)))
    }
    override func mouseDown(with event: NSEvent) { startPoint = phonePoint(event); startTime = Date(); window?.makeFirstResponder(self) }
    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil }
        if let startPoint, let end = phonePoint(event, clamp: true) { onGesture?(startPoint, end, Date().timeIntervalSince(startTime)) }
    }
    override func scrollWheel(with event: NSEvent) { if phonePoint(event) != nil { onScroll?(event.scrollingDeltaY) } }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }; onDrop?(urls); return true
    }
}

struct PhoneView: NSViewRepresentable {
    @ObservedObject var bridge: Bridge
    func makeNSView(context: Context) -> PhoneCanvas { PhoneCanvas(frame: .zero, videoSurface: bridge.videoSurface) }
    func updateNSView(_ view: PhoneCanvas, context: Context) {
        view.frameImage = bridge.image
        view.videoMode = bridge.videoActive
        view.onGesture = { bridge.gesture($0, $1, $2) }
        view.onScroll = { bridge.scroll($0) }
        view.onDrop = { urls in
            guard bridge.companionConnected else { bridge.error = "请先连接手机并打开手机端软件，再发送文件"; return }
            Task { await bridge.uploadCompanion(urls) }
        }
    }
}

private enum AuxiliaryPanel: String, Identifiable {
    case text, wifi, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self { case .text: return "输入文字"; case .wifi: return "连接 Wi-Fi"; case .diagnostics: return "连接诊断" }
    }
}

private struct PhoneAction: View {
    let title: String
    let icon: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.45))
    }
}

private struct FilesPopover: View {
    @ObservedObject var bridge: Bridge
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("文件互传").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭")
            }
            Button { bridge.chooseFiles() } label: {
                Label("发送文件到手机…", systemImage: "arrow.up.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!bridge.companionConnected || bridge.busy)
            if bridge.phoneFiles.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "folder").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(bridge.companionConnected ? "还没有共享文件" : "连接手机后即可互传文件").font(.subheadline)
                    Text("在手机上选择照片、视频或文档后，文件会出现在这里。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(bridge.phoneFiles) { file in
                            HStack(spacing: 10) {
                                Image(systemName: "doc").font(.title3).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.name).font(.subheadline).lineLimit(2)
                                    Text((file.received ? "已发送到手机 · " : "手机文件 · ") + ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Button("保存到 Mac") { bridge.receiveCompanion(file) }.disabled(bridge.busy)
                            }.padding(.vertical, 12)
                            Divider()
                        }
                    }
                }
            }
            if bridge.busy {
                HStack { ProgressView().controlSize(.small); Text(bridge.transferProgress).font(.caption).lineLimit(2) }
            } else if !bridge.transferProgress.isEmpty {
                Text(bridge.transferProgress).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(20).frame(width: 350, height: 420)
        .task { await bridge.refreshCompanion() }
    }
}

struct ContentView: View {
    @StateObject var bridge = Bridge()
    @State private var showFiles = false
    @State private var panel: AuxiliaryPanel?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "iphone").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mate 80 Pro Max").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(bridge.videoActive ? Color.green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
                        Text(bridge.videoActive ? "\(bridge.transportName) 投屏中" : (bridge.userPaused ? "已暂停" : "等待手机共享屏幕"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    if bridge.devices.isEmpty { Text("未发现连接") }
                    ForEach(bridge.devices, id: \.self) { device in
                        Button {
                            bridge.selectDevice(device)
                        } label: {
                            Text("\(device == bridge.target ? "✓ " : "")\(device.contains(":") ? "Wi-Fi 无线" : "USB 数据线") · \(device)")
                        }
                    }
                } label: {
                    Label("当前：\(bridge.transportName)", systemImage: bridge.target.contains(":") ? "wifi" : "cable.connector")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize().help("选择 USB 或 Wi-Fi 连接")
                Menu {
                    Button("输入文字…") { panel = .text }.disabled(!bridge.videoActive)
                    Button("连接 Wi-Fi…") { panel = .wifi }
                    Button("重新连接") {
                        bridge.resume(); bridge.stop()
                        Task { await bridge.refreshDevices() }
                    }
                    Divider()
                    Button("连接诊断…") { panel = .diagnostics }
                } label: { Image(systemName: "ellipsis").font(.system(size: 17)) }
                .menuStyle(.borderlessButton).fixedSize().help("更多")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.regularMaterial)
            ZStack {
                Color.black
                PhoneView(bridge: bridge)
                if bridge.image == nil && !bridge.videoActive {
                    VStack(spacing: 14) {
                        Image(systemName: bridge.userPaused ? "pause.circle" : "iphone.radiowaves.left.and.right")
                            .font(.system(size: 40, weight: .light))
                        Text(bridge.userPaused ? "投屏已暂停" : (bridge.target.isEmpty ? "连接你的手机" : "在手机上开启屏幕共享"))
                            .font(.system(size: 15, weight: .medium))
                        Text(bridge.userPaused ? "点击下方继续即可恢复" : (bridge.target.isEmpty ? "连接数据线或打开无线调试" : "允许共享后，画面会自动出现"))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    }.foregroundStyle(.white.opacity(0.85)).allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped().help("可将文件拖入此处发送到手机")
            Divider()
            HStack(spacing: 0) {
                PhoneAction(title: "返回", icon: "chevron.backward", enabled: bridge.videoActive) { bridge.control("keyEvent Back") }
                PhoneAction(title: "桌面", icon: "house", enabled: bridge.videoActive) { bridge.control("keyEvent Home") }
                PhoneAction(title: bridge.userPaused ? "继续" : "暂停", icon: bridge.userPaused ? "play" : "pause", enabled: bridge.videoActive || bridge.userPaused) {
                    if bridge.userPaused { bridge.resume() } else { bridge.pause() }
                }
                PhoneAction(title: "文件", icon: "arrow.up.arrow.down") { showFiles.toggle() }
                    .popover(isPresented: $showFiles, arrowEdge: .bottom) { FilesPopover(bridge: bridge) { showFiles = false } }
            }
            .padding(.horizontal, 6).background(.regularMaterial)
        }
        .frame(minWidth: 340, minHeight: 520)
        .task { bridge.beginMonitoring() }
        .onDisappear { bridge.endMonitoring() }
        .sheet(item: $panel) { selected in
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(selected.title).font(.headline)
                    Spacer()
                    Button("完成") { panel = nil }.keyboardShortcut(.cancelAction)
                }
                if selected == .text {
                    TextField("先点击手机输入框，再输入文字", text: $bridge.inputText).textFieldStyle(.roundedBorder)
                    Button("输入到手机") { bridge.sendText(); panel = nil }
                        .buttonStyle(.borderedProminent).disabled(bridge.inputText.isEmpty || !bridge.videoActive)
                } else if selected == .wifi {
                    Text("手机与 Mac 连同一个 Wi-Fi，并在手机开发者选项开启无线调试。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    TextField("手机 IP:端口", text: $bridge.wifiAddress).textFieldStyle(.roundedBorder)
                    Button("连接") {
                        Task { await bridge.connectWiFi(); if bridge.target.contains(":") { panel = nil } }
                    }.buttonStyle(.borderedProminent).disabled(bridge.wifiAddress.isEmpty)
                } else {
                    Text(bridge.status).font(.subheadline).textSelection(.enabled)
                    Text(bridge.fps).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text("\(bridge.target.contains(":") ? "Wi-Fi" : "USB") · 默认 60 FPS · 720 × 1552").font(.caption).foregroundStyle(.secondary)
                    Button("选择调试工具…") { bridge.chooseHDC() }
                }
            }.padding(24).frame(width: 360)
        }
        .alert("操作提示", isPresented: Binding(get: { bridge.error != nil }, set: { if !$0 { bridge.error = nil } })) {
            Button("好") { bridge.error = nil }
        } message: { Text(bridge.error ?? "") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let root = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Harmony Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu; menu.addItem(root)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu; menu.addItem(edit); NSApp.mainMenu = menu
        let height = min(860, (NSScreen.main?.visibleFrame.height ?? 900) - 40)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: height), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Harmony Bridge"
        window.contentView = NSHostingView(rootView: ContentView())
        window.minSize = NSSize(width: 360, height: 580)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.setAccessibilityRole(.window)
        window.setAccessibilityTitle(window.title)
        window.center(); window.makeKeyAndOrderFront(nil); self.window = window
        NSLog("HarmonyBridge: created window visible=%@ windows=%ld", window.isVisible ? "yes" : "no", NSApp.windows.count)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct HarmonyBridgeApp {
    @MainActor static func main() {
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--video-test" {
            let receiver = VideoReceiver()
            let port = UInt16(CommandLine.arguments[2])!
            let token = (try? String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)) ?? ""
            let duration = Double(CommandLine.arguments[4]) ?? 15
            receiver.onFrame = { _ in true }
            receiver.onStats = { print($0); fflush(stdout) }
            receiver.onError = { print("ERROR: \($0)"); fflush(stdout) }
            receiver.start(port: port, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { receiver.stop(); exit(0) }
            RunLoop.current.run(); return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        delegate.showWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            delegate.window?.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            let text = "windows=\(application.windows.count), visible=\(delegate.window?.isVisible ?? false), title=\(delegate.window?.title ?? "")"
            try? text.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("HarmonyBridge-window-diagnostic.txt"), atomically: true, encoding: .utf8)
        }
        withExtendedLifetime(delegate) { application.run() }
    }
}
