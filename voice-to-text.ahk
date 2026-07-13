#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook true
InstallKeybdHook()

configPath := A_ScriptDir "\config.ini"
RunAsAdministrator := IniRead(configPath, "Startup", "RunAsAdministrator", "false") = "true"

; --- Optional elevation for hotkeys in elevated windows ---
if RunAsAdministrator and !A_IsAdmin {
    Run('*RunAs "' A_ScriptFullPath '"')
    ExitApp()
}

; --- Global State ---
isRecording := false
isTranscribing := false
capturePID := 0
serverPID := 0
startupCancelled := false
startupProcessPID := 0
startupGui := 0
startupStatus := 0
startupDetail := 0
startupProgress := 0

; --- Load Config ---
MicDevice := IniRead(configPath, "Audio", "MicDevice", "")
FollowWindowsDefault := IniRead(configPath, "Audio", "FollowWindowsDefault", "true") = "true"
MicCapturePath := A_ScriptDir "\" IniRead(configPath, "Paths", "MicCapturePath", "bin\mic-capture.exe")
WhisperServerPath := A_ScriptDir "\" IniRead(configPath, "Paths", "WhisperServerPath", "bin\whisper-server.exe")
ModelPath := A_ScriptDir "\" IniRead(configPath, "Paths", "ModelPath", "models\ggml-small.en.bin")
TempWav := A_ScriptDir "\" IniRead(configPath, "Paths", "TempWav", "temp\recording.wav")
PushToTalkKey := IniRead(configPath, "Hotkey", "PushToTalk", "CapsLock")
WhisperThreads := IniRead(configPath, "Whisper", "Threads", "16")
ServerPort := IniRead(configPath, "Whisper", "ServerPort", "8178")

; --- Validate Binaries ---
if !FileExist(MicCapturePath) {
    MsgBox("mic-capture.exe not found at:`n" MicCapturePath "`n`nBuild it with: dotnet publish tools\mic-capture -c Release -o bin", "Voice-to-Text", "Icon!")
    ExitApp()
}
if !FileExist(WhisperServerPath) {
    MsgBox("whisper-server.exe not found at:`n" WhisperServerPath "`n`nRun setup.ps1 first.", "Voice-to-Text", "Icon!")
    ExitApp()
}

ShowStartupWindow()

if !FileExist(ModelPath) {
    modelDir := A_ScriptDir "\models"
    if !DirExist(modelDir)
        DirCreate(modelDir)

    modelUrl := "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
    downloadPath := ModelPath ".download"
    if FileExist(downloadPath)
        FileDelete(downloadPath)

    SetStartupPhase("Downloading speech model", "Connecting...", false)
    expectedBytes := GetRemoteFileSize(modelUrl, 487614201)

    try {
        downloadCmd := 'curl.exe -L --fail --retry 2 --output "' downloadPath '" "' modelUrl '"'
        Run(downloadCmd, A_ScriptDir, "Hide", &startupProcessPID)
    } catch {
        startupProcessPID := 0
    }

    while startupProcessPID and ProcessExist(startupProcessPID) {
        downloadedBytes := FileExist(downloadPath) ? FileGetSize(downloadPath) : 0
        progressPercent := Min(100, Floor(downloadedBytes * 100 / expectedBytes))
        downloadedMb := Floor(downloadedBytes / 1048576)
        expectedMb := Floor(expectedBytes / 1048576)
        startupProgress.Value := progressPercent
        startupDetail.Text := downloadedMb " of " expectedMb " MB (" progressPercent "%)"
        Sleep(100)
    }
    startupProcessPID := 0

    if startupCancelled {
        if FileExist(downloadPath)
            FileDelete(downloadPath)
        CloseStartupWindow()
        ExitApp()
    }

    downloadComplete := FileExist(downloadPath) and FileGetSize(downloadPath) >= expectedBytes
    if downloadComplete {
        SetStartupPhase("Verifying installation", "Preparing the speech model...", false, 100)
        FileMove(downloadPath, ModelPath, true)
        Sleep(300)
    }

    if !FileExist(ModelPath) {
        if FileExist(downloadPath)
            FileDelete(downloadPath)
        CloseStartupWindow()
        retryDownload := MsgBox("Failed to download the speech model.`nCheck your internet connection and try again.", "Voice-to-Text", "RetryCancel Icon!")
        if retryDownload = "Retry"
            Reload()
        ExitApp()
    }
}

