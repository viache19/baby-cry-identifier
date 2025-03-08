import Foundation
import AVFoundation
import Combine
import CoreML
import SoundAnalysis
import UIKit
import AudioToolbox
import CoreHaptics
import MediaPlayer
import UserNotifications

class AudioCapture: NSObject, ObservableObject {
    // MARK: - Published properties
    @Published var isDetectionActive: Bool = false {
        didSet {
            if isDetectionActive {
                startDetection()
            } else {
                stopDetection()
            }
        }
    }
    @Published var isCrying: Bool = false
    @Published var permissionGranted: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var cryingStartTime: Date?
    @Published var flashOnCry: Bool = false
    @Published var cameraPermissionGranted: Bool = false
    @Published var notificationsEnabled: Bool = true
    @Published var notificationPermissionGranted: Bool = false
    
    // MARK: - Private properties
    private var audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    private var audioSession = AVAudioSession.sharedInstance()
    private var analyzer: SNAudioStreamAnalyzer?
    private var analysisQueue = DispatchQueue(label: "com.babycry.analysis")
    
    // Core ML model
    private var cryDetectionRequest: SNClassifySoundRequest?
    
    private let requiredCryingDuration: TimeInterval = 3 // 7 seconds
    
    private var flashlight: AVCaptureDevice?
    
    // Update flash properties
    private var flashTimer: Timer?
    private let flashBlinkInterval: TimeInterval = 0.3 // Changed to 0.3 seconds
    private var isFlashBlinking: Bool = false // Add this to track flash state
    
    // Add a property to store the volume button observer
    private var volumeButtonObserver: NSKeyValueObservation?
    
    // Add property to control notification frequency
    private var lastNotificationTime: Date?
    private let minimumNotificationInterval: TimeInterval = 15 // Reduced to 15 seconds
    
    // Add at the top of the class
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    // Añade una propiedad para el background task de notificaciones
    private var notificationBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    // Añade propiedades para logging
    private let fileManager = FileManager.default
    private var logFileHandle: FileHandle?
    private let logFileName = "babymonitor.log"
    
