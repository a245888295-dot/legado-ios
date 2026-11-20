import AVFoundation
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
/// iOS 没有公开接口能读到音量键，唯一可行的是监听 `AVSystemController` 的私有通知
/// `AVSystemController_SystemVolumeDidChangeNotification`。它的 userInfo 里有两项关键信息：
///
/// - `AVSystemController_AudioVolumeNotificationParameter`：变化后的音量值
/// - `AVSystemController_AudioVolumeChangeReasonNotificationParameter`：变化原因。
///   只有值为 `ExplicitVolumeChange` 才是「用户按了实体键」，程序自己调音量不会是这个值。
///
/// 所以判断链是：原因是否为实体键 → 音量是升是降 → 翻页 → 把音量写回按键前的值。
/// 写回这一步让用户感觉音量根本没动过。
///
/// 一个绕不过去的瑕疵：系统会先弹出音量 HUD，我们才来得及把音量改回去，所以音量条
/// 会闪一下。要彻底不弹，只能在越狱环境下 hook SpringBoard，TrollStore 单 App 做不到。
/// 不用 @MainActor：这个类被 UIKit 的布局回调、通知回调两边访问，
/// 标了主 actor 反而会牵连一堆非隔离的调用点报并发错误。
/// 内部所有可变状态只在主线程读写（通知观察者指定了 queue: .main），因此标 unchecked。
final class VolumeKeyPager: @unchecked Sendable {
    static let shared = VolumeKeyPager()

    /// 翻页请求。direction 与 `Coordinator.turnPage(_:)` 一致：1 下一页，-1 上一页。
    static let turnNotification = Notification.Name("readerVolumeKeyTurn")

    private var observer: NSObjectProtocol?
    private var lastVolume: Float = 0
    private var lastFire: CFTimeInterval = 0
    /// 我们回写音量时系统也会发同一条通知，用这个旗子把它挡掉，否则会自己翻自己。
    private var isRestoringVolume = false

    private init() {}

    var isRunning: Bool { observer != nil }

    /// 音量+ 是上一页、音量− 是下一页（按用户指定方向）。
    static func direction(volumeRising: Bool) -> Int { volumeRising ? -1 : 1 }

    func start() {
        guard observer == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // 不激活音频会话，这条通知根本不会发出来。
        // 用 ambient + mixWithOthers：只为了让通知开始投递，不能把用户正在放的音乐掐掉。
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
        lastVolume = session.outputVolume
        // 会话刚激活时 outputVolume 可能还是 0，延迟再校准一次，
        // 否则用户第一次按键会被判成「音量从 0 升上来」，方向正好反了。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.observer != nil else { return }
            self.lastVolume = AVAudioSession.sharedInstance().outputVolume
        }

        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
            object: nil,
            queue: .main
        ) { note in
            // 通知对象跨线程不安全，先在本线程把值取成纯数据类型。
            let volume = (note.userInfo?["AVSystemController_AudioVolumeNotificationParameter"] as? NSNumber)?.floatValue
            let reason = note.userInfo?["AVSystemController_AudioVolumeChangeReasonNotificationParameter"] as? String
            // 观察者挂在主队列上，这里已经是主线程。
            VolumeKeyPager.shared.handle(volume: volume, reason: reason)
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func handle(volume: Float?, reason: String?) {
        // 开关随时可能被改，这里每次都读，关掉就完全不动系统音量。
        guard ReaderVolumeKeySetting.isEnabled else { return }
        guard !isRestoringVolume else { return }
        guard reason == "ExplicitVolumeChange" else { return }
        guard let current = volume else { return }

        // 一次按键可能连发两条通知，做个最小间隔。
        let now = CACurrentMediaTime()
        guard now - lastFire > 0.12 else { return }

        let previous = lastVolume
        lastVolume = current
        guard abs(current - previous) > 0.001 else { return }
        lastFire = now

        let direction = VolumeKeyPager.direction(volumeRising: current > previous)
        NotificationCenter.default.post(
            name: VolumeKeyPager.turnNotification,
            object: nil,
            userInfo: ["direction": direction]
        )
        restoreVolume(previous)
    }

    private func restoreVolume(_ value: Float) {
        isRestoringVolume = true
        lastVolume = value
        VolumeKeyPager.setSystemVolume(value)
        // 回写本身会再发一条通知，等它过去了再放开。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.isRestoringVolume = false
            self.lastVolume = AVAudioSession.sharedInstance().outputVolume
        }
    }

    /// 私有 API：`AVSystemController` 的 `setVolumeTo:forCategory:`。
    /// 版本之间方法名有差异，两个签名都试一遍；都失效就放弃回写（音量会真的变，但翻页仍然生效）。
    private static func setSystemVolume(_ value: Float) {
        let sharedSelector = NSSelectorFromString("sharedAVSystemController")
        guard let cls = NSClassFromString("AVSystemController") as? NSObject.Type,
              let factory = class_getClassMethod(cls, sharedSelector) else { return }
        typealias Factory = @convention(c) (AnyObject, Selector) -> AnyObject
        let controller = unsafeBitCast(method_getImplementation(factory), to: Factory.self)(cls, sharedSelector)

        guard let controllerClass = object_getClass(controller) else { return }

        let twoArg = NSSelectorFromString("setVolumeTo:forCategory:")
        if let method = class_getInstanceMethod(controllerClass, twoArg) {
            typealias Fn = @convention(c) (AnyObject, Selector, Float, AnyObject) -> Bool
            let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
            if fn(controller, twoArg, value, "Audio/Video" as AnyObject) { return }
        }

        let threeArg = NSSelectorFromString("setVolumeTo:forCategory:mode:")
        if let method = class_getInstanceMethod(controllerClass, threeArg) {
            typealias Fn = @convention(c) (AnyObject, Selector, Float, AnyObject, AnyObject) -> Bool
            let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
            _ = fn(controller, threeArg, value, "Audio/Video" as AnyObject, 0 as AnyObject)
        }
    }
}

/// 音量键翻页的开关。默认开启：这是阅读器该有的能力，不用专门去找。
enum ReaderVolumeKeySetting {
    static let key = "readerVolumeKeyPaging"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
