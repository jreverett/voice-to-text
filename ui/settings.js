const bridge = window.chrome.webview.hostObjects.sync.settings;

const pages = document.querySelectorAll(".settings-page");
const navItems = document.querySelectorAll(".nav-item");
const followWindows = document.querySelector("#follow-windows");
const microphone = document.querySelector("#microphone");
const hotkey = document.querySelector("#hotkey");
const runAtLogin = document.querySelector("#run-at-login");
const runAsAdmin = document.querySelector("#run-as-admin");
const engine = document.querySelector("#engine");
const engineError = document.querySelector("#engine-error");
const engineSpinner = document.querySelector("#engine-spinner");
const engineStatus = document.querySelector("#engine-status");
const groqKeyGroup = document.querySelector("#groq-key-group");
const groqKeyInput = document.querySelector("#groq-key");
const groqKeySave = document.querySelector("#groq-key-save");
const groqKeyClear = document.querySelector("#groq-key-clear");
const groqKeyStatus = document.querySelector("#groq-key-status");
const onboarding = document.querySelector("#onboarding");
const onboardingKey = document.querySelector("#onboarding-key");
const onboardingSave = document.querySelector("#onboarding-save");
const onboardingLocal = document.querySelector("#onboarding-local");
const onboardingOpenConsole = document.querySelector("#onboarding-open-console");
const onboardingStatus = document.querySelector("#onboarding-status");
const model = document.querySelector("#model");
const threads = document.querySelector("#threads");
const sendWordEnabled = document.querySelector("#send-word-enabled");
const sendRulesList = document.querySelector("#send-rules-list");
const addSendRule = document.querySelector("#add-send-rule");
const sendWordRow = document.querySelector("#send-word-row");
const tabNavEnabled = document.querySelector("#tab-nav-enabled");
const status = document.querySelector("#save-status");
const shortcutCapture = document.querySelector("#shortcut-capture");
const shortcutPreview = document.querySelector("#shortcut-preview");
const currentCustomHotkeyOption = hotkey.querySelector('option[value="__current_custom__"]');

const presetHotkeys = new Set(["ShiftAlt", "CapsLock", "F13", "ScrollLock", "Media_Play_Pause"]);
const settingSpinners = {
  followWindows: document.querySelector("#follow-windows-spinner"),
  microphone: document.querySelector("#microphone-spinner"),
  runAtLogin: document.querySelector("#run-at-login-spinner"),
  runAsAdmin: document.querySelector("#run-as-admin-spinner"),
  model: document.querySelector("#model-spinner"),
  threads: document.querySelector("#threads-spinner")
};

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
let configuredFollowWindows = true;
let configuredEngine = "Whisper";
let configuredMicrophone = "";
let lastDefaultMicrophoneRefresh = 0;
const busySettings = new Set();
const settlingTimers = new Map();

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

function updateEngineSummary() {
  const isGroq = engine.value === "Groq";
  let hasGroqApiKey = false;
  try {
    hasGroqApiKey = asBoolean(bridge.HasGroqApiKey());
  } catch {}
  document.querySelector("#engine-name").textContent = isGroq ? "Groq API" : "Local Whisper";
  document.querySelector("#engine-description").textContent = isGroq
    ? "Uses Groq's low-latency speech-to-text endpoint."
    : "Runs fully offline on this device.";
  engineStatus.classList.remove("missing", "ok", "error");
  if (isGroq) {
    engineStatus.textContent = hasGroqApiKey ? "GROQ_API_KEY found ✓" : "GROQ_API_KEY missing";
    engineStatus.classList.add(hasGroqApiKey ? "ok" : "error");
  } else {
    engineStatus.textContent = "Local";
  }
  document.querySelector("#local-model-settings").hidden = isGroq;
  document.querySelector("#model-group-title").hidden = isGroq;
  document.querySelector("#engine-note").hidden = !isGroq;
  groqKeyGroup.hidden = !isGroq;
  if (isGroq) {
    let hint = "";
    try {
      hint = asString(bridge.GetGroqApiKeyHint());
    } catch {}
    groqKeyStatus.textContent = hasGroqApiKey
      ? `Saved key: ${hint} — paste a new key to replace it.`
      : "No key saved yet.";
    groqKeyStatus.classList.toggle("ok", hasGroqApiKey);
    groqKeyInput.placeholder = hasGroqApiKey ? "Paste a new key to replace" : "gsk_…";
    groqKeyClear.hidden = !hasGroqApiKey;
  }
}

