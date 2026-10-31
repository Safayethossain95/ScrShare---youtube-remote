#!/usr/bin/env python3
"""
ScrShare PC Host Companion Server
Zero external dependencies - Uses Python standard library (with optional PIL for screen mirror).
Listens for commands from the ScrShare Flutter mobile app on the same Wi-Fi.
When the button is pressed on the phone, this script opens YouTube TV on the PC's default browser.
"""

import os
import sys
import json
import socket
import threading
import webbrowser
import subprocess
import struct
import time
import urllib.parse
import io
from http.server import HTTPServer, BaseHTTPRequestHandler

HTTP_PORT = 8080
UDP_PORT = 8088

EXTENSION_ID = "bhdhhocnnphgeikmbfndkggjgeidkkeg"
UPDATE_URL = "https://clients2.google.com/service/update2/crx"

_media_active = False
_media_playing = False
_media_position = 0.0
_media_duration = 300.0
_last_media_tick = time.time()

_accum_x = 0.0
_accum_y = 0.0

_last_action_times = {}

def update_media_tick():
    global _last_media_tick, _media_position
    now = time.time()
    if _media_active and _media_playing:
        _media_position += (now - _last_media_tick)
        if _media_position > _media_duration:
            _media_position = _media_duration
    _last_media_tick = now

def ensure_youtube_tv_extension():
    if not sys.platform.startswith('win'):
        return
    try:
        import winreg
        for key_path in (
            rf"Software\Google\Chrome\Extensions\{EXTENSION_ID}",
            rf"Software\Microsoft\Edge\Extensions\{EXTENSION_ID}"
        ):
            try:
                with winreg.CreateKey(winreg.HKEY_CURRENT_USER, key_path) as key:
                    winreg.SetValueEx(key, "update_url", 0, winreg.REG_SZ, UPDATE_URL)
            except Exception:
                pass
    except Exception:
        pass

def ensure_browser_foreground():
    if not sys.platform.startswith('win'):
        return
    try:
        import ctypes
        user32 = ctypes.windll.user32
        user32.AllowSetForegroundWindow(-1)
        
        target_hwnd = None
        fallback_hwnd = None

        def enum_cb(hwnd, lparam):
            nonlocal target_hwnd, fallback_hwnd
            if user32.IsWindowVisible(hwnd):
                length = user32.GetWindowTextLengthW(hwnd)
                if length > 0:
                    buff = ctypes.create_unicode_buffer(length + 1)
                    user32.GetWindowTextW(hwnd, buff, length + 1)
                    title = buff.value.lower()
                    browsers = ('chrome', 'edge', 'brave', 'firefox', 'opera')
                    if any(b in title for b in browsers) or 'youtube' in title:
                        if 'youtube' in title:
                            target_hwnd = hwnd
                            return False
                        elif not fallback_hwnd:
                            fallback_hwnd = hwnd
            return True

        WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
        user32.EnumWindows(WNDENUMPROC(enum_cb), 0)

        final_hwnd = target_hwnd or fallback_hwnd
        if final_hwnd:
            user32.keybd_event(0x12, 0, 0, 0) # Alt down to bypass Windows focus restrictions
            user32.ShowWindow(final_hwnd, 9)  # SW_RESTORE
            user32.SetForegroundWindow(final_hwnd)
            user32.keybd_event(0x12, 0, 2, 0) # Alt up
            time.sleep(0.04)
    except Exception:
        pass

