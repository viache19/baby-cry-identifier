import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioCapture: AudioCapture
    @State private var showDebugInfo = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    if audioCapture.permissionGranted {
                        mainContent
                    } else {
                        permissionRequest
                    }
                    
                    if let error = audioCapture.errorMessage {
                        ErrorBanner(message: error)
                    }
                }
                .padding()
            }
            .navigationTitle("Baby Monitor")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showDebugInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(showDebugInfo ? .blue : .gray)
                    }
                }
            }
            .sheet(isPresented: $showDebugInfo) {
                NavigationView {
                    DebugView(audioCapture: audioCapture)
                        .navigationTitle("Debug Info")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") {
                                    showDebugInfo = false
                                }
                            }
                        }
                }
                .presentationDetents([.medium])
            }
        }
    }
    
    private var mainContent: some View {
        VStack(spacing: 24) {
            // Status Card
            StatusCard(isCrying: audioCapture.isCrying, audioCapture: audioCapture)
            
            // Controls Section
            ControlsSection(audioCapture: audioCapture)
        }
    }
    
    private var permissionRequest: some View {
        VStack(spacing: 20) {
            PermissionRequestCard()
        }
    }
}

// MARK: - Supporting Views
struct StatusCard: View {
    let isCrying: Bool
    @ObservedObject var audioCapture: AudioCapture
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 16) {
            if audioCapture.isDetectionActive {
                // Active state
                Image(systemName: isCrying ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 80))
                    .foregroundStyle(isCrying ? .red : .green)
                    .symbolEffect(.bounce, value: isCrying)
                
                Text(isCrying ? "Baby is Crying" : "All Quiet")
                    .font(.title2.bold())
                    .foregroundStyle(isCrying ? .red : .green)
            } else {
                // Inactive state
                Image(systemName: "waveform.slash")
                    .font(.system(size: 80))
                    .foregroundStyle(.gray)
                
                Text("Audio Detection Disabled")
                    .font(.title2.bold())
                    .foregroundStyle(.gray)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Color(.systemGray6) : .white)
                .shadow(radius: 8)
        }
    }
}

struct ControlsSection: View {
    @ObservedObject var audioCapture: AudioCapture
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Controls")
                .font(.title3.bold())
                .foregroundStyle(.primary)
            
            VStack(spacing: 16) {
                Toggle(isOn: $audioCapture.isDetectionActive) {
                    Label {
                        Text("Detection")
                            .font(.headline)
                    } icon: {
                        Image(systemName: "ear")
                    }
                }
                .tint(.blue)
                
                Divider()
                
                Toggle(isOn: $audioCapture.flashOnCry) {
                    Label {
                        Text("Flash Alert")
                            .font(.headline)
                    } icon: {
                        Image(systemName: "bolt.fill")
                    }
                }
                .disabled(!audioCapture.isDetectionActive || !audioCapture.cameraPermissionGranted)
                .tint(.orange)
                
                Toggle(isOn: $audioCapture.notificationsEnabled) {
                    Label {
                        Text("Notifications")
                            .font(.headline)
                    } icon: {
                        Image(systemName: "bolt.fill")
                    }
                }
                .disabled(!audioCapture.isDetectionActive ||
                    !audioCapture.cameraPermissionGranted)
                .tint(.purple)
                
                if !audioCapture.cameraPermissionGranted {
                    Label("Enable camera access for flash alerts", systemImage: "camera.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // Add instruction for stopping flash
                if audioCapture.isCrying && audioCapture.flashOnCry {
                    Label("Press volume button to stop flash", systemImage: "button.programmable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background)
                    .shadow(radius: 4)
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
        }
        .font(.subheadline)
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.1))
        .foregroundColor(.red)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct DebugView: View {
    @ObservedObject var audioCapture: AudioCapture
    
    var body: some View {
        List {
            Section("Status") {
                LabeledContent("Detection Active", value: audioCapture.isDetectionActive ? "Yes" : "No")
                LabeledContent("Crying Detected", value: audioCapture.isCrying ? "Yes" : "No")
                if let startTime = audioCapture.cryingStartTime {
                    LabeledContent("Crying Duration") {
                        Text(Date().timeIntervalSince(startTime).formatted()) + Text(" seconds")
                    }
                }
            }
            
            Section("Permissions") {
                LabeledContent("Microphone", value: audioCapture.permissionGranted ? "Granted" : "Denied")
                LabeledContent("Camera", value: audioCapture.cameraPermissionGranted ? "Granted" : "Denied")
            }
        }
    }
}

struct PermissionRequestCard: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.slash.circle")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
            
            Text("Microphone Access Required")
                .font(.title2.bold())
            
            Text("This app needs microphone access to detect baby crying sounds. Please grant access in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            
            Button {
                if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsUrl)
                }
            } label: {
                Label("Open Settings", systemImage: "gear")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background)
                .shadow(radius: 8)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        // Vista previa en Xcode
        ContentView()
            .environmentObject(AudioCapture())
    }
}
