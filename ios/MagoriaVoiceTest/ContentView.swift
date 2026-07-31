//
//  ContentView.swift
//  MagoriaVoiceTest
//
//  App iOS SwiftUI tối giản để test luồng real-time với core Magoria:
//   - Mở WebSocket tới core (ws://localhost:8765/ws/...)
//   - Nhấn nút 🎤 để thu âm mic -> gửi audio frame
//   - Nhận response: phát audio TTS + log transcript/response/emotion
//   - Barge-in: trong khi core đang phát -> nếu user nói -> gửi frame "interrupt" ngay
//   - Realtime: nói xong -> gửi audio -> server xử lý -> trả audio
//
//  Cách dùng:
//   1. Tạo project iOS mới (File -> New -> Project -> iOS -> App, SwiftUI)
//   2. Đặt file này thành ContentView.swift (thay thế file mặc định)
//   3. Chạy trên simulator/device. Nhấn nút 🎤 để thu âm, nhấn lần nữa để gửi.
//   4. Cấp quyền microphone khi iOS hỏi.
//   5. Đảm bảo core backend đang chạy ở localhost:8765 (chạy trên máy Mac, hoặc dùng IP máy Mac nếu test trên iPhone thật).
//
//  Lưu ý:
//   - App chỉ ghi 1 turn audio mỗi lần nhấn (nhấn -> nói -> nhấn lại -> gửi). Để real-time streaming thì cần thêm logic ghi liên tục.
//   - Barge-in: nếu đang nghe audio TTS từ server -> nhấn 🎤 -> gửi "interrupt" -> server dừng. Đây là demo đơn giản.
//

import SwiftUI
import AVFoundation
import Starscream   // WebSocket client. Nếu chưa có: File -> Add Packages... -> https://github.com/daltoniam/Starscream

// MARK: - Cấu hình
// Khi test trên SIMULATOR (chạy iPhone trên Mac): để "localhost"
// Khi test trên iPhone THẬT (iOS device kết nối cùng WiFi với Mac chạy core):
//   đổi thành IP máy Mac. Tìm IP: System Settings -> Wi-Fi -> Details -> IP Address
//   vd "192.168.1.100". Hoặc dùng hostname Mac.local vd "macbook.local"
private let kServerHost = ProcessInfo.processInfo.environment["MAGORIA_HOST"] ?? "localhost"
private let kServerPort = Int(ProcessInfo.processInfo.environment["MAGORIA_PORT"] ?? "8765") ?? 8765
private let kServerWSURL = "ws://\(kServerHost):\(kServerPort)/ws/?session_id=ios-test&character_id=default&character_type=default"

// MARK: - ViewModel
@MainActor
final class VoiceViewModel: NSObject, ObservableObject, AVAudioRecorderDelegate {

    @Published var isConnected = false
    @Published var isRecording = false          // đang thu âm mic
    @Published var isPlaying = false            // đang phát audio TTS từ server
    @Published var statusText = "Nhấn 🎤 để thu âm"
    @Published var logText: [String] = []
    @Published var sttText = ""                 // transcript từ server
    @Published var llmText = ""                 // response text từ LLM
    @Published var emotionText = "—"            // emotion hiện tại

    private var ws: WebSocket?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordedFileURL: URL?

    // MARK: - WebSocket lifecycle
    func connect() {
        guard ws == nil else { return }
        log("Đang kết nối \(kServerWSURL)")
        var req = URLRequest(url: URL(string: kServerWSURL)!)
        let socket = WebSocket(request: req)
        socket.delegate = self
        socket.connect()
        ws = socket
    }

    func disconnect() {
        ws?.disconnect()
        ws = nil
        isConnected = false
        stopRecording()
        stopPlaying()
    }

    // MARK: - Recording
    func startRecording() {
        guard !isRecording else { return }

        // Xin quyền mic
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.log("❌ Không có quyền microphone")
                    return
                }
                self?.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
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
            AVSampleRateKey: 16000.0,           // core dùng 16k/24kHz, 16k đủ
            AVNumberOfChannelsKey: 1,            // mono
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

            // Barge-in: nếu đang phát audio TTS -> gửi interrupt ngay
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
        guard let ws = ws, isConnected else {
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
        if let data = try? JSONSerialization.data(withJSONObject: frame) {
            ws.write(data: data)
            statusText = "Đang gửi audio..."
        }
    }

    private func sendInterrupt() {
        guard let ws = ws, isConnected else { return }
        log("⛔ Barge-in: gửi interrupt")
        let frame: [String: Any] = [
            "type": "event",
            "event_type": "interrupt"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: frame) {
            ws.write(data: data)
        }
    }

    // MARK: - Playback (TTS từ server)
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

    // MARK: - Logging
    private func log(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logText.append("[\(ts)] \(msg)")
        if logText.count > 50 { logText.removeFirst(logText.count - 50) }
    }
}

// MARK: - WebSocket delegate
extension VoiceViewModel: WebSocketDelegate {
    nonisolated func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        Task { @MainActor in
            switch event {
            case .connected:
                self.isConnected = true
                self.statusText = "Đã kết nối. Nhấn 🎤 để nói."
                self.log("✅ Kết nối thành công")
            case .disconnected, .cancelled:
                self.isConnected = false
                self.statusText = "Mất kết nối. Bấm Kết nối lại."
                self.log("⚠️ Mất kết nối WS")
            case .text(let s):
                self.handleServerFrame(json: s)
            case .binary(let d):
                if let s = String(data: d, encoding: .utf8) {
                    self.handleServerFrame(json: s)
                }
            case .error(let e):
                self.log("❌ WS error: \(String(describing: e))")
            default:
                break
            }
        }
    }

    private func handleServerFrame(json: String) {
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
                llmText += (llmText.isEmpty ? "" : " ") + t
                log("🤖 LLM[\(emotion ?? "—")]: \(t)")
            }
            if let a = audioB64, !a.isEmpty {
                playAudio(audioB64: a)
            }
        case "listening":
            statusText = "Sẵn sàng lắng nghe. Nhấn 🎤."
            let lat = obj["latency_ms"] as? Double
            if let l = lat {
                log("⏱️ Total latency: \(Int(l)) ms")
            }
        default:
            break
        }
    }
}

// MARK: - Audio recorder delegate
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
            // Header
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

            // Transcript + LLM + Emotion
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

            // Log
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
        .onAppear {
            vm.connect()
        }
    }
}

#Preview {
    ContentView()
}