; --- First-run mic selection ---
if MicDevice = "" and !FollowWindowsDefault {
    CloseStartupWindow()
    ; Detect available devices
    tempDevices := A_ScriptDir "\temp\devices.txt"
    DirCreate(A_ScriptDir "\temp")
    cmd := 'cmd /c ""' MicCapturePath '" list > "' tempDevices '" 2>&1"'
    RunWait(cmd, A_ScriptDir, "Hide")

    firstRunDevices := []
    if FileExist(tempDevices) {
        content := FileRead(tempDevices)
        for line in StrSplit(content, "`n") {
            line := Trim(line)
            if line != ""
                firstRunDevices.Push(line)
        }
        FileDelete(tempDevices)
    }

    if firstRunDevices.Length = 0 {
        MsgBox("No audio input devices found.`nConnect a microphone and restart.", "Voice-to-Text", "Icon!")
        ExitApp()
    }

    ; Show picker
    setupGui := Gui("+AlwaysOnTop", "Voice-to-Text Setup")
    setupGui.Add("Text", , "Welcome! Select your microphone to get started:")
    setupLb := setupGui.Add("ListBox", "w400 r" Min(firstRunDevices.Length, 8), firstRunDevices)
    setupLb.Choose(1)
    setupGui.Add("Button", "w400 Default", "Continue").OnEvent("Click", SetupApply)
    setupGui.OnEvent("Close", (*) => ExitApp())
    setupGui.Show()

    SetupApply(*) {
        selected := setupLb.Text
        if selected = "" {
            MsgBox("Please select a device.", "Voice-to-Text", "Icon!")
            return
        }
        IniWrite(selected, configPath, "Audio", "MicDevice")
        setupGui.Destroy()
        Reload()
    }

    ; Block until GUI is closed (Reload or ExitApp will end execution)
    return
}

; --- CapsLock Override ---
isCapsLockHotkey := (PushToTalkKey = "CapsLock")
originalCapsLockState := GetKeyState("CapsLock", "T") ? "On" : "Off"
if isCapsLockHotkey
    SetCapsLockState("AlwaysOff")

; --- Shift+Alt combo state ---
isShiftAltMode := (PushToTalkKey = "ShiftAlt")
shiftAltActive := false

OnExit(CleanUp)

; --- Start Whisper Server (keeps model warm in memory) ---
SetStartupPhase("Starting speech engine", "Loading the speech model. This can take up to 30 seconds.", true)
serverCmd := '"' WhisperServerPath '" -m "' ModelPath '" --port ' ServerPort ' --threads ' WhisperThreads
Run(serverCmd, A_ScriptDir, "Hide", &serverPID)

; Wait for server to be ready by polling the health endpoint
serverReady := false
startTime := A_TickCount
while (A_TickCount - startTime < 30000) {
    if startupCancelled {
        CloseStartupWindow()
        ExitApp()
    }

    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("GET", "http://127.0.0.1:" ServerPort, false)
        http.Send()
        if (http.Status = 200) {
            serverReady := true
            break
        }
    }
    Sleep(500)
}

if !serverReady {
    CloseStartupWindow()
    if serverPID and ProcessExist(serverPID)
        ProcessClose(serverPID)
    retryStartup := MsgBox("The speech engine failed to start within 30 seconds.`nCheck that port " ServerPort " is available.", "Voice-to-Text", "RetryCancel Icon!")
    if retryStartup = "Retry"
        Reload()
    ExitApp()
}

SetStartupPhase("Ready", "Voice-to-Text is ready to use.", false, 100)
Sleep(400)
CloseStartupWindow()

; --- Tray Setup ---
idleIcon := A_ScriptDir "\icons\idle.ico"
startingIcon := A_ScriptDir "\icons\starting.ico"
recordingIcon := A_ScriptDir "\icons\recording.ico"
transcribingIcon := A_ScriptDir "\icons\transcribing.ico"

if FileExist(idleIcon)
    TraySetIcon(idleIcon)

A_TrayMenu.Delete()
A_TrayMenu.Add("Change Microphone", ListDevices)
A_TrayMenu.Add("Open Config", OpenConfig)
A_TrayMenu.Add("Run as Administrator", ToggleAdministratorMode)
if RunAsAdministrator
    A_TrayMenu.Check("Run as Administrator")
