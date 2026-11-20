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
/// iOS 没有公开接口能直接读音量键，能用的只有「音量变化」这件事本身。四个要点：
///
/// 1. **通知在 iOS 15 改了名字**：iOS 14 及以前叫 `AVSystemController_SystemVolumeDidChangeNotification`，
///    iOS 15 起叫 `SystemVolumeDidChange`，`userInfo` 的键也换成了 `Volume` / `Reason` / `SequenceNumber`。
///    两个名字都挂，按键才能收到。
/// 2. **必须留一个 MPVolumeView 实例**：没有它，系统不会发出这条通知；顺带它的滑块也是写入音量的公开通道。
/// 3. **静音音频循环**：App 没在出声时，系统不保证把音量变化投递给前台 App。循环播放一段全零 WAV，
///    让音频会话一直 active。音频是 0 音量且有 mixWithOthers，不会打断你后台放的音乐。
/// 4. **回写音量**：翻页后立刻把音量设回按键前的值，用户感觉音量没动过。
///
/// 一次按键系统会连发两条通知（`SequenceNumber` 相同），靠它去重。
final class VolumeKeyPager: NSObject, @unchecked Sendable {
    static let shared = VolumeKeyPager()

    /// 翻页请求。direction 与 `Coordinator.turnPage(_:)` 一致：1 下一页，-1 上一页。
    static let turnNotification = Notification.Name("readerVolumeKeyTurn")

    /// iOS 15 起改名，旧名字同时保留。
    private static let notificationNames = [
        "SystemVolumeDidChange",
        "AVSystemController_SystemVolumeDidChangeNotification",
    ].map { Notification.Name($0) }

    private var isActive = false
    private var volumeObservation: NSKeyValueObservation?
    private var silentPlayer: AVAudioPlayer?
    private var volumeView: MPVolumeView?

    private var lastVolume: Float = -1
    /// 打开阅读界面时的系统音量。每翻一页都把音量拉回这个值，
    /// 而不是「按键前的值」——某一次没写回去，也不会一路往下滑到底。
    private var baselineVolume: Float = -1
    private var lastSequence = -1
    private var lastFire: CFTimeInterval = 0
    /// 回写音量期间收到的通知要丢掉，否则会自己翻自己。
    private var suppressUntil: CFTimeInterval = 0
    /// 最近一次回写的时间。音量顶到边界时通知里的数值不变，只能靠「是不是刚回写过」来区分回声与真按键。
    private var lastRestoreAt: CFTimeInterval = 0

    private override init() { super.init() }

    var isRunning: Bool { isActive }

    /// 音量+ 是上一页、音量− 是下一页。
    static func direction(volumeRising: Bool) -> Int { volumeRising ? -1 : 1 }

