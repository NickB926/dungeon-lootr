' Publish Dungeon Lootr — double-click or pin the Desktop shortcut to the taskbar.
' Runs the same flow as publish-updates.bat / npm run publish:updates.

Option Explicit
Dim sh, fso, root, bat, ps1, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
bat = root & "\publish-updates.bat"
ps1 = root & "\Publish-DungeonLootr.ps1"

' Prefer the bat (pause at end so you can read errors). Fall back to PowerShell.
If fso.FileExists(bat) Then
  cmd = "cmd.exe /c """ & bat & """"
ElseIf fso.FileExists(ps1) Then
  cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """"
Else
  MsgBox "Missing publish-updates.bat / Publish-DungeonLootr.ps1 in:" & vbCrLf & root, vbCritical, "Dungeon Lootr Publish"
  WScript.Quit 1
End If

' 1 = normal window (see bump/push output). Working directory = repo root.
sh.CurrentDirectory = root
sh.Run cmd, 1, True
