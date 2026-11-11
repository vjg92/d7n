import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dictation = Dictation()
    private var hold = HoldState()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var window: NSWindow?
    private var label: NSTextField?
    private var ready = false
    private var preparing = false
    private var recording = false
    private var processing = false
    private var target: InsertionTarget?
    private var work: Task<Void, Never>?
    private var watchdog: Timer?
    private var started = Date()
    private var generation = 0
    private var status = "Setup required." { didSet { label?.stringValue = status } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(interrupted), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(interrupted), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(focusChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if UserDefaults.standard.bool(forKey: "configured") { Task { await prepare(prompt: false) } }
        else { showSetup() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSetup(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { cancel(); if let tap { CGEvent.tapEnable(tap: tap, enable: false) } }

    @objc private func focusChanged() { if recording || processing { cancel() } }
    @objc private func interrupted() { cancel(); hold.reset() }

    private func cancel() {
        generation += 1
        work?.cancel(); work = nil
        dictation.cancelRecording()
        // Keep processing true until the cancelled task actually finishes.
        watchdog?.invalidate(); watchdog = nil
        recording = false; target = nil
    }

    private func start() {
        guard ready, !recording, !processing, let target = InsertionTarget.capture() else { return }
        self.target = target
        do {
            try dictation.start(); recording = true; started = Date()
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if Date().timeIntervalSince(self.started) > 120 { self.cancel(); return }
                    if !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) { self.stop() }
                }
            }
        } catch { cancel(); status = "Microphone could not start. Check microphone permission and input device, then retry setup." }
    }

    private func stop() {
        guard recording else { return }
        watchdog?.invalidate(); watchdog = nil; recording = false
        do {
            let buffers = try dictation.stop()
            guard Date().timeIntervalSince(started) > 0.18, !buffers.isEmpty, let target else { self.target = nil; return }
            processing = true
            let token = generation
            work = Task {
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(45))
                    guard !Task.isCancelled, let self, self.processing, self.generation == token else { return }
                    self.cancel()
                    await self.dictation.cancelAnalysis()
                    self.status = "Transcription timed out. Hold Fn to try again."
                }
                defer { timeout.cancel(); processing = false; self.target = nil; work = nil }
                do {
                    let text = try await dictation.transcribe(buffers)
                    guard !Task.isCancelled, token == generation else { return }
                    if !text.isEmpty {
                        status = target.insert(text) ? "Ready. Hold Fn in a text field and speak." : "Text was discarded: focus changed or this app did not accept text insertion."
                    }
                } catch {
                    if !Task.isCancelled { status = "Transcription failed. Hold Fn to retry, or run setup again." }
                }
            }
        } catch { cancel(); status = "Recording discarded because it exceeded the memory or time limit." }
    }

    func event(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            interrupted()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let action: HoldState.Action
        if type == .flagsChanged {
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            action = hold.flags(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), fnDown: event.flags.contains(.maskSecondaryFn), otherModifiers: !event.flags.intersection(modifiers).isEmpty)
        } else {
            // Discard pending dictation if the user types or moves the caret.
            if processing { cancel() }
            if type == .leftMouseDown || type == .rightMouseDown { cancel() }
            action = hold.keyDown()
        }
        switch action { case .start: start(); case .stop: stop(); case .cancel: cancel(); case .none: break }
    }

    private func installTap() -> Bool {
        if tap != nil { return true }
        let mask = [CGEventType.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue().event(type, event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func prepare(prompt: Bool) async {
        guard !preparing, !processing, !recording else { return }
        preparing = true; ready = false
        defer { preparing = false }
        var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !microphone && prompt { microphone = await AVCaptureDevice.requestAccess(for: .audio) }
        guard microphone else { status = "Enable Microphone access for d7n, then click Prepare / Retry."; return }
        if !AXIsProcessTrusted(), prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        guard AXIsProcessTrusted() else { status = "Enable d7n in System Settings → Privacy & Security → Accessibility. Then retry."; return }
        if !CGPreflightListenEventAccess(), prompt { _ = CGRequestListenEventAccess() }
        guard CGPreflightListenEventAccess() else { status = "Enable d7n in Privacy & Security → Input Monitoring. Quit and reopen d7n if macOS asks, then retry."; return }
        status = "Preparing Australian English speech model. First setup may download an Apple model…"
        do {
            try await dictation.prepare()
            guard installTap() else { status = "Could not listen for Fn. Check Input Monitoring and reopen d7n."; return }
            UserDefaults.standard.set(true, forKey: "configured")
            ready = true
            status = "Ready. Close this window, click a text field, hold Fn and speak. Release to insert."
            if !UserDefaults.standard.bool(forKey: "loginPreferenceSet") {
                do {
                    try SMAppService.mainApp.register()
                    UserDefaults.standard.set(true, forKey: "loginPreferenceSet")
                } catch { status += " Login launch needs enabling using the button below." }
            }
        } catch { status = "Could not prepare the local speech model. Check internet for the initial model download, then retry." }
    }

    @objc private func prepareClicked() { Task { await prepare(prompt: true) } }
    @objc private func keyboardSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
    @objc private func privacySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc private func enableLogin() {
        do { try SMAppService.mainApp.register(); UserDefaults.standard.set(true, forKey: "loginPreferenceSet"); status = "Login launch requested. macOS may require approval in Login Items." }
        catch { status = "Unable to register login launch. Move d7n.app to Applications, reopen it and retry." }
    }
    @objc private func disableLogin() {
        Task {
            do { try await SMAppService.mainApp.unregister(); UserDefaults.standard.set(true, forKey: "loginPreferenceSet"); status = "Login launch disabled." }
            catch { status = "Could not disable login launch. Check System Settings → General → Login Items." }
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showSetup() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 470), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "d7n — Setup & Controls"; window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        func text(_ value: String, bold: Bool = false) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: value)
            label.font = bold ? .boldSystemFont(ofSize: 20) : .systemFont(ofSize: 13)
            stack.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return label
        }
        _ = text("Hold Fn. Speak. Release.", bold: true)
        _ = text("d7n runs invisibly after you close this window. Audio is processed on this Mac using Apple's speech model. No recordings, transcripts, clipboard writes or analytics are saved by this app.")
        _ = text("Before using it: in Keyboard settings, set ‘Press 🌐 key to’ to ‘Do Nothing’, and remove any Fn / Globe shortcut for Apple Dictation. Disable Wispr Flow's Fn shortcut too.")
        label = text(status)
        func row(_ buttons: [(String, Selector)]) {
            let row = NSStackView(); row.spacing = 10
            for (title, action) in buttons { row.addArrangedSubview(NSButton(title: title, target: self, action: action)) }
            stack.addArrangedSubview(row)
        }
        row([("Prepare / Retry", #selector(prepareClicked)), ("Keyboard Settings", #selector(keyboardSettings)), ("Permissions", #selector(privacySettings))])
        row([("Enable Login Launch", #selector(enableLogin)), ("Disable Login Launch", #selector(disableLogin)), ("Quit d7n", #selector(quit))])
        _ = text("Reopen d7n.app to return here. Esc or another key cancels a hold. Dictation is discarded if you change apps, click or type while it is processing. Maximum hold: 2 minutes. No cloud fallback.")
        self.window = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