A_TrayMenu.Add()
A_TrayMenu.Add("Reload", (*) => Reload())
A_TrayMenu.Add("Exit", (*) => ExitApp())
A_TrayMenu.Default := "Change Microphone"

; --- Register Hotkeys ---
if isShiftAltMode {
    Hotkey("~*LAlt", ShiftAltDown)
    Hotkey("~*LAlt Up", ShiftAltUp)
} else {
    Hotkey(PushToTalkKey, OnKeyDown)
    Hotkey(PushToTalkKey " Up", OnKeyUp)
}

; --- Shift+Alt Combo Handlers ---
ShiftAltDown(*) {
    global shiftAltActive
    if GetKeyState("LShift", "P") {
        if !shiftAltActive {
            shiftAltActive := true
            OnKeyDown()
        }
    }
}

ShiftAltUp(*) {
    global shiftAltActive
    if shiftAltActive {
        shiftAltActive := false
        OnKeyUp()
    }
}

; --- Check if push-to-talk key is still held ---
IsHotkeyHeld() {
    global isShiftAltMode, PushToTalkKey
    if isShiftAltMode
        return GetKeyState("LShift", "P") and GetKeyState("LAlt", "P")
    return GetKeyState(PushToTalkKey, "P")
}

; --- Stop mic-capture and reset to idle ---
AbortRecording() {
    global isRecording, capturePID
    isRecording := false
    StopCapture()
    ToolTip()
    ResetIcon()
}

StopCapture() {
    global capturePID, MicCapturePath
    ; Signal mic-capture to stop via named event (graceful WAV finalization)
    Run('"' MicCapturePath '" stop', A_ScriptDir, "Hide")
    if capturePID {
        ProcessWaitClose(capturePID, 2)
        ; Force kill if it didn't stop gracefully
        if ProcessExist(capturePID) {
            ProcessClose(capturePID)
            ProcessWaitClose(capturePID, 1)
        }
        capturePID := 0
    }
}

; --- Hotkey Handlers ---
OnKeyDown(*) {
    global isRecording, isTranscribing, capturePID

    if isRecording or isTranscribing
        return

    isRecording := true

    ; Delete stale files — retry briefly if locked
    readyFile := A_ScriptDir "\temp\capture_ready"
    loop 3 {
        try {
            if FileExist(TempWav)
                FileDelete(TempWav)
            if FileExist(readyFile)
                FileDelete(readyFile)
            break
        }
        Sleep(100)
    }

    ; Show loading state immediately
    if FileExist(startingIcon)
        TraySetIcon(startingIcon)
    ToolTip("Starting...")

    ; Launch mic-capture with WASAPI (near-instant startup vs ffmpeg dshow)
    deviceArg := FollowWindowsDefault ? "" : ' --device "' MicDevice '"'
    cmd := '"' MicCapturePath '" record' deviceArg ' --output "' TempWav '" --ready-file "' readyFile '"'
    Run(cmd, A_ScriptDir, "Hide", &capturePID)

    ; Wait for mic-capture to signal that audio is flowing
    captureReady := false
    waitStart := A_TickCount
    while (A_TickCount - waitStart < 5000) {
        ; Abort if user released the hotkey during startup
        if !IsHotkeyHeld() {
            AbortRecording()
            return
        }
        if FileExist(readyFile) {
            captureReady := true
            break
        }
        ; Bail if mic-capture died
        if !ProcessExist(capturePID)
            break
        Sleep(20)
    }

    if !captureReady {
        ShowTooltipTimed("Mic failed to start", 3000)
        AbortRecording()
        return
    }

    if FileExist(recordingIcon)
        TraySetIcon(recordingIcon)
    ToolTip("Recording...")
}

