import Cocoa
import CoreAudio
import AudioToolbox
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.hid
import IOKit.ps

// MARK: - Sensitivity & Configuration

enum Sensitivity: String {
    case low
    case medium
    case high

    var thresholdG: Double {
        switch self {
        case .low: return 0.45
        case .medium: return 0.25
        case .high: return 0.12
        }
    }
}

struct Config {
    var password = ProcessInfo.processInfo.environment["VIBE_TRAP_PASSWORD"] ?? "vibetrap"
    var countdown = Int(ProcessInfo.processInfo.environment["VIBE_TRAP_COUNTDOWN"] ?? "5") ?? 5
    var timeoutMs: Int? = nil // nil = persistent kiosk until password typed
    var customImage: String? = nil
    var customAudio: String? = nil
    var assetsDir = "assets"
    var triggerOnMove = false
    var maxVolume: Bool = {
        if let env = ProcessInfo.processInfo.environment["VIBE_TRAP_MAX_VOLUME"]?.lowercased() {
            return env != "0" && env != "false" && env != "no"
        }
        return true
    }()
    var dryRun = false
    var antiTheft = false
    var sensitivity: Sensitivity = .medium
}

func parseArguments() -> Config {
    var config = Config()
    let args = CommandLine.arguments

    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-v", "--version":
            print("vibe-trap v1.3.0")
            exit(0)
        case "-h", "--help":
            print("""
            usage: vibe-trap [-h] [-v] [--countdown SECONDS] [--password PASSWORD]
                             [--timeout TIMEOUT] [--image IMAGE] [--audio AUDIO]
                             [--assets-dir ASSETS_DIR] [--trigger-on-move]
                             [--max-volume | --no-max-volume] [--dry-run]
                             [-T | --anti-theft] [-s | --sensitivity <low|medium|high>]

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
              --max-volume          Force system output volume to 100% on trigger (default: enabled)
              --no-max-volume       Do not change system volume when trap triggers
              --dry-run             Test mode: trigger payload and window, but skip display sleep lock
              -T, --anti-theft      Coffee shop anti-theft mode: triggers on physical movement (accelerometer),
                                    AC power disconnect (MagSafe/USB-C), and lid closure
              -s, --sensitivity LEVEL
                                    Motion sensitivity for anti-theft: low, medium, or high (default: medium)
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
        case "--max-volume":
            config.maxVolume = true
        case "--no-max-volume":
            config.maxVolume = false
        case "--dry-run":
            config.dryRun = true
        case "-T", "--anti-theft":
            config.antiTheft = true
        case "-s", "--sensitivity":
            if i + 1 < args.count {
                if let sens = Sensitivity(rawValue: args[i + 1].lowercased()) {
                    config.sensitivity = sens
                }
                i += 1
            }
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

// MARK: - Audio Volume Control

func getSystemOutputVolume() -> Float32? {
    var defaultOutputDeviceID = AudioDeviceID(0)
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &defaultOutputDeviceID
    )
    guard status == noErr else { return nil }

    var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var volume = Float32(0.0)
    var volumeSize = UInt32(MemoryLayout<Float32>.size)
    let volStatus = AudioObjectGetPropertyData(
        defaultOutputDeviceID,
        &volumeAddress,
        0,
        nil,
        &volumeSize,
        &volume
    )
    return volStatus == noErr ? volume : nil
}

func getSystemIsMuted() -> Bool? {
    var defaultOutputDeviceID = AudioDeviceID(0)
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &defaultOutputDeviceID
    )
    guard status == noErr else { return nil }

    var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var isMuted: UInt32 = 0
    var muteSize = UInt32(MemoryLayout<UInt32>.size)
    let muteStatus = AudioObjectGetPropertyData(
        defaultOutputDeviceID,
        &muteAddress,
        0,
        nil,
        &muteSize,
        &isMuted
    )
    return muteStatus == noErr ? (isMuted != 0) : nil
}

func setSystemOutputVolume(_ volume: Float32, unmuted: Bool = true) {
    var defaultOutputDeviceID = AudioDeviceID(0)
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &defaultOutputDeviceID
    )
    guard status == noErr else { return }

    if unmuted {
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var mute: UInt32 = 0
        _ = AudioObjectSetPropertyData(
            defaultOutputDeviceID,
            &muteAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mute
        )
    }

    var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var vol = max(0.0, min(1.0, volume))
    _ = AudioObjectSetPropertyData(
        defaultOutputDeviceID,
        &volumeAddress,
        0,
        nil,
        UInt32(MemoryLayout<Float32>.size),
        &vol
    )
}

func setSystemMute(_ muted: Bool) {
    var defaultOutputDeviceID = AudioDeviceID(0)
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &defaultOutputDeviceID
    )
    guard status == noErr else { return }

    var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var muteVal: UInt32 = muted ? 1 : 0
    _ = AudioObjectSetPropertyData(
        defaultOutputDeviceID,
        &muteAddress,
        0,
        nil,
        UInt32(MemoryLayout<UInt32>.size),
        &muteVal
    )
}

// MARK: - State Management

class TrapManager {
    let config: Config
    let imagePath: String?
    let audioPath: String?

    var originalVolume: Float32? = nil
    var originalMuted: Bool? = nil

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

    // Anti-Theft state
    var wasACConnected: Bool? = nil
    var powerRunLoopSource: CFRunLoopSource? = nil
    var clamshellTimer: DispatchSourceTimer? = nil
    var sleepObserver: Any? = nil

    // Hardware IMU Accelerometer state
    var hidDevice: IOHIDDevice? = nil
    var reportBuffer: UnsafeMutablePointer<UInt8>? = nil
    var baselineGravity: (x: Double, y: Double, z: Double)? = nil
    var calibrationSamples: [(x: Double, y: Double, z: Double)] = []
    var isCalibrating = false

    init(config: Config) {
        self.config = config
        let assets = selectAssets(config: config)
        self.imagePath = assets.imagePath
        self.audioPath = assets.audioPath
        if config.maxVolume {
            self.originalVolume = getSystemOutputVolume()
            self.originalMuted = getSystemIsMuted()
        }
    }

    func start() {
        checkPermissionsAndPrintBanner()
        setupSignalHandlers()

        if config.antiTheft {
            self.wasACConnected = checkIsACConnected()
            setupAccelerometerMonitoring()
        }

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
            let label = config.antiTheft ? "anti-theft sensors" : "touch sensor"
            if isatty(STDOUT_FILENO) != 0 {
                print("\r⏳ Arming \(label) in \(secondsRemaining)s... (step away from workstation) ", terminator: "")
            } else {
                print("⏳ Arming \(label) in \(secondsRemaining)s...")
            }
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, !self.isDisarmed else { return }
                self.startCountdown(secondsRemaining: secondsRemaining - 1)
            }
        } else {
            let statusText = config.antiTheft
                ? "🛡️  [ARMED] Anti-Theft Defense ACTIVE! (Motion, AC power, and lid monitored)"
                : "🛡️  [ARMED] Touch sensors ACTIVE! Workstation is now protected."
            if isatty(STDOUT_FILENO) != 0 {
                print("\r\(statusText)              \r\n")
            } else {
                print("\(statusText)\n")
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

        if config.antiTheft {
            setupAntiTheftSensors()
        }
    }

    func checkPermissionsAndPrintBanner() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        let isRoot = geteuid() == 0

        print(String(repeating: "=", count: 64))
        print("                 ⚡ VIBE TRAP ARMED & READY ⚡")
        print(String(repeating: "=", count: 64))
        print("Disarm Password : '\(config.password)' (type to disarm)")
        print("Countdown       : \(config.countdown > 0 ? "\(config.countdown)s before arming sensors" : "Instant (0s)")")
        print("Volume Override : \(config.maxVolume ? "🔊 100% (Max) on trigger (restores on disarm)" : "Disabled (preserve current volume)")")
        print("Payload Image   : \(imagePath ?? "None (Fallback red text)")")
        print("Payload Audio   : \(audioPath ?? "None")")
        print("Trap Mode       : \(config.timeoutMs == nil ? "🔒 Persistent Kiosk (locks until disarmed)" : "⏱️  Timeout (\(config.timeoutMs!) ms)")")
        print("Bypass Defense  : 🛡️  ACTIVE (Ctrl+C / kill signals trigger instant lock)")
        print("Dry Run Mode    : \(config.dryRun ? "ENABLED (screen lock simulated)" : "DISABLED (screen will lock)")")
        if config.antiTheft {
            print(String(repeating: "-", count: 64))
            print("Anti-Theft Mode : 🛡️  ACTIVE (Coffee Shop Defense)")
            print("  - AC Power    : ✅ ACTIVE (MagSafe/USB-C disconnect monitor)")
            print("  - Lid Close   : ✅ ACTIVE (Clamshell close monitor)")
            if isRoot {
                print("  - Motion IMU  : ✅ ACTIVE (Apple Silicon accelerometer & gyro)")
            } else {
                print("  - Motion IMU  : ⚠️  STANDBY (Run with 'sudo vibe-trap --anti-theft'")
                print("                  to enable hardware accelerometer motion tracking)")
            }
            print("  - Sensitivity : \(config.sensitivity.rawValue.uppercased()) (\(config.sensitivity.thresholdG)g motion threshold)")
            print(String(repeating: "-", count: 64))
        }
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

    func restoreOriginalVolume() {
        guard config.maxVolume, let origVol = originalVolume else { return }
        print("[*] Restoring original system volume (\(Int(origVol * 100))%)...")
        fflush(stdout)
        setSystemOutputVolume(origVol, unmuted: !(originalMuted ?? false))
        if originalMuted == true {
            setSystemMute(true)
        }
        let mutedStr = (originalMuted == true) ? "with output muted" : "without output muted"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "set volume output volume \(Int(origVol * 100)) \(mutedStr)"]
        try? p.run()
    }

    func executePayload() {
        // 1. Force max system volume if enabled
        if config.maxVolume {
            print("[*] Forcing system output volume to 100% (unmuted)...")
            fflush(stdout)
            setSystemOutputVolume(1.0, unmuted: true)
            DispatchQueue.global(qos: .userInteractive).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "set volume output volume 100 without output muted"]
                try? p.run()
            }
        }

        // 2. Play continuous audio (looping)
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

        // 3. Launch fullscreen borderless topmost kiosk window
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

        // 4. Optional timeout (only if --timeout was explicitly specified)
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

            // 1. Stop audio & restore volume
            self.activeSound?.stop()
            if let p = self.activeAudioProcess, p.isRunning {
                p.terminate()
            }
            self.restoreOriginalVolume()

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
        restoreOriginalVolume()
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

    // MARK: - Anti-Theft Protection Suite

    func setupAntiTheftSensors() {
        setupPowerMonitoring()
        setupLidMonitoring()

        // If accelerometer was calibrating, ensure baseline is established
        if baselineGravity == nil && !calibrationSamples.isEmpty {
            let avgX = calibrationSamples.map { $0.x }.reduce(0, +) / Double(calibrationSamples.count)
            let avgY = calibrationSamples.map { $0.y }.reduce(0, +) / Double(calibrationSamples.count)
            let avgZ = calibrationSamples.map { $0.z }.reduce(0, +) / Double(calibrationSamples.count)
            self.baselineGravity = (x: avgX, y: avgY, z: avgZ)
            self.isCalibrating = false
            self.calibrationSamples.removeAll()
        }
    }

    func checkIsACConnected() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String? else { return false }
        return type == (kIOPMACPowerKey as String)
    }

    func checkIsClamshellClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        if let clamshell = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            return clamshell
        }
        return false
    }

    func setupPowerMonitoring() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let manager = Unmanaged<TrapManager>.fromOpaque(context).takeUnretainedValue()
            manager.handlePowerSourceChanged()
        }, selfPtr)?.takeRetainedValue() {
            self.powerRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }

    func handlePowerSourceChanged() {
        let currentAC = checkIsACConnected()
        if isSensorArmed && !isDisarmed && !isTriggered {
            if let wasAC = wasACConnected, wasAC && !currentAC {
                trigger(reason: "🚨 ANTI-THEFT: Power adapter unplugged (MagSafe/USB-C disconnect)!")
            }
        }
        self.wasACConnected = currentAC
    }

    func setupLidMonitoring() {
        self.sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isSensorArmed && !self.isDisarmed && !self.isTriggered else { return }
            self.trigger(reason: "🚨 ANTI-THEFT: Laptop lid closed (system sleep detected)!")
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isSensorArmed && !self.isDisarmed && !self.isTriggered else { return }
            if self.checkIsClamshellClosed() {
                self.trigger(reason: "🚨 ANTI-THEFT: Laptop lid closed (clamshell sensor)!")
            }
        }
        timer.resume()
        self.clamshellTimer = timer
    }

    func setupAccelerometerMonitoring() {
        guard geteuid() == 0 else { return }

        var iterator = io_iterator_t()
        let matching = IOServiceMatching("AppleSPUHIDDevice")
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return }

        var targetDev: IOHIDDevice? = nil
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let up = dict["PrimaryUsagePage"] as? Int, up == 65280,
               let u = dict["PrimaryUsage"] as? Int, u == 3 {
                targetDev = IOHIDDeviceCreate(kCFAllocatorDefault, service)
                IOObjectRelease(service)
                break
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)

        guard let dev = targetDev else { return }

        let reportSize = 22
        let reportBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
        self.reportBuffer = reportBuf
        self.hidDevice = dev

        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        let openRes = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openRes == kIOReturnSuccess else { return }

        self.isCalibrating = true
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputReportCallback(dev, reportBuf, reportSize, { context, result, sender, type, reportId, report, reportLen in
            guard let context = context, reportLen >= 18 else { return }
            let manager = Unmanaged<TrapManager>.fromOpaque(context).takeUnretainedValue()
            let x = report.advanced(by: 6).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
            let y = report.advanced(by: 10).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
            let z = report.advanced(by: 14).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
            let gx = Double(x) / 65536.0
            let gy = Double(y) / 65536.0
            let gz = Double(z) / 65536.0
            manager.handleAccelerometerReading(x: gx, y: gy, z: gz)
        }, selfPtr)
    }

    func handleAccelerometerReading(x: Double, y: Double, z: Double) {
        if isCalibrating {
            calibrationSamples.append((x: x, y: y, z: z))
            if calibrationSamples.count >= 30 {
                let avgX = calibrationSamples.map { $0.x }.reduce(0, +) / Double(calibrationSamples.count)
                let avgY = calibrationSamples.map { $0.y }.reduce(0, +) / Double(calibrationSamples.count)
                let avgZ = calibrationSamples.map { $0.z }.reduce(0, +) / Double(calibrationSamples.count)
                self.baselineGravity = (x: avgX, y: avgY, z: avgZ)
                self.isCalibrating = false
                self.calibrationSamples.removeAll()
            }
            return
        }

        guard isSensorArmed && !isDisarmed && !isTriggered, let baseline = baselineGravity else { return }
        let dx = x - baseline.x
        let dy = y - baseline.y
        let dz = z - baseline.z
        let delta = sqrt(dx * dx + dy * dy + dz * dz)

        if delta > config.sensitivity.thresholdG {
            DispatchQueue.main.async {
                self.trigger(reason: String(format: "🚨 ANTI-THEFT: Physical movement / tilt detected by accelerometer (Δ%.2fg)!", delta))
            }
        }
    }

    func cleanupAntiTheft() {
        if let source = powerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            powerRunLoopSource = nil
        }
        if let timer = clamshellTimer {
            timer.cancel()
            clamshellTimer = nil
        }
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepObserver = nil
        }
        if let dev = hidDevice {
            IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            hidDevice = nil
        }
        if let buf = reportBuffer {
            buf.deallocate()
            reportBuffer = nil
        }
    }

    func cleanupAndExit(success: Bool, message: String) {
        cleanupAntiTheft()
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