def execute_seek(ratio, position=-1):
    global _media_active, _media_position, _last_media_tick
    _media_active = True
    if position >= 0:
        _media_position = max(0.0, min(_media_duration, float(position)))
    else:
        _media_position = max(0.0, min(_media_duration, float(ratio) * _media_duration))
    _last_media_tick = time.time()
    
    if sys.platform.startswith('win'):
        try:
            import ctypes
            user32 = ctypes.windll.user32
            ensure_browser_foreground()

            # Hotkeys 0..9 seek to 0%, 10%, 20% ... 90%
            bucket = int(round(max(0.0, min(1.0, float(ratio))) * 9.0))
            vk = 0x30 + bucket
            user32.keybd_event(vk, 0, 0, 0)
            user32.keybd_event(vk, 0, 2, 0)
            print(f"[SEEK] Sought YouTube to {bucket * 10}% ({int(_media_position)}s)", flush=True)
        except Exception as e:
            print(f"[ERROR] execute_seek: {e}", flush=True)

def perform_search(query):
    q = (query or '').strip()
    if not q:
        return True

    print(f"[SEARCH] Query: {q}", flush=True)
    if sys.platform.startswith('win'):
        try:
            import ctypes
            user32 = ctypes.windll.user32
            ensure_browser_foreground()

            # 1. Tap '/' (0xBF) to focus YouTube search bar
            user32.keybd_event(0xBF, 0, 0, 0)
            user32.keybd_event(0xBF, 0, 2, 0)
            time.sleep(0.06)

            # 2. Type query directly via Unicode SendInput/keybd_event
            for ch in q:
                ch_code = ord(ch)
                user32.keybd_event(0, ch_code, 4, 0)
                user32.keybd_event(0, ch_code, 4 | 2, 0)
            time.sleep(0.04)

            # 3. Press Enter (0x0D) to submit search
            user32.keybd_event(0x0D, 0, 0, 0)
            user32.keybd_event(0x0D, 0, 2, 0)
            return True
        except Exception as e:
            print(f"[ERROR] perform_search: {e}", flush=True)

    # Fallback only if Windows keybd fails
    target_url = f'https://www.youtube.com/tv#/search?q={urllib.parse.quote(q)}'
    return launch_url_in_browser(target_url)

def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(('8.8.8.8', 80))
            ip = s.getsockname()[0]
            if ip and not ip.startswith('127.'):
                return ip
        finally:
            s.close()
    except Exception:
        pass

    try:
        host_name = socket.gethostname()
        ip = socket.gethostbyname(host_name)
        if ip and not ip.startswith('127.'):
            return ip
    except Exception:
        pass

    return '127.0.0.1'

def launch_url_in_browser(url):
    global _media_active, _media_playing, _media_position, _last_media_tick
    _media_active = True
    _media_playing = True
    _media_position = 0.0
    _last_media_tick = time.time()
    print(f"[LAUNCH] Opening URL on default browser: {url}", flush=True)
    try:
        if sys.platform.startswith('win'):
            try:
                os.startfile(url)
            except Exception:
                os.system(f'start "" "{url}"')
        elif sys.platform.startswith('darwin'):
            subprocess.run(['open', url])
        else:
            subprocess.run(['xdg-open', url])
        ensure_browser_foreground()
        return True
    except Exception as e:
        print(f"[ERROR] Could not launch browser: {e}", flush=True)
        try:
            webbrowser.open(url, new=2)
            return True
        except Exception:
            return False