function showEngineError(isVisible) {
  engineError.hidden = !isVisible;
}

function setEngineBusy(isBusy, message = "Switching…") {
  engine.disabled = isBusy;
  engineSpinner.hidden = !isBusy;
  if (isBusy) {
    engineStatus.textContent = message;
    engineStatus.classList.remove("missing");
  }
}

function setSettingBusy(name, isBusy, controls = []) {
  const spinner = settingSpinners[name];
  const settingRow = spinner.closest(".setting-row");
  clearTimeout(settlingTimers.get(name));
  settlingTimers.delete(name);
  spinner.hidden = !isBusy;
  settingRow.classList.toggle("busy", isBusy);
  settingRow.setAttribute("aria-busy", isBusy ? "true" : "false");
  if (isBusy) {
    busySettings.add(name);
    settingRow.classList.remove("settling");
  } else {
    busySettings.delete(name);
    settingRow.classList.add("settling");
    settlingTimers.set(name, window.setTimeout(() => {
      settingRow.classList.remove("settling");
      settlingTimers.delete(name);
    }, 250));
  }
  controls.forEach(control => {
    control.disabled = isBusy;
  });
}

document.addEventListener("click", event => {
  if (!event.target.closest(".setting-row.busy")) return;
  event.preventDefault();
  event.stopImmediatePropagation();
}, true);

function updateSetting(name, value) {
  try {
    const result = asString(bridge.UpdateSetting(name, String(value)));
    if (result === "restarting") {
      showStatus("Restarting…");
    }
    return result || "updated";
  } catch (error) {
    try {
      bridge.LogError(`Updating ${name}: ${error?.message ?? error}`);
    } catch {}
    const message = asString(error?.message ?? error);
    showStatus(message.includes("GROQ_API_KEY") ? "GROQ_API_KEY is not set" : "Couldn’t update setting");
    return false;
  }
}

function formatHotkey(value) {
  if (value === "ShiftAlt") return "Shift + Alt";
  if (value === "Media_Play_Pause") return "Headphone button (toggle)";
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
  if (now - lastDefaultMicrophoneRefresh < 800) return;
  lastDefaultMicrophoneRefresh = now;
  const defaultDevice = asString(bridge.GetWindowsDefaultAudioDevice());
  if (!defaultDevice) return;
  if (![...microphone.options].some(option => option.value === defaultDevice)) {
    microphone.add(new Option(defaultDevice, defaultDevice));
  }
  microphone.value = defaultDevice;
}

function loadSettings() {
  configuredFollowWindows = asBoolean(bridge.GetConfigValue("Audio", "FollowWindowsDefault", "true"));
  followWindows.checked = configuredFollowWindows;
  runAtLogin.checked = asBoolean(bridge.GetConfigValue("Startup", "RunAtLogin", "true"));
  runAsAdmin.checked = asBoolean(bridge.GetConfigValue("Startup", "RunAsAdministrator", "false"));
  selectHotkey(asString(bridge.GetActiveHotkey()));
  configuredEngine = asString(bridge.GetConfigValue("Transcription", "Engine", "Whisper"));
  if (/^(grok|xai|groq)$/i.test(configuredEngine)) {
    configuredEngine = "Groq";
  }
  engine.value = ["Whisper", "Groq"].includes(configuredEngine) ? configuredEngine : "Whisper";
  configuredEngine = engine.value;
  threads.value = asString(bridge.GetConfigValue("Whisper", "Threads", "8"));

  sendWordEnabled.checked = asBoolean(bridge.GetConfigValue("Send", "Enabled", "false"));
  loadSendRules();
  updateSendWordRow();
  tabNavEnabled.checked = asBoolean(bridge.GetConfigValue("TabNavigation", "Enabled", "true"));

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
  updateEngineSummary();
  updateModelSummary();
  showPage(localStorage.getItem("settingsPane") ?? "general");
}

