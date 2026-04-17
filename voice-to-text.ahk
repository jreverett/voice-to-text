#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook true
InstallKeybdHook()

; --- Auto-elevate to admin (required for hooks in elevated windows like Terminal) ---
if !A_IsAdmin {
    Run('*RunAs "' A_ScriptFullPath '"')
    ExitApp()
}

; --- Global State ---
isRecording := false
isTranscribing := false
ffmpegPID := 0
warmupPID := 0
serverPID := 0

; --- Load Config ---
configPath := A_ScriptDir "\config.ini"

MicDevice := IniRead(configPath, "Audio", "MicDevice", "Microphone (Realtek(R) Audio)")
FfmpegPath := A_ScriptDir "\" IniRead(configPath, "Paths", "FfmpegPath", "bin\ffmpeg.exe")
WhisperServerPath := A_ScriptDir "\" IniRead(configPath, "Paths", "WhisperServerPath", "bin\whisper-server.exe")
ModelPath := A_ScriptDir "\" IniRead(configPath, "Paths", "ModelPath", "models\ggml-small.en.bin")
TempWav := A_ScriptDir "\" IniRead(configPath, "Paths", "TempWav", "temp\recording.wav")
PushToTalkKey := IniRead(configPath, "Hotkey", "PushToTalk", "CapsLock")
ExtraFlags := IniRead(configPath, "Whisper", "ExtraFlags", "--no-timestamps --threads 16")
ServerPort := IniRead(configPath, "Whisper", "ServerPort", "8178")

; --- Validate Binaries ---
if !FileExist(FfmpegPath) {
    MsgBox("ffmpeg.exe not found at:`n" FfmpegPath "`n`nRun setup.ps1 first.", "Voice-to-Text", "Icon!")
    ExitApp()
}
if !FileExist(WhisperServerPath) {
    MsgBox("whisper-server.exe not found at:`n" WhisperServerPath "`n`nRun setup.ps1 first.", "Voice-to-Text", "Icon!")
    ExitApp()
}
if !FileExist(ModelPath) {
    MsgBox("Model not found at:`n" ModelPath "`n`nRun setup.ps1 first.", "Voice-to-Text", "Icon!")
    ExitApp()
}

; --- CapsLock Override ---
isCapsLockHotkey := (PushToTalkKey = "CapsLock")
if isCapsLockHotkey
    SetCapsLockState("AlwaysOff")

; --- Shift+Alt combo state ---
isShiftAltMode := (PushToTalkKey = "ShiftAlt")
shiftAltActive := false

; --- Start Whisper Server (keeps model warm in memory) ---
ToolTip("Loading whisper model...")
serverCmd := '"' WhisperServerPath '" -m "' ModelPath '" --port ' ServerPort ' --threads 16'
Run(serverCmd, A_ScriptDir, "Hide", &serverPID)

; Wait for server to be ready by polling the health endpoint
serverReady := false
startTime := A_TickCount
while (A_TickCount - startTime < 30000) {
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
    MsgBox("Whisper server failed to start within 30s.`nCheck that port " ServerPort " is available.", "Voice-to-Text", "Icon!")
    if serverPID and ProcessExist(serverPID)
        ProcessClose(serverPID)
    ExitApp()
}
ToolTip()

; --- Pre-warm microphone (keeps DirectShow device open so hotkey recording starts instantly) ---
StartMicWarmup()

; --- Tray Setup ---
idleIcon := A_ScriptDir "\icons\idle.ico"
recordingIcon := A_ScriptDir "\icons\recording.ico"
transcribingIcon := A_ScriptDir "\icons\transcribing.ico"

if FileExist(idleIcon)
    TraySetIcon(idleIcon)

A_TrayMenu.Delete()
A_TrayMenu.Add("List Audio Devices", ListDevices)
A_TrayMenu.Add("Open Config", OpenConfig)
A_TrayMenu.Add()
A_TrayMenu.Add("Reload", (*) => Reload())
A_TrayMenu.Add("Exit", (*) => ExitApp())
A_TrayMenu.Default := "List Audio Devices"

; --- Register Hotkeys ---
if isShiftAltMode {
    Hotkey("~*LAlt", ShiftAltDown)
    Hotkey("~*LAlt Up", ShiftAltUp)
} else {
    Hotkey(PushToTalkKey, OnKeyDown)
    Hotkey(PushToTalkKey " Up", OnKeyUp)
}

; --- Exit Handler ---
OnExit(CleanUp)

