//
//  ContentView.swift
//  MagoriaVoiceTest
//
//  App iOS SwiftUI tối giản để test luồng real-time với core Magoria.
//  Dùng URLSessionWebSocketTask (iOS 13+, built-in, không cần package ngoài).
//
//  Cách dùng:
//   1. Tạo project iOS mới (File -> New -> Project -> iOS -> App, SwiftUI)
//   2. Replace file ContentView.swift mặc định bằng file này
//   3. Chạy trên simulator/iPhone. Nhấn 🎤 để thu âm, nhấn lại để gửi.
//   4. Info.plist cần thêm: NSMicrophoneUsageDescription = "Cần mic để nói chuyện"
//   5. Core backend phải chạy ở host:port (mặc định localhost:8765).
//

import SwiftUI
import AVFoundation
import Foundation

// MARK: - Cấu hình
// Simulator: để "localhost" là được (chạy trên Mac cùng máy với backend).
// iPhone thật: đổi thành IP máy Mac (vd "192.168.1.100"). Hoặc dùng Scheme env var MAGORIA_HOST.
private let kServerHost = ProcessInfo.processInfo.environment["MAGORIA_HOST"] ?? "localhost"
private let kServerPort = Int(ProcessInfo.processInfo.environment["MAGORIA_PORT"] ?? "8765") ?? 8765
private let kServerWSURL: String = "ws://\(kServerHost):\(kServerPort)/ws/?session_id=ios-test&character_id=default&character_type=default"

// MARK: - ViewModel
@MainActor
final class VoiceViewModel: NSObject, ObservableObject, AVAudioRecorderDelegate {

    @Published var isConnected = false
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var statusText = "Đang kết nối..."
    @Published var logText: [String] = []
    @Published var sttText = ""
    @Published var llmText = ""
    @Published var emotionText = "—"

    private var wsTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordedFileURL: URL?