OnKeyUp(*) {
    global isRecording, isTranscribing, capturePID

    if !isRecording
        return

    isRecording := false

    ; Stop mic-capture gracefully (signals named event, WAV header finalized)
    StopCapture()

    ; Brief pause for file system flush
    Sleep(100)

    ; Validate recording
    if !FileExist(TempWav) {
        ShowTooltipTimed("No recording captured", 2000)
        ResetIcon()
        return
    }

    fileSize := FileGetSize(TempWav)
    if fileSize < 1000 {
        ShowTooltipTimed("Too short - try holding longer", 2000)
        ResetIcon()
        return
    }

    ; Transcribe via whisper server (model already loaded — no startup cost)
    isTranscribing := true
    if FileExist(transcribingIcon)
        TraySetIcon(transcribingIcon)
    ToolTip("Transcribing...")

    ; POST audio to whisper server via curl (ships with Windows 10+)
    tempOutput := A_ScriptDir "\temp\whisper_output.txt"
    if FileExist(tempOutput)
        FileDelete(tempOutput)

    curlCmd := 'cmd /c "curl -s -X POST'
        . " http://127.0.0.1:" ServerPort "/inference"
        . ' -F "file=@' TempWav '"'
        . ' -F "response_format=text"'
        . ' -F "temperature=0.0"'
        . ' > "' tempOutput '" 2>&1"'
    RunWait(curlCmd, A_ScriptDir, "Hide")

    output := ""
    if FileExist(tempOutput) {
        raw := Trim(FileRead(tempOutput))
        FileDelete(tempOutput)
        ; Join multi-line segments into a single line, collapse whitespace
        output := RegExReplace(raw, "\s+", " ")
        output := Trim(output)
    }

    if (output = "" or InStr(output, "[BLANK_AUDIO]")) {
        ShowTooltipTimed("No speech detected", 2000)
        isTranscribing := false
        ResetIcon()
        return
    }

    ; Copy to clipboard
    A_Clipboard := output
    preview := StrLen(output) > 50 ? SubStr(output, 1, 50) "..." : output
    ShowTooltipTimed("Copied: " preview, 3000)

    isTranscribing := false
    ResetIcon()
}

; --- Helper Functions ---
ShowStartupWindow() {
    global startupGui, startupStatus, startupDetail, startupProgress

    startupGui := Gui("+AlwaysOnTop -MaximizeBox -MinimizeBox", "Voice-to-Text")
    startupGui.MarginX := 20
    startupGui.MarginY := 16
    startupGui.SetFont("s14 bold")
    startupGui.Add("Text", "w380 Center", "Voice-to-Text")
    startupGui.SetFont("s10 norm")
    startupStatus := startupGui.Add("Text", "w380 Center y+14", "Preparing...")
    startupDetail := startupGui.Add("Text", "w380 Center y+6", "Starting setup")
    startupProgress := startupGui.Add("Progress", "w380 h18 y+14 Range0-100", 0)
    startupGui.Add("Button", "w100 x160 y+14", "Cancel").OnEvent("Click", CancelStartup)
    startupGui.OnEvent("Close", CancelStartup)
    startupGui.OnEvent("Escape", CancelStartup)
    startupGui.Show()
}

SetStartupPhase(status, detail, marquee := false, progress := 0) {
    global startupStatus, startupDetail, startupProgress

    startupStatus.Text := status
    startupDetail.Text := detail
    SendMessage(0x040A, 0, 0, startupProgress.Hwnd)
    startupProgress.Opt(marquee ? "+0x8" : "-0x8")
    if marquee
        SendMessage(0x040A, 1, 30, startupProgress.Hwnd)
    else
        startupProgress.Value := progress
}

CancelStartup(*) {
    global startupCancelled, startupProcessPID
    startupCancelled := true
    if startupProcessPID and ProcessExist(startupProcessPID)
        ProcessClose(startupProcessPID)
}

CloseStartupWindow() {
    global startupGui, startupProgress
    if startupGui {
        SendMessage(0x040A, 0, 0, startupProgress.Hwnd)
        startupGui.Destroy()
        startupGui := 0
    }
}

GetRemoteFileSize(url, fallbackBytes) {
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.SetTimeouts(5000, 5000, 5000, 5000)
        http.Open("HEAD", url, false)
        http.Send()
        contentLength := Integer(http.GetResponseHeader("Content-Length"))
        if contentLength > 400 * 1024 * 1024
            return contentLength
    }
    return fallbackBytes
}

ResetIcon() {
    if FileExist(idleIcon)
        TraySetIcon(idleIcon)
    else
        TraySetIcon(A_AhkPath)
}

ShowTooltipTimed(text, duration) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -duration)
}

