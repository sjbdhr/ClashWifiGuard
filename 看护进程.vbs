' ClashWifiGuard watchdog.
' Called by a scheduled task every few minutes. Starts the app only when no
' instance is running AND the user has not asked it to stay down.
' Uses WMI to inspect the process list, so nothing stays resident between runs.

Dim wmi, procs, p, found, sh, fso, appDir, ps1, stopFlag, cmd

Set fso = CreateObject("Scripting.FileSystemObject")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = appDir & "\ClashWifiGuard.ps1"
stopFlag = appDir & "\ClashWifiGuard.stop"

If Not fso.FileExists(ps1) Then
    WScript.Quit 1
End If

' "退出（停止监控）" writes this file. Respect it: a watchdog that restarts the
' app after the user explicitly quit it makes the app impossible to turn off.
If fso.FileExists(stopFlag) Then
    WScript.Quit 0
End If

found = False
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
Set procs = wmi.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name='powershell.exe'")
For Each p In procs
    If Not IsNull(p.CommandLine) Then
        If InStr(LCase(p.CommandLine), "clashwifiguard.ps1") > 0 Then
            found = True
            Exit For
        End If
    End If
Next

If found Then
    WScript.Quit 0
End If

Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
sh.Run cmd, 0, False
WScript.Quit 0
