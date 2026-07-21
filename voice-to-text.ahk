#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook true
#Include lib\WebView2\WebView2.ahk
InstallKeybdHook()

configPath := A_ScriptDir "\config.ini"
logPath := EnvGet("LOCALAPPDATA") "\VoiceToText\logs\voice-to-text.log"
groqKeyPath := EnvGet("LOCALAPPDATA") "\VoiceToText\groq_api_key.txt"
onboardedPath := EnvGet("LOCALAPPDATA") "\VoiceToText\onboarded"
headsetNotifiedPath := EnvGet("LOCALAPPDATA") "\VoiceToText\headset_notified"
RunAsAdministrator := IniRead(configPath, "Startup", "RunAsAdministrator", "false") = "true"
settingsLaunchArgument := A_Args.Length > 0 and A_Args[1] = "--settings" ? " --settings" : ""
InitializeLogging()
OnError(LogUnhandledError)

; --- Optional elevation for hotkeys in elevated windows ---
if RunAsAdministrator and !A_IsAdmin {
    Run('*RunAs "' A_ScriptFullPath '"' settingsLaunchArgument)
    ExitApp()
}

; --- Global State ---
isRecording := false
isTranscribing := false
isKeyHeld := false
capturePID := 0
serverPID := 0
startupCancelled := false
startupProcessPID := 0
startupGui := 0
startupStatus := 0
startupDetail := 0
startupProgress := 0
settingsGui := 0
settingsHost := 0
settingsController := 0
settingsWebView := 0
settingsReady := false
settingsShowWhenReady := false
settingsLargeIcon := 0
settingsSmallIcon := 0

; --- Load Config ---
MicDevice := IniRead(configPath, "Audio", "MicDevice", "")
FollowWindowsDefault := IniRead(configPath, "Audio", "FollowWindowsDefault", "true") = "true"
MicCapturePath := A_ScriptDir "\" IniRead(configPath, "Paths", "MicCapturePath", "bin\mic-capture.exe")
WhisperServerPath := A_ScriptDir "\" IniRead(configPath, "Paths", "WhisperServerPath", "bin\whisper-server.exe")
ModelPath := A_ScriptDir "\" IniRead(configPath, "Paths", "ModelPath", "models\ggml-small.en.bin")
TempWav := A_ScriptDir "\" IniRead(configPath, "Paths", "TempWav", "temp\recording.wav")
FfmpegPath := A_ScriptDir "\" IniRead(configPath, "Paths", "FfmpegPath", "bin\ffmpeg.exe")
PushToTalkKey := IniRead(configPath, "Hotkey", "PushToTalk", "CapsLock")
userHotkey := PushToTalkKey
AutoHeadsetToggle := IniRead(configPath, "Hotkey", "AutoHeadsetToggle", "true") = "true"
HeadsetDeviceMatch := IniRead(configPath, "Hotkey", "HeadsetDeviceMatch", "EarPods")
headsetActive := false
headsetPollCount := 0
headsetLastDevice := ""
headsetStableCount := 0
TranscriptionEngine := NormalizeTranscriptionEngine(IniRead(configPath, "Transcription", "Engine", "Whisper"))
WhisperThreads := IniRead(configPath, "Whisper", "Threads", "16")
ServerPort := IniRead(configPath, "Whisper", "ServerPort", "8178")
GroqModel := IniRead(configPath, "Groq", "Model", "whisper-large-v3-turbo")
GroqLanguage := IniRead(configPath, "Groq", "Language", "en")
SendWordEnabled := IniRead(configPath, "Send", "Enabled", "false") = "true"
SendRules := LoadSendRules()
TabNavEnabled := IniRead(configPath, "TabNavigation", "Enabled", "true") = "true"
TabNavProcess := IniRead(configPath, "TabNavigation", "TargetProcess", "WindowsTerminal.exe")
CommandsEnabled := IniRead(configPath, "Commands", "Enabled", "false") = "true"
CommandWakeWord := Trim(IniRead(configPath, "Commands", "WakeWord", "computer"))
CommandModel := IniRead(configPath, "Commands", "Model", "llama-3.3-70b-versatile")
lastTranscriptionError := ""

; Ensure the temp directory exists — device queries redirect mic-capture output into it,
; and a fresh release zip omits empty folders, so it may be missing on first run.
if !DirExist(A_ScriptDir "\temp")
    DirCreate(A_ScriptDir "\temp")

; --- Validate Binaries ---
if !FileExist(MicCapturePath) {
    MsgBox("mic-capture.exe not found at:`n" MicCapturePath "`n`nBuild it with: dotnet publish tools\mic-capture -c Release -o bin", "Voice-to-Text", "Icon!")
    ExitApp()
}
if IsWhisperEngine() and !FileExist(WhisperServerPath) {
    MsgBox("whisper-server.exe not found at:`n" WhisperServerPath "`n`nRun setup.ps1 first.", "Voice-to-Text", "Icon!")
    ExitApp()
}

ShowStartupWindow()

