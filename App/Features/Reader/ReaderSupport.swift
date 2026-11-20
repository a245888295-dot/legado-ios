import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

struct ReaderInteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.enableInteractivePopIfAvailable()
    }

    static func dismantleUIViewController(_ uiViewController: Controller, coordinator: Void) {
        uiViewController.restoreInteractivePopDelegate()
    }

    final class Controller: UIViewController {
        private weak var popGesture: UIGestureRecognizer?
        private var previousDelegate: (any UIGestureRecognizerDelegate)?
        private var releasedDelegate = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enableInteractivePopIfAvailable()
        }

        func enableInteractivePopIfAvailable() {
            guard let navigationController,
                  navigationController.viewControllers.count > 1,
                  let gesture = navigationController.interactivePopGestureRecognizer else { return }
            if gesture.delegate != nil {
                previousDelegate = gesture.delegate
                gesture.delegate = nil
                releasedDelegate = true
            }
            gesture.isEnabled = true
            popGesture = gesture
        }

        func restoreInteractivePopDelegate() {
            guard releasedDelegate, let popGesture, popGesture.delegate == nil else { return }
            popGesture.delegate = previousDelegate
            previousDelegate = nil
            releasedDelegate = false
        }

    }
}

struct ReaderMenuDismissShape: Shape {
    var leadingExclusion: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: min(max(leadingExclusion, 0), rect.width),
            y: 0,
            width: max(rect.width - leadingExclusion, 0),
            height: rect.height
        ))
    }
}

@MainActor enum ReaderScreenOrientation {
    static private(set) var supportedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    static func apply(_ value: String) {
        let mask: UIInterfaceOrientationMask = switch value {
        case "1": .portrait
        case "2": .landscape
        case "3": .all
        case "4": .portraitUpsideDown
        case "5": .landscapeLeft
        default: .allButUpsideDown
        }
        supportedOrientations = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    static func restoreApplicationDefault() { apply("0") }
}

extension NSAttributedString.Key {
    /// 标记这一段正文需要自绘下划线。值存 underlineMode（1 实线 / 2 点线）。
    /// 不交给 TextKit 画：它紧贴字底、颜色跟正文一样、行末还会提前截断。
    static let readerUnderline = NSAttributedString.Key("LegadoReaderUnderline")
}

enum ReaderUnderlinePainter {
    /// 下划线到字底的空隙。这里从 em 框底算，汉字墨迹底比 em 底高约 0.1 em，
    /// 所以取 0.10 → 视觉上离字底约 0.2 个字高（微信读书实测 0.18–0.2）。
    static func gap(pointSize: CGFloat) -> CGFloat {
        max(2.0, pointSize * 0.10)
    }

    /// 线本身要细而有存在感：约 0.045 个字高，实机上就是 1pt 上下。
    static func lineWidth(pointSize: CGFloat) -> CGFloat {
        max(0.9, min(1.1, pointSize * 0.045))
    }

    /// 短横虚线，实线段与空白约 1:2.2（微信读书 4px 线 + 8px 空，比例一致），
    /// 随字号缩放，所以改字号后观感不变。
    static func dashPattern(pointSize: CGFloat) -> [NSNumber] {
        let dash = max(1.6, pointSize * 0.10)
        let space = max(3.0, pointSize * 0.22)
        return [NSNumber(value: Double(dash)), NSNumber(value: Double(space))]
    }

    /// 比正文浅一档；正文纯黑时约 38% 不透明度。
    static func strokeColor(_ foreground: UIColor) -> UIColor {
        foreground.withAlphaComponent(0.38)
    }
}

// MARK: - 音量键翻页

/// 用实体音量键翻页。
///
/// 三个环节缺一不可：
///
/// 1. **静音音频循环**：App 没在播放任何音频时，系统不保证把音量变化投递给前台 App。
///    循环播放一段全零的 WAV（音量 0）让音频会话一直保持 active，后面两条监听才有事件可收。
/// 2. **两条监听**：`AVSystemController_SystemVolumeDidChangeNotification`（私有通知，userInfo 带音量值）
///    和 `AVAudioSession.outputVolume` 的 KVO。iOS 各版本对这两条的支持不一样，两条一起挂，
///    谁先到谁处理，另一条因为数值相同会被去重掉。
/// 3. **音量回写**：翻页后立刻把音量设回按键前的值。优先用 `MPVolumeView` 的滑块（公开 API），
///    拿不到滑块再退到私有方法 `setVolumeTo:forCategory:`。
final class VolumeKeyPager: @unchecked Sendable {
    static let shared = VolumeKeyPager()