    // MARK: - WebSocket lifecycle
    func connect() {
        guard wsTask == nil else { return }
        log("Đang kết nối \(kServerWSURL)")
        let url = URL(string: kServerWSURL)!
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: url)
        task.resume()
        wsTask = task
        wsSession = session
        receiveLoop()
    }

    func disconnect() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        wsSession = nil
        isConnected = false
        stopRecording()
        stopPlaying()
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self = self else { return }
            Task { @MainActor in
                switch result {
                case .success(let message):
                    self.isConnected = true
                    if self.statusText == "Đang kết nối..." {
                        self.statusText = "Đã kết nối. Nhấn 🎤 để nói."
                    }
                    switch message {
                    case .string(let text):
                        self.handleServerFrame(text)
                    case .data(let data):
                        if let s = String(data: data, encoding: .utf8) {
                            self.handleServerFrame(s)
                        }
                    @unknown default: break
                    }
                    // tiếp tục nhận
                    self.receiveLoop()
                case .failure(let error):
                    self.isConnected = false
                    self.statusText = "Mất kết nối. Bấm Kết nối lại."
                    self.log("⚠️ Mất kết nối WS: \(error.localizedDescription)")
                }
            }
        }
    }

    private func sendWS(_ text: String) {
        guard let task = wsTask else { return }
        let msg = URLSessionWebSocketTask.Message.string(text)
        task.send(msg) { [weak self] error in
            if let error = error {
                Task { @MainActor in
                    self?.log("❌ WS send error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Recording
    func startRecording() {
        guard !isRecording else { return }

        let handlePermission: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.log("❌ Không có quyền microphone")
                    return
                }
                self?.beginRecording()
            }
        }

        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                handlePermission(granted)
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                handlePermission(granted)
            }
        }
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            log("❌ AVAudioSession error: \(error)")
            return
        }

        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice.wav")
        recordedFileURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            r.prepareToRecord()
            r.record()
            recorder = r
            isRecording = true
            log("🎤 Đang thu âm... nhấn lại để gửi.")

            if isPlaying {
                sendInterrupt()
            }
        } catch {
            log("❌ Recorder error: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording, let r = recorder else { return }
        r.stop()
        isRecording = false
        log("✅ Thu âm xong, đang gửi lên server...")

        guard let url = recordedFileURL else { return }
        do {
            let data = try Data(contentsOf: url)
            sendAudioFrame(wavBytes: data)
        } catch {
            log("❌ Không đọc được file ghi âm: \(error)")
        }
    }

    private func sendAudioFrame(wavBytes: Data) {
        guard isConnected else {
            log("❌ Chưa kết nối WS")
            return
        }
        let b64 = wavBytes.base64EncodedString()
        let payloadDict: [String: Any] = ["audio_b64": b64]
        let frame: [String: Any] = [
            "type": "event",
            "event_type": "audio",
            "payload": payloadDict
        ]
        if let data = try? JSONSerialization.data(withJSONObject: frame),
           let s = String(data: data, encoding: .utf8) {
            sendWS(s)
            statusText = "Đang gửi audio..."
        }
    }

    private func sendInterrupt() {
        guard isConnected else { return }
        log("⛔ Barge-in: gửi interrupt")
        let frame: [String: Any] = [
            "type": "event",
            "event_type": "interrupt"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: frame),
           let s = String(data: data, encoding: .utf8) {
            sendWS(s)
        }
    }

    // MARK: - Playback
    private func playAudio(audioB64: String) {
        guard let data = Data(base64Encoded: audioB64) else { return }
        do {
            stopPlaying()
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            isPlaying = true
        } catch {
            log("❌ AudioPlayer error: \(error)")
        }
    }

    func stopPlaying() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    // MARK: - Server frame handler
    private func handleServerFrame(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let state = obj["state"] as? String ?? ""
        let text = obj["text"] as? String
        let emotion = obj["emotion"] as? String
        let audioB64 = obj["audio_chunk"] as? String

        switch state {
        case "thinking":
            if let t = text, !t.isEmpty, t != "Đang xử lý yêu cầu của bạn..." {
                sttText = t
                log("🎤 STT: \(t)")
                statusText = "Đã nhận: \(t)"
            }
        case "speaking":
            if let e = emotion { emotionText = e }
            if let t = text, !t.isEmpty {
                if llmText.isEmpty { llmText = t } else { llmText += " " + t }
                log("🤖 LLM[\(emotion ?? "—")]: \(t)")
            }
            if let a = audioB64, !a.isEmpty {
                playAudio(audioB64: a)
            }
        case "listening":
            statusText = "Sẵn sàng lắng nghe. Nhấn 🎤."
            if let lat = obj["latency_ms"] as? Double {
                log("⏱️ Total latency: \(Int(lat)) ms")
            }
        default:
            break
        }
    }

    // MARK: - Logging
    private func log(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logText.append("[\(ts)] \(msg)")
        if logText.count > 50 { logText.removeFirst(logText.count - 50) }
    }
}

// MARK: - Audio recorder / player delegate
extension VoiceViewModel: AVAudioPlayerDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.isRecording = false
            if !flag {
                self.log("❌ Ghi âm thất bại")
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }
}

// MARK: - UI View
struct ContentView: View {
    @StateObject private var vm = VoiceViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("Magoria Voice Test")
                .font(.title).bold()

            HStack {
                Circle().fill(vm.isConnected ? Color.green : Color.red).frame(width: 12, height: 12)
                Text(vm.isConnected ? "Đã kết nối" : "Chưa kết nối")
                    .font(.caption)
                Spacer()
                if !vm.isConnected {
                    Button("Kết nối") { vm.connect() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Ngắt") { vm.disconnect() }
                        .buttonStyle(.bordered)
                }
            }

            // Nút thu âm lớn
            Button {
                if vm.isRecording {
                    vm.stopRecording()
                } else {
                    vm.startRecording()
                }
            } label: {
                ZStack {
                    Circle().fill(vm.isRecording ? Color.red : Color.blue)
                        .frame(width: 120, height: 120)
                    Text(vm.isRecording ? "⏹" : "🎤")
                        .font(.system(size: 50))
                        .foregroundColor(.white)
                }
            }
            .padding(.vertical, 8)

            Text(vm.statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 4) {
                Text("🎤 Bạn nói:").font(.caption).bold()
                Text(vm.sttText).font(.callout).foregroundColor(.blue)
                Text("🤖 Cháu trả lời:").font(.caption).bold()
                Text(vm.llmText).font(.callout).foregroundColor(.green)
                Text("😊 Cảm xúc: \(vm.emotionText)").font(.caption)
            }
            .padding(.horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(vm.logText.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 250)
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
        .padding()
        .onAppear { vm.connect() }
    }
}

#Preview {
    ContentView()
}