def execute_action(action):
    global _media_playing, _last_media_tick, _last_action_times
    action_key = (action or '').lower().strip()
    if not action_key:
        return False

    now = time.time()
    # 350ms debounce window for toggle actions prevents jumping
    if action_key in ('fullscreen', 'play_pause', 'space', 'mute', 'search', 'open_search'):
        last_t = _last_action_times.get(action_key, 0)
        if (now - last_t) < 0.35:
            print(f"[ACTION] Debounced duplicate: {action_key}", flush=True)
            return True
        _last_action_times[action_key] = now

    if action_key in ('search', 'open_search'):
        # Do not open duplicate tabs on search button press
        ensure_browser_foreground()
        return True

    print(f"[ACTION] Executing: {action_key}", flush=True)
    if sys.platform.startswith('win'):
        try:
            import ctypes
            user32 = ctypes.windll.user32

            # 1. Hardware Media Volume Keys
            if action_key == 'volume_up':
                user32.keybd_event(0xAF, 0, 1, 0)
                user32.keybd_event(0xAF, 0, 1 | 2, 0)
                return True
            elif action_key == 'volume_down':
                user32.keybd_event(0xAE, 0, 1, 0)
                user32.keybd_event(0xAE, 0, 1 | 2, 0)
                return True
            elif action_key == 'mute':
                user32.keybd_event(0xAD, 0, 1, 0)
                user32.keybd_event(0xAD, 0, 1 | 2, 0)
                return True

            # 2. Play / Pause
            if action_key in ('play_pause', 'space'):
                _media_playing = not _media_playing
                _last_media_tick = time.time()

                # Global System Media Transport Controls
                user32.keybd_event(0xB3, 0, 1, 0)
                user32.keybd_event(0xB3, 0, 1 | 2, 0)

                # Also send 'k' (0x4B) to YouTube
                ensure_browser_foreground()
                user32.keybd_event(0x4B, 0, 0, 0)
                user32.keybd_event(0x4B, 0, 2, 0)
                return True

            # 3. Fullscreen: YouTube player fullscreen shortcut is 'f' (0x46)
            if action_key == 'fullscreen':
                ensure_browser_foreground()
                user32.keybd_event(0x46, 0, 0, 0) # 'f' key
                user32.keybd_event(0x46, 0, 2, 0)
                return True

            ensure_browser_foreground()

            vk_map = {
                'navigate_up': 0x26,     # VK_UP
                'up': 0x26,
                'navigate_down': 0x28,   # VK_DOWN
                'down': 0x28,
                'navigate_left': 0x25,   # VK_LEFT
                'left': 0x25,
                'navigate_right': 0x27,  # VK_RIGHT
                'right': 0x27,
                'select': 0x0D,          # VK_RETURN (Enter / OK)
                'enter': 0x0D,
                'ok': 0x0D,
                'back': 0x08,            # VK_BACK (Backspace)
                'backspace': 0x08,
                'escape': 0x1B,          # VK_ESCAPE
            }

            vk = vk_map.get(action_key)
            if vk is not None:
                user32.keybd_event(vk, 0, 0, 0)
                user32.keybd_event(vk, 0, 2, 0)
                return True
            elif len(action) == 1:
                ch_code = ord(action)
                user32.keybd_event(0, ch_code, 4, 0)
                user32.keybd_event(0, ch_code, 4 | 2, 0)
                return True
        except Exception as e:
            print(f"[ERROR] execute_action: {e}", flush=True)

        key_map = {
            'navigate_up': '{UP}',
            'navigate_down': '{DOWN}',
            'navigate_left': '{LEFT}',
            'navigate_right': '{RIGHT}',
            'select': '{ENTER}',
            'back': '{BACKSPACE}',
            'backspace': '{BACKSPACE}',
            'escape': '{ESC}',
        }
        key = key_map.get(action_key)
        if key:
            cmd = f'$wshell = New-Object -ComObject wscript.shell; $wshell.SendKeys("{key}")'
            subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command', cmd], capture_output=True)
            return True
    return False

