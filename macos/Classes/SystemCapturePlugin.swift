import Cocoa
import FlutterMacOS
import AVFoundation
import CoreAudio

// MARK: - Error Types
enum CaptureError: Error {
    case noPermission
    case unsupportedOS
    case alreadyCapturing
    case notCapturing
    case invalidConfiguration(String)
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case captureStartFailed(OSStatus)
    case captureStopFailed(OSStatus)

    var message: String {
        switch self {
        case .noPermission:
            return "System audio recording permission not granted"
        case .unsupportedOS:
            return "System audio recording requires macOS 14.2 or later"
        case .alreadyCapturing:
            return "Capture already in progress"
        case .notCapturing:
            return "No active capture session"
        case .invalidConfiguration(let detail):
            return "Invalid configuration: \(detail)"
        case .tapCreationFailed(let status):
            return "Failed to create system audio tap: \(status)"
        case .aggregateCreationFailed(let status):
            return "Failed to create system audio aggregate device: \(status)"
        case .ioProcCreationFailed(let status):
            return "Failed to create system audio IOProc: \(status)"
        case .captureStartFailed(let status):
            return "Failed to start system audio capture: \(status)"
        case .captureStopFailed(let status):
            return "Failed to stop system audio capture: \(status)"
        }
    }
}

// MARK: - Audio Configuration
struct AudioConfiguration {
    let sampleRate: Double
    let channelCount: Int

    static let `default` = AudioConfiguration(sampleRate: 16000, channelCount: 1)

    static func from(_ dict: [String: Any]?) -> Result<AudioConfiguration, CaptureError> {
        guard let dict = dict else {
            return .success(.default)
        }

        let sampleRate = (dict["sampleRate"] as? NSNumber)?.doubleValue ?? 16000
        let channelCount = (dict["channels"] as? NSNumber)?.intValue ?? 1

        guard [8000, 16000, 44100, 48000].contains(Int(sampleRate)) else {
            return .failure(.invalidConfiguration("Sample rate must be 8000, 16000, 44100, or 48000"))
        }

        guard (1...2).contains(channelCount) else {
            return .failure(.invalidConfiguration("Channel count must be 1 or 2"))
        }

        return .success(AudioConfiguration(sampleRate: sampleRate, channelCount: channelCount))
    }
}

// MARK: - Main Plugin
@available(macOS 14.2, *)
final class SystemCapturePlugin: NSObject, FlutterPlugin, @unchecked Sendable {
    private enum PermissionState: String {
        case granted
        case deniedOrUnavailable
    }

    enum SystemAudioPermissionResult {
        case allowed
        case deniedOrUnavailable(Error?)
    }

    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    private var statusEventChannel: FlutterEventChannel?
    var statusEventSink: FlutterEventSink?

    private var decibelEventChannel: FlutterEventChannel?
    var decibelEventSink: FlutterEventSink?

    var engine: SystemAudioTapEngine?

    private let stateQueue = DispatchQueue(label: "com.system_audio_transcriber.state_queue", qos: .utility)
    private var _isCapturing = false
    private var _lastPermissionState: PermissionState = .deniedOrUnavailable
    var isCapturing: Bool {
        get { stateQueue.sync { _isCapturing } }
        set { stateQueue.async { [weak self] in self?._isCapturing = newValue } }
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SystemCapturePlugin()

        let methodChannel = FlutterMethodChannel(
            name: "com.system_audio_transcriber/audio_capture",
            binaryMessenger: registrar.messenger
        )
        instance.methodChannel = methodChannel
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: "com.system_audio_transcriber/audio_stream",
            binaryMessenger: registrar.messenger
        )
        instance.eventChannel = eventChannel
        eventChannel.setStreamHandler(instance)

        let statusEventChannel = FlutterEventChannel(
            name: "com.system_audio_transcriber/audio_status",
            binaryMessenger: registrar.messenger
        )
        instance.statusEventChannel = statusEventChannel
        statusEventChannel.setStreamHandler(SystemStatusStreamHandler(plugin: instance))

        let decibelEventChannel = FlutterEventChannel(
            name: "com.system_audio_transcriber/audio_decibel",
            binaryMessenger: registrar.messenger
        )
        instance.decibelEventChannel = decibelEventChannel
        decibelEventChannel.setStreamHandler(SystemDecibelStreamHandler(plugin: instance))