    func start() {
        guard !isActive else { return }
        isActive = true

        let session = AVAudioSession.sharedInstance()
        // ambient：按苹果定义就与别的 App 混音，绝不会打断后台音乐；
        // 我们只需要「会话处于活跃状态」来接收音量事件，不需要真的出声。
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
        startSilentLoop()
        installVolumeView()

        lastVolume = session.outputVolume
        if baselineVolume < 0 { baselineVolume = lastVolume }
        note("启动 当前音量=\(lastVolume) 基准=\(baselineVolume) 输出通路=\(session.currentRoute.outputs.first?.portType.rawValue ?? "-")")

        for name in Self.notificationNames {
            NotificationCenter.default.addObserver(
                self, selector: #selector(volumeDidChange(_:)), name: name, object: nil
            )
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil
        )

        volumeObservation = session.observe(\.outputVolume, options: [.new]) { _, change in
            guard let value = change.newValue else { return }
            DispatchQueue.main.async { VolumeKeyPager.shared.receive(volume: value, reason: nil, sequence: nil, category: nil) }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        // 下次进阅读界面重新取一次基准，用户可能在别处调过音量。
        baselineVolume = -1
        NotificationCenter.default.removeObserver(self)
        volumeObservation?.invalidate()
        volumeObservation = nil
        silentPlayer?.stop()
        silentPlayer = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        note("停止")
    }

    /// 通知回调可能不在主线程，统一切回主线程处理。
    @objc private func volumeDidChange(_ notification: Notification) {
        let info = notification.userInfo
        let volume = (info?["Volume"] as? NSNumber)?.floatValue
            ?? (info?["AVSystemController_AudioVolumeNotificationParameter"] as? NSNumber)?.floatValue
        let reason = (info?["Reason"] as? String)
            ?? (info?["AVSystemController_AudioVolumeChangeReasonNotificationParameter"] as? String)
        let sequence = (info?["SequenceNumber"] as? NSNumber)?.intValue
        let category = info?["AudioCategory"] as? String
        DispatchQueue.main.async { [weak self] in
            self?.receive(volume: volume, reason: reason, sequence: sequence, category: category)
        }
    }

    private func receive(volume: Float?, reason: String?, sequence: Int?, category: String?) {
        // 开关随时可能被改，这里每次都读；关掉就完全不动系统音量。
        guard isActive, ReaderVolumeKeySetting.isEnabled else { return }
        guard let current = volume else { return }
        // 程序自己回写音量引起的通知，一律丢掉。
        guard reason == nil || reason == "ExplicitVolumeChange" else { return }
        if let sequence, sequence == lastSequence { return }
        if let sequence { lastSequence = sequence }

        let now = CACurrentMediaTime()
        if now < suppressUntil { lastVolume = current; return }
        guard now - lastFire > 0.12 else { lastVolume = current; return }

        let previous = lastVolume
        guard previous >= 0 else { lastVolume = current; return }

        let rising: Bool
        if abs(current - previous) > 0.004 {
            rising = current > previous
        } else if previous >= 0.999, now - lastRestoreAt > 0.6 {
            // 音量已经到顶，再按只能是音量+（通知里的数值不会变）。
            rising = true
        } else if previous <= 0.001, now - lastRestoreAt > 0.6 {
            rising = false
        } else {
            lastVolume = current
            return
        }

        lastFire = now
        lastVolume = current
        note("按键 \(previous) → \(current) 原因=\(reason ?? "无") 序号=\(sequence.map { String($0) } ?? "-")")

        NotificationCenter.default.post(
            name: VolumeKeyPager.turnNotification,
            object: nil,
            userInfo: ["direction": VolumeKeyPager.direction(volumeRising: rising)]
        )
        restore(category: category)
    }

    /// 别的 App 抢走音频（比如你开始放歌）会把我们的会话打断，恢复后要重新激活，
    /// 否则静音循环停了，音量事件也就跟着断了。
    @objc private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        guard isActive else { return }
        switch type {
        case .began:
            note("音频会话被中断")
        case .ended:
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true, options: [])
            if silentPlayer?.isPlaying != true { silentPlayer?.play() }
            note("音频会话已恢复")
        @unknown default:
            break
        }
    }

    /// 把音量写回去。
    ///
    /// 硬件音量键是在系统进程里处理的，我们收到通知时音量已经真的降了一档；
    /// 更麻烦的是系统往往在我们写回之后才把它自己那一次「落盘」，把我们的写回盖掉。
    /// 所以这里不写一次就算完，而是写一次、立刻读回来核对，没变就再写，最多四次。
    /// 目标值固定取 baseline（进阅读界面时的音量），保证任何一次失败都不会累积成一路下滑。
    private func restore(category: String?) {
        let target = baselineVolume >= 0 ? baselineVolume : lastVolume
        suppressUntil = CACurrentMediaTime() + 0.3
        lastRestoreAt = CACurrentMediaTime()
        lastVolume = target
        writeUntilStable(target, category: category, attempt: 0)
    }

    /// 写 → 读 → 没回到目标值就再写，每次隔 40 毫秒。
    private func writeUntilStable(_ target: Float, category: String?, attempt: Int) {
        applyVolume(target, category: category)
        let actual = AVAudioSession.sharedInstance().outputVolume
        if abs(actual - target) <= 0.012 { return }
        if attempt >= 3 {
            note("回写失败 实际=\(actual) 目标=\(target)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.isActive else { return }
            self.writeUntilStable(target, category: category, attempt: attempt + 1)
        }
    }

    private func applyVolume(_ value: Float, category: String?) {
        // 私有接口直写系统音量，按按键时那条通知里的类别写，避免写错通道（媒体音量 / 铃声音量）。
        _ = Self.setSystemVolume(value, category: category ?? "Audio/Video")
        // 滑块代表当前输出通路的音量，实在写不进去时靠它兜一次底。
        if let slider = volumeSlider() {
            slider.layoutIfNeeded()
            slider.value = value
            slider.sendActions(for: .touchUpInside)
        }
    }

    // MARK: 音量写入

    /// `MPVolumeView` 里的 UISlider 就是系统音量控制器。
    /// 这个视图必须挂在窗口上才有作用，所以放在屏幕外、不可交互、几乎透明。
    private func installVolumeView(retry: Int = 0) {
        guard volumeView == nil else { return }
        guard let window = Self.keyWindow() else {
            // makeUIView 阶段窗口可能还没挂上，稍后再试几次。
            guard retry < 5 else { note("MPVolumeView 挂载失败：找不到窗口"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.installVolumeView(retry: retry + 1)
            }
            return
        }
        let view = MPVolumeView(frame: CGRect(x: -600, y: -600, width: 120, height: 40))
        view.alpha = 1
        view.isHidden = false
        view.isUserInteractionEnabled = false
        view.showsRouteButton = false
        window.addSubview(view)
        view.layoutIfNeeded()
        volumeView = view
        note("MPVolumeView 已就位 滑块=\(volumeSlider() != nil)")
    }

    private func volumeSlider() -> UISlider? {
        volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        }
        return scenes.flatMap { $0.windows }.first
    }

    /// 备用通道：私有方法 `AVSystemController.setVolumeTo:forCategory:`。
    private static func setSystemVolume(_ value: Float, category: String) -> Bool {
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
            if fn(controller, twoArg, value, category as AnyObject) { return true }
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

    /// 生成 0.25 秒、16 位单声道、全零的 WAV，不需要外部资源。
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

    /// 无条件写一行到 volume-key.log（不受「记录运行日志」开关影响），同时进诊断日志。
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
