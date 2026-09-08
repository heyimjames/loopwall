import Foundation
import AppKit
import IOKit.ps
import Combine

/// Watches everything that should make a wallpaper stop burning power, and
/// answers one question: should this display be playing right now?
final class PowerPolicy: ObservableObject {
    @Published private(set) var isOnBattery = false
    @Published private(set) var isLowPowerMode = false
    @Published private(set) var isScreenLocked = false
    @Published private(set) var isScreenSaverRunning = false
    @Published private(set) var areScreensAsleep = false

    /// Called whenever any input changes, so the engine can re-evaluate.
    var onChange: (() -> Void)?

    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var observers: [Any] = []

    init() {
        refreshBatteryState()
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        startObserving()
    }

    deinit {
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    // MARK: - The actual decision

    /// `isVisible` comes from the window's occlusion state — WindowServer already
    /// knows whether anything is covering the desktop, so we don't have to guess.
    func shouldPlay(isVisible: Bool, preferences: Preferences) -> Bool {
        if preferences.manuallyPaused { return false }
        if areScreensAsleep { return false }
        if preferences.pauseOnScreenSaverAndLock && (isScreenLocked || isScreenSaverRunning) { return false }
        if preferences.pauseInLowPowerMode && isLowPowerMode { return false }
        if preferences.pauseOnBattery && isOnBattery { return false }
        if preferences.pauseWhenCovered && !isVisible { return false }
        return true
    }

    /// Human-readable reason playback is currently suspended, for the menu bar.
    func pauseReason(preferences: Preferences) -> String? {
        if preferences.manuallyPaused { return "Paused" }
        if areScreensAsleep { return "Display asleep" }
        if preferences.pauseOnScreenSaverAndLock && (isScreenLocked || isScreenSaverRunning) { return "Screen locked" }
        if preferences.pauseInLowPowerMode && isLowPowerMode { return "Low Power Mode" }
        if preferences.pauseOnBattery && isOnBattery { return "On battery" }
        return nil
    }

    // MARK: - Inputs

    private func startObserving() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() })
        }
        func observeDistributed(_ name: String, _ handler: @escaping () -> Void) {
            observers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in handler() })
        }

        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.set { $0.areScreensAsleep = true }
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.set { $0.areScreensAsleep = false }
        }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.set { $0.areScreensAsleep = true }
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.set { $0.areScreensAsleep = false }
        }
        observe(.default, .NSProcessInfoPowerStateDidChange) { [weak self] in
            self?.set { $0.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }

        observeDistributed("com.apple.screenIsLocked") { [weak self] in
            self?.set { $0.isScreenLocked = true }
        }
        observeDistributed("com.apple.screenIsUnlocked") { [weak self] in
            self?.set { $0.isScreenLocked = false }
        }
        observeDistributed("com.apple.screensaver.didstart") { [weak self] in
            self?.set { $0.isScreenSaverRunning = true }
        }
        observeDistributed("com.apple.screensaver.didstop") { [weak self] in
            self?.set { $0.isScreenSaverRunning = false }
        }

        startPowerSourceMonitoring()
    }

    private func set(_ mutate: (PowerPolicy) -> Void) {
        mutate(self)
        onChange?()
    }

    private func startPowerSourceMonitoring() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let policy = Unmanaged<PowerPolicy>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                policy.refreshBatteryState()
                policy.onChange?()
            }
        }, context)?.takeRetainedValue() else { return }

        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func refreshBatteryState() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            isOnBattery = false
            return
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            isOnBattery = (state == kIOPSBatteryPowerValue)
            return
        }
        isOnBattery = false
    }
}