    override init() {
        super.init()
        setupLogging() // Añade esto primero
        setupAudioSession()
        setupModel()
        checkMicrophonePermission()
        checkCameraPermission()
        setupFlashlight()
        setupVolumeButtonDetection()
        checkNotificationPermission()
        
        // Register for app lifecycle notifications
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(handleAppStateChange),
                                             name: UIApplication.didEnterBackgroundNotification,
                                             object: nil)
        NotificationCenter.default.addObserver(self,
                                             selector: #selector(handleAppStateChange),
                                             name: UIApplication.willEnterForegroundNotification,
                                             object: nil)
    }
    
    private func setupLogging() {
        guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let logFileURL = documentsPath.appendingPathComponent(logFileName)
        
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
        
        do {
            logFileHandle = try FileHandle(forWritingTo: logFileURL)
            logFileHandle?.seekToEndOfFile()
            log("📝 Logging initialized")
        } catch {
            print("Error setting up logging: \(error)")
        }
    }
    
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)\n"
        
        // Print to console
        print(logMessage)
        
        // Write to file
        if let data = logMessage.data(using: .utf8) {
            logFileHandle?.write(data)
        }
    }
    
    private func setupAudioSession() {
        do {
            // Configure for background audio
            try audioSession.setCategory(.playAndRecord,
                                       mode: .measurement,
                                       options: [.mixWithOthers, 
                                               .allowBluetooth,
                                               .defaultToSpeaker,
                                               .duckOthers])
            
            // Important: Set these before activating
            try audioSession.setPreferredIOBufferDuration(0.005)
            try audioSession.setPreferredSampleRate(44100)
            
            // Activate with options for background
            try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
            
            // Keep app active
            UIApplication.shared.beginReceivingRemoteControlEvents()
            UIApplication.shared.isIdleTimerDisabled = true
            
            print("🎤 Audio session setup completed for background operation")
        } catch {
            print("❌ Audio session setup error: \(error)")
            errorMessage = "Error setting up audio session: \(error.localizedDescription)"
        }
    }
    
    private func setupModel() {
        do {
            // Load the Core ML model
            guard let modelURL = Bundle.main.url(forResource: "baby_cry_identifier", withExtension: "mlmodelc") else {
                errorMessage = "Could not find model file"
                return
            }
            
            let model = try MLModel(contentsOf: modelURL)
            let request = try SNClassifySoundRequest(mlModel: model)
            self.cryDetectionRequest = request
            
        } catch {
            errorMessage = "Error loading model: \(error.localizedDescription)"
        }
    }
    
    private func setupFlashlight() {
        flashlight = AVCaptureDevice.default(for: .video)
    }
    
    private func setupVolumeButtonDetection() {
        volumeButtonObserver = audioSession.observe(\.outputVolume) { [weak self] session, _ in
            DispatchQueue.main.async {
                // Only stop the blinking, not the flash option
                if self?.isFlashBlinking == true {
                    self?.stopFlashBlinking()
                }
            }
        }
    }
    
    private func checkNotificationPermission() {
        UNUserNotificationCenter.current().delegate = self
        
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge, .criticalAlert]
        ) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.notificationPermissionGranted = granted
                print("📱 Notification permission: \(granted ? "granted" : "denied")")
            }
        }
    }
    
    // MARK: - Permission handling
    private func checkMicrophonePermission() {
        switch audioSession.recordPermission {
        case .granted:
            self.permissionGranted = true
        case .denied:
            self.permissionGranted = false
            self.errorMessage = "Microphone access was denied. Please enable it in Settings."
        case .undetermined:
            audioSession.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    self?.permissionGranted = granted
                    if !granted {
                        self?.errorMessage = "Microphone access is required to detect baby crying."
                    }
                }
            }
        @unknown default:
            self.permissionGranted = false
            self.errorMessage = "Unknown permission status"
        }
    }
    
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.cameraPermissionGranted = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.cameraPermissionGranted = granted
                    if !granted {
                        self?.errorMessage = "Camera access is required for flash notifications."
                    }
                }
            }
        case .denied, .restricted:
            self.cameraPermissionGranted = false
            self.errorMessage = "Camera access was denied. Please enable it in Settings for flash notifications."
        @unknown default:
            self.cameraPermissionGranted = false
            self.errorMessage = "Unknown camera permission status"
        }
    }
    
    // MARK: - Audio handling
    private func startDetection() {
        guard permissionGranted else {
            errorMessage = "Cannot start detection without microphone permission"
            isDetectionActive = false
            return
        }
        
        // Clean up existing detection
        stopDetection()
        
        do {
            // Ensure audio session is active
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            inputNode = audioEngine.inputNode
            let recordingFormat = inputNode!.outputFormat(forBus: 0)
            
            // Initialize analyzer with new format
            analyzer = SNAudioStreamAnalyzer(format: recordingFormat)
            
            guard let request = cryDetectionRequest else {
                errorMessage = "Sound classification request not initialized"
                return
            }
            
            try analyzer?.add(request, withObserver: self)
            
            // Install tap with smaller buffer size
            inputNode!.installTap(onBus: 0, bufferSize: 512, format: recordingFormat) { [weak self] buffer, when in
                self?.analysisQueue.async {
                    self?.analyzer?.analyze(buffer, atAudioFramePosition: when.sampleTime)
                }
            }
            
            try audioEngine.start()
            print("🎵 Audio detection started successfully")
            
            // Keep device awake
            UIApplication.shared.isIdleTimerDisabled = true
            
        } catch {
            print("❌ Start detection error: \(error)")
            isDetectionActive = false
            errorMessage = "Error starting audio detection: \(error.localizedDescription)"
        }
    }
    
    private func handleCryDetection(isNowCrying: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if isNowCrying {
                // Inicia una tarea en background específica para notificaciones y flash
                self.notificationBackgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                    self?.endNotificationBackgroundTask()
                }
                
                // Maneja el flash
                if self.flashOnCry && !self.isFlashBlinking {
                    self.startFlashBlinking()
                }
                
                // Maneja las notificaciones
                if self.notificationsEnabled {
                    print("🔔 Notification status: \(self.notificationPermissionGranted ? "Permitted" : "Not Permitted")")
                    let shouldNotify = self.lastNotificationTime.map {
                        Date().timeIntervalSince($0) >= self.minimumNotificationInterval
                    } ?? true
                    
                    if shouldNotify {
                        self.sendNotification()
                        self.lastNotificationTime = Date()
                    }
                }
            } else {
                // Si el llanto se detiene, termina la tarea de background
                self.endNotificationBackgroundTask()
            }
        }
    }
    
    private func startFlashBlinking() {
        stopFlashBlinking() // Stop any existing blinking
        isFlashBlinking = true
        
        // Initial flash on
        toggleFlash(on: true)
        
        // Usar un RunLoop común para el timer
        flashTimer = Timer(timeInterval: flashBlinkInterval, repeats: true) { [weak self] _ in
            self?.toggleFlash(on: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.toggleFlash(on: true)
            }
        }
        RunLoop.main.add(flashTimer!, forMode: .common)
    }
    
    private func stopFlashBlinking() {
        flashTimer?.invalidate()
        flashTimer = nil
        toggleFlash(on: false)
        isFlashBlinking = false
    }
    
    private func toggleFlash(on: Bool) {
        guard cameraPermissionGranted else {
            errorMessage = "Camera permission is required for flash"
            return
        }
        
        guard let device = flashlight,
              device.hasTorch,
              device.isTorchAvailable else { 
            errorMessage = "Flash is not available on this device"
            return 
        }
        
        do {
            try device.lockForConfiguration()
            if on {
                if device.torchMode == .off {
                    try device.setTorchModeOn(level: 1.0) // Always use 1.0 for on
                }
            } else {
                device.torchMode = .off // Use torchMode directly for off
            }
            device.unlockForConfiguration()
        } catch {
            errorMessage = "Error toggling flash: \(error.localizedDescription)"
        }
    }
    
    private func stopDetection() {
        // Stop the audio engine
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        
        // Remove tap if it exists
        inputNode?.removeTap(onBus: 0)
        
        // Clean up analyzer
        analyzer = nil
        
        // Reset state
        isCrying = false
        cryingStartTime = nil
        
        // Allow screen to sleep if we're stopping completely
        if !isDetectionActive {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
    
    @objc private func handleAppStateChange(_ notification: Notification) {
        if notification.name == UIApplication.didEnterBackgroundNotification {
            log("📱 App entering background")
            
            let taskID = UIApplication.shared.beginBackgroundTask { [weak self] in
                self?.log("⚠️ Background task expiring")
                self?.endBackgroundTask()
            }
            
            do {
                // Ensure audio session stays active
                try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
                
                if isDetectionActive {
                    // Instead of restarting, just ensure engine is running
                    if !audioEngine.isRunning {
                        try audioEngine.start()
                    }
                    log("🎵 Audio engine confirmed running in background")
                }
            } catch {
                log("❌ Background transition error: \(error)")
            }
            
            if taskID != .invalid {
                backgroundTask = taskID
                log("🔄 Background task started: \(taskID)")
            }
            
        } else if notification.name == UIApplication.willEnterForegroundNotification {
            print("📱 App entering foreground")
            
            if isDetectionActive && !audioEngine.isRunning {
                startDetection()
                print("🎵 Audio detection restarted in foreground")
            }
            
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
            print("🔄 Background task ended")
        }
    }
    
    private func endNotificationBackgroundTask() {
        if notificationBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(notificationBackgroundTask)
            notificationBackgroundTask = .invalid
        }
    }
    
    deinit {
        // Cierra el archivo de log
        logFileHandle?.closeFile()
        NotificationCenter.default.removeObserver(self)
        volumeButtonObserver?.invalidate()
        stopDetection()
        stopFlashBlinking()
        endNotificationBackgroundTask()
    }
    
    // Separate notification sending logic
    private func sendNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Baby Monitor Alert"
        content.body = "Baby crying detected!"
        content.sound = UNNotificationSound.defaultCritical
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "BabyCryAlert"
        content.categoryIdentifier = "BABY_CRY"
        
        // Añade badge
        content.badge = 1
        
        print("🔔 Preparing to send notification")
        print("- Notification permission status: \(notificationPermissionGranted)")
        print("- Notifications enabled: \(notificationsEnabled)")
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                print("❌ Failed to send notification: \(error)")
            } else {
                print("✅ Notification sent successfully")
                // Mantén la tarea de background viva un poco más
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self?.endNotificationBackgroundTask()
                }
            }
        }
    }
}