navItems.forEach(item => item.addEventListener("click", () => showPage(item.dataset.target)));

followWindows.addEventListener("change", () => {
  if (busySettings.has("followWindows")) return;
  const requestedValue = followWindows.checked;
  const previousValue = configuredFollowWindows;
  microphone.disabled = true;
  setSettingBusy("followWindows", true, [followWindows]);
  showStatus("Updating microphone…");

  window.setTimeout(() => {
    if (requestedValue) {
      refreshWindowsDefaultMicrophone();
    } else if ([...microphone.options].some(option => option.value === configuredMicrophone)) {
      microphone.value = configuredMicrophone;
    }

    const result = updateSetting("followWindows", requestedValue);
    if (result) {
      configuredFollowWindows = requestedValue;
    } else {
      followWindows.checked = previousValue;
      configuredFollowWindows = previousValue;
    }

    setSettingBusy("followWindows", false, [followWindows]);
    microphone.disabled = configuredFollowWindows;
  }, 50);
});
microphone.addEventListener("change", () => {
  if (busySettings.has("microphone")) return;
  const requestedMicrophone = microphone.value;
  const previousMicrophone = configuredMicrophone;
  setSettingBusy("microphone", true, [microphone]);

  window.setTimeout(() => {
    const result = updateSetting("microphone", requestedMicrophone);
    if (result) {
      configuredMicrophone = requestedMicrophone;
    } else {
      microphone.value = previousMicrophone;
    }

    setSettingBusy("microphone", false, [microphone]);
    microphone.disabled = configuredFollowWindows;
  }, 50);
});
hotkey.addEventListener("change", () => {
  if (hotkey.value === "__custom__") {
    openShortcutCapture();
  } else {
    updateSetting("hotkey", hotkey.value);
  }
});
runAtLogin.addEventListener("change", () => {
  if (busySettings.has("runAtLogin")) return;
  const requestedValue = runAtLogin.checked;
  setSettingBusy("runAtLogin", true, [runAtLogin]);

  window.setTimeout(() => {
    const result = updateSetting("runAtLogin", requestedValue);
    if (!result) {
      runAtLogin.checked = !requestedValue;
    }
    setSettingBusy("runAtLogin", false, [runAtLogin]);
  }, 50);
});
runAsAdmin.addEventListener("change", () => {
  if (busySettings.has("runAsAdmin")) return;
  const requestedValue = runAsAdmin.checked;
  setSettingBusy("runAsAdmin", true, [runAsAdmin]);

  window.setTimeout(() => {
    const result = updateSetting("runAsAdmin", requestedValue);
    if (result === "restarting") {
      return;
    }
    if (!result) {
      runAsAdmin.checked = !requestedValue;
    }
    setSettingBusy("runAsAdmin", false, [runAsAdmin]);
  }, 50);
});
engine.addEventListener("change", () => {
  const requestedEngine = engine.value;
  showEngineError(false);
  updateEngineSummary();
  setEngineBusy(true);
  window.setTimeout(() => {
    const result = updateSetting("engine", requestedEngine);
    if (result) {
      configuredEngine = requestedEngine;
      if (result === "restarting") {
        setEngineBusy(true, "Restarting…");
      } else {
        setEngineBusy(false);
        updateEngineSummary();
      }
      return;
    }

    setEngineBusy(false);
    if (requestedEngine === "Groq") {
      // Keep the dropdown on Groq so the API key field stays reachable; the app keeps running Whisper.
      updateEngineSummary();
      showEngineError(true);
    } else {
      engine.value = configuredEngine;
      updateEngineSummary();
    }
  }, 50);
});
function writeGroqKey(key, successMessage) {
  groqKeySave.disabled = true;
  groqKeyClear.disabled = true;
  try {
    asString(bridge.SetGroqApiKey(key));
    groqKeyInput.value = "";
    showStatus(successMessage);
    showEngineError(false);
    updateEngineSummary();
    if (key && engine.value === "Groq" && configuredEngine !== "Groq") {
      engine.dispatchEvent(new Event("change"));
    }
  } catch (error) {
    try {
      bridge.LogError(`Saving Groq key: ${error?.message ?? error}`);
    } catch {}
    showStatus("Couldn’t update the key");
  } finally {
    groqKeySave.disabled = false;
    groqKeyClear.disabled = false;
  }
}
groqKeySave.addEventListener("click", () => {
  const key = groqKeyInput.value.trim();
  if (!key) {
    showStatus("Enter a key first");
    return;
  }
  writeGroqKey(key, "Groq API key saved");
});
groqKeyClear.addEventListener("click", () => {
  writeGroqKey("", "Groq API key removed");
});
const MODIFIERS = [
  { symbol: "^", label: "Ctrl" },
  { symbol: "!", label: "Alt" },
  { symbol: "+", label: "Shift" },
  { symbol: "#", label: "Win" },
];
const KEY_OPTIONS = [
  ...["Enter", "Tab", "Space", "Escape", "Backspace", "Delete", "Insert",
    "Home", "End", "PgUp", "PgDn", "Up", "Down", "Left", "Right"].map(k => ({ value: k, label: k })),
  ...Array.from({ length: 24 }, (_, i) => ({ value: `F${i + 1}`, label: `F${i + 1}` })),
  ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("").map(c => ({ value: c.toLowerCase(), label: c })),
  ..."0123456789".split("").map(c => ({ value: c, label: c })),
];

