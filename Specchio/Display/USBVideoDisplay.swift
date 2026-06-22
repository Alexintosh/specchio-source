import AVFoundation
import os
import SwiftUI

class USBVideoCaptureManager: NSObject, ObservableObject {
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var isCapturing = false
    @Published var currentFPS: Double = 0

    private var captureSession: AVCaptureSession?
    private var fpsTimer: Timer?
    private let frameCounter = OSAllocatedUnfairLock(initialState: 0)

    func startCapture(device: AVCaptureDevice) throws {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw WDAError.connectionFailed("Cannot add USB device input")
        }
        session.addInput(input)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect

        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "usb.video.queue"))
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        self.captureSession = session
        self.previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
            DispatchQueue.main.async {
                self.isCapturing = true
                self.startFPSCounter()
            }
        }
    }

    func stopCapture() {
        captureSession?.stopRunning()
        captureSession = nil
        previewLayer = nil
        isCapturing = false
        fpsTimer?.invalidate()
    }

    private func startFPSCounter() {
        frameCounter.withLock { $0 = 0 }
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let count = self.frameCounter.withLock { val -> Int in let c = val; val = 0; return c }
            self.currentFPS = Double(count)
        }
    }
}

extension USBVideoCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCounter.withLock { $0 += 1 }
    }
}
