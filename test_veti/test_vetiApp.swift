//
//  test_vetiApp.swift
//  test_veti
//
//  Created by Viacheslav Pustovit on 22/1/25.
//

import SwiftUI
import AVFoundation

@main
struct test_vetiApp: App {
    // Podrías crear un ObservableObject para manejar la lógica de audio.
    @StateObject private var audioCapture = AudioCapture()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioCapture)
        }
    }
}
