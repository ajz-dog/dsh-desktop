' Hidden starter for the DeepSeek Harness Web GUI.
'
' The shortcut targets this file through wscript.exe so no console window ever
' appears. Everything real happens in dsh-web-launcher.mjs next to it; keep the
' two files together.

Option Explicit

Dim shell, fso, here, nodeExe, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)

nodeExe = "C:\Program Files\nodejs\node.exe"
If Not fso.FileExists(nodeExe) Then
  nodeExe = "node.exe"
End If

command = """" & nodeExe & """ """ & here & "\dsh-web-launcher.mjs"""

shell.CurrentDirectory = here
' 0 = hidden window, False = do not wait for the launcher to finish.
shell.Run command, 0, False