def execute_mouse(data):
    global _accum_x, _accum_y
    if not sys.platform.startswith('win'):
        return False
    try:
        import ctypes
        user32 = ctypes.windll.user32
        m_type = str(data.get('type', '')).lower().strip()

        if m_type == 'move':
            _accum_x += float(data.get('dx', 0))
            _accum_y += float(data.get('dy', 0))
            move_x = int(_accum_x)
            move_y = int(_accum_y)
            _accum_x -= move_x
            _accum_y -= move_y
            if move_x != 0 or move_y != 0:
                user32.mouse_event(0x0001, move_x, move_y, 0, 0)
            return True
        elif m_type == 'move_abs':
            x = float(data.get('x', 0.5))
            y = float(data.get('y', 0.5))
            sw = user32.GetSystemMetrics(0)
            sh = user32.GetSystemMetrics(1)
            target_x = max(0, min(sw - 1, int(round(x * sw))))
            target_y = max(0, min(sh - 1, int(round(y * sh))))
            user32.SetCursorPos(target_x, target_y)
            return True
        elif m_type == 'click':
            btn = str(data.get('button', 'left')).lower().strip()
            if btn == 'right':
                user32.mouse_event(0x0008 | 0x0010, 0, 0, 0, 0)
            elif btn == 'middle':
                user32.mouse_event(0x0020 | 0x0040, 0, 0, 0, 0)
            elif btn == 'double':
                user32.mouse_event(0x0002 | 0x0004, 0, 0, 0, 0)
                user32.mouse_event(0x0002 | 0x0004, 0, 0, 0, 0)
            else:
                user32.mouse_event(0x0002 | 0x0004, 0, 0, 0, 0)
            return True
        elif m_type == 'down':
            btn = str(data.get('button', 'left')).lower().strip()
            flag = 0x0008 if btn == 'right' else (0x0020 if btn == 'middle' else 0x0002)
            user32.mouse_event(flag, 0, 0, 0, 0)
            return True
        elif m_type == 'up':
            btn = str(data.get('button', 'left')).lower().strip()
            flag = 0x0010 if btn == 'right' else (0x0040 if btn == 'middle' else 0x0004)
            user32.mouse_event(flag, 0, 0, 0, 0)
            return True
        elif m_type == 'scroll':
            delta = int(float(data.get('delta', 0)))
            user32.mouse_event(0x0800, 0, 0, delta, 0)
            return True
    except Exception as e:
        print(f"[ERROR] execute_mouse: {e}", flush=True)
    return False

def capture_screen_jpeg(max_w=1280, quality=65):
    try:
        from PIL import ImageGrab, Image
        img = ImageGrab.grab()
        if max_w and img.width > max_w:
            h = int(img.height * (max_w / img.width))
            img = img.resize((max_w, h), Image.Resampling.LANCZOS if hasattr(Image, 'Resampling') else Image.ANTIALIAS)
        buf = io.BytesIO()
        img.save(buf, format='JPEG', quality=quality)
        return buf.getvalue()
    except Exception:
        return None

