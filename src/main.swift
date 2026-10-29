import Cocoa
import CoreGraphics
import Darwin
import Foundation

// MARK: - Configuration & Arguments

struct Config {
    var password = ProcessInfo.processInfo.environment["VIBE_TRAP_PASSWORD"] ?? "vibetrap"
    var countdown = Int(ProcessInfo.processInfo.environment["VIBE_TRAP_COUNTDOWN"] ?? "5") ?? 5
    var timeoutMs: Int? = nil // nil = persistent kiosk until password typed
    var customImage: String? = nil
    var customAudio: String? = nil
    var assetsDir = "assets"
    var triggerOnMove = false
    var dryRun = false
}

func parseArguments() -> Config {
    var config = Config()
    let args = CommandLine.arguments

    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-v", "--version":
            print("vibe-trap v1.1.0")
            exit(0)
        case "-h", "--help":
            print("""
            usage: vibe-trap [-h] [-v] [--countdown SECONDS] [--password PASSWORD]
                             [--timeout TIMEOUT] [--image IMAGE] [--audio AUDIO]
                             [--assets-dir ASSETS_DIR] [--trigger-on-move] [--dry-run]

            vibe-trap: macOS AFK trap utility. Keeps screen awake and triggers on unauthorized input.

            options:
              -h, --help            show this help message and exit
              -v, --version         show program's version number and exit
              --countdown, -c SECONDS
                                    Countdown in seconds before arming sensors (default: 5)
              --password, -p PASSWORD
                                    Secret disarm password (default: '\(config.password)')
              --timeout, -t TIMEOUT
                                    Optional auto-lock timeout in ms (default: persistent until disarmed)
              --image, -i IMAGE     Path to specific meme/jumpscare image (overrides auto-selection)
              --audio, -a AUDIO     Path to specific audio file (overrides auto-selection)
              --assets-dir ASSETS_DIR
                                    Directory containing image/audio payload assets (default: 'assets')
              --trigger-on-move     Also trigger trap on mouse movement (by default triggers only on mouse click)
              --dry-run             Test mode: trigger payload and window, but skip display sleep lock
            """)
            exit(0)
        case "-c", "--countdown":
            if i + 1 < args.count, let c = Int(args[i + 1]) { config.countdown = max(0, c); i += 1 }
        case "-p", "--password":
            if i + 1 < args.count { config.password = args[i + 1]; i += 1 }
        case "-t", "--timeout":
            if i + 1 < args.count, let t = Int(args[i + 1]) { config.timeoutMs = t; i += 1 }
        case "-i", "--image":
            if i + 1 < args.count { config.customImage = args[i + 1]; i += 1 }
        case "-a", "--audio":
            if i + 1 < args.count { config.customAudio = args[i + 1]; i += 1 }
        case "--assets-dir":
            if i + 1 < args.count { config.assetsDir = args[i + 1]; i += 1 }
        case "--trigger-on-move":
            config.triggerOnMove = true
        case "--dry-run":
            config.dryRun = true
        default:
            break
        }
        i += 1
    }
    return config
}

// MARK: - Asset Selection

func resolvePath(_ relativePath: String) -> String? {
    let fm = FileManager.default
    if fm.fileExists(atPath: relativePath) {
        return (relativePath as NSString).expandingTildeInPath
    }

    let execDir = Bundle.main.bundleURL.deletingLastPathComponent().path
    let candidate = (execDir as NSString).appendingPathComponent(relativePath)
    if fm.fileExists(atPath: candidate) {
        return candidate
    }

    let parentDir = (execDir as NSString).deletingLastPathComponent
    let parentCandidate = (parentDir as NSString).appendingPathComponent(relativePath)
    if fm.fileExists(atPath: parentCandidate) {
        return parentCandidate
    }

    return nil
}