        NotificationCenter.default.addObserver(
            instance,
            selector: #selector(instance.applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func applicationWillTerminate() {
        cleanupResources()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        cleanupResources()
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "requestPermissions":
            requestPermissions(result: result)
        case "requestPermissionStatus":
            let args = call.arguments as? [String: Any]
            let requestAccess = (args?["requestAccess"] as? Bool) ?? true
            requestPermissionStatus(requestAccess: requestAccess, result: result)

        case "startCapture":
            let config = call.arguments as? [String: Any]
            startCapture(config: config, result: result)

        case "stopCapture":
            stopCapture(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startCapture(config: [String: Any]?, result: @escaping FlutterResult) {
        if isCapturing {
            cleanupResources()
        }

        let audioConfig: AudioConfiguration
        switch AudioConfiguration.from(config) {
        case .success(let cfg):
            audioConfig = cfg
        case .failure(let error):
            result(FlutterError(code: "INVALID_CONFIG", message: error.message, details: nil))
            return
        }

        do {
            let newEngine = try SystemAudioTapEngine(
                config: audioConfig,
                eventSink: eventSink,
                decibelEventSink: decibelEventSink
            )
            try newEngine.start()
            engine = newEngine
            isCapturing = true
            _lastPermissionState = .granted
            sendStatusUpdate(isActive: true)
            result(true)
        } catch let error as CaptureError {
            cleanupResources()
            _lastPermissionState = .deniedOrUnavailable
            result(FlutterError(code: "CAPTURE_ERROR", message: error.message, details: nil))
        } catch {
            cleanupResources()
            _lastPermissionState = .deniedOrUnavailable
            result(FlutterError(code: "CAPTURE_ERROR", message: error.localizedDescription, details: "\(error)"))
        }
    }

    private func stopCapture(result: @escaping FlutterResult) {
        guard isCapturing else {
            result(FlutterError(code: "NOT_CAPTURING", message: CaptureError.notCapturing.message, details: nil))
            return
        }

        cleanupResources()
        result(true)
    }

    private func requestPermissions(result: @escaping FlutterResult) {
        requestPermissionStatus(requestAccess: true) { status in
            result(status == .granted)
        }
    }

    private func requestPermissionStatus(requestAccess: Bool, result: @escaping FlutterResult) {
        requestPermissionStatus(requestAccess: requestAccess) { status in
            // 返回三态字符串，供 Flutter 侧精确映射 UI 状态。
            result(status.rawValue)
        }
    }

    private func requestPermissionStatus(
        requestAccess: Bool,
        completion: @escaping (PermissionState) -> Void
    ) {
        // 已在采集时可认定授权通过。
        if isCapturing {
            completion(.granted)
            return
        }

        // 通过 TCC SPI 即时查询权限状态（kTCCServiceAudioCapture），无需启动采集引擎探测。
        // SPI 不可用时回退到探测法。
        if let preflight = SystemCapturePlugin.tccPreflightFunc {
            let result = preflight("kTCCServiceAudioCapture" as CFString, nil)
            // TCCAccessPreflight 返回 0 = 已授权，非 0 = 未授权或待决。
            if result == 0 {
                _lastPermissionState = .granted
                completion(.granted)
                return
            }

            // 未授权：若 requestAccess=true 则通过 TCC SPI 触发系统权限弹窗。
            if !requestAccess {
                _lastPermissionState = .deniedOrUnavailable
                completion(.deniedOrUnavailable)
                return
            }

            if let requestFn = SystemCapturePlugin.tccRequestFunc {
                requestFn("kTCCServiceAudioCapture" as CFString, nil) { [weak self] granted in
                    let state: PermissionState = granted ? .granted : .deniedOrUnavailable
                    self?._lastPermissionState = state
                    DispatchQueue.main.async { completion(state) }
                }
                return
            }

            // request SPI 也不可用，直接返回已知状态。
            _lastPermissionState = .deniedOrUnavailable
            completion(.deniedOrUnavailable)
            return
        }

        // TCC SPI 整体不可用时，回退到探测法（启动临时采集引擎，等待音频数据）。
        if !requestAccess {
            completion(_lastPermissionState)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let probeResult = await self.startSystemAudioCapture()
            let mapped = self.mapPermissionState(from: probeResult)
            self._lastPermissionState = mapped
            DispatchQueue.main.async { completion(mapped) }
        }
    }

    private func mapPermissionState(from result: SystemAudioPermissionResult) -> PermissionState {
        switch result {
        case .allowed:
            return .granted
        case .deniedOrUnavailable:
            return .deniedOrUnavailable
        }
    }

    // MARK: - 探测法 fallback（TCC SPI 不可用时使用）

    private func startSystemAudioCapture() async -> SystemAudioPermissionResult {
        do {
            var receivedBuffer = false
            let lock = NSLock()

            let probeConfig = AudioConfiguration(sampleRate: 16000, channelCount: 1)
            let probeEngine = try SystemAudioTapEngine(
                config: probeConfig,
                eventSink: { event in
                    if let bytes = event as? FlutterStandardTypedData, !bytes.data.isEmpty {
                        lock.lock()
                        receivedBuffer = true
                        lock.unlock()
                    }
                },
                decibelEventSink: nil
            )

            try probeEngine.start()
            defer { probeEngine.stop() }

            let hasBuffer = await waitForFirstAudioBuffer(timeout: 1.5) {
                lock.lock()
                let value = receivedBuffer
                lock.unlock()
                return value
            }
            return hasBuffer ? .allowed : .deniedOrUnavailable(nil)
        } catch {
            return .deniedOrUnavailable(error)
        }
    }

    private func waitForFirstAudioBuffer(
        timeout: TimeInterval,
        hasBuffer: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasBuffer() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return hasBuffer()
    }

    // MARK: - TCC 私有 SPI（系统音频录制权限 kTCCServiceAudioCapture）

    private typealias TCCPreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias TCCRequestFunc = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let tccHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }()

    private static let tccPreflightFunc: TCCPreflightFunc? = {
        guard let h = tccHandle, let sym = dlsym(h, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: TCCPreflightFunc.self)
    }()

    private static let tccRequestFunc: TCCRequestFunc? = {
        guard let h = tccHandle, let sym = dlsym(h, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: TCCRequestFunc.self)
    }()


    private func cleanupResources() {
        engine?.stop()
        engine = nil
        isCapturing = false
        sendStatusUpdate(isActive: false)
    }

    private func sendStatusUpdate(isActive: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.statusEventSink?([
                "isActive": isActive,
                "timestamp": Date().timeIntervalSince1970
            ])
        }
    }
}