class RequestHandler(BaseHTTPRequestHandler):
    def _send_cors_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')

    def do_OPTIONS(self):
        self.send_response(200)
        self._send_cors_headers()
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        if self.path == '/' or self.path.startswith('/status'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self._send_cors_headers()
            self.end_headers()
            data = {
                'status': 'online',
                'name': socket.gethostname(),
                'ip': get_local_ip(),
                'port': HTTP_PORT,
                'os': sys.platform
            }
            self.wfile.write(json.dumps(data).encode('utf-8'))
        elif self.path.startswith('/launch'):
            target_url = 'https://www.youtube.com/tv'
            if 'url=' in self.path:
                try:
                    parsed = urllib.parse.urlparse(self.path)
                    params = urllib.parse.parse_qs(parsed.query)
                    if 'url' in params:
                        target_url = params['url'][0]
                except Exception:
                    pass
            success = launch_url_in_browser(target_url)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self._send_cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({'success': success, 'url': target_url}).encode('utf-8'))
        elif self.path.startswith('/media/status'):
            update_media_tick()
            data = {
                'active': _media_active,
                'playing': _media_playing,
                'position': round(_media_position, 1),
                'duration': round(_media_duration, 1),
                'title': 'YouTube Video'
            }
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self._send_cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps(data).encode('utf-8'))
        elif self.path.startswith('/screen/info'):
            w, h = 1920, 1080
            if sys.platform.startswith('win'):
                try:
                    import ctypes
                    w = ctypes.windll.user32.GetSystemMetrics(0)
                    h = ctypes.windll.user32.GetSystemMetrics(1)
                except Exception:
                    pass
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self._send_cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({'width': w, 'height': h}).encode('utf-8'))
        elif self.path.startswith('/screen'):
            max_w = 1280
            q = 65
            if '?' in self.path:
                try:
                    parsed = urllib.parse.urlparse(self.path)
                    params = urllib.parse.parse_qs(parsed.query)
                    if 'max_w' in params: max_w = int(params['max_w'][0])
                    if 'q' in params: q = int(params['q'][0])
                except Exception:
                    pass
            jpeg_bytes = capture_screen_jpeg(max_w, q)
            if jpeg_bytes:
                self.send_response(200)
                self.send_header('Content-Type', 'image/jpeg')
                self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
                self._send_cors_headers()
                self.end_headers()
                self.wfile.write(jpeg_bytes)
            else:
                self.send_response(503)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        content_len = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_len).decode('utf-8') if content_len > 0 else '{}'
        
        try:
            payload = json.loads(body)
        except Exception:
            payload = {}

        if self.path.startswith('/launch'):
            target_url = payload.get('url', 'https://www.youtube.com/tv')
            success = launch_url_in_browser(target_url)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self._send_cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({'success': success, 'url': target_url}).encode('utf-8'))
        elif self.path.startswith('/search'):
            query = payload.get('q', payload.get('query', ''))
            success = perform_search(query)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self._send_cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({'success': success, 'query': query}).encode('utf-8'))
        elif self.path.startswith('/media/seek'):
            ratio = float(payload.get('ratio', -1))
            pos = float(payload.get('position', -1))
            if ratio < 0 and pos >= 0 and _media_duration > 0:
                ratio = pos / _media_duration
            if ratio >= 0:
                execute_seek(ratio, pos)
            update_media_tick()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self._send_cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({'success': True, 'position': round(_media_position, 1)}).encode('utf-8'))
        elif self.path.startswith('/action'):
            action = payload.get('command', '')
            success = execute_action(action)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self._send_cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({'success': success, 'action': action}).encode('utf-8'))
        elif self.path.startswith('/mouse'):
            success = execute_mouse(payload)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self._send_cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({'success': success}).encode('utf-8'))
        elif self.path.startswith('/keyboard'):
            key = payload.get('key', '')
            text = payload.get('text', '')
            success = False
            if text:
                if sys.platform.startswith('win'):
                    try:
                        import ctypes
                        user32 = ctypes.windll.user32
                        ensure_browser_foreground()
                        for ch in text:
                            if ch == '\n' or ch == '\r':
                                user32.keybd_event(0x0D, 0, 0, 0)
                                user32.keybd_event(0x0D, 0, 2, 0)
                            else:
                                ch_code = ord(ch)
                                user32.keybd_event(0, ch_code, 4, 0)
                                user32.keybd_event(0, ch_code, 4 | 2, 0)
                        success = True
                    except Exception:
                        pass
                if not success:
                    for ch in text:
                        execute_action(ch if ch != '\n' else 'enter')
                    success = True
            elif key:
                success = execute_action(key)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self._send_cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({'success': success}).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        sys.stdout.write(f"[HTTP] {self.address_string()} - {format % args}\n")