func selectAssets(config: Config) -> (imagePath: String?, audioPath: String?) {
    let fm = FileManager.default
    var selectedImg: String? = config.customImage.flatMap { resolvePath($0) }
    var selectedAudio: String? = config.customAudio.flatMap { resolvePath($0) }

    let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "bmp"]
    let audioExts: Set<String> = ["wav", "mp3", "aiff", "m4a", "aac", "flac"]

    var searchDirs = [config.assetsDir]
    if let resolvedAssets = resolvePath(config.assetsDir), resolvedAssets != config.assetsDir {
        searchDirs.append(resolvedAssets)
    }

    for dir in searchDirs {
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        let images = files.filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
        let audios = files.filter { audioExts.contains(($0 as NSString).pathExtension.lowercased()) }

        let imgStems = Dictionary(uniqueKeysWithValues: images.map { (($0 as NSString).deletingPathExtension, $0) })
        let audioStems = Dictionary(uniqueKeysWithValues: audios.map { (($0 as NSString).deletingPathExtension, $0) })

        let commonStems = Array(Set(imgStems.keys).intersection(Set(audioStems.keys))).sorted()
        if let stem = commonStems.randomElement() {
            if selectedImg == nil { selectedImg = (dir as NSString).appendingPathComponent(imgStems[stem]!) }
            if selectedAudio == nil { selectedAudio = (dir as NSString).appendingPathComponent(audioStems[stem]!) }
        }

        if selectedImg == nil, let img = images.randomElement() {
            selectedImg = (dir as NSString).appendingPathComponent(img)
        }
        if selectedAudio == nil, let audio = audios.randomElement() {
            selectedAudio = (dir as NSString).appendingPathComponent(audio)
        }

        if selectedImg != nil && selectedAudio != nil { break }
    }

    if selectedAudio == nil {
        for sysSound in ["/System/Library/Sounds/Sosumi.aiff", "/System/Library/Sounds/Basso.aiff"] {
            if fm.fileExists(atPath: sysSound) {
                selectedAudio = sysSound
                break
            }
        }
    }

    return (selectedImg, selectedAudio)
}

// MARK: - State Management

class TrapManager {
    let config: Config
    let imagePath: String?
    let audioPath: String?

    var typedBuffer = ""
    var slidingJumpscareBuffer = ""
    var isTriggered = false
    var isDisarmed = false
    var isSensorArmed = false

    var eventTap: CFMachPort? = nil
    var originalTerm = termios()
    var isRawTerm = false

    var lastCharTime: CFAbsoluteTime = 0
    var lastChar: String = ""

    var payloadWindow: NSWindow? = nil
    var activeSound: NSSound? = nil
    var activeAudioProcess: Process? = nil
    var signalSources: [DispatchSourceSignal] = []

    init(config: Config) {
        self.config = config
        let assets = selectAssets(config: config)
        self.imagePath = assets.imagePath
        self.audioPath = assets.audioPath
    }

    func start() {
        checkPermissionsAndPrintBanner()
        setupSignalHandlers()

        if config.countdown > 0 {
            startCountdown(secondsRemaining: config.countdown)
        } else {
            armSensors()
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func startCountdown(secondsRemaining: Int) {
        if secondsRemaining > 0 {
            if isatty(STDOUT_FILENO) != 0 {
                print("\r⏳ Arming touch sensor in \(secondsRemaining)s... (step away from mouse & keyboard) ", terminator: "")
            } else {
                print("⏳ Arming touch sensor in \(secondsRemaining)s...")
            }
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, !self.isDisarmed else { return }
                self.startCountdown(secondsRemaining: secondsRemaining - 1)
            }
        } else {
            if isatty(STDOUT_FILENO) != 0 {
                print("\r🛡️  [ARMED] Touch sensors ACTIVE! Workstation is now protected.              \r\n")
            } else {
                print("🛡️  [ARMED] Touch sensors ACTIVE! Workstation is now protected.\n")
            }
            print(String(repeating: "=", count: 64))
            fflush(stdout)
            self.armSensors()
        }
    }

    func armSensors() {
        guard !isSensorArmed && !isDisarmed else { return }
        isSensorArmed = true

        // Flush any pending keys typed during the countdown
        tcflush(STDIN_FILENO, TCIFLUSH)

        setupStdinListener()
        setupEventTap()
    }

    func checkPermissionsAndPrintBanner() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)