// MARK: - FlutterStreamHandler
@available(macOS 14.2, *)
extension SystemCapturePlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        engine?.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        engine?.eventSink = nil
        return nil
    }
}

// MARK: - Core Audio Process Tap Engine
@available(macOS 14.2, *)
final class SystemAudioTapEngine: @unchecked Sendable {
    var eventSink: FlutterEventSink?
    var decibelEventSink: FlutterEventSink?

    private let config: AudioConfiguration
    private let processingQueue = DispatchQueue(label: "com.system_audio_transcriber.tap_processing", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var inputSampleRate: Double = 48000
    private var nextOutputSamplePosition = 0.0
    private var hasLoggedFormat = false

    init(config: AudioConfiguration, eventSink: FlutterEventSink?, decibelEventSink: FlutterEventSink?) throws {
        self.config = config
        self.eventSink = eventSink
        self.decibelEventSink = decibelEventSink
        try createTapAndAggregateDevice()
    }

    func start() throws {
        let callback = SystemAudioTapEngine.ioProc
        let clientData = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(aggregateDeviceID, callback, clientData, &procID)
        guard status == noErr, let procID else {
            throw CaptureError.ioProcCreationFailed(status)
        }
        ioProcID = procID

        // 启动包含 process tap 的 aggregate device 会触发 macOS 的系统音频录制授权。
        status = AudioDeviceStart(aggregateDeviceID, procID)
        guard status == noErr else {
            throw CaptureError.captureStartFailed(status)
        }
    }

    func stop() {
        if let ioProcID {
            let stopStatus = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if stopStatus != noErr {
                print("⚠️ AudioDeviceStop failed: \(stopStatus)")
            }
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            if destroyStatus != noErr {
                print("⚠️ AudioDeviceDestroyIOProcID failed: \(destroyStatus)")
            }
            self.ioProcID = nil
        }

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status != noErr {
                print("⚠️ AudioHardwareDestroyAggregateDevice failed: \(status)")
            }
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr {
                print("⚠️ AudioHardwareDestroyProcessTap failed: \(status)")
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func createTapAndAggregateDevice() throws {
        let tapDescription: CATapDescription
        if config.channelCount == 1 {
            tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        } else {
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        tapDescription.name = "EasyO System Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr else {
            throw CaptureError.tapCreationFailed(status)
        }
        tapID = newTapID

        let aggregateUID = "cn.qkfintech.zhiban.system-audio.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EasyO System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationHighQuality
            ]],
            kAudioAggregateDeviceTapAutoStartKey: false
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw CaptureError.aggregateCreationFailed(status)
        }
        aggregateDeviceID = newAggregateID
        inputSampleRate = readInputSampleRate(deviceID: aggregateDeviceID) ?? 48000
    }

