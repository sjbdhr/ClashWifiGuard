' Launch ClashWifiGuard with no console window at all.
' Double-click this file instead of the .bat: the .bat still flashes a cmd box
' for a split second, while WScript.Shell.Run with window style 0 creates no
' console host for the PowerShell process behind the WPF window.
Dim fso, sh, appDir, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = appDir & "\ClashWifiGuard.ps1"
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
sh.Run cmd, 0, False
