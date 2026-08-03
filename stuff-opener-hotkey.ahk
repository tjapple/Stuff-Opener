#Requires AutoHotkey v2.0
#SingleInstance Force
SetTitleMatchMode 2

appTitle := "Stuff Opener"
appDir := A_ScriptDir
appExe := appDir "\StuffOpener.exe"
frozenExe := appDir "\StuffOpener.frozen.exe"
appRunVbs := appDir "\run.vbs"
appRunCmd := appDir "\run.cmd"
appPy := appDir "\app.py"

LaunchStuffOpener() {
    global appDir, appExe, frozenExe, appRunVbs, appRunCmd, appPy

    if FileExist(appExe) {
        Run('"' appExe '"', appDir, "Hide")
        return
    }

    ; Legacy packaged fallback from older builds.
    if FileExist(frozenExe) {
        Run('"' frozenExe '"', appDir, "Hide")
        return
    }

    if FileExist(appRunVbs) {
        Run('wscript.exe "' appRunVbs '"', appDir, "Hide")
        return
    }

    if FileExist(appRunCmd) {
        Run('"' appRunCmd '"', appDir, "Hide")
        return
    }

    if FileExist(appPy) {
        ; Source-run fallback for developer machines.
        localAppData := EnvGet("LOCALAPPDATA")
        if !localAppData {
            userProfile := EnvGet("USERPROFILE")
            if userProfile {
                localAppData := userProfile "\AppData\Local"
            }
        }

        pythonwCandidates := [
            localAppData "\Programs\Python\Python314\pythonw.exe",
            localAppData "\Programs\Python\Python313\pythonw.exe",
            localAppData "\Programs\Python\Python312\pythonw.exe"
        ]
        for candidate in pythonwCandidates {
            if FileExist(candidate) {
                Run('"' candidate '" "' appPy '"', appDir, "Hide")
                return
            }
        }
    }

    MsgBox "Could not find a Stuff Opener launcher or app.py in:`n" appDir, "Stuff Opener", "Iconx"
}

FindStuffOpenerWindow() {
    global appTitle
    hwnd := WinExist("ahk_exe StuffOpener.exe")
    if !hwnd
        hwnd := WinExist(appTitle)
    return hwnd
}

ActivateStuffOpenerWindow() {
    hwnd := FindStuffOpenerWindow()
    if !hwnd
        return 0

    target := "ahk_id " hwnd
    try {
        if !WinExist(target)
            return 0
        if WinGetMinMax(target) = -1
            WinRestore(target)
        WinActivate(target)
        return hwnd
    } catch as err {
        return 0
    }
}

$!o:: {
    if WinActive(appTitle) {
        Send("!c")
        return
    }

    hwnd := ActivateStuffOpenerWindow()
    if hwnd {
        return
    }

    LaunchStuffOpener()
}

$!c:: {
    hwnd := ActivateStuffOpenerWindow()
    if !hwnd {
        LaunchStuffOpener()
        if !WinWait(appTitle,, 3)
            if !WinWait("ahk_exe StuffOpener.exe",, 1)
                return
        hwnd := ActivateStuffOpenerWindow()
        if !hwnd
            return
    }

    Sleep 60
    Send("!c")
}
