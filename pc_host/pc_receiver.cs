using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Globalization;
using Microsoft.Win32;

namespace ScrShare
{
    public enum ThemePreference
    {
        System,
        Dark,
        Light
    }

    static class Program
    {
        [DllImport("user32.dll")]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("uxtheme.dll", EntryPoint = "#135", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern int SetPreferredAppMode(int appMode);

        private const int SW_RESTORE = 9;

        [STAThread]
        static void Main(string[] args)
        {
            try { SetPreferredAppMode(2); } catch { }

            bool createdNew = true;
            Mutex mutex = null;
            try
            {
                mutex = new Mutex(true, "Local\\ScrShare_PC_Receiver_SingleInstance", out createdNew);
            }
            catch (AbandonedMutexException)
            {
                createdNew = true;
            }
            catch { }

            if (!createdNew)
            {
                IntPtr hWnd = FindWindow(null, "ScrShare - PC Remote Receiver");
                if (hWnd != IntPtr.Zero)
                {
                    ShowWindow(hWnd, SW_RESTORE);
                    SetForegroundWindow(hWnd);
                    return;
                }

                // If window not found, kill any stale background instances so the UI opens cleanly
                try
                {
                    var current = Process.GetCurrentProcess();
                    foreach (var p in Process.GetProcessesByName("pc_receiver"))
                    {
                        if (p.Id != current.Id)
                        {
                            p.Kill();
                            p.WaitForExit(1000);
                        }
                    }
                }
                catch { }

                try
                {
                    if (mutex != null) mutex.Dispose();
                    mutex = new Mutex(true, "Local\\ScrShare_PC_Receiver_SingleInstance", out createdNew);
                }
                catch { }
            }

            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            {
                try
                {
                    File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "crash.log"), e.ExceptionObject.ToString());
                }
                catch { }
            };

            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += (s, e) =>
            {
                try
                {
                    File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "crash.log"), e.Exception.ToString());
                }
                catch { }
            };

            try
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                bool startMinimized = false;
                foreach (var arg in args)
                {
                    if (arg.Equals("--minimized", StringComparison.OrdinalIgnoreCase) ||
                        arg.Equals("--tray", StringComparison.OrdinalIgnoreCase) ||
                        arg.Equals("--startup", StringComparison.OrdinalIgnoreCase))
                    {
                        startMinimized = true;
                    }
                }

                Application.Run(new MainForm(startMinimized));
            }
            catch (Exception ex)
            {
                try
                {
                    File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "crash.log"), ex.ToString());
                }
                catch { }
                MessageBox.Show(ex.ToString(), "ScrShare Receiver Crash", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                if (mutex != null)
                {
                    try { mutex.ReleaseMutex(); } catch { }
                    mutex.Dispose();
                }
            }
        }
    }

    public class MainForm : Form
    {
        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;

        [DllImport("user32.dll")]
        private static extern bool AllowSetForegroundWindow(int dwProcessId);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, UIntPtr dwExtraInfo);

        private const uint MOUSEEVENTF_MOVE = 0x0001;
        private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        private const uint MOUSEEVENTF_LEFTUP = 0x0004;
        private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
        private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
        private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
        private const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
        private const uint MOUSEEVENTF_WHEEL = 0x0800;

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT
        {
            public int x;
            public int y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CURSORINFO
        {
            public int cbSize;
            public int flags;
            public IntPtr hCursor;
            public POINT ptScreenPos;
        }

        [DllImport("user32.dll")]
        private static extern bool GetCursorInfo(out CURSORINFO pci);

        [DllImport("user32.dll")]
        private static extern bool DrawIcon(IntPtr hDC, int X, int Y, IntPtr hIcon);

        private const int CURSOR_SHOWING = 0x00000001;

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT
        {
            public uint type;
            public InputUnion u;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion
        {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT
        {
            public ushort wVk;
            public ushort wScan;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT
        {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        private const uint INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_UNICODE = 0x0004;

        [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        private static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

        [DllImport("uxtheme.dll", EntryPoint = "#135", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern int SetPreferredAppMode(int appMode);

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

        private const int DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;
        private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

        private const int HttpPort = 8080;
        private const int UdpPort = 8088;
        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string AppRegistryName = "ScrShareReceiver";
        private const string SettingsKeyPath = @"Software\ScrShare";
        private const string ExtensionId = "jldjbkccldgbegjpggphaeikombjmnkh";
        private const string ExtensionWebStoreUrl = "https://chromewebstore.google.com/detail/youtube-tv-on-pc/jldjbkccldgbegjpggphaeikombjmnkh";
        private const string ExtensionUpdateUrl = "https://clients2.google.com/service/update2/crx";

        private TcpListener _httpListener;
        private UdpClient _udpListener;
        private Thread _httpThread;
        private Thread _udpThread;
        private volatile bool _isRunning = true;
        private bool _reallyExit = false;

        private string _localIp = "127.0.0.1";
        private readonly bool _startMinimized = false;
        private readonly List<string> _pendingLogs = new List<string>();

        // Theme State
        private ThemePreference _currentPreference = ThemePreference.System;
        private bool _isDarkActive = true;

        // UI Controls
        private NotifyIcon _notifyIcon;
        private ContextMenuStrip _trayMenu;
        private Panel _pnlHeader;
        private Label _lblTitle;
        private Label _lblSub;
        private Button _btnTheme;

        private Panel _cardStatus;
        private Panel _pnlDot;
        private Label _lblStatus;
        private Label _lblIpLabel;
        private Label _lblIp;
        private Button _btnCopyIp;
        private Label _lblHostLabel;
        private Label _lblHost;

        private Panel _cardSettings;
        private CheckBox _chkStartup;
        private Label _lblStartupHint;

        private Panel _pnlActions;
        private Button _btnTestLaunch;
        private Button _btnExtension;
        private Button _btnMinimizeTray;
        private Button _btnClearLog;

        private Panel _pnlLogHeader;
        private Label _lblLogTitle;
        private Panel _cardLog;
        private RichTextBox _rtbLog;

        // Media tracking state
        private bool _mediaActive = false;
        private bool _mediaPlaying = false;
        private double _mediaPosition = 0;
        private double _mediaDuration = 300;
        private string _mediaTitle = "";
        private DateTime _lastMediaTick = DateTime.UtcNow;

        private void UpdateMediaTick()
        {
            if (_mediaActive && _mediaPlaying)
            {
                var now = DateTime.UtcNow;
                double delta = (now - _lastMediaTick).TotalSeconds;
                _lastMediaTick = now;
                _mediaPosition += delta;
                if (_mediaPosition > _mediaDuration) _mediaPosition = _mediaDuration;
            }
            else
            {
                _lastMediaTick = DateTime.UtcNow;
            }
        }

        private void ExecuteSeek(double ratio, double position)
        {
            _mediaActive = true;
            if (position >= 0)
            {
                _mediaPosition = Math.Max(0, Math.Min(_mediaDuration, position));
            }
            else
            {
                _mediaPosition = Math.Max(0, Math.Min(_mediaDuration, ratio * _mediaDuration));
            }
            _lastMediaTick = DateTime.UtcNow;

            EnsureBrowserOrYouTubeForeground();

            // Direct seek via YouTube hotkeys 0..9 (jumps to 0%, 10%, 20%, ... 90%)
            int percentBucket = (int)Math.Round(Math.Max(0.0, Math.Min(1.0, ratio)) * 9.0);
            byte keyDigit = (byte)(0x30 + percentBucket); // 0x30 = '0'
            keybd_event(keyDigit, 0, 0, 0);
            keybd_event(keyDigit, 0, KEYEVENTF_KEYUP, 0);
            AddLog("[SEEK] Sought YouTube to " + (percentBucket * 10) + "% (approx " + (int)_mediaPosition + "s)");
        }

        public MainForm(bool startMinimized)
        {
            _startMinimized = startMinimized;
            InitializeComponent();
            _localIp = GetLocalIp();

            _lblIp.Text = "http://" + _localIp + ":" + HttpPort;
            _lblHost.Text = Environment.MachineName + " (" + Environment.OSVersion.VersionString + ")";

            // Sync startup checkbox with registry
            _chkStartup.Checked = IsStartupEnabled();
            _chkStartup.CheckedChanged += ChkStartup_CheckedChanged;

            // Load saved theme preference
            _currentPreference = LoadThemePreference();
            UpdateThemeFromPreference();

            // Listen for system theme changes in real-time
            try
            {
                SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
            }
            catch { }

            if (_startMinimized)
            {
                WindowState = FormWindowState.Minimized;
                ShowInTaskbar = false;
                Opacity = 0;
            }
        }

        private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            if (_currentPreference == ThemePreference.System)
            {
                if (InvokeRequired)
                {
                    try { BeginInvoke(new Action(UpdateThemeFromPreference)); } catch { }
                }
                else
                {
                    UpdateThemeFromPreference();
                }
            }
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);

            lock (_pendingLogs)
            {
                foreach (var m in _pendingLogs)
                {
                    string time = DateTime.Now.ToString("HH:mm:ss");
                    _rtbLog.AppendText("[" + time + "] " + m + Environment.NewLine);
                }
                _pendingLogs.Clear();
            }

            StartServers();
            AddLog("ScrShare PC Receiver initialized.");
            AddLog("Local IP: " + _localIp + " | HTTP Port: " + HttpPort + " | Discovery UDP: " + UdpPort);
            EnsureYouTubeTvExtensionInstalled();

            ApplyTheme(_isDarkActive);
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            ApplyImmersiveDarkMode(_isDarkActive);
            ApplyScrollbarTheme(_isDarkActive);
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            ApplyTheme(_isDarkActive);
            if (_startMinimized)
            {
                Hide();
                Opacity = 1;
                ShowInTaskbar = true;
            }
        }

        private void InitializeComponent()
        {
            Text = "ScrShare - PC Remote Receiver";
            Size = new Size(530, 630);
            MinimumSize = new Size(490, 570);
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9.5f, FontStyle.Regular);
            DoubleBuffered = true;

            try
            {
                string iconPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "app_icon.ico");
                if (File.Exists(iconPath))
                {
                    Icon = new Icon(iconPath);
                }
                else
                {
                    Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                }
            }
            catch { }

            // Tray Menu
            _trayMenu = new ContextMenuStrip();
            var itemOpen = new ToolStripMenuItem("Open ScrShare Receiver");
            itemOpen.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
            itemOpen.Click += (s, e) => RestoreFromTray();

            var itemLaunch = new ToolStripMenuItem("Launch YouTube TV");
            itemLaunch.Click += (s, e) => LaunchBrowser("https://www.youtube.com/tv");

            var itemExit = new ToolStripMenuItem("Exit");
            itemExit.Click += (s, e) =>
            {
                _reallyExit = true;
                Close();
            };

            _trayMenu.Items.Add(itemOpen);
            _trayMenu.Items.Add(itemLaunch);
            _trayMenu.Items.Add(new ToolStripSeparator());
            _trayMenu.Items.Add(itemExit);

            _notifyIcon = new NotifyIcon();
            _notifyIcon.Icon = Icon ?? SystemIcons.Application;
            _notifyIcon.Text = "ScrShare PC Receiver";
            _notifyIcon.Visible = true;
            _notifyIcon.ContextMenuStrip = _trayMenu;
            _notifyIcon.DoubleClick += (s, e) => RestoreFromTray();

            // Root Layout
            var pnlMain = new Panel { Dock = DockStyle.Fill, Padding = new Padding(18) };
            Controls.Add(pnlMain);

            // 1. Header with Theme Button
            _pnlHeader = new Panel { Dock = DockStyle.Top, Height = 64, BackColor = Color.Transparent };
            _lblTitle = new Label
            {
                Text = "ScrShare PC Receiver",
                Font = new Font("Segoe UI", 16f, FontStyle.Bold),
                Location = new Point(0, 4),
                AutoSize = true
            };
            _lblSub = new Label
            {
                Text = "Remote receiver for YouTube TV",
                Font = new Font("Segoe UI", 9f),
                Location = new Point(1, 36),
                AutoSize = true,
                MaximumSize = new Size(330, 0)
            };

            _btnTheme = new Button
            {
                Height = 32,
                Width = 145,
                Location = new Point(340, 10),
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 8.5f, FontStyle.Bold),
                Cursor = Cursors.Hand
            };
            _btnTheme.Click += (s, e) => CycleThemePreference();

            _pnlHeader.Controls.Add(_lblTitle);
            _pnlHeader.Controls.Add(_lblSub);
            _pnlHeader.Controls.Add(_btnTheme);

            // 2. Status Card
            _cardStatus = CreateCardPanel(110);
            _cardStatus.Dock = DockStyle.Top;

            _pnlDot = new Panel
            {
                Size = new Size(12, 12),
                Location = new Point(14, 16)
            };
            _pnlDot.Paint += (s, pe) =>
            {
                pe.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                using (var b = new SolidBrush(Color.FromArgb(46, 213, 115)))
                {
                    pe.Graphics.FillEllipse(b, 0, 0, 11, 11);
                }
            };

            _lblStatus = new Label
            {
                Text = "ONLINE - Ready for phone connections",
                Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
                ForeColor = Color.FromArgb(46, 213, 115),
                Location = new Point(32, 12),
                AutoSize = true
            };

            _lblIpLabel = new Label
            {
                Text = "PC Local IP:",
                Location = new Point(14, 42),
                AutoSize = true
            };
            _lblIp = new Label
            {
                Text = "Detecting IP...",
                Font = new Font("Consolas", 10.5f, FontStyle.Bold),
                Location = new Point(96, 41),
                AutoSize = true
            };

            _btnCopyIp = CreateSmallButton("Copy", new Point(310, 38), 54, 26);
            _btnCopyIp.Click += (s, e) =>
            {
                try
                {
                    Clipboard.SetText(_lblIp.Text);
                    _btnCopyIp.Text = "Copied!";
                    var t = new System.Windows.Forms.Timer { Interval = 1500 };
                    t.Tick += (ts, te) =>
                    {
                        _btnCopyIp.Text = "Copy";
                        t.Stop();
                        t.Dispose();
                    };
                    t.Start();
                }
                catch { }
            };

            _lblHostLabel = new Label
            {
                Text = "Hostname:",
                Location = new Point(14, 72),
                AutoSize = true
            };
            _lblHost = new Label
            {
                Text = "PC",
                Font = new Font("Segoe UI", 9.5f),
                Location = new Point(96, 72),
                AutoSize = true
            };

            _cardStatus.Controls.Add(_pnlDot);
            _cardStatus.Controls.Add(_lblStatus);
            _cardStatus.Controls.Add(_lblIpLabel);
            _cardStatus.Controls.Add(_lblIp);
            _cardStatus.Controls.Add(_btnCopyIp);
            _cardStatus.Controls.Add(_lblHostLabel);
            _cardStatus.Controls.Add(_lblHost);

            // 3. Settings Card (Startup Checkbox)
            _cardSettings = CreateCardPanel(68);
            _cardSettings.Dock = DockStyle.Top;

            _chkStartup = new CheckBox
            {
                Text = "launch at startup",
                Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
                Location = new Point(16, 12),
                AutoSize = true,
                Cursor = Cursors.Hand
            };

            _lblStartupHint = new Label
            {
                Text = "Automatically runs in the background when your computer boots up",
                Font = new Font("Segoe UI", 8.5f),
                Location = new Point(36, 38),
                AutoSize = true
            };

            _cardSettings.Controls.Add(_chkStartup);
            _cardSettings.Controls.Add(_lblStartupHint);

            // 4. Quick Action Buttons
            _pnlActions = new Panel { Dock = DockStyle.Top, Height = 48, Padding = new Padding(0, 8, 0, 0) };
            _btnTestLaunch = new Button
            {
                Text = "Open YouTube TV",
                Height = 36,
                Width = 142,
                BackColor = Color.FromArgb(235, 32, 38),
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 9.5f, FontStyle.Bold),
                Cursor = Cursors.Hand,
                Location = new Point(0, 6)
            };
            _btnTestLaunch.FlatAppearance.BorderSize = 0;
            _btnTestLaunch.Click += (s, e) => LaunchBrowser("https://www.youtube.com/tv");

            _btnExtension = new Button
            {
                Text = "TV Extension",
                Height = 36,
                Width = 110,
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 9f, FontStyle.Bold),
                Cursor = Cursors.Hand,
                Location = new Point(148, 6)
            };
            _btnExtension.Click += (s, e) =>
            {
                AddLog("[EXTENSION] Opening Chrome Web Store for 'YouTube TV On PC'...");
                LaunchBrowser(ExtensionWebStoreUrl);
            };

            _btnMinimizeTray = new Button
            {
                Text = "Minimize to Tray",
                Height = 36,
                Width = 120,
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 9f),
                Cursor = Cursors.Hand,
                Location = new Point(264, 6)
            };
            _btnMinimizeTray.Click += (s, e) =>
            {
                Hide();
                _notifyIcon.ShowBalloonTip(1500, "ScrShare PC Receiver", "Running in the system tray.", ToolTipIcon.Info);
            };

            _btnClearLog = new Button
            {
                Text = "Clear Log",
                Height = 36,
                Width = 80,
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 9f),
                Cursor = Cursors.Hand,
                Location = new Point(390, 6)
            };
            _btnClearLog.Click += (s, e) => _rtbLog.Clear();

            _pnlActions.Controls.Add(_btnTestLaunch);
            _pnlActions.Controls.Add(_btnExtension);
            _pnlActions.Controls.Add(_btnMinimizeTray);
            _pnlActions.Controls.Add(_btnClearLog);

            // 5. Activity Log Section
            _pnlLogHeader = new Panel { Dock = DockStyle.Top, Height = 28 };
            _lblLogTitle = new Label
            {
                Text = "Activity Log:",
                Font = new Font("Segoe UI", 9.5f, FontStyle.Bold),
                Location = new Point(0, 8),
                AutoSize = true
            };
            _pnlLogHeader.Controls.Add(_lblLogTitle);

            _rtbLog = new RichTextBox
            {
                Dock = DockStyle.Fill,
                Font = new Font("Consolas", 9f),
                BorderStyle = BorderStyle.None,
                ReadOnly = true,
                ScrollBars = RichTextBoxScrollBars.Vertical
            };
            _rtbLog.HandleCreated += (s, e) => ApplyScrollbarTheme(_isDarkActive);

            _cardLog = new Panel
            {
                Dock = DockStyle.Fill,
                Padding = new Padding(8)
            };
            _cardLog.Controls.Add(_rtbLog);

            // Spacing helpers
            var sep1 = new Panel { Dock = DockStyle.Top, Height = 10 };
            var sep2 = new Panel { Dock = DockStyle.Top, Height = 10 };
            var sep3 = new Panel { Dock = DockStyle.Top, Height = 6 };

            // Assemble controls in docking order (bottom to top)
            pnlMain.Controls.Add(_cardLog);
            pnlMain.Controls.Add(_pnlLogHeader);
            pnlMain.Controls.Add(sep3);
            pnlMain.Controls.Add(_pnlActions);
            pnlMain.Controls.Add(sep2);
            pnlMain.Controls.Add(_cardSettings);
            pnlMain.Controls.Add(sep1);
            pnlMain.Controls.Add(_cardStatus);
            pnlMain.Controls.Add(_pnlHeader);
        }

        private Panel CreateCardPanel(int height)
        {
            var p = new Panel
            {
                Height = height,
                Padding = new Padding(12)
            };
            p.Paint += (s, pe) =>
            {
                pe.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                Color borderColor = _isDarkActive ? Color.FromArgb(46, 50, 68) : Color.FromArgb(215, 218, 230);
                using (var pen = new Pen(borderColor, 1))
                {
                    pe.Graphics.DrawRectangle(pen, 0, 0, p.Width - 1, p.Height - 1);
                }
            };
            return p;
        }

        private Button CreateSmallButton(string text, Point loc, int w, int h)
        {
            var b = new Button
            {
                Text = text,
                Location = loc,
                Size = new Size(w, h),
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 8.5f),
                Cursor = Cursors.Hand
            };
            return b;
        }

        // ==================== THEME MANAGEMENT ====================
        private void CycleThemePreference()
        {
            switch (_currentPreference)
            {
                case ThemePreference.System:
                    _currentPreference = ThemePreference.Dark;
                    break;
                case ThemePreference.Dark:
                    _currentPreference = ThemePreference.Light;
                    break;
                case ThemePreference.Light:
                    _currentPreference = ThemePreference.System;
                    break;
            }

            SaveThemePreference(_currentPreference);
            UpdateThemeFromPreference();
        }

        private void UpdateThemeFromPreference()
        {
            bool effectiveDark = (_currentPreference == ThemePreference.System)
                ? GetSystemIsDark()
                : (_currentPreference == ThemePreference.Dark);

            ApplyTheme(effectiveDark);
        }

        private void ApplyTheme(bool isDark)
        {
            _isDarkActive = isDark;

            Color bg = isDark ? Color.FromArgb(20, 21, 30) : Color.FromArgb(244, 245, 249);
            Color cardBg = isDark ? Color.FromArgb(28, 30, 42) : Color.FromArgb(255, 255, 255);
            Color textPrimary = isDark ? Color.FromArgb(255, 255, 255) : Color.FromArgb(24, 26, 36);
            Color textSecondary = isDark ? Color.FromArgb(160, 165, 185) : Color.FromArgb(110, 115, 130);
            Color logBg = isDark ? Color.FromArgb(13, 14, 20) : Color.FromArgb(255, 255, 255);
            Color logText = isDark ? Color.FromArgb(160, 230, 160) : Color.FromArgb(20, 24, 34);
            Color btnSecBg = isDark ? Color.FromArgb(36, 38, 52) : Color.FromArgb(238, 240, 246);
            Color btnSecText = isDark ? Color.FromArgb(220, 224, 235) : Color.FromArgb(40, 45, 58);
            Color btnSecBorder = isDark ? Color.FromArgb(55, 58, 78) : Color.FromArgb(210, 215, 228);

            BackColor = bg;
            ForeColor = textPrimary;

            _lblTitle.ForeColor = textPrimary;
            _lblSub.ForeColor = textSecondary;

            _cardStatus.BackColor = cardBg;
            _lblIpLabel.ForeColor = textSecondary;
            _lblIp.ForeColor = textPrimary;
            _lblHostLabel.ForeColor = textSecondary;
            _lblHost.ForeColor = textPrimary;

            _cardSettings.BackColor = cardBg;
            _chkStartup.ForeColor = textPrimary;
            _lblStartupHint.ForeColor = textSecondary;

            _lblLogTitle.ForeColor = textPrimary;
            _cardLog.BackColor = logBg;
            _rtbLog.BackColor = logBg;
            _rtbLog.ForeColor = logText;

            // Secondary Buttons
            _btnCopyIp.BackColor = isDark ? Color.FromArgb(40, 44, 60) : Color.FromArgb(236, 239, 246);
            _btnCopyIp.ForeColor = textPrimary;
            _btnCopyIp.FlatAppearance.BorderColor = btnSecBorder;

            _btnExtension.BackColor = isDark ? Color.FromArgb(32, 36, 50) : Color.FromArgb(236, 245, 255);
            _btnExtension.ForeColor = isDark ? Color.FromArgb(90, 200, 255) : Color.FromArgb(0, 120, 215);
            _btnExtension.FlatAppearance.BorderColor = isDark ? Color.FromArgb(50, 90, 140) : Color.FromArgb(170, 205, 245);

            _btnMinimizeTray.BackColor = btnSecBg;
            _btnMinimizeTray.ForeColor = btnSecText;
            _btnMinimizeTray.FlatAppearance.BorderColor = btnSecBorder;

            _btnClearLog.BackColor = btnSecBg;
            _btnClearLog.ForeColor = btnSecText;
            _btnClearLog.FlatAppearance.BorderColor = btnSecBorder;

            // Theme Button Text
            string themeLabel = "";
            switch (_currentPreference)
            {
                case ThemePreference.System:
                    themeLabel = isDark ? "Auto (Dark)" : "Auto (Light)";
                    break;
                case ThemePreference.Dark:
                    themeLabel = "Dark 🌙";
                    break;
                case ThemePreference.Light:
                    themeLabel = "Light ☀️";
                    break;
            }
            _btnTheme.Text = "Theme: " + themeLabel;
            _btnTheme.BackColor = btnSecBg;
            _btnTheme.ForeColor = btnSecText;
            _btnTheme.FlatAppearance.BorderColor = btnSecBorder;

            // Tray Menu
            _trayMenu.BackColor = cardBg;
            _trayMenu.ForeColor = textPrimary;

            _cardStatus.Invalidate();
            _cardSettings.Invalidate();
            _cardLog.Invalidate();

            ApplyImmersiveDarkMode(isDark);
            ApplyScrollbarTheme(isDark);
        }

        private void ApplyImmersiveDarkMode(bool isDark)
        {
            try
            {
                int useDark = isDark ? 1 : 0;
                int res = DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, ref useDark, sizeof(int));
                if (res != 0)
                {
                    DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, ref useDark, sizeof(int));
                }
            }
            catch { }
        }

        private void ApplyScrollbarTheme(bool isDark)
        {
            try
            {
                SetPreferredAppMode(isDark ? 2 : 3);
            }
            catch { }

            try
            {
                if (_rtbLog != null && _rtbLog.IsHandleCreated)
                {
                    SetWindowTheme(_rtbLog.Handle, isDark ? "DarkMode_Explorer" : "Explorer", null);
                }
            }
            catch { }
        }

        private static bool GetSystemIsDark()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", false))
                {
                    if (key != null)
                    {
                        object val = key.GetValue("AppsUseLightTheme");
                        if (val != null && val is int)
                        {
                            return ((int)val) == 0;
                        }
                    }
                }
            }
            catch { }
            return true;
        }

        private ThemePreference LoadThemePreference()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(SettingsKeyPath, false))
                {
                    if (key != null)
                    {
                        string val = key.GetValue("ThemeMode") as string;
                        if (!string.IsNullOrEmpty(val))
                        {
                            if (val.Equals("Dark", StringComparison.OrdinalIgnoreCase)) return ThemePreference.Dark;
                            if (val.Equals("Light", StringComparison.OrdinalIgnoreCase)) return ThemePreference.Light;
                            if (val.Equals("System", StringComparison.OrdinalIgnoreCase)) return ThemePreference.System;
                        }
                    }
                }
            }
            catch { }

            try
            {
                string cfg = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "theme.cfg");
                if (File.Exists(cfg))
                {
                    string val = File.ReadAllText(cfg).Trim();
                    if (val.Equals("Dark", StringComparison.OrdinalIgnoreCase)) return ThemePreference.Dark;
                    if (val.Equals("Light", StringComparison.OrdinalIgnoreCase)) return ThemePreference.Light;
                    if (val.Equals("System", StringComparison.OrdinalIgnoreCase)) return ThemePreference.System;
                }
            }
            catch { }

            return ThemePreference.System;
        }

        private void SaveThemePreference(ThemePreference pref)
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(SettingsKeyPath))
                {
                    if (key != null)
                    {
                        key.SetValue("ThemeMode", pref.ToString(), RegistryValueKind.String);
                    }
                }
            }
            catch { }

            try
            {
                string cfg = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "theme.cfg");
                File.WriteAllText(cfg, pref.ToString());
            }
            catch { }
        }

        private void RestoreFromTray()
        {
            Show();
            WindowState = FormWindowState.Normal;
            BringToFront();
            Activate();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing && !_reallyExit)
            {
                e.Cancel = true;
                Hide();
                _notifyIcon.ShowBalloonTip(1500, "ScrShare Receiver", "Receiver is still running in the tray. Right-click the icon to exit.", ToolTipIcon.Info);
                return;
            }

            try
            {
                SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            }
            catch { }

            _isRunning = false;
            if (_httpListener != null)
            {
                try { _httpListener.Stop(); } catch { }
            }
            if (_udpListener != null)
            {
                try { _udpListener.Close(); } catch { }
            }
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            base.OnFormClosing(e);
        }

        // ==================== AUTOSTART REGISTRY ====================
        private bool IsStartupEnabled()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false))
                {
                    if (key != null)
                    {
                        var val = key.GetValue(AppRegistryName) as string;
                        if (!string.IsNullOrEmpty(val))
                        {
                            string clean = val.Trim('\"');
                            if (string.Equals(clean, Application.ExecutablePath, StringComparison.OrdinalIgnoreCase))
                                return true;
                        }
                    }
                }
            }
            catch { }

            string startupLnk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "ScrShareReceiver.lnk");
            return File.Exists(startupLnk);
        }

        private void ChkStartup_CheckedChanged(object sender, EventArgs e)
        {
            bool enable = _chkStartup.Checked;
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKeyPath, true))
                {
                    if (key != null)
                    {
                        if (enable)
                        {
                            key.SetValue(AppRegistryName, "\"" + Application.ExecutablePath + "\" --minimized");
                            AddLog("[STARTUP] Enabled: ScrShare will launch at Windows startup.");
                        }
                        else
                        {
                            key.DeleteValue(AppRegistryName, false);
                            AddLog("[STARTUP] Disabled: Removed from Windows startup.");
                        }
                    }
                }

                string startupLnk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "ScrShareReceiver.lnk");
                if (!enable && File.Exists(startupLnk))
                {
                    try { File.Delete(startupLnk); } catch { }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("Could not update startup registry: " + ex.Message, "ScrShare", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        // ==================== NETWORK LISTENERS ====================
        private void StartServers()
        {
            _httpThread = new Thread(RunHttpServer) { IsBackground = true };
            _httpThread.Start();

            _udpThread = new Thread(RunUdpDiscovery) { IsBackground = true };
            _udpThread.Start();
        }

        private void RunHttpServer()
        {
            try
            {
                _httpListener = new TcpListener(IPAddress.Any, HttpPort);
                _httpListener.Start();

                while (_isRunning)
                {
                    TcpClient client = _httpListener.AcceptTcpClient();
                    ThreadPool.QueueUserWorkItem(HandleHttpClient, client);
                }
            }
            catch (SocketException ex)
            {
                if (_isRunning)
                {
                    AddLog("[HTTP Error] Port " + HttpPort + ": " + ex.Message);
                    UpdateStatus("PORT CONFLICT: Port " + HttpPort + " is in use", false);
                }
            }
            catch (Exception ex)
            {
                AddLog("[HTTP Error] " + ex.Message);
                UpdateStatus("HTTP Error: " + ex.Message, false);
            }
        }

        private void HandleHttpClient(object state)
        {
            var client = (TcpClient)state;
            try
            {
                try { client.NoDelay = true; } catch { }
                using (client)
                using (var stream = client.GetStream())
                using (var reader = new StreamReader(stream, Encoding.UTF8))
                {
                    string reqLine = reader.ReadLine();
                    if (string.IsNullOrEmpty(reqLine)) return;

                    var parts = reqLine.Split(' ');
                    if (parts.Length < 2) return;

                    string method = parts[0].ToUpperInvariant();
                    string rawPath = parts[1];

                    int contentLength = 0;
                    string line;
                    while (!string.IsNullOrEmpty(line = reader.ReadLine()))
                    {
                        if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                        {
                            int.TryParse(line.Substring(15).Trim(), out contentLength);
                        }
                    }

                    string body = "";
                    if (contentLength > 0)
                    {
                        char[] buf = new char[contentLength];
                        int read = 0;
                        while (read < contentLength)
                        {
                            int r = reader.Read(buf, read, contentLength - read);
                            if (r <= 0) break;
                            read += r;
                        }
                        body = new string(buf, 0, read);
                    }

                    string uriPath = rawPath;
                    string query = "";
                    int qIdx = rawPath.IndexOf('?');
                    if (qIdx >= 0)
                    {
                        uriPath = rawPath.Substring(0, qIdx);
                        query = rawPath.Substring(qIdx + 1);
                    }

                    if (method == "OPTIONS")
                    {
                        SendHttpResponse(stream, 200, "OK", "application/json", "{}");
                    }
                    else if (uriPath == "/" || uriPath == "/status")
                    {
                        string json = "{\"status\":\"online\",\"name\":\"" + EscapeJson(Environment.MachineName) +
                                      "\",\"ip\":\"" + _localIp + "\",\"port\":" + HttpPort + ",\"os\":\"windows\"}";
                        SendHttpResponse(stream, 200, "OK", "application/json", json);
                    }
                    else if (uriPath == "/launch")
                    {
                        string targetUrl = "https://www.youtube.com/tv";
                        if (!string.IsNullOrEmpty(body))
                        {
                            string parsed = ExtractJsonString(body, "url");
                            if (!string.IsNullOrEmpty(parsed)) targetUrl = parsed;
                        }
                        else if (!string.IsNullOrEmpty(query))
                        {
                            foreach (var p in query.Split('&'))
                            {
                                if (p.StartsWith("url="))
                                {
                                    targetUrl = Uri.UnescapeDataString(p.Substring(4));
                                    break;
                                }
                            }
                        }

                        AddLog("[LAUNCH] Opening: " + targetUrl);
                        LaunchBrowser(targetUrl);

                        string json = "{\"success\":true,\"url\":\"" + EscapeJson(targetUrl) + "\"}";
                        SendHttpResponse(stream, 200, "OK", "application/json", json);
                    }
                    else if (uriPath == "/search")
                    {
                        string q = ExtractParam(body, query, "q");
                        if (string.IsNullOrEmpty(q)) q = ExtractParam(body, query, "query");
                        AddLog("[SEARCH] YouTube TV search: " + (string.IsNullOrEmpty(q) ? "(open search)" : q));
                        PerformYouTubeSearch(q);

                        string json = "{\"success\":true,\"query\":\"" + EscapeJson(q) + "\"}";
                        SendHttpResponse(stream, 200, "OK", "application/json", json);
                    }
                    else if (uriPath == "/media/status")
                    {
                        UpdateMediaTick();
                        string json = "{\"active\":" + (_mediaActive ? "true" : "false") +
                                      ",\"playing\":" + (_mediaPlaying ? "true" : "false") +
                                      ",\"position\":" + Math.Round(_mediaPosition, 1).ToString(System.Globalization.CultureInfo.InvariantCulture) +
                                      ",\"duration\":" + Math.Round(_mediaDuration, 1).ToString(System.Globalization.CultureInfo.InvariantCulture) +
                                      ",\"title\":\"" + EscapeJson(_mediaTitle) + "\"}";
                        SendHttpResponse(stream, 200, "OK", "application/json", json);
                    }
                    else if (uriPath == "/media/seek")
                    {
                        double pos = ExtractParamDouble(body, query, "position", -1);
                        double ratio = ExtractParamDouble(body, query, "ratio", -1);
                        if (ratio < 0 && pos >= 0 && _mediaDuration > 0)
                        {
                            ratio = pos / _mediaDuration;
                        }
                        if (ratio >= 0)
                        {
                            ExecuteSeek(ratio, pos);
                        }
                        UpdateMediaTick();
                        string json = "{\"success\":true,\"position\":" + Math.Round(_mediaPosition, 1).ToString(System.Globalization.CultureInfo.InvariantCulture) + "}";
                        SendHttpResponse(stream, 200, "OK", "application/json", json);
                    }
                    else if (uriPath == "/action")
                    {
                        string action = ExtractParam(body, query, "command");
                        if (string.IsNullOrEmpty(action)) action = ExtractParam(body, query, "action");
                        AddLog("[ACTION] " + action);
                        ExecuteKeyAction(action);

                        string json = "{\"success\":true,\"action\":\"" + EscapeJson(action) + "\"}";
                        SendHttpResponse(stream, 200, "OK", "application/json", json);
                    }
                    else if (uriPath == "/mouse")
                    {
                        string mType = ExtractParam(body, query, "type");
                        double dx = ExtractParamDouble(body, query, "dx", 0);
                        double dy = ExtractParamDouble(body, query, "dy", 0);
                        double x = ExtractParamDouble(body, query, "x", 0);
                        double y = ExtractParamDouble(body, query, "y", 0);
                        string button = ExtractParam(body, query, "button");
                        int delta = ExtractParamInt(body, query, "delta", 0);

                        ExecuteMouseAction(mType, dx, dy, x, y, button, delta);
                        SendHttpResponse(stream, 200, "OK", "application/json", "{\"success\":true}");
                    }
                    else if (uriPath == "/keyboard")
                    {
                        string text = ExtractParam(body, query, "text");
                        string key = ExtractParam(body, query, "key");

                        if (!string.IsNullOrEmpty(text))
                        {
                            SendUnicodeString(text);
                            SendHttpResponse(stream, 200, "OK", "application/json", "{\"success\":true,\"text\":\"" + EscapeJson(text) + "\"}");
                        }
                        else if (!string.IsNullOrEmpty(key))
                        {
                            ExecuteSpecialKey(key);
                            SendHttpResponse(stream, 200, "OK", "application/json", "{\"success\":true,\"key\":\"" + EscapeJson(key) + "\"}");
                        }
                        else
                        {
                            SendHttpResponse(stream, 400, "Bad Request", "application/json", "{\"error\":\"Missing text or key\"}");
                        }
                    }
                    else if (uriPath == "/screen" || uriPath == "/screen.jpg")
                    {
                        try
                        {
                            int maxW = ExtractParamInt(body, query, "max_w", 1280);
                            int quality = ExtractParamInt(body, query, "q", 65);
                            byte[] jpegBytes = CaptureScreenJpeg(maxW, quality);
                            SendHttpBinaryResponse(stream, 200, "OK", "image/jpeg", jpegBytes);
                        }
                        catch (Exception ex)
                        {
                            SendHttpResponse(stream, 500, "Internal Server Error", "application/json", "{\"error\":\"" + EscapeJson(ex.Message) + "\"}");
                        }
                    }
                    else if (uriPath == "/screen/info")
                    {
                        Rectangle bounds = Screen.PrimaryScreen.Bounds;
                        string json = "{\"width\":" + bounds.Width + ",\"height\":" + bounds.Height + "}";
                        SendHttpResponse(stream, 200, "OK", "application/json", json);
                    }
                    else
                    {
                        SendHttpResponse(stream, 404, "Not Found", "text/plain", "Not Found");
                    }
                }
            }
            catch { }
        }

        private static readonly Encoding Utf8NoBom = new UTF8Encoding(false);

        private void SendHttpResponse(Stream stream, int code, string status, string contentType, string content)
        {
            byte[] bodyBytes = Utf8NoBom.GetBytes(content);
            SendHttpBinaryResponse(stream, code, status, contentType + "; charset=utf-8", bodyBytes);
        }

        private void SendHttpBinaryResponse(Stream stream, int code, string status, string contentType, byte[] bodyBytes)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("HTTP/1.1 ").Append(code).Append(" ").Append(status).Append("\r\n");
            sb.Append("Access-Control-Allow-Origin: *\r\n");
            sb.Append("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n");
            sb.Append("Access-Control-Allow-Headers: Content-Type\r\n");
            sb.Append("Cache-Control: no-cache, no-store, must-revalidate\r\n");
            sb.Append("Content-Type: ").Append(contentType).Append("\r\n");
            sb.Append("Content-Length: ").Append(bodyBytes.Length).Append("\r\n");
            sb.Append("Connection: close\r\n\r\n");

            byte[] headerBytes = Encoding.ASCII.GetBytes(sb.ToString());
            stream.Write(headerBytes, 0, headerBytes.Length);
            if (bodyBytes.Length > 0)
            {
                stream.Write(bodyBytes, 0, bodyBytes.Length);
            }
            stream.Flush();
        }

        private void RunUdpDiscovery()
        {
            try
            {
                _udpListener = new UdpClient(UdpPort);
                _udpListener.EnableBroadcast = true;

                while (_isRunning)
                {
                    IPEndPoint remoteEP = new IPEndPoint(IPAddress.Any, 0);
                    byte[] data = _udpListener.Receive(ref remoteEP);
                    if (data == null || data.Length == 0) continue;

                    // Fast Path: Zero-overhead binary protocol (opcodes 0x01..0x0A)
                    if (data[0] <= 0x0A)
                    {
                        byte opcode = data[0];
                        switch (opcode)
                        {
                            case 0x01: // MOVE_REL (5 bytes: opcode + Int16 dx + Int16 dy)
                                if (data.Length >= 5)
                                {
                                    short rawDx = (short)(data[1] | (data[2] << 8));
                                    short rawDy = (short)(data[3] | (data[4] << 8));
                                    ExecuteMouseAction("move", rawDx / 10.0, rawDy / 10.0, 0, 0, "", 0);
                                }
                                break;
                            case 0x02: // CLICK (2 bytes: opcode + button code)
                                if (data.Length >= 2)
                                {
                                    byte btn = data[1];
                                    string btnName = btn == 2 ? "right" : (btn == 3 ? "double" : (btn == 4 ? "middle" : "left"));
                                    ExecuteMouseAction("click", 0, 0, 0, 0, btnName, 0);
                                }
                                break;
                            case 0x03: // DOWN (2 bytes: opcode + button code)
                                if (data.Length >= 2)
                                {
                                    ExecuteMouseAction("down", 0, 0, 0, 0, data[1] == 2 ? "right" : "left", 0);
                                }
                                break;
                            case 0x04: // UP (2 bytes: opcode + button code)
                                if (data.Length >= 2)
                                {
                                    ExecuteMouseAction("up", 0, 0, 0, 0, data[1] == 2 ? "right" : "left", 0);
                                }
                                break;
                            case 0x05: // SCROLL (3 bytes: opcode + Int16 delta)
                                if (data.Length >= 3)
                                {
                                    short delta = (short)(data[1] | (data[2] << 8));
                                    ExecuteMouseAction("scroll", 0, 0, 0, 0, "", delta);
                                }
                                break;
                            case 0x06: // MOVE_ABS (5 bytes: opcode + Uint16 x + Uint16 y)
                                if (data.Length >= 5)
                                {
                                    ushort rawX = (ushort)(data[1] | (data[2] << 8));
                                    ushort rawY = (ushort)(data[3] | (data[4] << 8));
                                    ExecuteMouseAction("move_abs", 0, 0, rawX / 65535.0, rawY / 65535.0, "", 0);
                                }
                                break;
                        }
                        continue;
                    }

                    // Fallback Text / Discovery Path
                    string msg = Encoding.UTF8.GetString(data).Trim();

                    if (msg == "SCRSHARE_DISCOVER")
                    {
                        string reply = "{\"type\":\"SCRSHARE_HOST\",\"name\":\"" + EscapeJson(Environment.MachineName) +
                                       "\",\"ip\":\"" + _localIp + "\",\"port\":" + HttpPort + ",\"os\":\"windows\"}";
                        byte[] replyBytes = Encoding.UTF8.GetBytes(reply);
                        _udpListener.Send(replyBytes, replyBytes.Length, remoteEP);
                    }
                    else if (msg.StartsWith("K:"))
                    {
                        ExecuteKeyAction(msg.Substring(2));
                    }
                    else if (msg.StartsWith("Q:"))
                    {
                        PerformYouTubeSearch(msg.Substring(2));
                    }
                    else if (msg.StartsWith("SEEK:"))
                    {
                        double r = 0;
                        if (double.TryParse(msg.Substring(5), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out r))
                        {
                            ExecuteSeek(r, -1);
                        }
                    }
                }
            }
            catch (SocketException ex)
            {
                if (_isRunning)
                {
                    AddLog("[UDP Error] Port " + UdpPort + ": " + ex.Message);
                }
            }
            catch (Exception ex)
            {
                AddLog("[UDP Error] " + ex.Message);
            }
        }

        private void UpdateStatus(string text, bool isOnline)
        {
            if (InvokeRequired)
            {
                try { BeginInvoke(new Action<string, bool>(UpdateStatus), text, isOnline); } catch { }
                return;
            }
            _lblStatus.Text = text;
            _lblStatus.ForeColor = isOnline ? Color.FromArgb(46, 213, 115) : Color.FromArgb(255, 75, 75);
        }

        // ==================== EXTENSION MANAGEMENT ====================
        private void EnsureYouTubeTvExtensionInstalled()
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Google\Chrome\Extensions\" + ExtensionId))
                {
                    if (key != null) key.SetValue("update_url", ExtensionUpdateUrl, RegistryValueKind.String);
                }

                using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Edge\Extensions\" + ExtensionId))
                {
                    if (key != null) key.SetValue("update_url", ExtensionUpdateUrl, RegistryValueKind.String);
                }

                bool isInstalled = IsExtensionInstalledOnDisk();
                if (isInstalled)
                {
                    AddLog("[EXTENSION] 'YouTube TV On PC' extension is installed & active.");
                }
                else
                {
                    AddLog("[EXTENSION] Registered 'YouTube TV On PC' extension in Windows Registry.");

                    string markerFile = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".ext_opened");
                    if (!File.Exists(markerFile))
                    {
                        try { File.WriteAllText(markerFile, DateTime.Now.ToString()); } catch { }
                        AddLog("[EXTENSION] Opening Chrome Web Store for initial 1-click install...");
                        LaunchBrowser(ExtensionWebStoreUrl);
                    }
                }
            }
            catch (Exception ex)
            {
                AddLog("[EXTENSION Error] " + ex.Message);
            }
        }

        private bool IsExtensionInstalledOnDisk()
        {
            try
            {
                string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                string[] searchPaths = new string[]
                {
                    Path.Combine(localAppData, @"Google\Chrome\User Data\Default\Extensions\" + ExtensionId),
                    Path.Combine(localAppData, @"Microsoft\Edge\User Data\Default\Extensions\" + ExtensionId)
                };

                foreach (var p in searchPaths)
                {
                    if (Directory.Exists(p)) return true;
                }
            }
            catch { }
            return false;
        }

        // ==================== KEYBOARD ACTIONS ====================
        private readonly Dictionary<string, DateTime> _lastActionTime = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);

        private void ForceForeground(IntPtr hWnd)
        {
            try
            {
                AllowSetForegroundWindow(-1);
                keybd_event(0x12, 0, 0, 0); // Alt down to bypass Windows focus restriction
                ShowWindow(hWnd, 9); // SW_RESTORE
                Program.SetForegroundWindow(hWnd);
                keybd_event(0x12, 0, KEYEVENTF_KEYUP, 0); // Alt up
                Thread.Sleep(30);
            }
            catch { }
        }

        private void EnsureBrowserOrYouTubeForeground()
        {
            try
            {
                AllowSetForegroundWindow(-1);
                string[] browserProcesses = new string[] { "chrome", "msedge", "brave", "firefox", "opera" };
                IntPtr fallbackWnd = IntPtr.Zero;

                foreach (var name in browserProcesses)
                {
                    var procs = Process.GetProcessesByName(name);
                    foreach (var p in procs)
                    {
                        if (p.MainWindowHandle != IntPtr.Zero)
                        {
                            if (p.MainWindowTitle.IndexOf("YouTube", StringComparison.OrdinalIgnoreCase) >= 0)
                            {
                                ForceForeground(p.MainWindowHandle);
                                return;
                            }
                            if (fallbackWnd == IntPtr.Zero)
                            {
                                fallbackWnd = p.MainWindowHandle;
                            }
                        }
                    }
                }

                if (fallbackWnd != IntPtr.Zero)
                {
                    ForceForeground(fallbackWnd);
                }
            }
            catch { }
        }

        private void ExecuteKeyAction(string action)
        {
            string act = (action ?? "").ToLower().Trim();
            if (string.IsNullOrEmpty(act)) return;

            DateTime now = DateTime.UtcNow;
            if (act == "fullscreen" || act == "play_pause" || act == "space" || act == "mute" || act == "search" || act == "open_search")
            {
                DateTime last;
                if (_lastActionTime.TryGetValue(act, out last) && (now - last).TotalMilliseconds < 350)
                {
                    AddLog("[DEBOUNCE] Dropped rapid toggle: " + act);
                    return;
                }
                _lastActionTime[act] = now;
            }

            if (act == "search" || act == "open_search")
            {
                EnsureBrowserOrYouTubeForeground();
                return;
            }

            if (act == "volume_up")
            {
                keybd_event(0xAF, 0, KEYEVENTF_EXTENDEDKEY, 0);
                keybd_event(0xAF, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0);
                return;
            }

            if (act == "volume_down")
            {
                keybd_event(0xAE, 0, KEYEVENTF_EXTENDEDKEY, 0);
                keybd_event(0xAE, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0);
                return;
            }

            if (act == "mute")
            {
                keybd_event(0xAD, 0, KEYEVENTF_EXTENDEDKEY, 0);
                keybd_event(0xAD, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0);
                return;
            }

            if (act == "play_pause" || act == "space")
            {
                _mediaPlaying = !_mediaPlaying;
                _lastMediaTick = DateTime.UtcNow;

                // 1. Hardware System Media Transport Controls (0xB3)
                keybd_event(0xB3, 0, KEYEVENTF_EXTENDEDKEY, 0);
                keybd_event(0xB3, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0);

                // 2. Also send 'k' (0x4B) to YouTube
                EnsureBrowserOrYouTubeForeground();
                keybd_event(0x4B, 0, 0, 0);
                keybd_event(0x4B, 0, KEYEVENTF_KEYUP, 0);
                return;
            }

            if (act == "fullscreen")
            {
                EnsureBrowserOrYouTubeForeground();
                // Send F11 (0x7A) - browser fullscreen toggle like hitting F11 on keyboard
                keybd_event(0x7A, 0, 0, 0);
                keybd_event(0x7A, 0, KEYEVENTF_KEYUP, 0);
                return;
            }

            EnsureBrowserOrYouTubeForeground();

            byte vk = 0;
            switch (act)
            {
                case "navigate_up":
                case "up":
                    vk = 0x26; // VK_UP
                    break;
                case "navigate_down":
                case "down":
                    vk = 0x28; // VK_DOWN
                    break;
                case "navigate_left":
                case "left":
                    vk = 0x25; // VK_LEFT
                    break;
                case "navigate_right":
                case "right":
                    vk = 0x27; // VK_RIGHT
                    break;
                case "select":
                case "enter":
                case "ok":
                    vk = 0x0D; // VK_RETURN
                    break;
                case "back":
                case "backspace":
                    vk = 0x08; // VK_BACK
                    break;
                case "escape":
                    vk = 0x1B; // VK_ESCAPE
                    break;
            }

            if (vk != 0)
            {
                keybd_event(vk, 0, 0, 0);
                keybd_event(vk, 0, KEYEVENTF_KEYUP, 0);
            }
        }

        private void LaunchBrowser(string url)
        {
            try
            {
                _mediaActive = true;
                _mediaPlaying = true;
                _mediaPosition = 0;
                _lastMediaTick = DateTime.UtcNow;
                AddLog("[LAUNCH] Opening in default browser: " + url);
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                AddLog("[Launch Error] " + ex.Message);
                try
                {
                    Process.Start(new ProcessStartInfo("explorer.exe", "\"" + url + "\"") { UseShellExecute = true });
                }
                catch (Exception ex2)
                {
                    AddLog("[Launch Fallback Error] " + ex2.Message);
                }
            }
        }

        private void PerformYouTubeSearch(string query)
        {
            try
            {
                string q = (query ?? "").Trim();
                if (string.IsNullOrEmpty(q)) return; // Do not open duplicate tab on empty search

                EnsureBrowserOrYouTubeForeground();

                // Send '/' (0xBF) to focus YouTube search bar, type query directly via SendUnicodeString, press Enter
                Thread.Sleep(50);
                keybd_event(0xBF, 0, 0, 0); // '/' key in YouTube
                keybd_event(0xBF, 0, KEYEVENTF_KEYUP, 0);
                Thread.Sleep(70);

                SendUnicodeString(q);
                Thread.Sleep(50);

                keybd_event(0x0D, 0, 0, 0); // Enter
                keybd_event(0x0D, 0, KEYEVENTF_KEYUP, 0);

                AddLog("[SEARCH] Typed query directly into YouTube search: " + q);
            }
            catch (Exception ex)
            {
                AddLog("[Search Error] " + ex.Message);
            }
        }

        // ==================== UTILS ====================
        private string GetLocalIp()
        {
            try
            {
                using (var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, 0))
                {
                    s.Connect("8.8.8.8", 80);
                    var ep = s.LocalEndPoint as IPEndPoint;
                    if (ep != null) return ep.Address.ToString();
                }
            }
            catch { }

            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus == OperationalStatus.Up && ni.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                    {
                        foreach (var addr in ni.GetIPProperties().UnicastAddresses)
                        {
                            if (addr.Address.AddressFamily == AddressFamily.InterNetwork)
                            {
                                string ip = addr.Address.ToString();
                                if (ip.StartsWith("192.168.") || ip.StartsWith("10.") || ip.StartsWith("172."))
                                    return ip;
                            }
                        }
                    }
                }
            }
            catch { }

            return "127.0.0.1";
        }

        private void AddLog(string msg)
        {
            if (InvokeRequired)
            {
                try { BeginInvoke(new Action<string>(AddLog), msg); } catch { }
                return;
            }

            if (!IsHandleCreated || _rtbLog == null)
            {
                lock (_pendingLogs)
                {
                    _pendingLogs.Add(msg);
                }
                return;
            }

            try
            {
                string time = DateTime.Now.ToString("HH:mm:ss");
                _rtbLog.AppendText("[" + time + "] " + msg + Environment.NewLine);
                _rtbLog.SelectionStart = _rtbLog.TextLength;
                _rtbLog.ScrollToCaret();
            }
            catch { }
        }

        private double _accumX = 0;
        private double _accumY = 0;

        private void ExecuteMouseAction(string type, double dx, double dy, double x, double y, string button, int scrollDelta)
        {
            switch ((type ?? "").ToLower().Trim())
            {
                case "move":
                    _accumX += dx;
                    _accumY += dy;
                    int moveX = (int)_accumX;
                    int moveY = (int)_accumY;
                    _accumX -= moveX;
                    _accumY -= moveY;
                    if (moveX != 0 || moveY != 0)
                    {
                        mouse_event(MOUSEEVENTF_MOVE, moveX, moveY, 0, UIntPtr.Zero);
                    }
                    break;
                case "move_abs":
                    Rectangle bounds = Screen.PrimaryScreen.Bounds;
                    int absX = (int)Math.Round(x * bounds.Width);
                    int absY = (int)Math.Round(y * bounds.Height);
                    int clampedX = Math.Max(0, Math.Min(bounds.Width - 1, absX));
                    int clampedY = Math.Max(0, Math.Min(bounds.Height - 1, absY));
                    Cursor.Position = new Point(bounds.X + clampedX, bounds.Y + clampedY);
                    break;
                case "click":
                    string b = (button ?? "left").ToLower().Trim();
                    if (b == "right")
                    {
                        mouse_event(MOUSEEVENTF_RIGHTDOWN | MOUSEEVENTF_RIGHTUP, 0, 0, 0, UIntPtr.Zero);
                    }
                    else if (b == "middle")
                    {
                        mouse_event(MOUSEEVENTF_MIDDLEDOWN | MOUSEEVENTF_MIDDLEUP, 0, 0, 0, UIntPtr.Zero);
                    }
                    else if (b == "double")
                    {
                        mouse_event(MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
                        mouse_event(MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
                    }
                    else // left
                    {
                        mouse_event(MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
                    }
                    break;
                case "down":
                    if ((button ?? "left").ToLower().Trim() == "right")
                        mouse_event(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, UIntPtr.Zero);
                    else
                        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
                    break;
                case "up":
                    if ((button ?? "left").ToLower().Trim() == "right")
                        mouse_event(MOUSEEVENTF_RIGHTUP, 0, 0, 0, UIntPtr.Zero);
                    else
                        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
                    break;
                case "scroll":
                    mouse_event(MOUSEEVENTF_WHEEL, 0, 0, (uint)scrollDelta, UIntPtr.Zero);
                    break;
            }
        }

        private void SendUnicodeString(string text)
        {
            if (string.IsNullOrEmpty(text)) return;
            List<INPUT> inputs = new List<INPUT>();
            foreach (char c in text)
            {
                if (c == '\r') continue;
                if (c == '\n')
                {
                    INPUT down = new INPUT { type = INPUT_KEYBOARD };
                    down.u.ki = new KEYBDINPUT { wVk = 0x0D, dwFlags = 0 };
                    INPUT up = new INPUT { type = INPUT_KEYBOARD };
                    up.u.ki = new KEYBDINPUT { wVk = 0x0D, dwFlags = KEYEVENTF_KEYUP };
                    inputs.Add(down);
                    inputs.Add(up);
                    continue;
                }

                INPUT charDown = new INPUT { type = INPUT_KEYBOARD };
                charDown.u.ki = new KEYBDINPUT { wVk = 0, wScan = (ushort)c, dwFlags = KEYEVENTF_UNICODE };
                INPUT charUp = new INPUT { type = INPUT_KEYBOARD };
                charUp.u.ki = new KEYBDINPUT { wVk = 0, wScan = (ushort)c, dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP };
                inputs.Add(charDown);
                inputs.Add(charUp);
            }
            if (inputs.Count > 0)
            {
                SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf(typeof(INPUT)));
            }
        }

        private void ExecuteSpecialKey(string key)
        {
            if (string.IsNullOrEmpty(key)) return;
            string k = key.ToLower().Trim();

            bool ctrl = false;
            bool alt = false;
            bool shift = false;
            bool win = false;

            if (k.StartsWith("ctrl+")) { ctrl = true; k = k.Substring(5); }
            if (k.StartsWith("alt+")) { alt = true; k = k.Substring(4); }
            if (k.StartsWith("shift+")) { shift = true; k = k.Substring(6); }
            if (k.StartsWith("win+")) { win = true; k = k.Substring(4); }

            byte vk = 0;
            switch (k)
            {
                case "enter": case "return": case "ok": vk = 0x0D; break;
                case "backspace": case "back": vk = 0x08; break;
                case "escape": case "esc": vk = 0x1B; break;
                case "tab": vk = 0x09; break;
                case "space": vk = 0x20; break;
                case "delete": case "del": vk = 0x2E; break;
                case "up": case "navigate_up": vk = 0x26; break;
                case "down": case "navigate_down": vk = 0x28; break;
                case "left": case "navigate_left": vk = 0x25; break;
                case "right": case "navigate_right": vk = 0x27; break;
                case "home": vk = 0x24; break;
                case "end": vk = 0x23; break;
                case "pageup": vk = 0x21; break;
                case "pagedown": vk = 0x22; break;
                case "f1": vk = 0x70; break;
                case "f2": vk = 0x71; break;
                case "f3": vk = 0x72; break;
                case "f4": vk = 0x73; break;
                case "f5": vk = 0x74; break;
                case "f11": vk = 0x7A; break;
                case "f12": vk = 0x7B; break;
                case "win": vk = 0x5B; break;
                case "ctrl": vk = 0x11; break;
                case "alt": vk = 0x12; break;
                case "shift": vk = 0x10; break;
                case "c": vk = 0x43; break;
                case "v": vk = 0x56; break;
                case "x": vk = 0x58; break;
                case "z": vk = 0x5A; break;
                case "a": vk = 0x41; break;
                case "w": vk = 0x57; break;
                case "d": vk = 0x44; break;
                default:
                    if (k.Length == 1)
                    {
                        vk = (byte)char.ToUpper(k[0]);
                    }
                    break;
            }

            if (ctrl) keybd_event(0x11, 0, 0, 0);
            if (alt) keybd_event(0x12, 0, 0, 0);
            if (shift) keybd_event(0x10, 0, 0, 0);
            if (win) keybd_event(0x5B, 0, 0, 0);

            if (vk != 0)
            {
                keybd_event(vk, 0, 0, 0);
                Thread.Sleep(20);
                keybd_event(vk, 0, KEYEVENTF_KEYUP, 0);
            }

            if (win) keybd_event(0x5B, 0, KEYEVENTF_KEYUP, 0);
            if (shift) keybd_event(0x10, 0, KEYEVENTF_KEYUP, 0);
            if (alt) keybd_event(0x12, 0, KEYEVENTF_KEYUP, 0);
            if (ctrl) keybd_event(0x11, 0, KEYEVENTF_KEYUP, 0);
        }

        private static ImageCodecInfo _cachedJpegEncoder = null;
        private static ImageCodecInfo GetEncoder(ImageFormat format)
        {
            if (_cachedJpegEncoder != null && format.Guid == ImageFormat.Jpeg.Guid) return _cachedJpegEncoder;
            ImageCodecInfo[] codecs = ImageCodecInfo.GetImageEncoders();
            foreach (ImageCodecInfo codec in codecs)
            {
                if (codec.FormatID == format.Guid)
                {
                    if (format.Guid == ImageFormat.Jpeg.Guid) _cachedJpegEncoder = codec;
                    return codec;
                }
            }
            return null;
        }

        private byte[] CaptureScreenJpeg(int maxWidth, int quality)
        {
            Rectangle bounds = Screen.PrimaryScreen.Bounds;
            using (var bmp = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format24bppRgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    try
                    {
                        g.CopyFromScreen(bounds.X, bounds.Y, 0, 0, bounds.Size, CopyPixelOperation.SourceCopy);
                    }
                    catch
                    {
                        g.Clear(Color.FromArgb(20, 24, 33));
                        using (var f = new Font("Segoe UI", 16, FontStyle.Bold))
                        using (var b = new SolidBrush(Color.White))
                        {
                            g.DrawString("Desktop screen mirroring active", f, b, 50, 50);
                        }
                    }

                    try
                    {
                        CURSORINFO ci = new CURSORINFO();
                        ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
                        if (GetCursorInfo(out ci) && ci.flags == CURSOR_SHOWING)
                        {
                            IntPtr hdc = g.GetHdc();
                            try
                            {
                                DrawIcon(hdc, ci.ptScreenPos.x - bounds.X, ci.ptScreenPos.y - bounds.Y, ci.hCursor);
                            }
                            finally
                            {
                                g.ReleaseHdc(hdc);
                            }
                        }
                    }
                    catch { }
                }

                Bitmap output = bmp;
                bool mustDisposeOutput = false;
                try
                {
                    if (maxWidth > 0 && bounds.Width > maxWidth)
                    {
                        int targetHeight = (int)((double)bounds.Height * maxWidth / bounds.Width);
                        output = new Bitmap(maxWidth, targetHeight, PixelFormat.Format24bppRgb);
                        mustDisposeOutput = true;
                        using (var gScaled = Graphics.FromImage(output))
                        {
                            gScaled.InterpolationMode = InterpolationMode.Low;
                            gScaled.CompositingQuality = CompositingQuality.HighSpeed;
                            gScaled.SmoothingMode = SmoothingMode.HighSpeed;
                            gScaled.PixelOffsetMode = PixelOffsetMode.HighSpeed;
                            gScaled.DrawImage(bmp, 0, 0, maxWidth, targetHeight);
                        }
                    }

                    using (var ms = new MemoryStream(65536))
                    {
                        ImageCodecInfo jpgEncoder = GetEncoder(ImageFormat.Jpeg);
                        if (jpgEncoder != null)
                        {
                            using (EncoderParameters encParams = new EncoderParameters(1))
                            {
                                encParams.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)Math.Max(10, Math.Min(100, quality)));
                                output.Save(ms, jpgEncoder, encParams);
                            }
                        }
                        else
                        {
                            output.Save(ms, ImageFormat.Jpeg);
                        }
                        return ms.ToArray();
                    }
                }
                finally
                {
                    if (mustDisposeOutput && output != null)
                    {
                        output.Dispose();
                    }
                }
            }
        }

        private static string ExtractJsonValue(string json, string key)
        {
            if (string.IsNullOrEmpty(json) || string.IsNullOrEmpty(key)) return "";
            try
            {
                string search = "\"" + key + "\"";
                int idx = json.IndexOf(search, StringComparison.OrdinalIgnoreCase);
                if (idx < 0) return "";
                int colon = json.IndexOf(':', idx + search.Length);
                if (colon < 0) return "";

                int start = colon + 1;
                while (start < json.Length && char.IsWhiteSpace(json[start]))
                {
                    start++;
                }
                if (start >= json.Length) return "";

                if (json[start] == '\"')
                {
                    int endQuote = json.IndexOf('\"', start + 1);
                    if (endQuote < 0) return "";
                    return json.Substring(start + 1, endQuote - start - 1);
                }

                int end = start;
                while (end < json.Length && json[end] != ',' && json[end] != '}' && json[end] != ']' && !char.IsWhiteSpace(json[end]))
                {
                    end++;
                }
                return json.Substring(start, end - start).Trim();
            }
            catch { return ""; }
        }

        private static string ExtractParam(string body, string query, string key)
        {
            if (!string.IsNullOrEmpty(body))
            {
                string s = ExtractJsonValue(body, key);
                if (!string.IsNullOrEmpty(s)) return s;
            }
            if (!string.IsNullOrEmpty(query))
            {
                string prefix = key + "=";
                foreach (var p in query.Split('&'))
                {
                    if (p.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                    {
                        return Uri.UnescapeDataString(p.Substring(prefix.Length));
                    }
                }
            }
            return "";
        }

        private static double ExtractParamDouble(string body, string query, string key, double defaultVal)
        {
            string s = ExtractParam(body, query, key);
            if (string.IsNullOrEmpty(s)) return defaultVal;

            double val;
            if (double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out val))
            {
                return val;
            }
            return defaultVal;
        }

        private static int ExtractParamInt(string body, string query, string key, int defaultVal)
        {
            return (int)Math.Round(ExtractParamDouble(body, query, key, defaultVal));
        }

        private static string EscapeJson(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "\\n");
        }

        private static string ExtractJsonString(string json, string key)
        {
            return ExtractJsonValue(json, key);
        }
    }
}
