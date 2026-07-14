const bridge = window.chrome.webview.hostObjects.sync.settings;

const pages = document.querySelectorAll(".settings-page");
const navItems = document.querySelectorAll(".nav-item");
const followWindows = document.querySelector("#follow-windows");
const microphone = document.querySelector("#microphone");
const hotkey = document.querySelector("#hotkey");
const runAtLogin = document.querySelector("#run-at-login");
const runAsAdmin = document.querySelector("#run-as-admin");
const model = document.querySelector("#model");
const threads = document.querySelector("#threads");
const status = document.querySelector("#save-status");
const shortcutCapture = document.querySelector("#shortcut-capture");
const shortcutPreview = document.querySelector("#shortcut-preview");
const currentCustomHotkeyOption = hotkey.querySelector('option[value="__current_custom__"]');

const presetHotkeys = new Set(["ShiftAlt", "CapsLock", "F13", "ScrollLock"]);

const models = {
  "small.en": {
    name: "Small English",
    description: "Fast and accurate for everyday dictation.",
    size: "466 MB"
  },
  "medium.en": {
    name: "Medium English",
    description: "Higher accuracy with slower processing.",
    size: "1.43 GB"
  }
};

let statusTimer;
let previousHotkey;
let configuredMicrophone = "";
let lastDefaultMicrophoneRefresh = 0;

function asString(value) {
  return String(value ?? "");
}

function asBoolean(value) {
  return asString(value).toLowerCase() === "true";
}

function showStatus(message) {
  clearTimeout(statusTimer);
  status.textContent = message;
  status.classList.add("visible");
  statusTimer = setTimeout(() => status.classList.remove("visible"), 1600);
}

function showPage(id) {
  const page = document.querySelector(`#${id}`) ?? document.querySelector("#general");
  pages.forEach(item => item.classList.toggle("active", item === page));
  navItems.forEach(item => item.classList.toggle("active", item.dataset.target === page.id));
  localStorage.setItem("settingsPane", page.id);
  try {
    bridge.SetWindowTitle(`${page.querySelector("h1").textContent} — Voice-to-Text Settings`);
  } catch {}
}

function updateModelSummary() {
  const details = models[model.value];
  const installed = asBoolean(bridge.IsModelInstalled(model.value));
  document.querySelector("#model-name").textContent = details.name;
  document.querySelector("#model-description").textContent = details.description;
  const modelStatus = document.querySelector("#model-status");
  modelStatus.textContent = `${details.size} · ${installed ? "Installed" : "Download required"}`;
  modelStatus.classList.toggle("missing", !installed);
}

function updateSetting(name, value) {
  try {
    const result = asString(bridge.UpdateSetting(name, String(value)));
    if (result === "restarting") {
      showStatus("Restarting…");
    }
  } catch (error) {
    try {
      bridge.LogError(`Updating ${name}: ${error?.message ?? error}`);
    } catch {}
    showStatus("Couldn’t update setting");
  }
}

function formatHotkey(value) {
  if (value === "ShiftAlt") return "Shift + Alt";
  const modifiers = [];
  let key = value;
  const modifierNames = [["^", "Ctrl"], ["!", "Alt"], ["+", "Shift"], ["#", "Win"]];
  modifierNames.forEach(([symbol, name]) => {
    if (key.includes(symbol)) {
      modifiers.push(name);
      key = key.replace(symbol, "");
    }
  });
  return [...modifiers, key].join(" + ");
}

function selectHotkey(value) {
  if (presetHotkeys.has(value)) {
    currentCustomHotkeyOption.textContent = "";
    currentCustomHotkeyOption.dataset.hotkey = "";
    hotkey.value = value;
    return;
  }
  currentCustomHotkeyOption.dataset.hotkey = value;
  currentCustomHotkeyOption.textContent = `Custom: ${formatHotkey(value)}`;
  hotkey.value = "__current_custom__";
}

function openShortcutCapture() {
  previousHotkey = currentCustomHotkeyOption.dataset.hotkey || asString(bridge.GetConfigValue("Hotkey", "PushToTalk", "ShiftAlt"));
  currentCustomHotkeyOption.dataset.hotkey = "";
  currentCustomHotkeyOption.textContent = "";
  shortcutPreview.textContent = "Waiting for input…";
  shortcutCapture.hidden = false;
}

function closeShortcutCapture() {
  shortcutCapture.hidden = true;
}

function getCapturedHotkey(event) {
  const keyMap = {
    " ": "Space",
    ArrowUp: "Up",
    ArrowDown: "Down",
    ArrowLeft: "Left",
    ArrowRight: "Right",
    PageUp: "PgUp",
    PageDown: "PgDn",
    Esc: "Escape"
  };
  const ignoredKeys = new Set(["Control", "Alt", "Shift", "Meta", "AltGraph"]);
  if (event.shiftKey && event.altKey && !event.ctrlKey && !event.metaKey && ignoredKeys.has(event.key)) {
    return "ShiftAlt";
  }
  if (ignoredKeys.has(event.key)) return "";

  let key = keyMap[event.key] ?? event.key;
  if (key.length === 1) key = key.toUpperCase();
  if (!/^(?:[A-Z0-9]|F(?:[1-9]|1[0-9]|2[0-4])|CapsLock|ScrollLock|Space|Enter|Tab|Backspace|Escape|Delete|Insert|Home|End|PgUp|PgDn|Up|Down|Left|Right)$/.test(key)) {
    return "";
  }

  return `${event.ctrlKey ? "^" : ""}${event.altKey ? "!" : ""}${event.shiftKey ? "+" : ""}${event.metaKey ? "#" : ""}${key}`;
}