function updateSendWordRow() {
  const on = sendWordEnabled.checked;
  sendWordRow.classList.toggle("disabled", !on);
  sendRulesList.querySelectorAll("input, select, button").forEach(el => { el.disabled = !on; });
  addSendRule.disabled = !on;
}

// Parse an AHK send string like "!{F4}" into { mods: Set("!"), key: "F4" }.
function parseKeys(keys) {
  const mods = new Set();
  let rest = keys || "";
  while (rest && "^!+#".includes(rest[0])) {
    mods.add(rest[0]);
    rest = rest.slice(1);
  }
  const match = rest.match(/^\{(.+)\}$/);
  return { mods, key: match ? match[1] : "" };
}

function buildKeys(mods, key) {
  if (!key) return "";
  const order = MODIFIERS.map(m => m.symbol).filter(s => mods.has(s));
  return order.join("") + `{${key}}`;
}

function createRuleRow(word, keys) {
  const parsed = parseKeys(keys);
  const row = document.createElement("div");
  row.className = "send-rule";

  const wordInput = document.createElement("input");
  wordInput.type = "text";
  wordInput.className = "rule-word";
  wordInput.autocomplete = "off";
  wordInput.spellcheck = false;
  wordInput.placeholder = "trigger word";
  wordInput.value = word || "";
  wordInput.addEventListener("change", commitSendRules);

  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "rule-remove";
  remove.title = "Remove";
  remove.textContent = "×";
  remove.addEventListener("click", () => {
    row.remove();
    commitSendRules();
  });

  const keysWrap = document.createElement("div");
  keysWrap.className = "rule-keys";
  for (const mod of MODIFIERS) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "rule-mod";
    btn.dataset.mod = mod.symbol;
    btn.textContent = mod.label;
    btn.setAttribute("aria-pressed", parsed.mods.has(mod.symbol) ? "true" : "false");
    btn.addEventListener("click", () => {
      const pressed = btn.getAttribute("aria-pressed") === "true";
      btn.setAttribute("aria-pressed", pressed ? "false" : "true");
      commitSendRules();
    });
    keysWrap.append(btn);
  }
  const keySelect = document.createElement("select");
  keySelect.className = "rule-key";
  keySelect.append(...KEY_OPTIONS.map(o => new Option(o.label, o.value, false, o.value === parsed.key)));
  keySelect.addEventListener("change", commitSendRules);
  keysWrap.append(keySelect);

  row.append(wordInput, remove, keysWrap);
  return row;
}

function readSendRules() {
  return [...sendRulesList.querySelectorAll(".send-rule")].map(row => {
    const word = row.querySelector(".rule-word").value.trim();
    const mods = new Set([...row.querySelectorAll('.rule-mod[aria-pressed="true"]')].map(b => b.dataset.mod));
    const key = row.querySelector(".rule-key").value;
    return { word, keys: buildKeys(mods, key) };
  });
}

