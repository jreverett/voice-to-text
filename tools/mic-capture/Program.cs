using NAudio.CoreAudioApi;
using NAudio.Wave;

if (args.Length == 0)
{
    Console.Error.WriteLine("Usage: mic-capture <record|stop|list|default>");
    return 1;
}

return args[0].ToLowerInvariant() switch
{
    "list" => ListDevices(),
    "default" => GetDefaultDevice(),
    "stop" => SignalStop(),
    "record" => Record(args[1..]),
    _ => Error($"Unknown command: {args[0]}")
};

static int Error(string message)
{
    Console.Error.WriteLine(message);
    return 1;
}

static int ListDevices()
{
    using var enumerator = new MMDeviceEnumerator();
    foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        Console.WriteLine(device.FriendlyName);

    return 0;
}

static int GetDefaultDevice()
{
    using var enumerator = new MMDeviceEnumerator();
    using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
    Console.WriteLine(device.FriendlyName);
    return 0;
}

static int SignalStop()
{
    try
    {
        using var evt = EventWaitHandle.OpenExisting(@"Global\VoiceToText_StopCapture");
        evt.Set();
        return 0;
    }
    catch (WaitHandleCannotBeOpenedException)
    {
        Console.Error.WriteLine("No active recording to stop");
        return 1;
    }
}

static int Record(string[] args)
{
    string? deviceName = null;
    var outputPath = "recording.wav";
    string? readyFile = null;

    for (var i = 0; i < args.Length; i++)
    {
        switch (args[i])
        {
            case "--device" when i + 1 < args.Length:
                deviceName = args[++i];
                break;
            case "--output" when i + 1 < args.Length:
                outputPath = args[++i];
                break;
            case "--ready-file" when i + 1 < args.Length:
                readyFile = args[++i];
                break;
        }
    }

    // Find the requested capture device
    using var enumerator = new MMDeviceEnumerator();
    var device = deviceName is not null
        ? enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
              .FirstOrDefault(d => d.FriendlyName.Contains(deviceName, StringComparison.OrdinalIgnoreCase))
          ?? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console)
        : enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);

    // Named event for cross-process stop signaling
    using var stopEvent = new EventWaitHandle(false, EventResetMode.ManualReset, @"Global\VoiceToText_StopCapture");

    Console.CancelKeyPress += (_, e) =>
    {
        e.Cancel = true;
        stopEvent.Set();
    };

    // WASAPI shared mode, 50ms buffer for low latency
    using var capture = new WasapiCapture(device, true, 50);
    using var writer = new WaveFileWriter(outputPath, capture.WaveFormat);

    capture.DataAvailable += (_, e) => writer.Write(e.Buffer, 0, e.BytesRecorded);

    capture.StartRecording();

    // Signal to the calling process that audio is now being captured
    if (readyFile is not null)
        File.WriteAllText(readyFile, "ready");

    // Block until stop signal
    stopEvent.WaitOne();
    capture.StopRecording();

    return 0;
}
