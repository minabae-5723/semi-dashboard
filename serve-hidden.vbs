' Launch the SEMI dashboard local server hidden (no console window).
' Placed in the Startup folder so it runs at every logon; also runnable on demand.
Set sh = CreateObject("WScript.Shell")
profile = sh.ExpandEnvironmentStrings("%USERPROFILE%")
cmd = "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & profile & "\code\semi-dashboard\serve.ps1"" -Port 8090 -NoBrowser"
sh.Run cmd, 0, False