    /// 翻页请求。direction 与 `Coordinator.turnPage(_:)` 一致：1 下一页，-1 上一页。
    static let turnNotification = Notification.Name("readerVolumeKeyTurn")

    private var isActive = false
    private var noteObserver: NSObjectProtocol?
    private var volumeObservation: NSKeyValueObservation?
    private var silentPlayer: AVAudioPlayer?
    private var volumeView: MPVolumeView?

    private var lastVolume: Float = -1
    private var lastFire: CFTimeInterval = 0
    /// 回写音量期间收到的通知要丢掉，否则会自己翻自己。
    private var suppressUntil: CFTimeInterval = 0

    private init() {}

    var isRunning: Bool { isActive }

    /// 音量+ 是上一页、音量− 是下一页。
    static func direction(volumeRising: Bool) -> Int { volumeRising ? -1 : 1 }

    func start() {
        guard !isActive else { return }
        isActive = true

        let session = AVAudioSession.sharedInstance()
        // playback + mixWithOthers：既让会话 active，又不会掐掉用户正在放的音乐。
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
        startSilentLoop()

        lastVolume = session.outputVolume
        note("启动 会话活跃=\(session.isActive) 当前音量=\(lastVolume)")

        noteObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
            object: nil,
            queue: .main
        ) { note in
            let value = (note.userInfo?["AVSystemController_AudioVolumeNotificationParameter"] as? NSNumber)?.floatValue
            let reason = note.userInfo?["AVSystemController_AudioVolumeChangeReasonNotificationParameter"] as? String
            VolumeKeyPager.shared.receive(volume: value, reason: reason)
        }

        volumeObservation = session.observe(\.outputVolume, options: [.new]) { _, change in
            guard let value = change.newValue else { return }
            DispatchQueue.main.async { VolumeKeyPager.shared.receive(volume: value, reason: nil) }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        if let noteObserver {
            NotificationCenter.default.removeObserver(noteObserver)
        }
        noteObserver = nil
        volumeObservation?.invalidate()
        volumeObservation = nil
        silentPlayer?.stop()
        silentPlayer = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        note("停止")
    }

    private func receive(volume: Float?, reason: String?) {
        // 开关随时可能被改，这里每次都读；关掉就完全不动系统音量。
        guard isActive, ReaderVolumeKeySetting.isEnabled else { return }
        guard let current = volume else { return }

        let now = CACurrentMediaTime()
        // 自己回写音量会再触发一次，落在压制窗口里直接丢掉。
        if now < suppressUntil { lastVolume = current; return }
        guard now - lastFire > 0.13 else { lastVolume = current; return }

        let previous = lastVolume
        guard previous >= 0, abs(current - previous) > 0.004 else { lastVolume = current; return }

        lastFire = now
        lastVolume = current
        note("按键 \(previous) → \(current) 原因=\(reason ?? "无")")

        NotificationCenter.default.post(
            name: VolumeKeyPager.turnNotification,
            object: nil,
            userInfo: ["direction": VolumeKeyPager.direction(volumeRising: current > previous)]
        )
        restore(to: previous)
    }

    private func restore(to value: Float) {
        suppressUntil = CACurrentMediaTime() + 0.2
        lastVolume = value
        let ok = setVolume(value)
        note("回写 \(value) \(ok ? "成功" : "失败")")
        // 回写落地后以系统真实值为准，防止和系统值漂移。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isActive else { return }
            self.lastVolume = AVAudioSession.sharedInstance().outputVolume
        }
    }

