# 📺 ScrShare - YouTube TV Wi-Fi Remote (for PC)

A modern cross-platform **Flutter App & PC Companion** that connects your mobile phone to your PC over local Wi-Fi and automatically opens **YouTube TV** (`tv.youtube.com`) on your computer's default browser with a single button press.

---

## ⚡ How It Works

```
┌─────────────────────────────────┐                 ┌─────────────────────────────────┐
│     Mobile Phone (Flutter)      │   Same Wi-Fi    │          Windows PC             │
│                                 │                 │                                 │
│  [🚀 LAUNCH YOUTUBE TV]         │ ──────────────> │  Receives HTTP / UDP Command    │
│  - D-Pad TV Navigation          │  HTTP / Port    │  Automatic Default Browser:     │
│  - Play / Pause / Volume / F11  │      8080       │  👉 https://www.youtube.com/tv │
└─────────────────────────────────┘                 └─────────────────────────────────┘
```

1. **Mobile Controller**:
   - Auto-discovers the PC via UDP broadcast (`SCRSHARE_DISCOVER` on port 8088) or manual IP entry.
   - Large tactile **"Launch YouTube TV"** hero button with real-time feedback.
   - Quick launch for **YouTube TV UI** (`youtube.com/tv`), **YouTube Music**, and custom URLs.
   - Smart D-Pad navigation (Up/Down/Left/Right/OK) and media controls (Play/Pause, Volume, Mute, F11 Fullscreen).

2. **PC Receiver (Two flexible options)**:
   - **Option 1: The Flutter App in Host Mode**: Run the app directly on your Windows PC (`flutter run -d windows`). It acts as a visual Host Hub with a QR Code and live event log.
   - **Option 2: Lightweight Companion Script**: Double-click `pc_host/start_server.bat` or run `python pc_host/pc_server.py`. Zero dependencies required!

---

## 🚀 Quick Start Guide

### Step 1: Start the PC Receiver (On your PC)

Choose either option:

#### Option A: Lightweight Script (Recommended for daily use)
Double-click `pc_host/start_server.bat` or run:
```bash
python pc_host/pc_server.py
```
This displays your PC's local Wi-Fi IP (e.g. `http://192.168.1.105:8080`) and starts listening for phone commands.

#### Option B: Flutter Desktop Host App
Run the Flutter app directly on Windows:
```bash
flutter run -d windows
```
The app will automatically launch in **PC Host Mode**, displaying your local IP, a QR code, and a live log of commands received from your phone.

---

### Step 2: Run the Remote on Your Phone

Connect your phone to the **same Wi-Fi network** as your PC:

```bash
flutter run -d <your-android-device-or-emulator>
```

1. Open the app on your phone.
2. Tap the **Radar / Scan** icon in the top right: it will auto-detect your PC on the Wi-Fi.
   *(Or tap the slider icon to enter your PC's IP address directly, e.g. `192.168.1.105`)*.
3. Tap the big glowing **"Launch YouTube TV"** button!
4. Your PC's default browser will instantly open `https://tv.youtube.com`.

---

## 🎮 Extra Remote Controls

When YouTube TV is open on your PC:
- **D-Pad (Arrows + OK)**: Navigate menus and select videos.
- **Play / Pause**: Toggles video playback (Space).
- **Fullscreen (F11)**: Toggles browser fullscreen mode.
- **Volume + / - / Mute**: Controls system audio playback.
- **Back**: Returns to the previous menu (`Esc`).

---

## 📁 Project Structure

```
scrshare/
├── lib/
│   ├── main.dart                       # App entrypoint (Host on Desktop, Remote on Mobile)
│   ├── theme/
│   │   └── app_theme.dart              # Sleek dark theme with crimson accents
│   ├── models/
│   │   └── host_info.dart              # PC Host network model
│   ├── services/
│   │   ├── pc_host_service.dart        # Embedded Dart HTTP + UDP server for PC
│   │   ├── remote_client_service.dart  # Client API caller with history & health check
│   │   └── network_discovery_service.dart # UDP broadcast & subnet discovery
│   ├── screens/
│   │   ├── remote_screen.dart          # Mobile TV controller UI
│   │   └── host_screen.dart            # PC Host receiver dashboard with QR & Live Log
│   └── widgets/
│       └── dpad_widget.dart            # Smart TV D-Pad controller
├── pc_host/
│   ├── pc_server.py                    # Zero-dependency Python PC host companion
│   └── start_server.bat                # 1-Click launcher for Windows
└── android/app/src/main/AndroidManifest.xml # Configured with Wi-Fi & cleartext permissions
```