    private func readInputSampleRate(deviceID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format)
        guard status == noErr, format.mSampleRate > 0 else { return nil }
        return format.mSampleRate
    }

    private static let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
        guard let clientData else { return noErr }
        let engine = Unmanaged<SystemAudioTapEngine>.fromOpaque(clientData).takeUnretainedValue()
        engine.handleAudio(inputData)
        return noErr
    }

    private func handleAudio(_ inputData: UnsafePointer<AudioBufferList>) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            let pcm = self.convertInputToInt16PCM(inputData)
            guard !pcm.isEmpty else { return }
            let decibel = self.calculateDecibel(from: pcm)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.eventSink?(FlutterStandardTypedData(bytes: pcm))
                self.decibelEventSink?([
                    "decibel": decibel,
                    "timestamp": Date().timeIntervalSince1970
                ])
            }
        }
    }

    private func convertInputToInt16PCM(_ inputData: UnsafePointer<AudioBufferList>) -> Data {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard !buffers.isEmpty else { return Data() }

        let frameCount = buffers.map { Int($0.mDataByteSize) / MemoryLayout<Float32>.size / max(Int($0.mNumberChannels), 1) }.max() ?? 0
        guard frameCount > 0 else { return Data() }

        if !hasLoggedFormat {
            hasLoggedFormat = true
            print("🎧 System tap format: inputRate=\(inputSampleRate), buffers=\(buffers.count), outputRate=\(config.sampleRate), channels=\(config.channelCount)")
        }

        let ratio = max(inputSampleRate / config.sampleRate, 1)
        var output = Data(capacity: Int(Double(frameCount) / ratio) * MemoryLayout<Int16>.size * config.channelCount)

        while nextOutputSamplePosition < Double(frameCount) {
            let frameIndex = min(Int(nextOutputSamplePosition), frameCount - 1)
            let mono = mixedFloatSample(buffers: buffers, frameIndex: frameIndex)
            let clamped = min(max(mono, -1.0), 1.0)
            let sample = Int16(clamped * Float32(Int16.max))
            for _ in 0..<config.channelCount {
                withUnsafeBytes(of: sample.littleEndian) { output.append(contentsOf: $0) }
            }
            nextOutputSamplePosition += ratio
        }
        nextOutputSamplePosition -= Double(frameCount)
        return output
    }

    private func mixedFloatSample(buffers: UnsafeMutableAudioBufferListPointer, frameIndex: Int) -> Float32 {
        var sum: Float32 = 0
        var count: Float32 = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            let pointer = data.assumingMemoryBound(to: Float32.self)

            if channelCount == 1 {
                if frameIndex < sampleCount {
                    sum += pointer[frameIndex]
                    count += 1
                }
            } else {
                let base = frameIndex * channelCount
                for channel in 0..<channelCount where base + channel < sampleCount {
                    sum += pointer[base + channel]
                    count += 1
                }
            }
        }

        guard count > 0 else { return 0 }
        return sum / count
    }

    private func calculateDecibel(from audioData: Data) -> Double {
        guard audioData.count >= 2 else { return -120.0 }
        let sampleCount = audioData.count / MemoryLayout<Int16>.size
        var sumOfSquares = 0.0
        audioData.withUnsafeBytes { bytes in
            let pointer = bytes.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let value = Double(Int16(littleEndian: pointer[i]))
                sumOfSquares += value * value
            }
        }
        guard sampleCount > 0 else { return -120.0 }
        let rms = sqrt(sumOfSquares / Double(sampleCount))
        guard rms > 0 else { return -120.0 }
        return max(-120.0, min(0.0, 20.0 * log10(rms / Double(Int16.max))))
    }
}

// MARK: - System Status Stream Handler
@available(macOS 14.2, *)
class SystemStatusStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: SystemCapturePlugin?

    init(plugin: SystemCapturePlugin) {
        self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.statusEventSink = events
        events([
            "isActive": plugin?.isCapturing ?? false,
            "timestamp": Date().timeIntervalSince1970
        ])
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.statusEventSink = nil
        return nil
    }
}

// MARK: - System Decibel Stream Handler
@available(macOS 14.2, *)
class SystemDecibelStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: SystemCapturePlugin?

    init(plugin: SystemCapturePlugin) {
        self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.decibelEventSink = events
        plugin?.engine?.decibelEventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.decibelEventSink = nil
        plugin?.engine?.decibelEventSink = nil
        return nil
    }
}