    // MARK: 音量写入

    @discardableResult
    private func setVolume(_ value: Float) -> Bool {
        if let slider = volumeSlider() {
            slider.value = value
            return true
        }
        return Self.setSystemVolume(value)
    }

    /// `MPVolumeView` 内部的 UISlider 就是系统音量控制器，必须挂在窗口上才有作用。
    private func volumeSlider() -> UISlider? {
        if let view = volumeView, view.window != nil,
           let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            return slider
        }
        guard let window = Self.keyWindow() else { return nil }
        let view = MPVolumeView(frame: CGRect(x: -300, y: -300, width: 120, height: 40))
        view.alpha = 0.01
        view.showsRouteButton = false
        window.addSubview(view)
        volumeView = view
        view.layoutIfNeeded()
        return view.subviews.compactMap { $0 as? UISlider }.first
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        }
        return scenes.flatMap(\.windows).first
    }

    /// 私有 API：`AVSystemController` 的 `setVolumeTo:forCategory:`，两个签名都试。
    private static func setSystemVolume(_ value: Float) -> Bool {
        let sharedSelector = NSSelectorFromString("sharedAVSystemController")
        guard let cls = NSClassFromString("AVSystemController") as? NSObject.Type,
              let factory = class_getClassMethod(cls, sharedSelector) else { return false }
        typealias Factory = @convention(c) (AnyObject, Selector) -> AnyObject
        let controller = unsafeBitCast(method_getImplementation(factory), to: Factory.self)(cls, sharedSelector)
        guard let controllerClass = object_getClass(controller) else { return false }

        let twoArg = NSSelectorFromString("setVolumeTo:forCategory:")
        if let method = class_getInstanceMethod(controllerClass, twoArg) {
            typealias Fn = @convention(c) (AnyObject, Selector, Float, AnyObject) -> Bool
            let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
            if fn(controller, twoArg, value, "Audio/Video" as AnyObject) { return true }
        }

        let threeArg = NSSelectorFromString("setVolumeTo:forCategory:mode:")
        if let method = class_getInstanceMethod(controllerClass, threeArg) {
            typealias Fn = @convention(c) (AnyObject, Selector, Float, AnyObject, AnyObject) -> Bool
            let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
            return fn(controller, threeArg, value, "Audio/Video" as AnyObject, 0 as AnyObject)
        }
        return false
    }

    // MARK: 静音循环

    private func startSilentLoop() {
        guard silentPlayer == nil else { return }
        guard let player = try? AVAudioPlayer(data: Self.silentWAV()) else {
            note("静音循环创建失败")
            return
        }
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        player.play()
        silentPlayer = player
    }

    /// 生成一段 0.25 秒、16 位单声道、全零的 WAV。不需要外部资源文件。
    private static func silentWAV(seconds: Double = 0.25, sampleRate: Int = 8000) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        let dataSize = frames * 2
        var data = Data()
        func put32(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func put16(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        put32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        put32(16)
        put16(1)
        put16(1)
        put32(UInt32(sampleRate))
        put32(UInt32(sampleRate * 2))
        put16(2)
        put16(16)
        data.append(contentsOf: Array("data".utf8))
        put32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }

    // MARK: 日志

    private static let logURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("volume-key.log")
    }()

    /// 无条件写一行日志到 volume-key.log，同时进诊断日志。
    /// 这样即使「记录日志」开关关着，也能从这里查到按键有没有被收到。
    private func note(_ text: String) {
        DiagnosticLog.shared.record(category: "音量键", message: text)
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: Self.logURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if size > 64 * 1024 {
            try? data.write(to: Self.logURL)
            return
        }
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.logURL)
        }
    }
}

/// 音量键翻页的开关。默认开启：这是阅读器该有的能力，不用专门去设置里翻。
enum ReaderVolumeKeySetting {
    static let key = "readerVolumeKeyPaging"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
