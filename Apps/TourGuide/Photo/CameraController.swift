import Foundation
import AVFoundation
import UIKit

/// From PocketTourGuide; the deprecated high-resolution flags replaced by `maxPhotoDimensions`,
/// and the session started off the main thread (startRunning blocks).
@MainActor
final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published var available = true
    private let photoOutput = AVCapturePhotoOutput()
    private var captureCompletion: ((UIImage?) -> Void)?
    private var configured = false
    private let queue = DispatchQueue(label: "camera.session")

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in if granted { self.configureAndRun() } else { self.available = false } }
            }
        default: available = false
        }
    }

    func stop() { let s = session; queue.async { if s.isRunning { s.stopRunning() } } }

    private func configureAndRun() {
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                session.commitConfiguration(); available = false; return
            }
            session.addInput(input)
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                if let largest = device.activeFormat.supportedMaxPhotoDimensions.last { photoOutput.maxPhotoDimensions = largest }
            }
            session.commitConfiguration()
            configured = true
        }
        let s = session
        queue.async { s.startRunning() }
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        guard configured else { completion(nil); return }
        captureCompletion = completion
        let settings = AVCapturePhotoSettings()
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        Task { @MainActor in self.captureCompletion?(image); self.captureCompletion = nil }
    }
}
