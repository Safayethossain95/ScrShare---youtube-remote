@echo off
set SCRIPT_DIR=%~dp0
set VBS_TARGET=%SCRIPT_DIR%start_receiver_silent.vbs
set STARTUP_LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ScrShareReceiver.lnk

echo Setting up ScrShare to start automatically on Windows boot...
powershell -NoProfile -Command "$ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut('%STARTUP_LNK%'); $s.TargetPath = 'wscript.exe'; $s.Arguments = '\"%VBS_TARGET%\"'; $s.WorkingDirectory = '%SCRIPT_DIR%'; $s.Save()"

if exist "%STARTUP_LNK%" (
    echo.
    echo [SUCCESS] ScrShare will now automatically start in the background when your PC boots!
    echo You will never need to launch it manually.
) else (
    echo [ERROR] Could not create startup shortcut.
)
echo.
pause
