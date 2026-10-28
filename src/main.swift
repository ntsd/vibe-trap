import Cocoa
import CoreGraphics
import Foundation

// MARK: - Configuration & Arguments

struct Config {
    var password = ProcessInfo.processInfo.environment["VIBE_TRAP_PASSWORD"] ?? "ntsd"
    var timeoutMs = 3000
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
        case "-h", "--help":
            print("""
            usage: vibe-trap [-h] [--password PASSWORD] [--timeout TIMEOUT]
                             [--image IMAGE] [--audio AUDIO] [--assets-dir ASSETS_DIR]
                             [--trigger-on-move] [--dry-run]

            vibe-trap: macOS AFK trap utility. Keeps screen awake and triggers on unauthorized input.

            options:
              -h, --help            show this help message and exit
              --password, -p PASSWORD
                                    Secret disarm password (default: '\(config.password)')
              --timeout, -t TIMEOUT
                                    Payload window duration in milliseconds (default: \(config.timeoutMs))
              --image, -i IMAGE     Path to specific meme/jumpscare image (overrides auto-selection)
              --audio, -a AUDIO     Path to specific audio file (overrides auto-selection)
              --assets-dir ASSETS_DIR
                                    Directory containing image/audio payload assets (default: 'assets')
              --trigger-on-move     Also trigger trap on mouse movement (by default triggers only on mouse click)
              --dry-run             Test mode: trigger payload and window, but skip display sleep lock
            """)
            exit(0)
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

    if selectedImg == nil { selectedImg = resolvePath("vibe.png") }
    if selectedAudio == nil { selectedAudio = resolvePath("vibe.wav") }

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
    var isTriggered = false
    var isDisarmed = false
    var eventTap: CFMachPort? = nil
    var originalTerm = termios()
    var isRawTerm = false

    init(config: Config) {
        self.config = config
        let assets = selectAssets(config: config)
        self.imagePath = assets.imagePath
        self.audioPath = assets.audioPath
    }

    func start() {
        checkPermissionsAndPrintBanner()
        setupSignalHandlers()
        setupStdinListener()
        setupEventTap()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func checkPermissionsAndPrintBanner() {
        // Request prompt if not trusted
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)

        print(String(repeating: "=", count: 64))
        print("                 ⚡ VIBE TRAP ARMED & READY ⚡")
        print(String(repeating: "=", count: 64))
        print("Disarm Password : '\(config.password)' (type to disarm)")
        print("Payload Image   : \(imagePath ?? "None (Fallback red text)")")
        print("Payload Audio   : \(audioPath ?? "None")")
        print("Window Timeout  : \(config.timeoutMs) ms (\(Double(config.timeoutMs) / 1000.0)s)")
        print("Dry Run Mode    : \(config.dryRun ? "ENABLED (will not lock screen)" : "DISABLED (will lock screen)")")
        print("Permissions     : \(isTrusted ? "✅ Accessibility Granted" : "⚠️  Accessibility Prompted (Allow in Settings)")")
        print("Status          : 🛡️  ARMED! Listening for intruders...")
        print(String(repeating: "=", count: 64))
        print("Tip: Keep MacBook awake by running: caffeinate -d npx vibe-trap")
        print(String(repeating: "=", count: 64))

        if !isTrusted {
            print("""
            ⚠️   macOS Accessibility Permission Required:
            macOS requires permission to monitor global keyboard and mouse events.
            If a system dialog popped up, click 'Open System Settings' and toggle
            ON your Terminal app.
            
            👉 In the meantime, direct keystrokes in this terminal will still be trapped!
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
        signal(SIGINT) { _ in
            print("\n[!] Vibe Trap interrupted by user (SIGINT). Disarming...")
            exit(0)
        }
        signal(SIGTERM) { _ in
            print("\n[!] Vibe Trap terminated (SIGTERM).")
            exit(0)
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
            while let self = self, !self.isTriggered && !self.isDisarmed {
                let bytesRead = read(STDIN_FILENO, &buf, buf.count)
                if bytesRead <= 0 { break }

                if bytesRead > 0 {
                    // Check for Ctrl+C (ASCII 3)
                    if buf.prefix(bytesRead).contains(3) {
                        self.restoreTerminal()
                        print("\r\n[!] Disarmed by user (Ctrl+C). Exiting...")
                        fflush(stdout)
                        exit(0)
                    }

                    if let str = String(bytes: buf[0..<bytesRead], encoding: .utf8) {
                        DispatchQueue.main.async {
                            self.handleKeyString(str)
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.trigger(reason: "Non-UTF8 input sequence detected in terminal")
                        }
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
        if isTriggered || isDisarmed {
            return Unmanaged.passRetained(event)
        }

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
                handleKeyString(chars)
            } else {
                trigger(reason: "Special key pressed")
            }
            return nil

        default:
            return Unmanaged.passRetained(event)
        }
    }

    func handleKeyString(_ chars: String) {
        if isTriggered || isDisarmed { return }

        for char in chars {
            typedBuffer.append(char)
            if typedBuffer == config.password {
                restoreTerminal()
                print("\r\n[✓] PASSWORD VERIFIED ('\(config.password)')! Vibe Trap disarmed.")
                print("[✓] Welcome back. Exiting safely.")
                fflush(stdout)
                isDisarmed = true
                exit(0)
            } else if config.password.hasPrefix(typedBuffer) {
                // Prefix matches, keep waiting silently
                continue
            } else {
                trigger(reason: "Incorrect key sequence (typed '\(typedBuffer)', expected prefix of '\(config.password)')")
                return
            }
        }
    }

    func trigger(reason: String) {
        guard !isTriggered && !isDisarmed else { return }
        isTriggered = true
        restoreTerminal()

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        print("\r\n" + String(repeating: "!", count: 56))
        print("💥💥💥 VIBE TRAP TRIGGERED! EXECUTING PAYLOAD 💥💥💥")
        print("!" + String(repeating: "!", count: 55))
        print("[!] Trigger Cause: \(reason)")
        fflush(stdout)

        DispatchQueue.main.async {
            self.executePayload()
        }
    }

    func executePayload() {
        // 1. Play audio asynchronously
        var audioProc: Process? = nil
        if let audio = audioPath, FileManager.default.fileExists(atPath: audio) {
            print("[*] Playing audio: \(audio)")
            fflush(stdout)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            p.arguments = [audio]
            try? p.run()
            audioProc = p
        }

        // 2. Launch fullscreen borderless topmost window
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

        print("[*] Displaying payload window (duration: \(config.timeoutMs) ms)...")
        fflush(stdout)

        // 3. Timeout & Screen Lock after timeoutMs
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(config.timeoutMs)) {
            NSCursor.unhide()
            window.close()

            if let p = audioProc, p.isRunning {
                p.terminate()
            }

            if !self.config.dryRun {
                print("[*] Locking macOS screen via 'pmset displaysleepnow'...")
                fflush(stdout)
                let lockProc = Process()
                lockProc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                lockProc.arguments = ["displaysleepnow"]
                try? lockProc.run()
                lockProc.waitUntilExit()
            } else {
                print("[DRY-RUN] Screen lock simulated ('pmset displaysleepnow' skipped).")
                fflush(stdout)
            }

            print("[*] Terminating vibe-trap.")
            fflush(stdout)
            exit(0)
        }
    }
}

// MARK: - Entry Point

let config = parseArguments()
let manager = TrapManager(config: config)
manager.start()
