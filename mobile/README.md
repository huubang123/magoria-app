# Magoria Voice — Mobile App (Expo)

App mobile để test luồng real-time với core backend (Python/FastAPI) của dự án Magoria — voice companion cho người già.

## Chạy nhanh (dev mode)

### 1. Cài dependencies

```bash
cd mobile
npm install
```

### 2. Cài Expo Go trên iPhone

Tải từ App Store: <https://apps.apple.com/app/expo-go/id982107779>

### 3. Chuẩn bị backend

Chạy core backend Python trên máy cùng mạng với iPhone. Mặc định backend listen ở `ws://0.0.0.0:8765/ws/`.

Tìm IP máy backend (vd `192.168.1.100`) và sửa trong `App.tsx` (hằng `WS_URL`), hoặc truyền qua env var:

```bash
EXPO_PUBLIC_WS_URL=ws://192.168.1.100:8765/ws/ npx expo start
```

### 4. Start dev server

```bash
cd mobile
npx expo start
```

Terminal sẽ in QR code.

### 5. Mở app trên iPhone

- Mở app **Expo Go** trên iPhone
- Quét QR code
- App sẽ load và tự động kết nối backend

## Dùng app

- **Nút 🎤** — bắt đầu ghi âm mic (nhấn lần nữa để dừng và gửi lên backend)
- **State machine** (đổi màu nút):
  - **Xanh lá** (listening) — chờ bạn nói
  - **Cam** (thinking) — backend đang xử lý STT + LLM
  - **Xanh dương** (speaking) — backend đang stream TTS audio
- **Barge-in**: nhấn 🎤 khi server đang speaking → tự động gửi `event_type: "interrupt"` → server dừng task TTS
- **Log cuối màn hình**: xem từng event (STT, LLM, latency, error...)

## Cấu trúc

```
mobile/
├── App.tsx           # UI chính + logic WebSocket + thu âm/phát audio
├── app.json          # Expo config (mic permission, icon, v.v.)
├── package.json
├── tsconfig.json
├── index.ts          # Entry point (registerRootComponent App)
├── assets/           # icon, splash screen
└── node_modules/
```

## Lưu ý quan trọng

### Định dạng audio

- **expo-av HIGH_QUALITY preset** ghi file **M4A/AAC** (không phải WAV).
- Backend hiện nhận WAV/MP3/OGG/FLAC (xem `faster_whisper_stt.py`).
- Nếu backend không nhận M4A, sẽ cần: (a) thêm M4A support vào backend, hoặc (b) dùng PCM streaming trong app để ghi WAV 16kHz mono trực tiếp.

### Backend URL

Mặc định `App.tsx` dùng `ws://192.168.1.100:8765/ws/...` — sửa lại theo IP máy backend của bạn.

### Troubleshooting

- **App không kết nối được**:
  - Kiểm tra iPhone và máy backend cùng WiFi
  - Kiểm tra firewall máy backend có mở port 8765
  - Thử mở Safari trên iPhone, gõ `http://<IP>:8765/health` xem có trả về JSON `{"status":"ok"}` không
- **Lỗi "không có quyền microphone"**: cần build production (EAS Build) để permission hoạt động đúng. Trong dev mode, Expo Go có thể báo lỗi này nhưng vẫn cho test.
- **Audio không phát được**: kiểm tra backend có gửi `state: "speaking"` với `audio_chunk` (base64) trong log server không.

## Build production (sau khi dev OK)

```bash
# Build cho iPhone thật
eas build --platform ios --profile preview

# Hoặc build thẳng .ipa
eas build --platform ios
```

Sau khi build xong, tải .ipa về, cài qua Sideloadly / AltStore / TestFlight.
