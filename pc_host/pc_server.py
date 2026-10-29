#!/usr/bin/env python3
"""
ScrShare PC Host Companion Server
Zero external dependencies - Uses Python standard library.
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
from http.server import HTTPServer, BaseHTTPRequestHandler

HTTP_PORT = 8080
UDP_PORT = 8088

def get_local_ip():
    s = socket.socket(socket.AF_AF_INET if hasattr(socket, 'AF_AF_INET') else socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # Doesn't actually have to be reachable
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = '127.0.0.1'
    finally:
        s.close()
    return ip

def launch_url_in_browser(url):
    print(f"[LAUNCH] Opening URL on default browser: {url}", flush=True)
    try:
        if sys.platform.startswith('win'):
            # cmd start ensures system default browser is used cleanly
            os.system(f'start "" "{url}"')
        elif sys.platform.startswith('darwin'):
            subprocess.run(['open', url])
        else:
            subprocess.run(['xdg-open', url])
        return True
    except Exception as e:
        print(f"[ERROR] Could not launch browser: {e}", flush=True)
        try:
            webbrowser.open(url, new=2)
            return True
        except Exception:
            return False

def execute_action(action):
    action_key = action.lower().strip()
    print(f"[ACTION] Executing: {action_key}", flush=True)
    if sys.platform.startswith('win'):
        # 1. Try instant Windows user32 keybd_event (0ms latency, no focus loss)
        try:
            import ctypes
            user32 = ctypes.windll.user32

            # Virtual key codes
            vk_map = {
                'fullscreen': 0x7A,      # VK_F11
                'play_pause': 0x20,      # VK_SPACE
                'space': 0x20,           # VK_SPACE
                'mute': 0x4D,            # 'M' key (YouTube mute)
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
                'back': 0x08,            # VK_BACK (Backspace - YouTube TV Back action)
                'backspace': 0x08,
                'escape': 0x1B,          # VK_ESCAPE
                'volume_up': 0x26,       # Up arrow (YouTube volume up)
                'volume_down': 0x28,     # Down arrow (YouTube volume down)
            }

            vk = vk_map.get(action_key)
            if vk is not None:
                user32.keybd_event(vk, 0, 0, 0)      # Key down
                user32.keybd_event(vk, 0, 2, 0)      # Key up
                return True
        except Exception as e:
            print(f"[ERROR] ctypes keybd_event error: {e}", flush=True)

        # 2. Fallback to PowerShell SendKeys
        key_map = {
            'fullscreen': '{F11}',
            'play_pause': ' ',
            'mute': 'm',
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

class RequestHandler(BaseHTTPRequestHandler):
    def _send_cors_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')

    def do_OPTIONS(self):
        self.send_response(200)
        self._send_cors_headers()
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
            # Allow launching via GET query parameter: /launch?url=...
            target_url = 'https://www.youtube.com/tv'
            if 'url=' in self.path:
                try:
                    import urllib.parse
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
        elif self.path.startswith('/action'):
            action = payload.get('command', '')
            success = execute_action(action)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self._send_cors_headers()
            self.end_headers()
            self.wfile.write(json.dumps({'success': success, 'action': action}).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Clean logging
        sys.stdout.write(f"[HTTP] {self.address_string()} - {format % args}\n")

def start_udp_discovery_responder(local_ip):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(('0.0.0.0', UDP_PORT))
        while True:
            data, addr = sock.recvfrom(1024)
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
    except Exception as e:
        print(f"[UDP Warning] Discovery socket error: {e}")

def main():
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
