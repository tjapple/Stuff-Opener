Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

shell.CurrentDirectory = scriptDir
runCmd = fso.BuildPath(scriptDir, "run.cmd")

If fso.FileExists(runCmd) Then
    shell.Run """" & runCmd & """", 0, False
Else
    shell.Run "cmd.exe /c uv run python app.py", 0, False
End If