// MARK: - Sound Classification Observer
extension AudioCapture: SNResultsObserving {
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        
        let classifications = result.classifications
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Log classifications
            var logMessage = "\n🎤 Sound Classifications:"
            classifications.forEach { classification in
                logMessage += "\n- \(classification.identifier): \(String(format: "%.2f", classification.confidence))"
            }
            self.log(logMessage)
            
            if let classification = classifications.first,
               classification.identifier == "baby_cry" && classification.confidence > 0.7 {
                self.log("👶 Baby crying detected with confidence: \(String(format: "%.2f", classification.confidence))")
                
                if self.cryingStartTime == nil {
                    self.cryingStartTime = Date()
                    self.log("⏱️ Started crying timer")
                }
                
                if let startTime = self.cryingStartTime,
                   Date().timeIntervalSince(startTime) >= self.requiredCryingDuration {
                    if !self.isCrying {
                        self.log("🚨 Crying duration threshold reached - Triggering alerts")
                        self.isCrying = true
                        self.handleCryDetection(isNowCrying: true)
                    }
                }
            } else {
                if self.isCrying {
                    self.log("😊 Baby stopped crying")
                    self.cryingStartTime = nil
                    self.isCrying = false
                    self.handleCryDetection(isNowCrying: false)
                }
            }
        }
    }
    
    func request(_ request: SNRequest, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = "Analysis failed: \(error.localizedDescription)"
        }
    }
}

// Update the notification delegate
extension AudioCapture: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Mostrar notificación incluso con la app en primer plano
        completionHandler([.banner, .sound, .badge, .list])
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Reset badge cuando se interactúa con la notificación
        UIApplication.shared.applicationIconBadgeNumber = 0
        completionHandler()
    }
}
