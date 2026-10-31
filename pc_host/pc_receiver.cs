using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
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
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("uxtheme.dll", EntryPoint = "#135", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern int SetPreferredAppMode(int appMode);

        private const int SW_RESTORE = 9;

        [STAThread]
        static void Main(string[] args)
        {
            try { SetPreferredAppMode(2); } catch { }

            bool createdNew;
            using (var mutex = new Mutex(true, "Global\\ScrShare_PC_Receiver_SingleInstance", out createdNew))
            {
                if (!createdNew)
                {
                    IntPtr hWnd = FindWindow(null, "ScrShare - PC Remote Receiver");
                    if (hWnd != IntPtr.Zero)
                    {
                        ShowWindow(hWnd, SW_RESTORE);
                        SetForegroundWindow(hWnd);
                    }
                    return;
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
            }
        }
    }

    public class MainForm : Form
    {
        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);
        private const uint KEYEVENTF_KEYUP = 0x0002;

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
                Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
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
                    else if (uriPath == "/action")
                    {
                        string action = "";
                        if (!string.IsNullOrEmpty(body))
                        {
                            action = ExtractJsonString(body, "command");
                        }
                        else if (!string.IsNullOrEmpty(query))
                        {
                            foreach (var p in query.Split('&'))
                            {
                                if (p.StartsWith("command="))
                                {
                                    action = Uri.UnescapeDataString(p.Substring(8));
                                    break;
                                }
                            }
                        }

                        AddLog("[ACTION] " + action);
                        ExecuteKeyAction(action);

                        string json = "{\"success\":true,\"action\":\"" + EscapeJson(action) + "\"}";
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
            StringBuilder sb = new StringBuilder();
            sb.Append("HTTP/1.1 ").Append(code).Append(" ").Append(status).Append("\r\n");
            sb.Append("Access-Control-Allow-Origin: *\r\n");
            sb.Append("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n");
            sb.Append("Access-Control-Allow-Headers: Content-Type\r\n");
            sb.Append("Content-Type: ").Append(contentType).Append("; charset=utf-8\r\n");
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
                    string msg = Encoding.UTF8.GetString(data).Trim();

                    if (msg == "SCRSHARE_DISCOVER")
                    {
                        string reply = "{\"type\":\"SCRSHARE_HOST\",\"name\":\"" + EscapeJson(Environment.MachineName) +
                                       "\",\"ip\":\"" + _localIp + "\",\"port\":" + HttpPort + ",\"os\":\"windows\"}";
                        byte[] replyBytes = Encoding.UTF8.GetBytes(reply);
                        _udpListener.Send(replyBytes, replyBytes.Length, remoteEP);
                        AddLog("[DISCOVERY] Answered broadcast from " + remoteEP.Address);
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
        private void ExecuteKeyAction(string action)
        {
            byte vk = 0;
            switch (action.ToLower().Trim())
            {
                case "fullscreen":
                    vk = 0x7A; // VK_F11
                    break;
                case "play_pause":
                case "space":
                    vk = 0x20; // VK_SPACE
                    break;
                case "mute":
                    vk = 0x4D; // 'M'
                    break;
                case "navigate_up":
                case "up":
                case "volume_up":
                    vk = 0x26; // VK_UP
                    break;
                case "navigate_down":
                case "down":
                case "volume_down":
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
                Thread.Sleep(20);
                keybd_event(vk, 0, KEYEVENTF_KEYUP, 0);
            }
        }

        private void LaunchBrowser(string url)
        {
            try
            {
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

        private static string EscapeJson(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "\\n");
        }

        private static string ExtractJsonString(string json, string key)
        {
            try
            {
                string search = "\"" + key + "\"";
                int idx = json.IndexOf(search, StringComparison.OrdinalIgnoreCase);
                if (idx < 0) return "";
                int colon = json.IndexOf(':', idx + search.Length);
                if (colon < 0) return "";
                int startQuote = json.IndexOf('\"', colon + 1);
                if (startQuote < 0) return "";
                int endQuote = json.IndexOf('\"', startQuote + 1);
                if (endQuote < 0) return "";
                return json.Substring(startQuote + 1, endQuote - startQuote - 1);
            }
            catch { return ""; }
        }
    }
}