function commitSendRules() {
  const rules = readSendRules().filter(r => r.word && r.keys);
  const serialized = rules.map(r => `${r.word}\t${r.keys}`).join("\n");
  updateSetting("sendRules", serialized);
}

function loadSendRules() {
  const serialized = asString(bridge.GetSendRules());
  sendRulesList.replaceChildren();
  for (const line of serialized.split("\n").filter(Boolean)) {
    const [word, keys] = line.split("\t");
    sendRulesList.append(createRuleRow(word, keys));
  }
}

sendWordEnabled.addEventListener("change", () => {
  updateSendWordRow();
  updateSetting("sendWordEnabled", sendWordEnabled.checked ? "true" : "false");
});
addSendRule.addEventListener("click", () => {
  sendRulesList.append(createRuleRow("", "{Enter}"));
  updateSendWordRow();
});
tabNavEnabled.addEventListener("change", () => {
  updateSetting("tabNavEnabled", tabNavEnabled.checked ? "true" : "false");
});
onboardingOpenConsole.addEventListener("click", () => {
  try {
    bridge.OpenGroqConsole();
  } catch {}
});
onboardingSave.addEventListener("click", () => {
  const key = onboardingKey.value.trim();
  onboardingStatus.classList.remove("error");
  if (!key) {
    onboardingStatus.textContent = "Paste your API key first.";
    onboardingStatus.classList.add("error");
    return;
  }
  onboardingSave.disabled = true;
  try {
    asString(bridge.SetGroqApiKey(key));
    bridge.MarkOnboarded();
    onboarding.hidden = true;
    updateEngineSummary();
    showStatus("Groq API key saved");
  } catch (error) {
    try {
      bridge.LogError(`Onboarding save: ${error?.message ?? error}`);
    } catch {}
    onboardingStatus.textContent = "Couldn’t save the key — try again.";
    onboardingStatus.classList.add("error");
  } finally {
    onboardingSave.disabled = false;
  }
});
onboardingLocal.addEventListener("click", () => {
  onboardingLocal.disabled = true;
  onboardingStatus.classList.remove("error");
  onboardingStatus.textContent = "Switching to Local Whisper — the model will download on restart…";
  try {
    bridge.ChooseLocalEngine();
  } catch {
    onboardingLocal.disabled = false;
  }
});
model.addEventListener("change", () => {
  const requestedModel = model.value;
  setSettingBusy("model", true, [model]);
  updateModelSummary();

  window.setTimeout(() => {
    const result = updateSetting("model", requestedModel);
    if (result === "restarting") {
      return;
    }
    setSettingBusy("model", false, [model]);
    updateModelSummary();
  }, 50);
});
threads.addEventListener("change", () => {
  if (threads.reportValidity()) {
    const requestedThreads = threads.value;
    setSettingBusy("threads", true, [threads]);

    window.setTimeout(() => {
      const result = updateSetting("threads", requestedThreads);
      if (result === "restarting") {
        return;
      }
      setSettingBusy("threads", false, [threads]);
    }, 50);
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
// Keep the hotkey dropdown and mic display in sync when devices/hotkeys change under the app.
function syncDynamicState() {
  // Hotkey sync is a cheap global read — always safe to run.
  if (shortcutCapture.hidden && document.activeElement !== hotkey) {
    try {
      const active = asString(bridge.GetActiveHotkey());
      if (active) {
        const current = hotkey.value === "__current_custom__" ? currentCustomHotkeyOption.dataset.hotkey : hotkey.value;
        if (active !== current) selectHotkey(active);
      }
    } catch {}
  }
  // Mic refresh spawns a process, so only while the window is actually in view.
  if (document.hasFocus()) refreshWindowsDefaultMicrophone();
}

window.addEventListener("DOMContentLoaded", () => {
  try {
    loadSettings();
    if (!asBoolean(bridge.IsOnboarded()) && !asBoolean(bridge.HasGroqApiKey())) {
      onboarding.hidden = false;
    }
  } finally {
    bridge.Ready();
  }
  setInterval(syncDynamicState, 1000);
});
