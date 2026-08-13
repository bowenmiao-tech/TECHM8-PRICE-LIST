Option Explicit

Dim shell, fileSystem, scriptFolder, queueScript, command, exitCode
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptFolder = fileSystem.GetParentFolderName(WScript.ScriptFullName)
queueScript = fileSystem.BuildPath(scriptFolder, "process-crazyparts-run-queue.ps1")
command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & queueScript & """"

' Window style 0 starts PowerShell completely hidden. True waits for the queue check to finish.
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