; --- Mic Warmup ---
StartMicWarmup() {
    global warmupPID, FfmpegPath, MicDevice
    ; Record to NUL to keep DirectShow device open and audio pipeline active
    cmd := 'cmd /c ""' FfmpegPath '" -f dshow -i audio="' MicDevice '" -f null NUL"'
    Run(cmd, A_ScriptDir, "Hide", &warmupPID)
}

StopMicWarmup() {
    global warmupPID
    if warmupPID and ProcessExist(warmupPID) {
        Run('cmd /c "taskkill /pid ' warmupPID ' 2>nul"', , "Hide")
        ProcessWaitClose(warmupPID, 2)
        if ProcessExist(warmupPID) {
            ProcessClose(warmupPID)
            ProcessWaitClose(warmupPID, 1)
        }
        warmupPID := 0
    }
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

; --- Hotkey Handlers ---
OnKeyDown(*) {
    global isRecording, isTranscribing, ffmpegPID

    if isRecording or isTranscribing
        return

    isRecording := true

    ; Delete stale temp file
    if FileExist(TempWav)
        FileDelete(TempWav)

    ; Update tray icon
    if FileExist(recordingIcon)
        TraySetIcon(recordingIcon)

    ; Kill warmup ffmpeg — device stays warm in the OS audio pipeline briefly
    StopMicWarmup()

    ; Start real recording immediately — device re-init is near-instant while warm
    cmd := 'cmd /c ""' FfmpegPath '" -f dshow -i audio="' MicDevice '" -ac 1 -ar 16000 -t 30 -y "' TempWav '""'
    Run(cmd, A_ScriptDir, "Hide", &ffmpegPID)

    ; Short wait for ffmpeg process to start (not full device init)
    Sleep(150)
    ToolTip("Recording...")
}

OnKeyUp(*) {
    global isRecording, isTranscribing, ffmpegPID

    if !isRecording
        return

    isRecording := false

    ; Stop ffmpeg gracefully
    if ffmpegPID {
        Run('cmd /c "taskkill /pid ' ffmpegPID ' 2>nul"', , "Hide")
        ProcessWaitClose(ffmpegPID, 3)
        if ProcessExist(ffmpegPID) {
            ProcessClose(ffmpegPID)
            ProcessWaitClose(ffmpegPID, 1)
        }
        ffmpegPID := 0
    }

    ; Wait for file system flush
    Sleep(300)

    ; Validate recording
    if !FileExist(TempWav) {
        ShowTooltipTimed("No recording captured", 2000)
        ResetIcon()
        StartMicWarmup()
        return
    }

    fileSize := FileGetSize(TempWav)
    if fileSize < 1000 {
        ShowTooltipTimed("Too short - try holding longer", 2000)
        ResetIcon()
        StartMicWarmup()
        return
    }

    ; Transcribe via whisper server (model already loaded — no startup cost)
    isTranscribing := true
    if FileExist(transcribingIcon)
        TraySetIcon(transcribingIcon)
    ToolTip("Transcribing...")

    ; Restart mic warmup while transcription runs
    StartMicWarmup()

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
        output := Trim(FileRead(tempOutput))
        FileDelete(tempOutput)
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
    cmd := '"' FfmpegPath '" -list_devices true -f dshow -i dummy 2>&1'
    wshell := ComObject("WScript.Shell")
    exec := wshell.Exec('cmd /c ' cmd)

    output := ""
    while !exec.StdOut.AtEndOfStream
        output .= exec.StdOut.ReadLine() "`n"

    devices := "Audio Input Devices:`n`n"
    inAudio := false
    for line in StrSplit(output, "`n") {
        if InStr(line, "DirectShow audio devices")
            inAudio := true
        else if InStr(line, "DirectShow video devices")
            inAudio := false
        else if inAudio and RegExMatch(line, '"(.+?)"', &m)
            devices .= "  " m[1] "`n"
    }

    MsgBox(devices "`nCopy the device name into config.ini [Audio] MicDevice", "Audio Devices")
}

OpenConfig(*) {
    Run(configPath)
}

CleanUp(exitReason, exitCode) {
    global ffmpegPID, warmupPID, serverPID, isCapsLockHotkey

    ; Kill any running ffmpeg
    if ffmpegPID and ProcessExist(ffmpegPID)
        ProcessClose(ffmpegPID)

    ; Kill warmup ffmpeg
    if warmupPID and ProcessExist(warmupPID)
        ProcessClose(warmupPID)

    ; Kill whisper server
    if serverPID and ProcessExist(serverPID)
        ProcessClose(serverPID)

    ; Restore CapsLock state
    if isCapsLockHotkey
        SetCapsLockState("Off")

    ; Clean temp files
    if FileExist(TempWav)
        FileDelete(TempWav)
}