        print(String(repeating: "=", count: 64))
        print("                 ⚡ VIBE TRAP ARMED & READY ⚡")
        print(String(repeating: "=", count: 64))
        print("Disarm Password : '\(config.password)' (type to disarm)")
        print("Countdown       : \(config.countdown > 0 ? "\(config.countdown)s before arming sensors" : "Instant (0s)")")
        print("Payload Image   : \(imagePath ?? "None (Fallback red text)")")
        print("Payload Audio   : \(audioPath ?? "None")")
        print("Trap Mode       : \(config.timeoutMs == nil ? "🔒 Persistent Kiosk (locks until disarmed)" : "⏱️  Timeout (\(config.timeoutMs!) ms)")")
        print("Bypass Defense  : 🛡️  ACTIVE (Ctrl+C / kill signals trigger instant lock)")
        print("Dry Run Mode    : \(config.dryRun ? "ENABLED (screen lock simulated)" : "DISABLED (screen will lock)")")
        print("Permissions     : \(isTrusted ? "✅ Accessibility Granted" : "⚠️  Accessibility Prompted (Allow in Settings)")")
        print("Status          : \(config.countdown > 0 ? "⏳ Arming in \(config.countdown)s..." : "🛡️  ARMED! Listening for intruders...")")
        print(String(repeating: "=", count: 64))
        print("Tip: Keep MacBook awake by running: caffeinate -d npx vibe-trap")
        print(String(repeating: "=", count: 64))