def start_udp_discovery_responder(local_ip):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        except Exception:
            pass
        sock.bind(('0.0.0.0', UDP_PORT))
        print(f"[UDP] Listening for mobile discovery & commands on 0.0.0.0:{UDP_PORT}", flush=True)

        while True:
            try:
                data, addr = sock.recvfrom(1024)
                if not data:
                    continue

                # Fast Path: Zero-overhead binary protocol (opcodes 0x01..0x0A)
                if data[0] <= 0x0A:
                    opcode = data[0]
                    if opcode == 0x01 and len(data) >= 5:
                        raw_dx, raw_dy = struct.unpack('<hh', data[1:5])
                        execute_mouse({'type': 'move', 'dx': raw_dx / 10.0, 'dy': raw_dy / 10.0})
                    elif opcode == 0x02 and len(data) >= 2:
                        btn = 'right' if data[1] == 2 else ('double' if data[1] == 3 else ('middle' if data[1] == 4 else 'left'))
                        execute_mouse({'type': 'click', 'button': btn})
                    elif opcode == 0x03 and len(data) >= 2:
                        execute_mouse({'type': 'down', 'button': 'right' if data[1] == 2 else 'left'})
                    elif opcode == 0x04 and len(data) >= 2:
                        execute_mouse({'type': 'up', 'button': 'right' if data[1] == 2 else 'left'})
                    elif opcode == 0x05 and len(data) >= 3:
                        delta, = struct.unpack('<h', data[1:3])
                        execute_mouse({'type': 'scroll', 'delta': delta})
                    elif opcode == 0x06 and len(data) >= 5:
                        raw_x, raw_y = struct.unpack('<HH', data[1:5])
                        execute_mouse({'type': 'move_abs', 'x': raw_x / 65535.0, 'y': raw_y / 65535.0})
                    continue

                # Text commands & Discovery
                msg = data.decode('utf-8', errors='ignore').strip()
                if msg == 'SCRSHARE_DISCOVER':
                    reply = json.dumps({
                        'type': 'SCRSHARE_HOST',
                        'name': socket.gethostname(),
                        'ip': local_ip,
                        'port': HTTP_PORT,
                        'os': sys.platform
                    })
                    sock.sendto(reply.encode('utf-8'), addr)
                elif msg.startswith('M:'):
                    parts = msg[2:].split(',')
                    if len(parts) == 2:
                        execute_mouse({'type': 'move', 'dx': float(parts[0]), 'dy': float(parts[1])})
                elif msg.startswith('MA:'):
                    parts = msg[3:].split(',')
                    if len(parts) == 2:
                        execute_mouse({'type': 'move_abs', 'x': float(parts[0]), 'y': float(parts[1])})
                elif msg.startswith('C:'):
                    execute_mouse({'type': 'click', 'button': msg[2:]})
                elif msg.startswith('MD:'):
                    execute_mouse({'type': 'down', 'button': msg[3:]})
                elif msg.startswith('MU:'):
                    execute_mouse({'type': 'up', 'button': msg[3:]})
                elif msg.startswith('S:'):
                    execute_mouse({'type': 'scroll', 'delta': int(msg[2:])})
                elif msg.startswith('K:'):
                    execute_action(msg[2:])
                elif msg.startswith('Q:'):
                    perform_search(msg[2:])
                elif msg.startswith('SEEK:'):
                    try:
                        r = float(msg[5:])
                        execute_seek(r)
                    except Exception:
                        pass
            except Exception as pkt_err:
                print(f"[UDP Packet Warning] {pkt_err}", flush=True)

    except Exception as e:
        print(f"[UDP Error] Discovery socket error: {e}", flush=True)

def main():
    ensure_youtube_tv_extension()
    local_ip = get_local_ip()
    print("=" * 60)
    print("  SCRSHARE - PC RECEIVER (YOUTUBE TV LAUNCHER)")
    print("=" * 60)
    print(f"  PC Local Wi-Fi IP : http://{local_ip}:{HTTP_PORT}")
    print(f"  Hostname          : {socket.gethostname()}")
    print(f"  Discovery Port    : {UDP_PORT} (UDP)")
    print("=" * 60)
    print("  Status: READY and waiting for phone commands...")
    print("  Press Ctrl+C to exit.")
    print("=" * 60)

    # Start UDP discovery thread
    udp_thread = threading.Thread(target=start_udp_discovery_responder, args=(local_ip,), daemon=True)
    udp_thread.start()

    # Start HTTP server
    server = HTTPServer(('0.0.0.0', HTTP_PORT), RequestHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        server.server_close()

if __name__ == '__main__':
    main()
