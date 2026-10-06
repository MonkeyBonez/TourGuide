import SwiftUI
import PhotosUI
import TourGuideCore

/// "What's this?" (PRD §6): photo first, an optional spoken question, an answer read aloud.
/// The camera screen from PocketTourGuide, without the wake word, with the walk as context.
struct PhotoView: View {
    @ObservedObject var model: AppModel
    @StateObject private var camera = CameraController()
    @StateObject private var recorder = QuestionRecorder()
    @StateObject private var tts = TTSService()
    @State private var image: UIImage?
    @State private var answer: TourAnswer?
    @State private var error: String?
    @State private var sending = false
    @State private var sendTask: Task<Void, Never>?
    @State private var picked: PhotosPickerItem?
    @AppStorage("openaiModel") private var openaiModel = "gpt-5"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit().ignoresSafeArea()
            } else if camera.available {
                CameraPreview(session: camera.session).ignoresSafeArea()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.fill").font(.largeTitle)
                    Text("No camera here. Pick a photo instead.").font(.subheadline)
                }.foregroundStyle(.white.opacity(0.8))
            }
            VStack {
                HStack {
                    Button { tts.stop(); dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)).padding(10) }
                        .glassEffect(in: .circle).accessibilityIdentifier("closePhoto").accessibilityLabel("Close")
                    Spacer()
                    PhotosPicker(selection: $picked, matching: .images) { Image(systemName: "photo.on.rectangle").font(.title3).padding(10) }
                        .glassEffect(in: .circle).accessibilityIdentifier("pickPhoto").accessibilityLabel("Choose a photo")
                }
                .padding(.horizontal)
                Spacer()
                if !recorder.transcript.isEmpty || recorder.isRecording {
                    Text(recorder.transcript.isEmpty ? "Listening…" : "“\(recorder.transcript)”")
                        .font(.callout).padding(12).glassEffect(in: .rect(cornerRadius: 14)).padding(.horizontal)
                }
                if let answer { answerCard(answer) }
                if let e = error ?? recorder.error {
                    Text(e).font(.footnote).foregroundStyle(.white).padding(10)
                        .background(.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
                        .accessibilityIdentifier("photoError")
                    if KeychainService.apiKey() == nil {
                        Button("Open Settings") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.showSettings = true } }
                            .buttonStyle(.glassProminent)
                    }
                }
                controls
            }
            .padding(.bottom, 12)
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop(); recorder.stop(); tts.stop(); sendTask?.cancel() }
        .onChange(of: picked) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self), let ui = UIImage(data: data) {
                    image = ui; answer = nil; error = nil; camera.stop()
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button { recorder.toggle() } label: {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill").font(.title2).frame(width: 56, height: 56)
            }
            .glassEffect(in: .circle).accessibilityIdentifier("micButton").accessibilityLabel(recorder.isRecording ? "Stop" : "Ask by voice")
            if image == nil {
                Button {
                    camera.capturePhoto { img in image = img; camera.stop(); if img != nil { send() } }
                } label: { Circle().fill(.white).frame(width: 74, height: 74).overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 4).padding(-6)) }
                .accessibilityIdentifier("shutterButton").accessibilityLabel("Take photo")
                .disabled(!camera.available)
            } else if sending {
                Button { sendTask?.cancel(); sending = false } label: {
                    ProgressView().tint(.white).frame(width: 74, height: 74)
                }.accessibilityLabel("Cancel")
            } else {
                Button { send() } label: { Image(systemName: "paperplane.fill").font(.title).frame(width: 74, height: 74) }
                    .buttonStyle(.glassProminent).accessibilityIdentifier("sendButton").accessibilityLabel("Ask")
            }
            Button { image = nil; answer = nil; error = nil; tts.stop(); recorder.transcript = ""; camera.start() } label: {
                Image(systemName: "arrow.counterclockwise").font(.title2).frame(width: 56, height: 56)
            }
            .glassEffect(in: .circle).accessibilityLabel("Retake").disabled(image == nil)
        }
    }

    private func answerCard(_ a: TourAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = a.title { Text(t).font(.headline) }
            ScrollView { Text(a.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
            HStack {
                Button { tts.isSpeaking ? tts.stop() : tts.speak(a.text) } label: {
                    Label(tts.isSpeaking ? "Stop" : "Read aloud", systemImage: tts.isSpeaking ? "pause.fill" : "speaker.wave.2.fill")
                }
                Spacer()
                Text("AI answer · may be wrong").font(.caption2).foregroundStyle(.secondary)
            }.font(.footnote)
        }
        .padding(14).glassEffect(in: .rect(cornerRadius: 18)).padding(.horizontal)
        .accessibilityIdentifier("answerCard")
    }

    private func send() {
        guard let image, let jpeg = ImageProcessor.jpegResized(from: image) else { return }
        recorder.stop()
        let question = recorder.transcript
        guard let key = KeychainService.apiKey(), !key.isEmpty else {
            error = OpenAIClient.Failure.noKey.errorDescription; return
        }
        sending = true; error = nil; answer = nil
        sendTask = Task {
            let context = await model.photoContext(question: question.isEmpty ? nil : question)
            do {
                let a = try await OpenAIClient(apiKey: key, model: openaiModel).describe(jpeg: jpeg, context: context)
                guard !Task.isCancelled else { return }
                answer = a; tts.speak(a.text)
            } catch is CancellationError {
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            sending = false
        }
    }
}