        if !isTrusted {
            print("""
            ⚠️   macOS Accessibility Permission Notice:
            Global background monitoring requires Accessibility permissions.
            If a system dialog popped up, click 'Open System Settings' and toggle
            ON your Terminal app.
            
            👉 Keystrokes inside this terminal are monitored directly via stdin!
            \(String(repeating: "=", count: 64))
            """)
        }
        fflush(stdout)
    }

    func restoreTerminal() {
        if isRawTerm {
            tcsetattr(STDIN_FILENO, TCSANOW, &originalTerm)
            isRawTerm = false
        }
    }

    func setupSignalHandlers() {
        // Ignore standard signal handlers so kernel doesn't immediately kill the process
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)

        // Capture signals via Grand Central Dispatch on main queue
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self = self, !self.isDisarmed else { return }

                // If interrupted during countdown, exit cleanly without locking screen
                if !self.isSensorArmed {
                    print("\r\n[*] Aborted during countdown. Exiting safely.")
                    fflush(stdout)
                    self.cleanupAndExit(success: true, message: "")
                    return
                }

                print("\r\n🚨 [SECURITY BREACH] Bypass signal (\(sig)) caught! Enforcing immediate lock screen...")
                fflush(stdout)
                self.enforceScreenSleepLock()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func setupStdinListener() {
        if isatty(STDIN_FILENO) != 0 {
            tcgetattr(STDIN_FILENO, &originalTerm)
            var raw = originalTerm
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
            isRawTerm = true
        }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 16)
            while let self = self, !self.isDisarmed {
                let bytesRead = read(STDIN_FILENO, &buf, buf.count)
                if bytesRead <= 0 { break }

                // Check for bypass attempts: Ctrl+C (3), Ctrl+\ (28), Ctrl+D (4)
                if buf.prefix(bytesRead).contains(where: { $0 == 3 || $0 == 28 || $0 == 4 }) {
                    DispatchQueue.main.async {
                        print("\r\n🚨 [SECURITY BREACH] Terminal bypass combination detected! Enforcing immediate lock screen...")
                        fflush(stdout)
                        self.enforceScreenSleepLock()
                    }
                    return
                }

                if let str = String(bytes: buf[0..<bytesRead], encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.handleIncomingKeyString(str)
                    }
                } else if !self.isTriggered {
                    DispatchQueue.main.async {
                        self.trigger(reason: "Non-UTF8 input sequence detected in terminal")
                    }
                }
            }
        }
    }

    func setupEventTap() {
        var mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        if config.triggerOnMove {
            mask |= (1 << CGEventType.mouseMoved.rawValue)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<TrapManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            return
        }

        self.eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if !isSensorArmed || isDisarmed {
            return Unmanaged.passRetained(event)
        }

        // --- WHILE ARMED (Before Jumpscare) ---
        if !isTriggered {
            switch type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                trigger(reason: "Mouse click detected (\(type))")
                return nil

            case .mouseMoved:
                if config.triggerOnMove {
                    trigger(reason: "Mouse movement detected")
                    return nil
                }
                return Unmanaged.passRetained(event)

            case .keyDown:
                if let nsEvent = NSEvent(cgEvent: event), let chars = nsEvent.characters, !chars.isEmpty {
                    handleIncomingKeyString(chars)
                } else {
                    trigger(reason: "Special key pressed")
                }
                return nil

            default:
                return Unmanaged.passRetained(event)
            }
        }

        // --- WHILE JUMPSCARE IS ACTIVE (Kiosk Lockout) ---
        // Eat all mouse clicks so intruder cannot interact with other windows
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved:
            return nil // Swallowed completely

        case .keyDown:
            if let nsEvent = NSEvent(cgEvent: event), let chars = nsEvent.characters, !chars.isEmpty {
                handleIncomingKeyString(chars)
            }
            return nil // Eat key event so background apps don't receive it

        default:
            return nil
        }
    }

    func handleIncomingKeyString(_ chars: String) {
        if !isSensorArmed || isDisarmed { return }

        let now = CFAbsoluteTimeGetCurrent()

        for char in chars {
            let charStr = String(char)

            // Deduplicate if identical character received from both CGEvent and stdin within 50ms
            if charStr == lastChar && (now - lastCharTime) < 0.05 {
                continue
            }
            lastChar = charStr
            lastCharTime = now

            if !isTriggered {
                // Armed phase: strict prefix checking
                processArmedKeystroke(char)
            } else {
                // Jumpscare phase: continuous sliding window matching
                processJumpscareKeystroke(char)
            }
        }
    }

    func processArmedKeystroke(_ char: Character) {
        typedBuffer.append(char)
        let current = typedBuffer.lowercased()
        let target = config.password.lowercased()

        if current == target {
            isDisarmed = true
            cleanupAndExit(success: true, message: "\r\n[✓] PASSWORD VERIFIED ('\(config.password)')! Vibe Trap disarmed.\r\n[✓] Welcome back. Exiting safely.")
        } else if target.hasPrefix(current) {
            // Valid prefix, wait silently
            return
        } else {
            trigger(reason: "Incorrect key sequence (typed '\(typedBuffer)', expected prefix of '\(config.password)')")
        }
    }

    func processJumpscareKeystroke(_ char: Character) {
        slidingJumpscareBuffer.append(char)

        let target = config.password.lowercased()
        let maxLen = max(target.count, 16)
        if slidingJumpscareBuffer.count > maxLen {
            slidingJumpscareBuffer = String(slidingJumpscareBuffer.suffix(maxLen))
        }

        if slidingJumpscareBuffer.lowercased().hasSuffix(target) {
            disarmFromJumpscare()
        }
    }

    func trigger(reason: String) {
        guard !isTriggered && !isDisarmed else { return }
        isTriggered = true

        print("\r\n" + String(repeating: "!", count: 56))
        print("💥💥💥 VIBE TRAP TRIGGERED! EXECUTING PAYLOAD 💥💥💥")
        print("!" + String(repeating: "!", count: 55))
        print("[!] Trigger Cause: \(reason)")
        print("[*] Screen locked with jumpscare. Type password to disarm.")
        print("[!] Warning: Any attempt to exit or bypass will lock screen immediately.")
        fflush(stdout)

        DispatchQueue.main.async {
            self.executePayload()
        }
    }

    func executePayload() {
        // 1. Play continuous audio (looping)
        if let audio = audioPath, FileManager.default.fileExists(atPath: audio) {
            print("[*] Starting continuous looping audio: \(audio)")
            fflush(stdout)

            // Try NSSound with looping first
            if let sound = NSSound(contentsOfFile: audio, byReference: true) {
                sound.loops = true
                sound.play()
                self.activeSound = sound
            } else {
                // Fallback to afplay process
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                p.arguments = [audio]
                try? p.run()
                self.activeAudioProcess = p
            }
        }

        // 2. Launch fullscreen borderless topmost kiosk window
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let contentView = NSView(frame: screen.frame)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = contentView

        var imageLoaded = false
        if let imgPath = imagePath, let image = NSImage(contentsOfFile: imgPath) {
            let imageView = NSImageView(frame: screen.frame)
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            contentView.addSubview(imageView)
            imageLoaded = true
        }

        if !imageLoaded {
            let label = NSTextField(labelWithString: "🚨  UNAUTHORIZED ACCESS DETECTED  🚨\n\nWORKSTATION BREACH PROTOCOL ENGAGED\nLOCKING SYSTEM NOW")
            label.alignment = .center
            label.textColor = NSColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 1.0)
            label.font = NSFont.boldSystemFont(ofSize: 38)
            label.frame = CGRect(x: 50, y: screen.frame.height / 2 - 100, width: screen.frame.width - 100, height: 200)
            contentView.addSubview(label)
        }

        NSCursor.hide()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.payloadWindow = window

        print("[*] Displaying jumpscare window (Persistent Kiosk Mode)...")
        print("[*] Type '\(config.password)' blindly anywhere on the keyboard to disarm.")
        fflush(stdout)

        // 3. Optional timeout (only if --timeout was explicitly specified)
        if let timeout = config.timeoutMs, timeout > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeout)) { [weak self] in
                guard let self = self, self.isTriggered && !self.isDisarmed else { return }
                self.enforceScreenSleepLock()
            }
        }
    }

    func disarmFromJumpscare() {
        guard isTriggered && !isDisarmed else { return }
        isDisarmed = true

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 1. Stop audio
            self.activeSound?.stop()
            if let p = self.activeAudioProcess, p.isRunning {
                p.terminate()
            }

            // 2. Unhide cursor & close window
            NSCursor.unhide()
            self.payloadWindow?.close()

            // 3. Cleanup terminal & exit
            self.cleanupAndExit(
                success: true,
                message: "\r\n" + String(repeating: "=", count: 64)
                    + "\r\n🔓 [✓] PASSWORD VERIFIED ('\(self.config.password)')!"
                    + "\r\n🛡️  VIBE TRAP DISARMED. WORKSTATION RESTORED."
                    + "\r\n" + String(repeating: "=", count: 64)
            )
        }
    }

    func enforceScreenSleepLock() {
        activeSound?.stop()
        if let p = activeAudioProcess, p.isRunning { p.terminate() }
        NSCursor.unhide()
        payloadWindow?.close()
        restoreTerminal()

        if !config.dryRun {
            print("\r\n🔒 [SECURITY PROTOCOL] Locking macOS screen and enforcing password...")
            fflush(stdout)

            typealias LockFunc = @convention(c) () -> Int32
            if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW) {
                if let sym = dlsym(handle, "SACLockScreenImmediate") {
                    let lockScreen = unsafeBitCast(sym, to: LockFunc.self)
                    _ = lockScreen()
                }
                dlclose(handle)
            }

            let lockProc = Process()
            lockProc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            lockProc.arguments = ["displaysleepnow"]
            try? lockProc.run()
            lockProc.waitUntilExit()
        } else {
            print("\r\n[DRY-RUN] Screen lock simulated ('pmset displaysleepnow' & 'SACLockScreenImmediate' skipped).")
            fflush(stdout)
        }

        cleanupAndExit(success: false, message: "[*] Terminating vibe-trap.")
    }

    func cleanupAndExit(success: Bool, message: String) {
        restoreTerminal()
        print(message)
        fflush(stdout)
        exit(success ? 0 : 1)
    }
}

// MARK: - Entry Point

let config = parseArguments()
let manager = TrapManager(config: config)
manager.start()
