//
//  App.tsx - Magoria voice companion (Expo + React Native + TypeScript)
//
//  App mobile dùng để test luồng real-time với core backend (Python/FastAPI):
//   - Nhấn nút 🎤 để thu âm mic
//   - App ghi WAV 16kHz mono PCM -> base64 -> gửi qua WebSocket
//   - Backend xử lý: STT -> LLM -> TTS -> trả audio_chunk base64
//   - App nhận audio_chunk -> phát ra loa
//   - UI hiển thị state machine: listening / thinking / speaking
//
//  Cách chạy dev mode:
//   1. Cài Expo Go trên iPhone (App Store, miễn phí)
//   2. cd magoria-app/mobile && npx expo start
//   3. Quét QR code hiện trong terminal
//   4. App mở trong Expo Go, test với core backend đang chạy
//
//  Cấu hình URL backend qua biến môi trường EXPO_PUBLIC_WS_URL.
//  Mặc định: ws://192.168.1.100:8765/ws/?session_id=expo-test&character_id=default&character_type=default
//  (Sửa IP theo máy backend của bạn. Với simulator, để localhost được.)
//

import { Audio } from 'expo-av';
import * as FileSystem from 'expo-file-system/legacy';
import { StatusBar } from 'expo-status-bar';
import React, { useEffect, useRef, useState } from 'react';
import {
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';

// === Cấu hình ===
// Đổi IP theo máy chạy backend. Có thể override qua env var khi start:
//   EXPO_PUBLIC_WS_URL=ws://192.168.1.50:8765/ws/ npx expo start
const WS_URL: string =
  process.env.EXPO_PUBLIC_WS_URL ||
  'ws://192.168.1.5:8765/ws/?session_id=expo-test&character_id=default&character_type=default';

// State machine của backend
type State = 'connecting' | 'listening' | 'thinking' | 'speaking' | 'error';

export default function App() {
  // === State ===
  const [connectionStatus, setConnectionStatus] = useState<'disconnected' | 'connected'>('disconnected');
  const [state, setState] = useState<State>('listening');
  const [isRecording, setIsRecording] = useState(false);
  const [transcript, setTranscript] = useState('');
  const [assistantText, setAssistantText] = useState('');
  const [emotion, setEmotion] = useState('—');
  const [logs, setLogs] = useState<string[]>([]);

  // === Refs ===
  const wsRef = useRef<WebSocket | null>(null);
  const recordingRef = useRef<Audio.Recording | null>(null);
  const soundRef = useRef<Audio.Sound | null>(null);
  const playbackQueueRef = useRef<string[]>([]);
  const isPlayingRef = useRef(false);
  const playbackRunIdRef = useRef(0);
  const audioFileCounterRef = useRef(0);

  // === Logging ===
  const log = (msg: string) => {
    const ts = new Date().toLocaleTimeString();
    setLogs((prev) => {
      const next = [...prev, `[${ts}] ${msg}`];
      return next.slice(-30); // giữ 30 dòng cuối
    });
  };

  // === WebSocket lifecycle ===
  useEffect(() => {
    connect();
    return () => {
      wsRef.current?.close();
      if (recordingRef.current) {
        recordingRef.current.stopAndUnloadAsync().catch(() => {});
      }
      if (soundRef.current) {
        soundRef.current.unloadAsync().catch(() => {});
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const connect = () => {
    log(`Đang kết nối ${WS_URL}`);
    setState('connecting');
    const ws = new WebSocket(WS_URL);
    wsRef.current = ws;

    ws.onopen = () => {
      log('✅ WS connected');
      setConnectionStatus('connected');
      setState('listening');
    };

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data as string);
        handleServerFrame(msg);
      } catch (e) {
        log(`❌ Parse error: ${String(e)}`);
      }
    };

    ws.onerror = (e) => {
      log(`❌ WS error: ${JSON.stringify(e)}`);
      setState('error');
    };

    ws.onclose = () => {
      log('⚠️ WS closed');
      setConnectionStatus('disconnected');
      if (state !== 'error') setState('listening');
    };
  };

  // === Xử lý frame từ server ===
  const handleServerFrame = (msg: any) => {
    const newState: string = msg.state || '';
    const text: string = msg.text || '';
    const emo: string = msg.emotion || '';
    const audioB64: string = msg.audio_chunk || '';

    // Lấy STT transcript từ frame thinking (frame đầu là placeholder "Đang xử lý...")
    if (newState === 'thinking' && text && text !== 'Đang xử lý yêu cầu của bạn...') {
      setTranscript(text);
      log(`🎤 STT: ${text}`);
    }

    // Gom LLM response. Mỗi chunk là 1 word delta → append để xây câu hoàn chỉnh.
    if (newState === 'speaking') {
      if (emo) setEmotion(emo);
      if (text && !audioB64) {
        setAssistantText((prev) => (prev ? prev + ' ' + text : text));
        log(`🤖 LLM[${emo || '—'}]: ${text}`);
      }
      // Phát audio
      if (audioB64) {
        enqueueAudio(audioB64);
      }
    }

    // Cập nhật state. Listening frame cuối turn mang full_response_text → REPLACE
    // (không append) để tránh ghép với text delta trước đó. Cách này tránh được
    // lặp/tách vụn khi backend streaming delta.
    if (newState === 'listening') {
      setState('listening');
      if (text && text !== 'Sẵn sàng lắng nghe tiếp') {
        // Full response từ backend (đã chuẩn hóa, không bị lặp)
        setAssistantText(text);
      } else {
        // Không có full text (vd turn ngắn hoặc lỗi) → reset để tránh lưu cũ
        setAssistantText('');
      }
      if (msg.latency_ms) {
        log(`⏱️ Total latency: ${Math.round(msg.latency_ms)} ms`);
      }
    } else if (newState === 'thinking') {
      setState('thinking');
    } else if (newState === 'speaking') {
      setState('speaking');
    }
  };

  // === Ghi âm + gửi audio ===
  const startRecording = async () => {
    try {
      // Xin quyền mic
      const { status } = await Audio.requestPermissionsAsync();
      if (status !== 'granted') {
        log('❌ Không có quyền microphone');
        return;
      }

      // Set audio mode cho recording
      await Audio.setAudioModeAsync({
        allowsRecordingIOS: true,
        playsInSilentModeIOS: true,
      });

      if (state === 'speaking') {
        await clearPlaybackQueue();
      }

      // expo-av HIGH_QUALITY preset ghi M4A/AAC.
      // Backend STT (faster-whisper) tự động decode M4A/MP4/WebM/MP3/OGG/WAV
      // về PCM 16kHz mono qua ffmpeg — không cần convert ở app.
      const rec = new Audio.Recording();
      await rec.prepareToRecordAsync(Audio.RecordingOptionsPresets.HIGH_QUALITY);
      await rec.startAsync();
      recordingRef.current = rec;
      setIsRecording(true);
      log('🎤 Đang thu âm... nhấn lại để gửi.');

      // Barge-in: nếu server đang nói -> gửi interrupt
      if (state === 'speaking') {
        sendInterrupt();
      }
    } catch (e) {
      log(`❌ startRecording error: ${String(e)}`);
    }
  };

  const stopRecording = async () => {
    if (!recordingRef.current) return;
    try {
      setIsRecording(false);
      log('✅ Thu âm xong, đang xử lý...');
      await recordingRef.current.stopAndUnloadAsync();
      const uri = recordingRef.current.getURI();
      recordingRef.current = null;

      if (!uri) {
        log('❌ Không lấy được URI file');
        return;
      }

      // Đọc file -> base64
      const base64 = await FileSystem.readAsStringAsync(uri, {
        encoding: FileSystem.EncodingType.Base64,
      });
      sendAudioFrame(base64);
    } catch (e) {
      log(`❌ stopRecording error: ${String(e)}`);
    }
  };

  const sendAudioFrame = (audioB64: string) => {
    if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) {
      log('❌ WS chưa kết nối');
      return;
    }
    log(`📤 Gửi audio frame (${audioB64.length} chars base64)`);
    setState('thinking');
    wsRef.current.send(
      JSON.stringify({
        type: 'event',
        event_type: 'audio',
        payload: { audio_b64: audioB64 },
      })
    );
  };

  const sendInterrupt = () => {
    if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) return;
    log('⛔ Barge-in: gửi interrupt');
    wsRef.current.send(
      JSON.stringify({
        type: 'event',
        event_type: 'interrupt',
      })
    );
  };

  // === Phát audio TTS từ server ===
  const clearPlaybackQueue = async () => {
    playbackRunIdRef.current += 1;
    playbackQueueRef.current = [];
    isPlayingRef.current = false;
    const sound = soundRef.current;
    soundRef.current = null;
    if (sound) {
      await sound.unloadAsync().catch(() => {});
    }
  };

  const enqueueAudio = (audioB64: string) => {
    playbackQueueRef.current.push(audioB64);
    void playNextAudio();
  };

  const playNextAudio = async () => {
    if (isPlayingRef.current) return;
    const audioB64 = playbackQueueRef.current.shift();
    if (!audioB64) return;
    isPlayingRef.current = true;
    await playAudio(audioB64, playbackRunIdRef.current);
  };

  const playAudio = async (audioB64: string, runId: number) => {
    try {
      // Dừng audio đang phát
      // Tạo data URI từ base64
      const cacheDirectory = FileSystem.cacheDirectory;
      if (!cacheDirectory) {
        throw new Error('Audio cache directory is unavailable');
      }
      const fileUri = `${cacheDirectory}magoria-tts-${audioFileCounterRef.current++}.mp3`;
      await FileSystem.writeAsStringAsync(fileUri, audioB64, {
        encoding: FileSystem.EncodingType.Base64,
      });
      await Audio.setAudioModeAsync({
        allowsRecordingIOS: false,
        playsInSilentModeIOS: true,
      });
      // expo-av SDK 54 dùng createAsync (createFromURI deprecated).
      // { shouldPlay: true } phát ngay khi load xong; không cần gọi playAsync() thêm.
      const { sound } = await Audio.Sound.createAsync(
        { uri: fileUri },
        { shouldPlay: true }
      );
      if (runId !== playbackRunIdRef.current) {
        await sound.unloadAsync();
        await FileSystem.deleteAsync(fileUri, { idempotent: true });
        return;
      }
      soundRef.current = sound;
      sound.setOnPlaybackStatusUpdate((status) => {
        if (status.isLoaded && status.didJustFinish) {
          void finishPlayback(sound, fileUri, runId);
        }
      });
    } catch (e) {
      log(`❌ Audio play error: ${String(e)}`);
    }
  };

  // === UI ===
  const finishPlayback = async (sound: Audio.Sound, fileUri: string, runId: number) => {
    if (soundRef.current === sound) {
      soundRef.current = null;
    }
    await sound.unloadAsync().catch(() => {});
    await FileSystem.deleteAsync(fileUri, { idempotent: true }).catch(() => {});
    if (runId !== playbackRunIdRef.current) return;
    isPlayingRef.current = false;
    void playNextAudio();
  };

  const stateColor = (s: State): string => {
    switch (s) {
      case 'listening': return '#4CAF50'; // xanh lá
      case 'thinking': return '#FF9800';  // cam
      case 'speaking': return '#2196F3';  // xanh dương
      case 'connecting': return '#9E9E9E'; // xám
      case 'error': return '#F44336';       // đỏ
    }
  };

  return (
    <View style={styles.container}>
      <StatusBar style="dark" />

      <Text style={styles.title}>Magoria Voice Test</Text>

      <View style={styles.statusRow}>
        <View
          style={[
            styles.statusDot,
            { backgroundColor: connectionStatus === 'connected' ? '#4CAF50' : '#F44336' },
          ]}
        />
        <Text style={styles.statusText}>
          {connectionStatus === 'connected' ? `Đã kết nối · ${state}` : 'Chưa kết nối'}
        </Text>
        <View style={{ flex: 1 }} />
        {connectionStatus === 'disconnected' ? (
          <TouchableOpacity onPress={connect} style={styles.smallBtn}>
            <Text>Kết nối</Text>
          </TouchableOpacity>
        ) : (
          <TouchableOpacity
            onPress={() => wsRef.current?.close()}
            style={styles.smallBtn}
          >
            <Text>Ngắt</Text>
          </TouchableOpacity>
        )}
      </View>

      <View style={[styles.bigBtn, { backgroundColor: stateColor(state) }]}>
        <TouchableOpacity
          onPress={isRecording ? stopRecording : startRecording}
          style={styles.bigBtnTouch}
        >
          <Text style={styles.bigBtnText}>{isRecording ? '⏹' : '🎤'}</Text>
        </TouchableOpacity>
      </View>

      <Text style={styles.subtle}>{isRecording ? 'Đang thu âm... bấm để gửi' : 'Bấm 🎤 để nói'}</Text>

      <View style={styles.transcriptBlock}>
        <Text style={styles.label}>🎤 Bạn nói:</Text>
        <Text style={styles.transcriptText}>{transcript || '—'}</Text>
        <Text style={styles.label}>🤖 Cháu trả lời:</Text>
        <Text style={styles.transcriptText}>{assistantText || '—'}</Text>
        <Text style={styles.label}>😊 Cảm xúc: {emotion}</Text>
      </View>

      <View style={styles.logBox}>
        <Text style={styles.logLabel}>Log:</Text>
        <ScrollView style={styles.logScroll}>
          {logs.map((line, i) => (
            <Text key={i} style={styles.logLine}>
              {line}
            </Text>
          ))}
        </ScrollView>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    padding: 20,
    paddingTop: Platform.OS === 'ios' ? 60 : 20,
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    textAlign: 'center',
    marginBottom: 16,
  },
  statusRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 16,
  },
  statusDot: {
    width: 12,
    height: 12,
    borderRadius: 6,
    marginRight: 8,
  },
  statusText: {
    fontSize: 14,
    color: '#333',
  },
  smallBtn: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    backgroundColor: '#E0E0E0',
    borderRadius: 4,
  },
  bigBtn: {
    width: 120,
    height: 120,
    borderRadius: 60,
    alignSelf: 'center',
    marginVertical: 24,
    elevation: 4,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.3,
    shadowRadius: 4,
  },
  bigBtnTouch: {
    width: '100%',
    height: '100%',
    alignItems: 'center',
    justifyContent: 'center',
  },
  bigBtnText: {
    fontSize: 56,
    color: '#fff',
  },
  subtle: {
    textAlign: 'center',
    color: '#666',
    marginBottom: 16,
  },
  transcriptBlock: {
    backgroundColor: '#F5F5F5',
    padding: 12,
    borderRadius: 8,
    marginBottom: 16,
  },
  label: {
    fontSize: 12,
    color: '#888',
    marginTop: 4,
  },
  transcriptText: {
    fontSize: 15,
    color: '#222',
    marginBottom: 4,
  },
  logBox: {
    flex: 1,
    backgroundColor: '#FAFAFA',
    borderRadius: 8,
    padding: 8,
  },
  logLabel: {
    fontSize: 12,
    color: '#888',
    fontWeight: 'bold',
  },
  logScroll: {
    flex: 1,
  },
  logLine: {
    fontSize: 11,
    fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace',
    color: '#333',
  },
});