ListDevices(*) {
    ; Use mic-capture for WASAPI device listing
    tempDevices := A_ScriptDir "\temp\devices.txt"
    if FileExist(tempDevices)
        FileDelete(tempDevices)

    cmd := 'cmd /c ""' MicCapturePath '" list > "' tempDevices '" 2>&1"'
    RunWait(cmd, A_ScriptDir, "Hide")

    deviceList := ["Windows default (follows system changes)"]
    if FileExist(tempDevices) {
        content := FileRead(tempDevices)
        for line in StrSplit(content, "`n") {
            line := Trim(line)
            if line != ""
                deviceList.Push(line)
        }
        FileDelete(tempDevices)
    }

    if deviceList.Length = 0 {
        MsgBox("No audio input devices found.", "Audio Devices", "Icon!")
        return
    }

    ; Build GUI with listbox and apply button
    devGui := Gui("+AlwaysOnTop", "Select Audio Device")
    devGui.Add("Text", , "Select a microphone to use:")
    lb := devGui.Add("ListBox", "w400 r" Min(deviceList.Length, 8), deviceList)

    if FollowWindowsDefault {
        lb.Choose(1)
    } else {
        for i, name in deviceList {
            if name = MicDevice {
                lb.Choose(i)
                break
            }
        }
    }

    devGui.Add("Button", "w400 Default", "Apply && Reload").OnEvent("Click", ApplyDevice)
    devGui.Show()

    ApplyDevice(*) {
        selected := lb.Text
        if selected = "" {
            MsgBox("No device selected.", "Audio Devices", "Icon!")
            return
        }
        useWindowsDefault := selected = "Windows default (follows system changes)"
        IniWrite(useWindowsDefault ? "true" : "false", configPath, "Audio", "FollowWindowsDefault")
        if !useWindowsDefault
            IniWrite(selected, configPath, "Audio", "MicDevice")
        devGui.Destroy()
        Reload()
    }
}

OpenConfig(*) {
    Run(configPath)
}

ToggleAdministratorMode(*) {
    global RunAsAdministrator, configPath
    RunAsAdministrator := !RunAsAdministrator
    IniWrite(RunAsAdministrator ? "true" : "false", configPath, "Startup", "RunAsAdministrator")

    if RunAsAdministrator {
        A_TrayMenu.Check("Run as Administrator")
        ToolTip("Restarting as administrator...")
        try {
            Run('*RunAs "' A_ScriptFullPath '"')
        } catch {
            RunAsAdministrator := false
            IniWrite("false", configPath, "Startup", "RunAsAdministrator")
            A_TrayMenu.Uncheck("Run as Administrator")
            ShowTooltipTimed("Administrator mode unchanged", 2000)
            return
        }
    } else {
        A_TrayMenu.Uncheck("Run as Administrator")
        ToolTip("Restarting without administrator access...")
        restartScript := A_Temp "\VoiceToText_Restart_" A_TickCount ".cmd"
        try {
            FileAppend('@ping 127.0.0.1 -n 2 > nul`r`n@start "" "' A_ScriptFullPath '"`r`n@del "%~f0"', restartScript)
            RunAsDesktopUser(restartScript, "", A_Temp, "open", 0)
        } catch {
            if FileExist(restartScript)
                FileDelete(restartScript)
            RunAsAdministrator := true
            IniWrite("true", configPath, "Startup", "RunAsAdministrator")
            A_TrayMenu.Check("Run as Administrator")
            ShowTooltipTimed("Administrator mode unchanged", 2000)
            return
        }
    }

    ExitApp()
}

RunAsDesktopUser(filePath, arguments := "", directory := "", operation := "open", show := 1) {
    static VT_UI4 := 0x13, desktopWindow := ComValue(VT_UI4, 0x8)
    ComObject("Shell.Application").Windows.Item(desktopWindow).Document.Application
        .ShellExecute(filePath, arguments, directory, operation, show)
}

CleanUp(exitReason, exitCode) {
    global capturePID, serverPID, isCapsLockHotkey, originalCapsLockState, MicCapturePath

    ; Stop mic-capture gracefully
    Run('"' MicCapturePath '" stop', A_ScriptDir, "Hide")
    if capturePID and ProcessExist(capturePID) {
        ProcessWaitClose(capturePID, 1)
        if ProcessExist(capturePID)
            ProcessClose(capturePID)
    }

    ; Kill whisper server
    if serverPID and ProcessExist(serverPID)
        ProcessClose(serverPID)

    ; Restore CapsLock to its original state
    if isCapsLockHotkey
        SetCapsLockState(originalCapsLockState)

    ; Clean temp files
    if FileExist(TempWav)
        FileDelete(TempWav)
}