function refreshWindowsDefaultMicrophone() {
  if (!followWindows.checked) return;
  const now = Date.now();
  if (now - lastDefaultMicrophoneRefresh < 1500) return;
  lastDefaultMicrophoneRefresh = now;
  const defaultDevice = asString(bridge.GetWindowsDefaultAudioDevice());
  if (!defaultDevice) return;
  if (![...microphone.options].some(option => option.value === defaultDevice)) {
    microphone.add(new Option(defaultDevice, defaultDevice));
  }
  microphone.value = defaultDevice;
}

function loadSettings() {
  followWindows.checked = asBoolean(bridge.GetConfigValue("Audio", "FollowWindowsDefault", "true"));
  runAtLogin.checked = asBoolean(bridge.GetConfigValue("Startup", "RunAtLogin", "true"));
  runAsAdmin.checked = asBoolean(bridge.GetConfigValue("Startup", "RunAsAdministrator", "false"));
  selectHotkey(asString(bridge.GetConfigValue("Hotkey", "PushToTalk", "ShiftAlt")));
  threads.value = asString(bridge.GetConfigValue("Whisper", "Threads", "8"));

  configuredMicrophone = asString(bridge.GetConfigValue("Audio", "MicDevice", ""));
  const devices = asString(bridge.GetAudioDevices()).split("\n").filter(Boolean);
  microphone.replaceChildren(...devices.map(name => new Option(name, name, false, name === configuredMicrophone)));
  if (!devices.length) {
    microphone.add(new Option("No microphones found", ""));
  } else if (!microphone.value) {
    microphone.value = devices[0];
  }
  microphone.disabled = followWindows.checked;
  refreshWindowsDefaultMicrophone();

  model.value = asString(bridge.GetCurrentModel());
  updateModelSummary();
  showPage(localStorage.getItem("settingsPane") ?? "general");
}

navItems.forEach(item => item.addEventListener("click", () => showPage(item.dataset.target)));

followWindows.addEventListener("change", () => {
  microphone.disabled = followWindows.checked;
  if (followWindows.checked) {
    refreshWindowsDefaultMicrophone();
  } else if ([...microphone.options].some(option => option.value === configuredMicrophone)) {
    microphone.value = configuredMicrophone;
  }
  updateSetting("followWindows", followWindows.checked);
});
microphone.addEventListener("change", () => {
  configuredMicrophone = microphone.value;
  updateSetting("microphone", microphone.value);
});
hotkey.addEventListener("change", () => {
  if (hotkey.value === "__custom__") {
    openShortcutCapture();
  } else {
    updateSetting("hotkey", hotkey.value);
  }
});
runAtLogin.addEventListener("change", () => updateSetting("runAtLogin", runAtLogin.checked));
runAsAdmin.addEventListener("change", () => updateSetting("runAsAdmin", runAsAdmin.checked));
model.addEventListener("change", () => {
  updateModelSummary();
  updateSetting("model", model.value);
});
threads.addEventListener("change", () => {
  if (threads.reportValidity()) {
    updateSetting("threads", threads.value);
  }
});

document.querySelector("#open-config").addEventListener("click", () => bridge.OpenRawConfig());
document.querySelector("#open-log").addEventListener("click", () => bridge.OpenLog());
document.querySelector("#export-log").addEventListener("click", () => {
  if (asString(bridge.ExportLog()) === "exported") {
    showStatus("Log exported");
  }
});
document.querySelector("#cancel-shortcut").addEventListener("click", () => {
  selectHotkey(previousHotkey);
  closeShortcutCapture();
});
window.addEventListener("keydown", event => {
  if (shortcutCapture.hidden || event.repeat) return;
  event.preventDefault();
  event.stopPropagation();
  if (event.key === "Escape") {
    selectHotkey(previousHotkey);
    closeShortcutCapture();
    return;
  }
  const capturedHotkey = getCapturedHotkey(event);
  if (!capturedHotkey) {
    shortcutPreview.textContent = "Hold modifiers, then press another key…";
    return;
  }
  shortcutPreview.textContent = formatHotkey(capturedHotkey);
  selectHotkey(capturedHotkey);
  closeShortcutCapture();
  updateSetting("hotkey", capturedHotkey);
}, true);
window.addEventListener("focus", refreshWindowsDefaultMicrophone);
window.addEventListener("error", event => {
  try {
    bridge.LogError(`${event.message} at ${event.filename}:${event.lineno}`);
  } catch {}
});
window.addEventListener("unhandledrejection", event => {
  try {
    bridge.LogError(`Unhandled promise rejection: ${event.reason}`);
  } catch {}
});
window.addEventListener("DOMContentLoaded", () => {
  try {
    loadSettings();
  } finally {
    bridge.Ready();
  }
});