if IsWhisperEngine() and !FileExist(ModelPath) {
    SplitPath(ModelPath, , &modelDir)
    if !DirExist(modelDir)
        DirCreate(modelDir)

    modelDetails := GetModelDetails(ModelPath)
    if !modelDetails {
        CloseStartupWindow()
        MsgBox("The selected model cannot be downloaded automatically:`n" ModelPath, "Voice-to-Text", "Icon!")
        ExitApp()
    }

    modelUrl := modelDetails.Url
    downloadPath := ModelPath ".download"
    if FileExist(downloadPath)
        FileDelete(downloadPath)

    SetStartupPhase("Downloading speech model", "Connecting...", false)
    expectedBytes := GetRemoteFileSize(modelUrl, modelDetails.ExpectedBytes)

    try {
        downloadCmd := 'curl.exe -L --fail --retry 2 --output "' downloadPath '" "' modelUrl '"'
        Run(downloadCmd, A_ScriptDir, "Hide", &startupProcessPID)
    } catch as downloadError {
        LogError("Starting model download", downloadError)
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
isCustomHotkey := !HasValue(["ShiftAlt", "CapsLock", "F13", "ScrollLock", "Media_Play_Pause"], PushToTalkKey)
isToggleHotkey := IsMediaHotkey(PushToTalkKey)
shiftAltActive := false

OnExit(CleanUp)

if IsWhisperEngine() {
    ; --- Start Whisper Server (keeps model warm in memory) ---
    SetStartupPhase("Starting speech engine", "Loading the speech model. This can take up to 30 seconds.", true)
    serverReady := StartWhisperServer(30000, () => startupCancelled)
    if startupCancelled {
        CloseStartupWindow()
        ExitApp()
    }

    if !serverReady {
        CloseStartupWindow()
        StopWhisperServer()
        retryStartup := MsgBox("The speech engine failed to start within 30 seconds.`nCheck that port " ServerPort " is available.", "Voice-to-Text", "RetryCancel Icon!")
        if retryStartup = "Retry"
            Reload()
        ExitApp()
    }
} else {
    groqPhaseDetail := GetGroqApiKey() = "" ? "Add your Groq API key in Settings to start transcribing." : "Using Groq for transcription."
    SetStartupPhase("Checking Groq API settings", groqPhaseDetail, false, 100)
    Sleep(300)
    if startupCancelled {
        CloseStartupWindow()
        ExitApp()
    }
}

StartWhisperServer(timeoutMs := 30000, shouldCancel := 0) {
    global serverPID, WhisperServerPath, ModelPath, ServerPort, WhisperThreads
    if serverPID and ProcessExist(serverPID)
        return true

    serverCmd := '"' WhisperServerPath '" -m "' ModelPath '" --port ' ServerPort ' --threads ' WhisperThreads
    Run(serverCmd, A_ScriptDir, "Hide", &serverPID)

    startTime := A_TickCount
    while (A_TickCount - startTime < timeoutMs) {
        if IsObject(shouldCancel) and shouldCancel.Call()
            return false

        try {
            http := ComObject("WinHttp.WinHttpRequest.5.1")
            http.Open("GET", "http://127.0.0.1:" ServerPort, false)
            http.Send()
            if (http.Status = 200)
                return true
        }
        Sleep(500)
    }

    return false
}

StopWhisperServer() {
    global serverPID
    if serverPID and ProcessExist(serverPID)
        ProcessClose(serverPID)
    serverPID := 0
}

SwitchTranscriptionEngine(engine) {
    global TranscriptionEngine, configPath, WhisperServerPath, ModelPath
    if engine = TranscriptionEngine
        return

    if engine = "Groq" {
        if GetGroqApiKey() = ""
            throw ValueError("GROQ_API_KEY is not set")
        StopWhisperServer()
    } else {
        if !FileExist(WhisperServerPath)
            throw ValueError("whisper-server.exe not found")
        if !FileExist(ModelPath)
            throw ValueError("Speech model not found")
        if !StartWhisperServer(30000)
            throw ValueError("The speech engine failed to start")
    }

    TranscriptionEngine := engine
    IniWrite(engine, configPath, "Transcription", "Engine")
    WriteLog("INFO", "Transcription engine changed to " engine)
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
A_TrayMenu.Add("Settings", ShowSettings)
A_TrayMenu.Add("Run as Administrator", ToggleAdministratorMode)
if RunAsAdministrator
    A_TrayMenu.Check("Run as Administrator")
A_TrayMenu.Add()
A_TrayMenu.Add("Reload", (*) => Reload())
A_TrayMenu.Add("Exit", (*) => ExitApp())
A_TrayMenu.Default := "Settings"
A_TrayMenu.ClickCount := 2

if (A_Args.Length > 0 and A_Args[1] = "--settings") or (IsGroqEngine() and GetGroqApiKey() = "")
    SetTimer(ShowSettings, -1)
else
    SetTimer(InitializeSettings, -1)

; --- Register Hotkeys ---
RegisterPushToTalkHotkey()

; --- Auto-switch to the headphone toggle when EarPods become the default device ---
OnMessage(0x0219, OnDeviceChange)    ; WM_DEVICECHANGE
OnMessage(0x0218, OnPowerBroadcast)  ; WM_POWERBROADCAST (catch sleep/resume)
EvaluateHeadsetHotkey()
SetTimer(EvaluateHeadsetHotkey, 10000)  ; periodic backstop; no-op (and no process spawn) when auto-switch is off

; --- Headset volume buttons navigate tabs in the target app (suppressing the volume change) ---
if TabNavEnabled
    RegisterTabNavigation()

RegisterTabNavigation() {
    global tabNavGui, tabNavMsg, tabNavVolume
    if IsSet(tabNavGui) && tabNavGui
        return
    tabNavGui := Gui()  ; hidden helper window; the shell delivers app-commands here
    tabNavMsg := DllCall("RegisterWindowMessage", "Str", "SHELLHOOK", "UInt")
    DllCall("RegisterShellHookWindow", "Ptr", tabNavGui.Hwnd)
    OnMessage(tabNavMsg, OnShellHook)
    tabNavVolume := SoundGetVolume()
    SetTimer(TrackTabNavVolume, 400)
}

UnregisterTabNavigation() {
    global tabNavGui, tabNavMsg
    if !(IsSet(tabNavGui) && tabNavGui)
        return
    SetTimer(TrackTabNavVolume, 0)
    DllCall("DeregisterShellHookWindow", "Ptr", tabNavGui.Hwnd)
    OnMessage(tabNavMsg, OnShellHook, 0)
    tabNavGui.Destroy()
    tabNavGui := ""
}

; Remember the real volume while the target app isn't focused, so we can restore to it.
TrackTabNavVolume() {
    global TabNavProcess, tabNavVolume
    if !WinActive("ahk_exe " TabNavProcess)
        tabNavVolume := SoundGetVolume()
}

; Volume app-commands bubble up to the shell hook when the focused app ignores them.
; Windows still applies the volume change (explorer handles its own copy), so we snap it back.
OnShellHook(wParam, lParam, msg, hwnd) {
    global TabNavProcess, tabNavVolume
    if (wParam != 12)  ; HSHELL_APPCOMMAND
        return
    cmd := (lParam >> 16) & 0x0FFF
    if (cmd != 10 && cmd != 9)  ; APPCOMMAND_VOLUME_UP / _DOWN
        return
    if !WinActive("ahk_exe " TabNavProcess)
        return
    Send(cmd = 10 ? "^{Tab}" : "^+{Tab}")  ; volume up -> next tab, down -> previous
    SoundSetVolume(tabNavVolume)
    return 1
}

RegisterPushToTalkHotkey() {
    global isShiftAltMode, isCustomHotkey, isToggleHotkey, PushToTalkKey
    if isShiftAltMode {
        Hotkey("~*LAlt", ShiftAltDown)
        Hotkey("~*LAlt Up", ShiftAltUp)
        Hotkey("~*LAlt", "On")
        Hotkey("~*LAlt Up", "On")
    } else if isToggleHotkey {
        Hotkey(PushToTalkKey, OnToggleKey)
        Hotkey(PushToTalkKey, "On")
    } else if isCustomHotkey {
        Hotkey(PushToTalkKey, OnKeyDown)
        Hotkey("~*" GetHotkeyBaseKey(PushToTalkKey) " Up", OnKeyUp)
        Hotkey(PushToTalkKey, "On")
        Hotkey("~*" GetHotkeyBaseKey(PushToTalkKey) " Up", "On")
    } else {
        Hotkey(PushToTalkKey, OnKeyDown)
        Hotkey(PushToTalkKey " Up", OnKeyUp)
        Hotkey(PushToTalkKey, "On")
        Hotkey(PushToTalkKey " Up", "On")
    }
}

UnregisterPushToTalkHotkey() {
    global isShiftAltMode, isCustomHotkey, isToggleHotkey, PushToTalkKey
    if isShiftAltMode {
        Hotkey("~*LAlt", "Off")
        Hotkey("~*LAlt Up", "Off")
    } else if isToggleHotkey {
        Hotkey(PushToTalkKey, "Off")
    } else if isCustomHotkey {
        Hotkey(PushToTalkKey, "Off")
        Hotkey("~*" GetHotkeyBaseKey(PushToTalkKey) " Up", "Off")
    } else {
        Hotkey(PushToTalkKey, "Off")
        Hotkey(PushToTalkKey " Up", "Off")
    }
}

ApplyPushToTalkHotkey(newHotkey) {
    global PushToTalkKey, isShiftAltMode, isCustomHotkey, isToggleHotkey, isCapsLockHotkey
    global originalCapsLockState, shiftAltActive, isRecording

    oldHotkey := PushToTalkKey
    oldShiftAltMode := isShiftAltMode
    oldCustomHotkey := isCustomHotkey
    oldToggleHotkey := isToggleHotkey
    oldCapsLockHotkey := isCapsLockHotkey
    oldCapsLockState := originalCapsLockState

    if isRecording
        AbortRecording()
    shiftAltActive := false
    UnregisterPushToTalkHotkey()
    if oldCapsLockHotkey
        SetCapsLockState(oldCapsLockState)

    PushToTalkKey := newHotkey
    isShiftAltMode := newHotkey = "ShiftAlt"
    isCustomHotkey := !HasValue(["ShiftAlt", "CapsLock", "F13", "ScrollLock", "Media_Play_Pause"], newHotkey)
    isToggleHotkey := IsMediaHotkey(newHotkey)
    isCapsLockHotkey := newHotkey = "CapsLock"
    if isCapsLockHotkey {
        originalCapsLockState := GetKeyState("CapsLock", "T") ? "On" : "Off"
        SetCapsLockState("AlwaysOff")
    }

    try {
        RegisterPushToTalkHotkey()
    } catch as error {
        if isCapsLockHotkey
            SetCapsLockState(originalCapsLockState)
        PushToTalkKey := oldHotkey
        isShiftAltMode := oldShiftAltMode
        isCustomHotkey := oldCustomHotkey
        isToggleHotkey := oldToggleHotkey
        isCapsLockHotkey := oldCapsLockHotkey
        originalCapsLockState := oldCapsLockState
        if isCapsLockHotkey
            SetCapsLockState("AlwaysOff")
        RegisterPushToTalkHotkey()
        throw error
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

; --- Check if push-to-talk key is still held ---
IsHotkeyHeld() {
    global isShiftAltMode, PushToTalkKey, isKeyHeld
    if isShiftAltMode
        return GetKeyState("LShift", "P") and GetKeyState("LAlt", "P")
    ; Media/remote keys don't report a physical held state via GetKeyState, so rely on the down/up events.
    if IsMediaHotkey(PushToTalkKey)
        return isKeyHeld
    return GetKeyState(GetHotkeyBaseKey(PushToTalkKey), "P")
}

IsMediaHotkey(value) {
    return RegExMatch(value, "i)^(Media_|Volume_|Launch_|Browser_)") > 0
}

GetHotkeyBaseKey(hotkeyValue) {
    return RegExReplace(hotkeyValue, "^[\^!+#]+")
}

; --- Auto headset-toggle switching ---
OnDeviceChange(wParam, lParam, msg, hwnd) {
    StartHeadsetPoll()
}

OnPowerBroadcast(wParam, lParam, msg, hwnd) {
    ; PBT_APMRESUMESUSPEND (0x07) / PBT_APMRESUMEAUTOMATIC (0x12): re-check after waking.
    if wParam = 0x07 or wParam = 0x12
        StartHeadsetPoll()
}

StartHeadsetPoll() {
    global headsetPollCount, headsetLastDevice, headsetStableCount
    headsetPollCount := 0
    headsetStableCount := 0
    headsetLastDevice := "`n"  ; sentinel that won't match any real reading
    SetTimer(HeadsetPoll, -150)  ; near-immediate first check; HeadsetPoll re-arms itself
}

HeadsetPoll(*) {
    global headsetPollCount, headsetLastDevice, headsetStableCount
    headsetPollCount += 1
    device := EvaluateHeadsetHotkey()
    ; Poll at a steady fast rate (Windows can take a couple of seconds to promote a newly-connected device
    ; to default), and stop once the reading settles so we don't spawn the query process indefinitely.
    if device = headsetLastDevice
        headsetStableCount += 1
    else
        headsetStableCount := 0
    headsetLastDevice := device
    if headsetStableCount >= 3 or headsetPollCount >= 40
        return  ; settled (or hard cap); the 10s backstop covers anything beyond
    SetTimer(HeadsetPoll, -300)
}

GetDefaultCaptureDevice() {
    global MicCapturePath
    tempOut := A_ScriptDir "\temp\default_device.txt"
    try {
        if FileExist(tempOut)
            FileDelete(tempOut)
        RunWait('cmd /c ""' MicCapturePath '" default > "' tempOut '""', A_ScriptDir, "Hide")
        if FileExist(tempOut) {
            name := Trim(FileRead(tempOut), " `t`r`n")
            FileDelete(tempOut)
            return name
        }
    }
    return ""
}

EvaluateHeadsetHotkey(*) {
    global AutoHeadsetToggle, FollowWindowsDefault, HeadsetDeviceMatch
    global userHotkey, PushToTalkKey, headsetActive, isRecording, isTranscribing

    ; Don't change the hotkey mid-recording; the periodic backstop and device-change poll will retry.
    if isRecording or isTranscribing
        return ""

    desired := userHotkey
    device := ""
    if AutoHeadsetToggle and FollowWindowsDefault and HeadsetDeviceMatch != "" {
        device := GetDefaultCaptureDevice()
        headsetActive := InStr(device, HeadsetDeviceMatch) > 0
        if headsetActive
            desired := "Media_Play_Pause"
    } else {
        headsetActive := false
    }

    if desired != PushToTalkKey {
        try {
            ApplyPushToTalkHotkey(desired)
            WriteLog("INFO", "Auto-switched push-to-talk to " desired " (default device: " device ")")
            if headsetActive
                NotifyHeadsetToggle()
        } catch as switchError {
            LogError("Auto headset hotkey switch", switchError)
        }
    }
    return device
}

NotifyHeadsetToggle() {
    global headsetNotifiedPath
    if FileExist(headsetNotifiedPath)
        return
    SplitPath(headsetNotifiedPath, , &dir)
    if !DirExist(dir)
        DirCreate(dir)
    FileAppend("", headsetNotifiedPath)
    ; No icon-type flag, so Windows uses the app's own icon instead of the generic info icon.
    TrayTip("Push-to-talk switched to your earphone button. Click it once to start recording, click again to stop.", "Headphones connected")
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
; Toggle keys (e.g. a headset button) can't hold-to-talk — holding the button grounds the mic — so click to start, click to stop.
OnToggleKey(*) {
    global isRecording, isTranscribing
    if isTranscribing
        return
    if isRecording
        OnKeyUp()
    else
        OnKeyDown()
}

OnKeyDown(*) {
    global isRecording, isTranscribing, capturePID, isKeyHeld, isToggleHotkey

    isKeyHeld := true
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
        ; Abort if user released the hotkey during startup (hold-to-talk only; toggle keys expect a release)
        if !isToggleHotkey and !IsHotkeyHeld() {
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
    global isRecording, isTranscribing, capturePID, lastTranscriptionError, isKeyHeld
    global SendWordEnabled, SendRules, CommandsEnabled, CommandWakeWord

    isKeyHeld := false
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

    isTranscribing := true
    if FileExist(transcribingIcon)
        TraySetIcon(transcribingIcon)
    ToolTip("Transcribing...")

    output := TranscribeAudio(TempWav)

    if (output = "" or InStr(output, "[BLANK_AUDIO]")) {
        ShowTooltipTimed(lastTranscriptionError != "" ? lastTranscriptionError : "No speech detected", 2000)
        isTranscribing := false
        ResetIcon()
        return
    }

    ; Voice command mode: if the transcript starts with the wake word, route it to the LLM instead of pasting.
    if CommandsEnabled and CommandWakeWord != "" {
        escapedWake := RegExReplace(CommandWakeWord, "([\\.\*\?\+\[\]\{\}\(\)\^\$\|\/])", "\$1")
        wakePattern := "i)^\s*" escapedWake "\b[\s,\.:;]*"
        if RegExMatch(output, wakePattern) {
            RunVoiceCommand(RegExReplace(output, wakePattern, ""))
            isTranscribing := false
            ResetIcon()
            return
        }
    }

    ; Optional send rules: if the transcript ends with a trigger word, strip it and press its mapped keys after pasting.
    sendKeys := ""
    if SendWordEnabled {
        for rule in SendRules {
            trigger := Trim(rule.word)
            if trigger = ""
                continue
            escaped := RegExReplace(trigger, "([\\.\*\?\+\[\]\{\}\(\)\^\$\|\/])", "\$1")
            trailingPattern := "i)(?:\s+|^)" escaped "[\s\.\,\!\?\;\:]*$"
            if RegExMatch(output, trailingPattern) {
                output := RegExReplace(output, trailingPattern, "")
                ; The model often inserts a comma before the trigger word; drop trailing comma-family punctuation but keep sentence-ending . ! ?
                output := RegExReplace(output, "[\s,;:]+$", "")
                sendKeys := rule.keys
                break
            }
        }
    }

    ; Copy to clipboard and paste into the focused input (trailing space so consecutive dictations don't run together)
    sendNow := sendKeys != ""
    pasteText := sendNow ? output : output " "
    A_Clipboard := pasteText
    if pasteText != "" {
        ClipWait(1)
        SendInput("^v")
    }
    if sendNow {
        ; Windows ignores synthetic Win+L, so trigger the lock through the API instead.
        if RegExMatch(sendKeys, "i)^#\{l\}$")
            DllCall("user32\LockWorkStation")
        else
            SendInput(sendKeys)
    }

    preview := StrLen(output) > 50 ? SubStr(output, 1, 50) "..." : (output != "" ? output : (sendNow ? FormatSendKeys(sendKeys) : "(empty)"))
    ShowTooltipTimed((sendNow ? "Sent: " : "Pasted: ") preview, 3000)

    isTranscribing := false
    ResetIcon()
}

; --- Helper Functions ---
NormalizeTranscriptionEngine(value) {
    value := StrLower(String(value))
    switch value {
        case "groq", "grok", "xai":
            return "Groq"
        default:
            return "Whisper"
    }
}

IsWhisperEngine() {
    global TranscriptionEngine
    return TranscriptionEngine = "Whisper"
}

IsGroqEngine() {
    global TranscriptionEngine
    return TranscriptionEngine = "Groq"
}

GetGroqApiKey() {
    global groqKeyPath
    if FileExist(groqKeyPath) {
        stored := Trim(FileRead(groqKeyPath))
        if stored != ""
            return stored
    }
    return EnvGet("GROQ_API_KEY")
}

TranscribeAudio(audioPath) {
    if IsGroqEngine()
        return TranscribeWithGroq(audioPath)
    return TranscribeWithWhisper(audioPath)
}

TranscribeWithWhisper(audioPath) {
    global ServerPort, lastTranscriptionError
    lastTranscriptionError := ""
    tempOutput := A_ScriptDir "\temp\whisper_output.txt"
    if FileExist(tempOutput)
        FileDelete(tempOutput)

    curlCmd := 'cmd /c "curl -s -X POST'
        . " http://127.0.0.1:" ServerPort "/inference"
        . ' -F "file=@' audioPath '"'
        . ' -F "response_format=text"'
        . ' -F "temperature=0.0"'
        . ' > "' tempOutput '" 2>&1"'
    exitCode := RunWait(curlCmd, A_ScriptDir, "Hide")

    raw := ""
    if FileExist(tempOutput) {
        raw := Trim(FileRead(tempOutput))
        FileDelete(tempOutput)
    }

    if exitCode != 0 {
        lastTranscriptionError := "Transcription failed"
        LogError("Whisper transcription failed", raw)
        return ""
    }

    return NormalizeTranscriptText(raw)
}

TranscribeWithGroq(audioPath) {
    global GroqModel, GroqLanguage, lastTranscriptionError
    lastTranscriptionError := ""
    apiKey := GetGroqApiKey()
    if apiKey = "" {
        lastTranscriptionError := "GROQ_API_KEY is not set"
        return ""
    }

    tempOutput := A_ScriptDir "\temp\groq_output.txt"
    if FileExist(tempOutput)
        FileDelete(tempOutput)

    ; Groq caps uploads at 25MB; the raw WAV is the device's native format (often
    ; 48kHz stereo float), so downsample to 16kHz mono FLAC before sending.
    uploadPath := CompressForGroq(audioPath)

    curlCmd := 'cmd /c "curl -sS -X POST https://api.groq.com/openai/v1/audio/transcriptions'
        . ' -H "Authorization: Bearer ' . apiKey . '"'
        . ' -F "model=' . GroqModel . '"'
        . ' -F "language=' . GroqLanguage . '"'
        . ' -F "temperature=0"'
        . ' -F "response_format=text"'
        . ' -F "file=@' . uploadPath . '"'
        . ' -w "\n__HTTP__%{http_code}"'
        . ' > "' tempOutput '" 2>&1"'
    exitCode := RunWait(curlCmd, A_ScriptDir, "Hide")
    if uploadPath != audioPath
        try FileDelete(uploadPath)

    raw := ""
    if FileExist(tempOutput) {
        raw := Trim(FileRead(tempOutput))
        FileDelete(tempOutput)
    }

    status := 0
    body := raw
    if RegExMatch(raw, "__HTTP__(\d+)\s*$", &statusMatch) {
        status := Integer(statusMatch[1])
        body := Trim(SubStr(raw, 1, statusMatch.Pos - 1))
    }

    if exitCode != 0 and status = 0 {
        lastTranscriptionError := "Groq request failed (network or curl error)"
        LogError("Groq request failed", raw)
        return ""
    }

    if status = 413 {
        lastTranscriptionError := "Recording too long for Groq - try a shorter clip"
        LogError("Groq API returned HTTP 413 (payload too large)", body)
        return ""
    }

    if status != 200 {
        detail := ParseJsonString(body, "message")
        lastTranscriptionError := detail != "" ? detail : "Groq API returned HTTP " status
        LogError("Groq API returned HTTP " status, body)
        return ""
    }

    output := NormalizeTranscriptText(body)
    if output = "" {
        lastTranscriptionError := "Groq returned no transcript"
        LogError("Groq response empty", body)
        return ""
    }

    return output
}

CompressForGroq(audioPath) {
    global FfmpegPath
    if !FileExist(FfmpegPath)
        return audioPath

    flacPath := RegExReplace(audioPath, "\.wav$", "") . ".flac"
    if FileExist(flacPath)
        try FileDelete(flacPath)

    ffmpegCmd := 'cmd /c ""' FfmpegPath '" -y -i "' audioPath '" -ac 1 -ar 16000 "' flacPath '""'
    RunWait(ffmpegCmd, A_ScriptDir, "Hide")

    if FileExist(flacPath)
        return flacPath

    LogError("ffmpeg compression failed, sending raw WAV", audioPath)
    return audioPath
}

NormalizeTranscriptText(text) {
    text := RegExReplace(Trim(text), "\s+", " ")
    return Trim(text)
}

ParseJsonString(json, propertyName) {
    pattern := '"' . propertyName . '"\s*:\s*"((?:\\.|[^"\\])*)"'
    if RegExMatch(json, pattern, &match)
        return JsonUnescape(match[1])
    return ""
}

JsonUnescape(value) {
    while RegExMatch(value, "\\u([0-9A-Fa-f]{4})", &match)
        value := StrReplace(value, match[0], Chr(Integer("0x" match[1])))
    value := StrReplace(value, '\"', '"')
    value := StrReplace(value, '\n', "`n")
    value := StrReplace(value, '\r', "`r")
    value := StrReplace(value, '\t', "`t")
    value := StrReplace(value, '\\', '\')
    return value
}

JsonEscape(value) {
    value := StrReplace(value, '\', '\\')
    value := StrReplace(value, '"', '\"')
    value := StrReplace(value, "`r", '\r')
    value := StrReplace(value, "`n", '\n')
    value := StrReplace(value, "`t", '\t')
    return value
}

; Visible top-level windows with a title, for the model to pick from when focusing.
GetCommandWindows() {
    result := []
    for hwnd in WinGetList() {
        title := ""
        try title := WinGetTitle("ahk_id " hwnd)
        if title = ""
            continue
        exe := ""
        try exe := WinGetProcessName("ahk_id " hwnd)
        if exe = ""
            continue
        result.Push({ hwnd: hwnd, title: title, exe: exe })
        if result.Length >= 40
            break
    }
    return result
}

; User-authored launch aliases from [CommandAliases] (e.g. email=outlook.exe). Values are trusted.
GetCommandAliases() {
    global configPath
    aliases := Map()
    raw := ""
    try raw := IniRead(configPath, "CommandAliases")
    for line in StrSplit(raw, "`n") {
        pos := InStr(line, "=")
        if pos < 2
            continue
        name := Trim(SubStr(line, 1, pos - 1))
        target := Trim(SubStr(line, pos + 1))
        if name != "" and target != ""
            aliases[StrLower(name)] := target
    }
    return aliases
}

RunVoiceCommand(commandText) {
    commandText := Trim(commandText)
    if commandText = "" {
        ShowTooltipTimed("No command heard", 2000)
        return
    }
    if GetGroqApiKey() = "" {
        ShowTooltipTimed("Voice commands need a Groq API key (Settings)", 3000)
        return
    }

    windows := GetCommandWindows()
    aliases := GetCommandAliases()
    action := AskGroqForCommand(commandText, windows, aliases)
    if !IsObject(action) {
        ShowTooltipTimed("Command failed", 2500)
        return
    }
    ExecuteCommandAction(action, windows, aliases)
}

AskGroqForCommand(commandText, windows, aliases) {
    global CommandModel

    windowList := ""
    for index, win in windows
        windowList .= index ". " win.title " [" win.exe "]`n"
    if windowList = ""
        windowList := "(none open)"

    aliasList := ""
    for name, target in aliases
        aliasList .= "- " name "`n"
    if aliasList = ""
        aliasList := "(none configured)"

    schema := 'Schema: {"action":"focus|launch|tab|keys|none","window":<number or null>,"query":"<tab name or null>","app":"<alias or executable or null>","keys":"<AHK send string or null>","then":"<AHK send string to press after focusing/launching or null>"}'
    systemPrompt := "You route a spoken desktop command to ONE action. Reply with JSON only.`n"
        . "Open windows (use the number to focus one):`n" . windowList
        . "Launch aliases (use the alias name):`n" . aliasList
        . schema . "`n"
        . "Rules:`n"
        . "- switch to / go to / go back to an open window => focus, with its number.`n"
        . "- go to / open the <name> tab (in a browser window) => tab, with the browser window number and query set to <name>.`n"
        . "- open / launch / start an app => launch. Use a listed alias name if one fits, otherwise a runnable executable. "
        . "Common apps: notepad=notepad.exe, calculator=calc.exe, edge or browser=msedge.exe, chrome=chrome.exe, files or explorer=explorer.exe, word=winword.exe, excel=excel.exe, email or outlook=outlook.exe, terminal=wt.exe, task manager=taskmgr.exe.`n"
        . "- a keyboard shortcut => keys (e.g. !{F4} for Alt+F4, #{l} to lock the screen).`n"
        . "- if the request also asks to do something in the app after opening it, set then to the shortcut. To start a new email in Outlook use then ^+m. New document/item is usually ^n.`n"
        . "- prefer focus over launch when the app is already in the open windows list.`n"
        . "- use none only if nothing matches.`n"
        . 'Examples: {"action":"launch","app":"notepad.exe"} | {"action":"launch","app":"outlook.exe","then":"^+m"} | {"action":"focus","window":2,"then":"^+m"} | {"action":"tab","window":3,"query":"GitHub"} | {"action":"keys","keys":"!{F4}"}'

    body := '{"model":"' . CommandModel . '","temperature":0,"response_format":{"type":"json_object"},"messages":['
        . '{"role":"system","content":"' . JsonEscape(systemPrompt) . '"},'
        . '{"role":"user","content":"' . JsonEscape(commandText) . '"}]}'

    bodyPath := A_ScriptDir "\temp\command_request.json"
    outPath := A_ScriptDir "\temp\command_output.txt"
    requestFile := FileOpen(bodyPath, "w", "UTF-8-RAW")
    requestFile.Write(body)
    requestFile.Close()
    if FileExist(outPath)
        FileDelete(outPath)

    curlCmd := 'cmd /c "curl -sS -X POST https://api.groq.com/openai/v1/chat/completions'
        . ' -H "Authorization: Bearer ' . GetGroqApiKey() . '"'
        . ' -H "Content-Type: application/json"'
        . ' --data-binary "@' . bodyPath . '"'
        . ' -w "\n__HTTP__%{http_code}"'
        . ' > "' . outPath . '" 2>&1"'
    exitCode := RunWait(curlCmd, A_ScriptDir, "Hide")

    raw := ""
    if FileExist(outPath) {
        raw := Trim(FileRead(outPath))
        FileDelete(outPath)
    }
    if FileExist(bodyPath)
        FileDelete(bodyPath)

    status := 0
    respBody := raw
    if RegExMatch(raw, "__HTTP__(\d+)\s*$", &statusMatch) {
        status := Integer(statusMatch[1])
        respBody := Trim(SubStr(raw, 1, statusMatch.Pos - 1))
    }
    if exitCode != 0 and status = 0 {
        LogError("Command request failed", raw)
        return ""
    }
    if status != 200 {
        LogError("Command API returned HTTP " status, respBody)
        return ""
    }

    content := ParseJsonString(respBody, "content")
    if content = "" {
        LogError("Command response empty", respBody)
        return ""
    }

    action := { action: StrLower(ParseJsonString(content, "action")), app: ParseJsonString(content, "app"), keys: ParseJsonString(content, "keys"), query: ParseJsonString(content, "query"), then: ParseJsonString(content, "then"), window: 0 }
    if RegExMatch(content, '"window"\s*:\s*(\d+)', &windowMatch)
        action.window := Integer(windowMatch[1])
    return action
}

ExecuteCommandAction(action, windows, aliases) {
    switch action.action {
        case "focus":
            if action.window >= 1 and action.window <= windows.Length {
                win := windows[action.window]
                WinActivate("ahk_id " win.hwnd)
                SendThenKeys(action.then, "ahk_id " win.hwnd, 4)
                ShowTooltipTimed("Focused: " win.title, 2500)
            } else {
                ShowTooltipTimed("No matching window", 2500)
            }
        case "launch":
            aliasKey := StrLower(action.app)
            target := aliases.Has(aliasKey) ? aliases[aliasKey] : action.app
            if target != "" and (aliases.Has(aliasKey) or RegExMatch(target, "i)^[\w.\-]+$")) {
                try {
                    Run(target)
                    SendThenKeys(action.then, "ahk_exe " LaunchExeName(target), 20)
                    ShowTooltipTimed("Launched: " target, 2500)
                } catch {
                    ShowTooltipTimed("Couldn't launch " target, 2500)
                }
            } else {
                ShowTooltipTimed("Nothing to launch", 2500)
            }
        case "tab":
            if action.window >= 1 and action.window <= windows.Length {
                win := windows[action.window]
                if FocusTab(win.hwnd, action.query) {
                    SendThenKeys(action.then, "ahk_id " win.hwnd, 4)
                    ShowTooltipTimed("Tab: " action.query, 2500)
                } else {
                    ShowTooltipTimed("Tab not found: " action.query, 2500)
                }
            } else {
                ShowTooltipTimed("No matching window", 2500)
            }
        case "keys":
            if action.keys != "" {
                if RegExMatch(action.keys, "i)^#\{l\}$")
                    DllCall("user32\LockWorkStation")
                else
                    SendInput(action.keys)
                ShowTooltipTimed("Sent: " FormatSendKeys(action.keys), 2500)
            } else {
                ShowTooltipTimed("Command not understood", 2500)
            }
        default:
            ShowTooltipTimed("Command not understood", 2500)
    }
}

; Cycle a browser window's tabs (Ctrl+Tab) until the active tab's title contains the query.
FocusTab(hwnd, query) {
    query := Trim(query)
    WinActivate("ahk_id " hwnd)
    WinWaitActive("ahk_id " hwnd, , 2)
    if query = ""
        return false
    firstTitle := ""
    try firstTitle := WinGetTitle("ahk_id " hwnd)
    if InStr(firstTitle, query)
        return true
    loop 40 {
        SendInput("^{Tab}")
        Sleep(130)
        current := ""
        try current := WinGetTitle("ahk_id " hwnd)
        if InStr(current, query)
            return true
        if current = firstTitle
            return false
    }
    return false
}

; Press a follow-up shortcut once the target window is present and active (for launch: waits for it to load).
SendThenKeys(keys, winSpec, waitSeconds) {
    if Trim(keys) = ""
        return
    if !WinWait(winSpec, , waitSeconds)
        return
    WinActivate(winSpec)
    WinWaitActive(winSpec, , 3)
    Sleep(700)
    SendInput(keys)
}

LaunchExeName(target) {
    SplitPath(target, &name)
    if !InStr(name, ".")
        name .= ".exe"
    return name
}

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

InitializeLogging() {
    global logPath
    SplitPath(logPath, , &logDirectory)
    if !DirExist(logDirectory)
        DirCreate(logDirectory)
    RotateLogIfNeeded()
    WriteLog("INFO", "Voice-to-Text started")
}

RotateLogIfNeeded() {
    global logPath
    if !FileExist(logPath) or FileGetSize(logPath) < 1048576
        return

    previousLogPath := StrReplace(logPath, ".log", ".previous.log")
    if FileExist(previousLogPath)
        FileDelete(previousLogPath)
    FileMove(logPath, previousLogPath)
}

WriteLog(level, message) {
    global logPath
    try {
        RotateLogIfNeeded()
        cleanMessage := StrReplace(StrReplace(String(message), "`r", " "), "`n", " | ")
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " [" level "] " cleanMessage "`r`n", logPath, "UTF-8")
    }
}

LogError(context, error := "") {
    if IsObject(error) {
        details := context ": " error.Message
        if error.File != ""
            details .= " (" error.File ":" error.Line ")"
        if error.Stack != ""
            details .= " | " error.Stack
        WriteLog("ERROR", details)
    } else {
        WriteLog("ERROR", context (error != "" ? ": " error : ""))
    }
}

LogUnhandledError(error, mode) {
    LogError("Unhandled " mode " error", error)
    return false
}

GetModelDetails(modelPath) {
    SplitPath(modelPath, &fileName)
    switch fileName {
        case "ggml-small.en.bin":
            return {
                Key: "small.en",
                Url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin",
                ExpectedBytes: 487614201
            }
        case "ggml-medium.en.bin":
            return {
                Key: "medium.en",
                Url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin",
                ExpectedBytes: 1533774781
            }
    }
    return 0
}

GetModelPath(modelKey) {
    switch modelKey {
        case "small.en":
            return A_ScriptDir "\models\ggml-small.en.bin"
        case "medium.en":
            return A_ScriptDir "\models\ggml-medium.en.bin"
    }
    return ""
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

GetAudioDevices() {
    global MicCapturePath
    tempDevices := A_ScriptDir "\temp\devices.txt"
    if FileExist(tempDevices)
        FileDelete(tempDevices)

    cmd := 'cmd /c ""' MicCapturePath '" list > "' tempDevices '" 2>&1"'
    RunWait(cmd, A_ScriptDir, "Hide")

    deviceList := []
    if FileExist(tempDevices) {
        content := FileRead(tempDevices)
        for line in StrSplit(content, "`n") {
            line := Trim(line)
            if line != ""
                deviceList.Push(line)
        }
        FileDelete(tempDevices)
    }

    return deviceList
}

GetWindowsDefaultAudioDevice() {
    global MicCapturePath
    defaultDeviceFile := A_ScriptDir "\temp\default-device.txt"
    if FileExist(defaultDeviceFile)
        FileDelete(defaultDeviceFile)

    command := 'cmd /c ""' MicCapturePath '" default > "' defaultDeviceFile '" 2>&1"'
    try RunWait(command, A_ScriptDir, "Hide")
    if FileExist(defaultDeviceFile) {
        defaultDevice := Trim(FileRead(defaultDeviceFile))
        FileDelete(defaultDeviceFile)
        return defaultDevice
    }
    return ""
}

ListDevices(*) {
    global FollowWindowsDefault, MicDevice, configPath
    deviceList := ["Windows default (follows system changes)"]
    for device in GetAudioDevices()
        deviceList.Push(device)

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
    global configPath
    Run(configPath)
}

ShowSettings(*) {
    global settingsGui, settingsController, settingsReady, settingsShowWhenReady
    settingsShowWhenReady := true
    if !settingsGui
        InitializeSettings(true)
    else if settingsReady {
        settingsGui.Show()
        settingsController.Fill()
        settingsController.IsVisible := true
    }
}

InitializeSettings(showWhenReady := false) {
    global settingsGui, settingsHost, settingsController, settingsWebView
    global settingsReady, settingsShowWhenReady
    if showWhenReady
        settingsShowWhenReady := true
    if settingsGui
        return

    loaderPath := A_ScriptDir "\lib\WebView2Loader.dll"
    settingsPage := A_ScriptDir "\ui\settings.html"
    if !FileExist(loaderPath) or !FileExist(settingsPage) {
        if settingsShowWhenReady {
            MsgBox("The settings UI files are missing. Opening the raw configuration instead.", "Voice-to-Text", "Icon!")
            OpenConfig()
        }
        return
    }

    settingsGui := Gui("+Resize MinSize720x560", "Voice-to-Text Settings")
    settingsGui.MarginX := 0
    settingsGui.MarginY := 0
    settingsGui.OnEvent("Close", HideSettings)
    settingsGui.OnEvent("Escape", HideSettings)
    settingsGui.OnEvent("Size", ResizeSettings)
    settingsGui.Show("Hide w840 h700")
    SetSettingsWindowIcon(settingsGui.Hwnd)

    try {
        settingsController := WebView2.CreateControllerAsync(
            settingsGui.Hwnd, 0, A_Temp "\VoiceToTextWebView2", "", loaderPath
        ).await2(10000)
        settingsController.Fill()
        settingsWebView := settingsController.CoreWebView2
        webViewSettings := settingsWebView.Settings
        webViewSettings.AreDevToolsEnabled := false
        webViewSettings.AreDefaultContextMenusEnabled := false
        webViewSettings.IsStatusBarEnabled := false
        webViewSettings.IsZoomControlEnabled := false
        settingsHost := {
            GetConfigValue: SettingsGetConfigValue,
            GetSendRules: SettingsGetSendRules,
            GetAudioDevices: SettingsGetAudioDevices,
            GetWindowsDefaultAudioDevice: GetWindowsDefaultAudioDevice,
            GetCurrentModel: SettingsGetCurrentModel,
            IsModelInstalled: SettingsIsModelInstalled,
            GetActiveHotkey: SettingsGetActiveHotkey,
            HasGroqApiKey: SettingsHasGroqApiKey,
            GetGroqApiKeyHint: SettingsGetGroqApiKeyHint,
            SetGroqApiKey: SettingsSetGroqApiKey,
            IsOnboarded: SettingsIsOnboarded,
            MarkOnboarded: SettingsMarkOnboarded,
            OpenGroqConsole: SettingsOpenGroqConsole,
            ChooseLocalEngine: SettingsChooseLocalEngine,
            LogError: SettingsLogError,
            OpenRawConfig: OpenConfig,
            OpenLog: SettingsOpenLog,
            ExportLog: SettingsExportLog,
            Ready: NotifySettingsReady,
            SetWindowTitle: SettingsSetWindowTitle,
            UpdateSetting: SettingsUpdateSetting
        }
        settingsWebView.AddHostObjectToScript("settings", settingsHost)
        settingsWebView.SetVirtualHostNameToFolderMapping("voice-to-text.local", A_ScriptDir "\ui", 1)
        settingsWebView.Navigate("https://voice-to-text.local/settings.html?v=20260715-4")
    } catch as error {
        LogError("Opening Settings", error)
        showError := settingsShowWhenReady
        DestroySettings()
        if showError {
            MsgBox("The settings window could not start. Opening the raw configuration instead.`n`n" error.Message, "Voice-to-Text", "Icon!")
            OpenConfig()
        }
    }
}

SetSettingsWindowIcon(windowHandle) {
    global settingsLargeIcon, settingsSmallIcon
    iconPath := A_ScriptDir "\icons\app.ico"
    if !FileExist(iconPath)
        return
    settingsLargeIcon := LoadPicture(iconPath, "Icon1 w32 h32", &imageType)
    settingsSmallIcon := LoadPicture(iconPath, "Icon1 w16 h16", &imageType)
    DllCall("SendMessage", "ptr", windowHandle, "uint", 0x80, "ptr", 1, "ptr", settingsLargeIcon)
    DllCall("SendMessage", "ptr", windowHandle, "uint", 0x80, "ptr", 0, "ptr", settingsSmallIcon)
}

ResizeSettings(guiObject, minMax, width, height) {
    global settingsController
    if minMax != -1 and settingsController
        settingsController.Fill()
}

HideSettings(*) {
    global settingsGui, settingsController, settingsShowWhenReady
    settingsShowWhenReady := false
    if settingsGui {
        if settingsController
            settingsController.IsVisible := false
        settingsGui.Hide()
    }
}

NotifySettingsReady() {
    global settingsGui, settingsController, settingsReady, settingsShowWhenReady
    settingsReady := true
    if settingsShowWhenReady and settingsGui {
        settingsGui.Show()
        settingsController.Fill()
        settingsController.IsVisible := true
    }
}

DestroySettings() {
    global settingsGui, settingsHost, settingsController, settingsWebView
    global settingsReady, settingsShowWhenReady, settingsLargeIcon, settingsSmallIcon
    settingsWebView := 0
    settingsController := 0
    settingsHost := 0
    if settingsGui {
        guiToClose := settingsGui
        settingsGui := 0
        guiToClose.Destroy()
    }
    if settingsLargeIcon {
        DllCall("DestroyIcon", "ptr", settingsLargeIcon)
        settingsLargeIcon := 0
    }
    if settingsSmallIcon {
        DllCall("DestroyIcon", "ptr", settingsSmallIcon)
        settingsSmallIcon := 0
    }
    settingsReady := false
    settingsShowWhenReady := false
}

SettingsGetConfigValue(section, key, defaultValue) {
    global configPath
    return IniRead(configPath, String(section), String(key), String(defaultValue))
}

LoadSendRules() {
    global configPath
    rules := []
    count := 0
    try count := Integer(IniRead(configPath, "Send", "RuleCount", "0"))
    if count = 0 {
        ; Migrate the legacy single-word setting (Word=go -> Enter).
        legacy := Trim(IniRead(configPath, "Send", "Word", ""))
        if legacy != ""
            rules.Push({ word: legacy, keys: "{Enter}" })
    } else {
        loop count {
            word := Trim(IniRead(configPath, "Send", "Rule" A_Index "Word", ""))
            keys := Trim(IniRead(configPath, "Send", "Rule" A_Index "Keys", ""))
            if word != "" and keys != ""
                rules.Push({ word: word, keys: keys })
        }
    }
    SortSendRulesByLength(rules)
    return rules
}

; Turn an AHK send string ("#{l}", "!{F4}") into a friendly label ("Win+L", "Alt+F4") for the tooltip.
FormatSendKeys(keys) {
    labels := Map("^", "Ctrl", "!", "Alt", "+", "Shift", "#", "Win")
    parts := []
    rest := keys
    while rest != "" and InStr("^!+#", SubStr(rest, 1, 1)) {
        parts.Push(labels[SubStr(rest, 1, 1)])
        rest := SubStr(rest, 2)
    }
    key := RegExMatch(rest, "^\{(.+)\}$", &m) ? m[1] : rest
    if StrLen(key) = 1
        key := StrUpper(key)
    parts.Push(key)
    result := ""
    for part in parts
        result .= (result = "" ? "" : "+") part
    return result
}

; Longest trigger first so a longer phrase wins over a shorter one it contains.
SortSendRulesByLength(rules) {
    n := rules.Length
    if n < 2
        return
    loop n - 1 {
        i := A_Index
        loop n - i {
            j := A_Index
            if StrLen(rules[j].word) < StrLen(rules[j + 1].word) {
                tmp := rules[j]
                rules[j] := rules[j + 1]
                rules[j + 1] := tmp
            }
        }
    }
}

; Return rules in config order (word<tab>keys per line) so the UI shows them as entered.
SettingsGetSendRules() {
    global configPath
    result := ""
    count := 0
    try count := Integer(IniRead(configPath, "Send", "RuleCount", "0"))
    if count = 0 {
        legacy := Trim(IniRead(configPath, "Send", "Word", ""))
        if legacy != ""
            result := legacy "`t{Enter}"
    } else {
        loop count {
            word := Trim(IniRead(configPath, "Send", "Rule" A_Index "Word", ""))
            keys := Trim(IniRead(configPath, "Send", "Rule" A_Index "Keys", ""))
            if word != "" and keys != ""
                result .= (result = "" ? "" : "`n") word "`t" keys
        }
    }
    return result
}

SettingsSetSendRules(serialized) {
    global configPath, SendRules
    oldCount := 0
    try oldCount := Integer(IniRead(configPath, "Send", "RuleCount", "0"))
    loop oldCount {
        IniDelete(configPath, "Send", "Rule" A_Index "Word")
        IniDelete(configPath, "Send", "Rule" A_Index "Keys")
    }
    IniDelete(configPath, "Send", "Word")

    rules := []
    for line in StrSplit(String(serialized), "`n") {
        line := Trim(line, " `t`r`n")
        if line = ""
            continue
        parts := StrSplit(line, "`t")
        word := parts.Length >= 1 ? Trim(parts[1]) : ""
        keys := parts.Length >= 2 ? Trim(parts[2]) : ""
        if word != "" and keys != ""
            rules.Push({ word: word, keys: keys })
    }

    loop rules.Length {
        IniWrite(rules[A_Index].word, configPath, "Send", "Rule" A_Index "Word")
        IniWrite(rules[A_Index].keys, configPath, "Send", "Rule" A_Index "Keys")
    }
    IniWrite(rules.Length, configPath, "Send", "RuleCount")

    SortSendRulesByLength(rules)
    SendRules := rules
}

SettingsGetAudioDevices() {
    devices := ""
    for device in GetAudioDevices()
        devices .= (devices = "" ? "" : "`n") device
    return devices
}

SettingsGetCurrentModel() {
    global ModelPath
    modelDetails := GetModelDetails(ModelPath)
    return modelDetails ? modelDetails.Key : "small.en"
}

SettingsIsModelInstalled(modelKey) {
    modelPath := GetModelPath(String(modelKey))
    return modelPath != "" and FileExist(modelPath) ? "true" : "false"
}

SettingsGetActiveHotkey() {
    global PushToTalkKey
    return PushToTalkKey
}

SettingsIsOnboarded() {
    global onboardedPath
    return FileExist(onboardedPath) ? "true" : "false"
}

SettingsMarkOnboarded() {
    global onboardedPath
    SplitPath(onboardedPath, , &dir)
    if !DirExist(dir)
        DirCreate(dir)
    if !FileExist(onboardedPath)
        FileAppend("", onboardedPath)
    return "ok"
}

SettingsOpenGroqConsole() {
    Run("https://console.groq.com/keys")
    return "ok"
}

SettingsChooseLocalEngine() {
    global configPath
    IniWrite("Whisper", configPath, "Transcription", "Engine")
    SettingsMarkOnboarded()
    WriteLog("INFO", "Onboarding: chose local Whisper engine")
    SetTimer(() => Reload(), -200)
    return "restarting"
}

SettingsHasGroqApiKey() {
    return GetGroqApiKey() != "" ? "true" : "false"
}

SettingsGetGroqApiKeyHint() {
    key := GetGroqApiKey()
    if key = ""
        return ""
    if StrLen(key) <= 8
        return "••••"
    return SubStr(key, 1, 4) "…" SubStr(key, -4)
}

SettingsSetGroqApiKey(value) {
    global groqKeyPath
    key := Trim(String(value))
    SplitPath(groqKeyPath, , &keyDir)
    if !DirExist(keyDir)
        DirCreate(keyDir)
    if key = "" {
        if FileExist(groqKeyPath)
            FileDelete(groqKeyPath)
        WriteLog("INFO", "Groq API key cleared")
        return "cleared"
    }
    if FileExist(groqKeyPath)
        FileDelete(groqKeyPath)
    FileAppend(key, groqKeyPath, "UTF-8-RAW")
    WriteLog("INFO", "Groq API key saved")
    return "saved"
}

SettingsSetWindowTitle(title) {
    global settingsGui
    if settingsGui
        settingsGui.Title := String(title)
}

SettingsLogError(message) {
    LogError("Settings UI", String(message))
}

SettingsOpenLog() {
    global logPath
    if !FileExist(logPath)
        WriteLog("INFO", "Log opened")
    Run(logPath)
}

SettingsExportLog() {
    global logPath
    if !FileExist(logPath)
        WriteLog("INFO", "Log exported")
    exportPath := FileSelect("S16", A_Desktop "\voice-to-text.log", "Export Voice-to-Text Log", "Log files (*.log)")
    if exportPath = ""
        return "cancelled"
    if !RegExMatch(exportPath, "i)\.log$")
        exportPath .= ".log"
    FileCopy(logPath, exportPath, true)
    return "exported"
}

SettingsUpdateSetting(setting, value) {
    global configPath, FollowWindowsDefault, MicDevice, PushToTalkKey, userHotkey, TranscriptionEngine, WhisperThreads, ModelPath, RunAsAdministrator, SendWordEnabled, SendRules, TabNavEnabled, CommandsEnabled, CommandWakeWord
    setting := String(setting)
    value := String(value)

    switch setting {
        case "followWindows":
            FollowWindowsDefault := value = "true"
            IniWrite(FollowWindowsDefault ? "true" : "false", configPath, "Audio", "FollowWindowsDefault")
            EvaluateHeadsetHotkey()
        case "microphone":
            if value != "" {
                MicDevice := value
                IniWrite(MicDevice, configPath, "Audio", "MicDevice")
            }
        case "runAtLogin":
            enabled := value = "true"
            IniWrite(enabled ? "true" : "false", configPath, "Startup", "RunAtLogin")
            UpdateStartupShortcut(enabled)
        case "runAsAdmin":
            enabled := value = "true"
            if enabled != RunAsAdministrator {
                SetTimer(RelaunchWithAdministratorMode.Bind(enabled, true), -100)
                return "restarting"
            }
        case "hotkey":
            if !IsSupportedHotkey(value)
                throw ValueError("Unsupported hotkey")
            if value != userHotkey {
                userHotkey := value
                IniWrite(value, configPath, "Hotkey", "PushToTalk")
                EvaluateHeadsetHotkey()
                WriteLog("INFO", "Push-to-talk shortcut changed to " value)
            }
        case "engine":
            engine := NormalizeTranscriptionEngine(value)
            if engine != TranscriptionEngine {
                SwitchTranscriptionEngine(engine)
                return "updated"
            }
        case "threads":
            try threadCount := Integer(value)
            catch
                throw ValueError("Threads must be a number")
            threadCount := Max(1, Min(64, threadCount))
            if threadCount != WhisperThreads {
                IniWrite(threadCount, configPath, "Whisper", "Threads")
                SetTimer(RestartWithSettings, -100)
                return "restarting"
            }
        case "model":
            modelPath := GetModelPath(value)
            if modelPath = ""
                throw ValueError("Unsupported speech model")
            if modelPath != ModelPath {
                IniWrite("models\ggml-" value ".bin", configPath, "Paths", "ModelPath")
                SetTimer(RestartWithSettings, -100)
                return "restarting"
            }
        case "sendWordEnabled":
            SendWordEnabled := value = "true"
            IniWrite(SendWordEnabled ? "true" : "false", configPath, "Send", "Enabled")
        case "sendRules":
            SettingsSetSendRules(value)
        case "commandsEnabled":
            CommandsEnabled := value = "true"
            IniWrite(CommandsEnabled ? "true" : "false", configPath, "Commands", "Enabled")
        case "commandWakeWord":
            CommandWakeWord := Trim(value)
            if CommandWakeWord != ""
                IniWrite(CommandWakeWord, configPath, "Commands", "WakeWord")
        case "tabNavEnabled":
            TabNavEnabled := value = "true"
            IniWrite(TabNavEnabled ? "true" : "false", configPath, "TabNavigation", "Enabled")
            if TabNavEnabled
                RegisterTabNavigation()
            else
                UnregisterTabNavigation()
        default:
            throw ValueError("Unsupported setting")
    }

    return "updated"
}

HasValue(values, expected) {
    for value in values {
        if value = expected
            return true
    }
    return false
}

IsSupportedHotkey(value) {
    if HasValue(["ShiftAlt", "CapsLock", "F13", "ScrollLock", "Media_Play_Pause"], value)
        return true
    return RegExMatch(value, "^(?:[\^!+#]*)(?:[A-Z0-9]|F(?:[1-9]|1[0-9]|2[0-4])|Space|Enter|Tab|Backspace|Escape|Delete|Insert|Home|End|PgUp|PgDn|Up|Down|Left|Right)$")
}

UpdateStartupShortcut(enabled) {
    shortcutPath := A_AppData "\Microsoft\Windows\Start Menu\Programs\Startup\voice-to-text - Shortcut.lnk"
    if enabled {
        shell := ComObject("WScript.Shell")
        shortcut := shell.CreateShortcut(shortcutPath)
        shortcut.TargetPath := A_ScriptFullPath
        shortcut.WorkingDirectory := A_ScriptDir
        shortcut.Description := "Voice-to-Text"
        shortcut.Save()
    } else if FileExist(shortcutPath) {
        FileDelete(shortcutPath)
    }
}

RestartWithSettings(*) {
    Run('"' A_ScriptFullPath '" --settings', A_ScriptDir)
    ExitApp()
}

ToggleAdministratorMode(*) {
    global RunAsAdministrator
    RelaunchWithAdministratorMode(!RunAsAdministrator)
}

RelaunchWithAdministratorMode(runAsAdmin, openSettings := false) {
    global RunAsAdministrator, configPath
    previousMode := RunAsAdministrator
    RunAsAdministrator := runAsAdmin
    IniWrite(RunAsAdministrator ? "true" : "false", configPath, "Startup", "RunAsAdministrator")
    launchArguments := openSettings ? " --settings" : ""

    if RunAsAdministrator {
        A_TrayMenu.Check("Run as Administrator")
        ToolTip("Restarting as administrator...")
        try {
            Run('*RunAs "' A_ScriptFullPath '"' launchArguments)
        } catch as error {
            LogError("Relaunching as administrator", error)
            RunAsAdministrator := previousMode
            IniWrite(previousMode ? "true" : "false", configPath, "Startup", "RunAsAdministrator")
            A_TrayMenu.Uncheck("Run as Administrator")
            ShowTooltipTimed("Administrator mode unchanged", 2000)
            return
        }
    } else {
        A_TrayMenu.Uncheck("Run as Administrator")
        ToolTip("Restarting without administrator access...")
        restartScript := A_Temp "\VoiceToText_Restart_" A_TickCount ".cmd"
        try {
            FileAppend('@ping 127.0.0.1 -n 2 > nul`r`n@start "" "' A_ScriptFullPath '"' launchArguments '`r`n@del "%~f0"', restartScript)
            RunAsDesktopUser(restartScript, "", A_Temp, "open", 0)
        } catch as error {
            LogError("Relaunching without administrator access", error)
            if FileExist(restartScript)
                FileDelete(restartScript)
            RunAsAdministrator := previousMode
            IniWrite(previousMode ? "true" : "false", configPath, "Startup", "RunAsAdministrator")
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

    DestroySettings()

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
