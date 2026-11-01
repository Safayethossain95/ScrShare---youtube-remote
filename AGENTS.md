# Project Rules & Persistent Instructions

## YouTube TV Remote Control - Back Button Specification

> **CRITICAL RULE**: DO NOT CHANGE the key mapping for the **Back button** (`action == 'back'` or `'backspace'`). It is working and must be preserved forever across all receivers and future prompts.

### 1. Key Mapping Requirement
* **`'back'` and `'backspace'` MUST ALWAYS send `Backspace`**:
  * In Win32 / C# (`pc_host/pc_receiver.cs`): Send `VK_BACK` (`0x08`).
  * In Dart / PowerShell (`pc_host/pc_receiver.dart` and `lib/services/pc_host_service.dart`): Send `{BACKSPACE}`.
  * In Python (`pc_host/pc_server.py`): Send `0x08`.
* **`'escape'` and `'esc'` MUST ALWAYS send `Escape`**:
  * In Win32 / C#: Send `VK_ESCAPE` (`0x1B`).
  * In Dart / PowerShell: Send `{ESC}`.

### 2. Why This is Required (Technical Rationale)
* On **YouTube TV on PC (`youtube.com/tv`)**, the app is a Leanback TV interface.
* **`Backspace` is the official TV remote "Back" / "Return" button**. Pressing Backspace while a video is playing exits the video player and returns to the home screen or previous menu.
* **`Escape` (`0x1B`) DOES NOT go back** in YouTube TV (it only toggles browser fullscreen or closes system menus).
* **`Alt + Left Arrow` DOES NOT work** in YouTube TV on PC because the TV interface intercepts keys specifically for remote navigation.

### 3. Window Foreground & Focus Rules
* In `pc_host/pc_receiver.cs`, `ForceForeground()` must **never simulate the Alt key** if the target browser window is already the foreground window (`GetForegroundWindow() == hWnd`). Simulating `Alt` activates the browser's menu bar, which intercepts subsequent keystrokes.
