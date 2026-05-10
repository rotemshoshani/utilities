const STORAGE_KEY = "interval-timer-templates";
const LEGACY_STORAGE_KEY = "interval-studio-workflows";
const AUDIO_FILES = {
  calfraises: "Audio/Calf%20Raises.mp3",
  curlsswingscycle: "Audio/Curls-Swings-Cycle.mp3",
  hamstringstretch: "Audio/Hamstring%20Stretch.mp3",
  jump: "Audio/Jump.mp3",
  lungeiso: "Audio/Lunge%20ISO.mp3",
  next: "Audio/Next.mp3",
  rest: "Audio/Rest.mp3",
  roll: "Audio/Roll.mp3",
  squat: "Audio/Squat.mp3",
};
const AUDIO_ALIASES = {
  calfraise: "calfraises",
  calves: "calfraises",
  curls: "curlsswingscycle",
  curlswingscycle: "curlsswingscycle",
  swingcycle: "curlsswingscycle",
  hamstrings: "hamstringstretch",
  hamstring: "hamstringstretch",
  lunge: "lungeiso",
  lunges: "lungeiso",
  lungehold: "lungeiso",
  lungeisometric: "lungeiso",
  squats: "squat",
  jumps: "jump",
  rolling: "roll",
};

let savedWorkflows = loadWorkflows();
let workflow = savedWorkflows[0] ? cloneWorkflow(savedWorkflows[0]) : null;
let draftWorkflow = null;
let timeline = [];
let currentStepIndex = 0;
let remainingMs = 0;
let activeDurationMs = 0;
let timerId = null;
let lastTick = 0;
let lastCountdownSecond = null;
let soundEnabled = true;
let voiceEnabled = true;
let speechAvailable = false;
let speechVoice = null;
let announcementAudio = null;
let announcementToken = 0;

const elements = {
  savedList: document.querySelector("#saved-list"),
  csvInput: document.querySelector("#csv-input"),
  creatorBackdrop: document.querySelector("#creator-backdrop"),
  closeCreator: document.querySelector("#close-creator"),
  discardWorkflow: document.querySelector("#discard-workflow"),
  intervalList: document.querySelector("#interval-list"),
  intervalTemplate: document.querySelector("#interval-template"),
  workflowName: document.querySelector("#workflow-name"),
  saveWorkflow: document.querySelector("#save-workflow"),
  newWorkout: document.querySelector("#new-workout"),
  addInterval: document.querySelector("#add-interval"),
  playPause: document.querySelector("#play-pause"),
  previousStep: document.querySelector("#previous-step"),
  nextStep: document.querySelector("#next-step"),
  reset: document.querySelector("#reset"),
  timeReadout: document.querySelector("#time-readout"),
  phaseKind: document.querySelector("#phase-kind"),
  phasePosition: document.querySelector("#phase-position"),
  phaseName: document.querySelector("#phase-name"),
  phaseProgress: document.querySelector("#phase-progress"),
  upNext: document.querySelector("#up-next"),
  upcoming: document.querySelector("#upcoming"),
  soundToggle: document.querySelector("#sound-toggle"),
  voiceToggle: document.querySelector("#voice-toggle"),
  voiceStatus: document.querySelector("#voice-status"),
  creatorTitle: document.querySelector("#creator-title"),
};

init();

function init() {
  initializeSpeech();
  renderAll();
  bindEvents();
}

function bindEvents() {
  elements.newWorkout.addEventListener("click", () => openCreator());
  elements.closeCreator.addEventListener("click", closeCreator);
  elements.discardWorkflow.addEventListener("click", closeCreator);
  elements.creatorBackdrop.addEventListener("click", (event) => {
    if (event.target === elements.creatorBackdrop) closeCreator();
  });

  elements.csvInput.addEventListener("change", importCsvTemplate);

  elements.workflowName.addEventListener("input", () => {
    if (!draftWorkflow) return;
    draftWorkflow.name = elements.workflowName.value || "Untitled";
  });

  elements.addInterval.addEventListener("click", () => {
    if (!draftWorkflow) return;
    draftWorkflow.intervals.push(createInterval());
    renderIntervals();
  });

  elements.saveWorkflow.addEventListener("click", saveDraftWorkout);
  elements.playPause.addEventListener("click", toggleTimer);
  elements.previousStep.addEventListener("click", previousStep);
  elements.nextStep.addEventListener("click", nextStep);

  elements.reset.addEventListener("click", () => {
    stopTimer();
    jumpToStep(0);
  });

  elements.soundToggle.addEventListener("click", () => {
    soundEnabled = !soundEnabled;
    elements.soundToggle.textContent = soundEnabled ? "Sound on" : "Sound off";
    elements.soundToggle.setAttribute("aria-pressed", String(soundEnabled));
  });

  elements.voiceToggle.addEventListener("click", () => {
    voiceEnabled = !voiceEnabled;
    elements.voiceToggle.textContent = voiceEnabled ? "Voice on" : "Voice off";
    elements.voiceToggle.setAttribute("aria-pressed", String(voiceEnabled));
    if (!voiceEnabled) cancelSpeech();
  });

  window.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !elements.creatorBackdrop.classList.contains("is-hidden")) {
      closeCreator();
    }
  });
}

function initializeSpeech() {
  if (!canUseSpeech()) {
    speechAvailable = false;
    elements.voiceToggle.textContent = "Voice on";
    elements.voiceToggle.setAttribute("aria-pressed", "false");
    setVoiceStatus("Using recorded audio files.");
    return;
  }

  refreshSpeechVoices();
  window.speechSynthesis.addEventListener("voiceschanged", refreshSpeechVoices);
  window.setTimeout(refreshSpeechVoices, 250);
  window.setTimeout(refreshSpeechVoices, 1000);
}

function refreshSpeechVoices() {
  if (!canUseSpeech()) return;

  const voices = window.speechSynthesis.getVoices();
  speechVoice =
    voices.find((voice) => voice.default) ||
    voices.find((voice) => voice.lang?.toLowerCase().startsWith("en")) ||
    voices[0] ||
    null;

  speechAvailable = Boolean(speechVoice);

  if (speechAvailable) {
    elements.voiceToggle.textContent = voiceEnabled ? "Voice on" : "Voice off";
    elements.voiceToggle.setAttribute("aria-pressed", String(voiceEnabled));
    setVoiceStatus("Using recorded audio files first.");
  } else {
    elements.voiceToggle.textContent = voiceEnabled ? "Voice on" : "Voice off";
    elements.voiceToggle.setAttribute("aria-pressed", String(voiceEnabled));
    setVoiceStatus("Using recorded audio files.");
  }
}

function renderAll() {
  renderTemplateList();
  rebuildTimeline();
  updateTimerDisplay();
}

function renderTemplateList() {
  elements.savedList.innerHTML = "";

  if (!savedWorkflows.length) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "No templates";
    elements.savedList.append(empty);
    return;
  }

  savedWorkflows.forEach((item) => {
    const row = document.createElement("div");
    row.className = "saved-workout-row";
    row.append(createTemplateButton(item));

    const editButton = document.createElement("button");
    editButton.className = "action-button";
    editButton.type = "button";
    editButton.textContent = "Edit";
    editButton.addEventListener("click", () => openCreator(item));
    row.append(editButton);

    const exportButton = document.createElement("button");
    exportButton.className = "action-button";
    exportButton.type = "button";
    exportButton.textContent = "CSV";
    exportButton.addEventListener("click", () => exportWorkflowCsv(item));
    row.append(exportButton);

    const deleteButton = document.createElement("button");
    deleteButton.className = "icon-button";
    deleteButton.type = "button";
    deleteButton.setAttribute("aria-label", `Delete ${item.name}`);
    deleteButton.innerHTML = "&times;";
    deleteButton.addEventListener("click", () => deleteSavedWorkout(item.id));
    row.append(deleteButton);

    elements.savedList.append(row);
  });
}

function createTemplateButton(item) {
  const button = document.createElement("button");
  button.className = "workout-card";
  button.type = "button";
  if (workflow?.id === item.id) button.classList.add("is-active");

  const stats = getWorkflowStats(item);
  button.innerHTML = `
    <strong>${escapeHtml(item.name)}</strong>
    <span>${formatSeconds(stats.totalSeconds)} - ${stats.rounds} rounds - ${item.intervals.length} steps</span>
  `;
  button.addEventListener("click", () => selectWorkout(item));
  return button;
}

function selectWorkout(item) {
  stopTimer();
  workflow = cloneWorkflow(item);
  currentStepIndex = 0;
  renderAll();
}

function openCreator(existingWorkflow = null) {
  draftWorkflow = existingWorkflow
    ? cloneWorkflow(existingWorkflow)
    : {
        id: makeId(),
        name: "New template",
        intervals: [createInterval("Work", 45, 15, 4)],
      };
  elements.creatorTitle.textContent = existingWorkflow ? "Edit template" : "New template";
  elements.workflowName.value = draftWorkflow.name;
  renderIntervals();
  elements.creatorBackdrop.classList.remove("is-hidden");
  elements.creatorBackdrop.setAttribute("aria-hidden", "false");
  elements.workflowName.focus();
}

function closeCreator() {
  draftWorkflow = null;
  elements.creatorBackdrop.classList.add("is-hidden");
  elements.creatorBackdrop.setAttribute("aria-hidden", "true");
}

function saveDraftWorkout() {
  if (!draftWorkflow) return;
  draftWorkflow.name = elements.workflowName.value.trim() || "Untitled";
  saveWorkflow(draftWorkflow);
  closeCreator();
}

function saveWorkflow(nextWorkflow) {
  const stored = cloneWorkflow(nextWorkflow);
  const existingIndex = savedWorkflows.findIndex((item) => item.id === stored.id);
  if (existingIndex >= 0) {
    savedWorkflows[existingIndex] = stored;
  } else {
    savedWorkflows.push(stored);
  }

  persistWorkflows();
  stopTimer();
  workflow = cloneWorkflow(stored);
  currentStepIndex = 0;
  renderAll();
}

function deleteSavedWorkout(id) {
  const item = savedWorkflows.find((workflowItem) => workflowItem.id === id);
  const name = item?.name || "this template";
  if (!window.confirm(`Delete ${name}?`)) return;

  savedWorkflows = savedWorkflows.filter((item) => item.id !== id);
  persistWorkflows();
  if (workflow?.id === id) {
    workflow = savedWorkflows[0] ? cloneWorkflow(savedWorkflows[0]) : null;
    stopTimer();
    currentStepIndex = 0;
  }
  renderAll();
}

function exportWorkflowCsv(item) {
  const csv = workflowToCsv(item);
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `${filenameSafe(item.name)}.csv`;
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

function workflowToCsv(item) {
  const rows = [["name", "work", "rest", "repeat"]];
  item.intervals.forEach((interval) => {
    rows.push([
      interval.name,
      formatSeconds(interval.workSeconds),
      formatSeconds(interval.restSeconds),
      String(interval.repeat),
    ]);
  });
  return rows.map((row) => row.map(csvEscape).join(",")).join("\n");
}

async function importCsvTemplate(event) {
  const file = event.target.files?.[0];
  event.target.value = "";
  if (!file) return;

  try {
    const csvText = await file.text();
    const imported = workflowFromCsv(csvText, file.name.replace(/\.csv$/i, ""));
    saveWorkflow(imported);
  } catch (error) {
    elements.upNext.textContent = error.message || "CSV import failed";
  }
}

function workflowFromCsv(csvText, fallbackName) {
  const rows = parseCsv(csvText).filter((row) => row.some((cell) => cell.trim()));
  if (rows.length < 2) throw new Error("CSV needs a header row and at least one step");

  const headers = rows[0].map((cell) => normalizeHeader(cell));
  const nameIndex = findHeader(headers, ["name", "step", "exercise", "block"]);
  const workIndex = findHeader(headers, ["work", "workseconds", "worktime", "duration", "seconds"]);
  const restIndex = findHeader(headers, ["rest", "restseconds", "resttime"]);
  const repeatIndex = findHeader(headers, ["repeat", "repeats", "rounds", "sets"]);

  if (nameIndex < 0 || workIndex < 0) {
    throw new Error("CSV columns: name, work, rest, repeat");
  }

  const intervals = rows.slice(1).map((row, index) => {
    const name = row[nameIndex]?.trim() || `Step ${index + 1}`;
    const workSeconds = parseDuration(row[workIndex]);
    const restSeconds = restIndex >= 0 ? parseDuration(row[restIndex]) : 0;
    const repeat = repeatIndex >= 0 ? Math.max(1, readPositiveInteger(row[repeatIndex], 1)) : 1;
    if (workSeconds <= 0) throw new Error(`Work time missing on row ${index + 2}`);
    return createInterval(name, workSeconds, restSeconds, repeat);
  });

  return {
    id: makeId(),
    name: fallbackName || "Imported template",
    intervals,
  };
}

function parseCsv(text) {
  const rows = [];
  let row = [];
  let cell = "";
  let quoted = false;

  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    const next = text[index + 1];

    if (char === '"' && quoted && next === '"') {
      cell += '"';
      index += 1;
    } else if (char === '"') {
      quoted = !quoted;
    } else if (char === "," && !quoted) {
      row.push(cell);
      cell = "";
    } else if ((char === "\n" || char === "\r") && !quoted) {
      if (char === "\r" && next === "\n") index += 1;
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
    } else {
      cell += char;
    }
  }

  row.push(cell);
  rows.push(row);
  return rows;
}

function normalizeHeader(value) {
  return value.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function findHeader(headers, names) {
  return headers.findIndex((header) => names.includes(header));
}

function parseDuration(value) {
  const text = String(value || "").trim();
  if (!text) return 0;

  if (text.includes(":")) {
    const parts = text.split(":").map((part) => readPositiveInteger(part, 0));
    if (parts.length === 2) return parts[0] * 60 + parts[1];
    if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  }

  const minuteMatch = text.match(/(\d+)\s*m/i);
  const secondMatch = text.match(/(\d+)\s*s/i);
  if (minuteMatch || secondMatch) {
    return readPositiveInteger(minuteMatch?.[1], 0) * 60 + readPositiveInteger(secondMatch?.[1], 0);
  }

  return readPositiveInteger(text, 0);
}

function readPositiveInteger(value, fallback) {
  const number = Number.parseInt(String(value || "").trim(), 10);
  if (Number.isNaN(number)) return fallback;
  return Math.max(0, number);
}

function renderIntervals() {
  elements.intervalList.innerHTML = "";
  if (!draftWorkflow) return;

  draftWorkflow.intervals.forEach((interval, index) => {
    const node = elements.intervalTemplate.content.firstElementChild.cloneNode(true);
    node.querySelector(".interval-name").value = interval.name;
    node.querySelector(".work-minutes").value = Math.floor(interval.workSeconds / 60);
    node.querySelector(".work-seconds").value = interval.workSeconds % 60;
    node.querySelector(".rest-minutes").value = Math.floor(interval.restSeconds / 60);
    node.querySelector(".rest-seconds").value = interval.restSeconds % 60;
    node.querySelector(".repeat-count").value = interval.repeat;

    node.querySelector(".move-up").disabled = index === 0;
    node.querySelector(".move-down").disabled = index === draftWorkflow.intervals.length - 1;
    node.querySelector(".remove-interval").disabled = draftWorkflow.intervals.length === 1;

    node.addEventListener("input", (event) => updateDraftInterval(interval.id, node, event));
    node.querySelector(".remove-interval").addEventListener("click", () => removeDraftInterval(interval.id));
    node.querySelector(".move-up").addEventListener("click", () => moveDraftInterval(index, -1));
    node.querySelector(".move-down").addEventListener("click", () => moveDraftInterval(index, 1));

    elements.intervalList.append(node);
  });
}

function updateDraftInterval(id, node, event) {
  if (!draftWorkflow) return;
  const interval = draftWorkflow.intervals.find((item) => item.id === id);
  if (!interval) return;

  const workMinutes = readNumber(node.querySelector(".work-minutes"), 0, 99);
  const workSeconds = readNumber(node.querySelector(".work-seconds"), 0, 59);
  const restMinutes = readNumber(node.querySelector(".rest-minutes"), 0, 99);
  const restSeconds = readNumber(node.querySelector(".rest-seconds"), 0, 59);
  const repeat = readNumber(node.querySelector(".repeat-count"), 1, 99);

  if (event.target.classList.contains("interval-name")) {
    interval.name = event.target.value || "Untitled";
  }

  interval.workSeconds = Math.max(1, workMinutes * 60 + workSeconds);
  interval.restSeconds = restMinutes * 60 + restSeconds;
  interval.repeat = repeat;
}

function removeDraftInterval(id) {
  if (!draftWorkflow) return;
  draftWorkflow.intervals = draftWorkflow.intervals.filter((item) => item.id !== id);
  renderIntervals();
}

function moveDraftInterval(index, direction) {
  if (!draftWorkflow) return;
  const nextIndex = index + direction;
  const [interval] = draftWorkflow.intervals.splice(index, 1);
  draftWorkflow.intervals.splice(nextIndex, 0, interval);
  renderIntervals();
}

function rebuildTimeline() {
  timeline = workflow
    ? workflow.intervals.flatMap((interval) => {
        const steps = [];
        for (let round = 1; round <= interval.repeat; round += 1) {
          steps.push({
            type: "work",
            exercise: interval.name,
            round,
            repeat: interval.repeat,
            durationSeconds: interval.workSeconds,
          });

          if (interval.restSeconds > 0) {
            steps.push({
              type: "rest",
              exercise: interval.name,
              round,
              repeat: interval.repeat,
              durationSeconds: interval.restSeconds,
            });
          }
        }
        return steps;
      })
    : [];

  currentStepIndex = Math.min(currentStepIndex, Math.max(timeline.length - 1, 0));
  if (!timerId) {
    setStepTime(currentStepIndex);
  }
}

function toggleTimer() {
  if (timerId) {
    pauseTimer();
  } else {
    startTimer();
  }
}

function startTimer() {
  if (!timeline.length) return;
  if (remainingMs <= 0 || currentStepIndex >= timeline.length) {
    currentStepIndex = 0;
    setStepTime(currentStepIndex);
  }
  timerId = window.setInterval(tick, 100);
  lastTick = performance.now();
  lastCountdownSecond = null;
  setPlayButton(true);
  playStepTone(timeline[currentStepIndex]?.type || "work");
  speakStep(timeline[currentStepIndex]);
}

function pauseTimer() {
  if (!timerId) return;
  window.clearInterval(timerId);
  timerId = null;
  setPlayButton(false);
}

function stopTimer() {
  pauseTimer();
  currentStepIndex = 0;
  setStepTime(currentStepIndex);
}

function tick() {
  const now = performance.now();
  remainingMs = Math.max(0, remainingMs - (now - lastTick));
  lastTick = now;

  playCountdownTone();

  if (remainingMs <= 0) {
    advanceStep();
  }

  updateTimerDisplay();
}

function previousStep() {
  if (!timeline.length) return;
  const elapsedMs = activeDurationMs - remainingMs;
  const targetIndex = elapsedMs > 2500 || currentStepIndex === 0 ? currentStepIndex : currentStepIndex - 1;
  jumpToStep(targetIndex);
}

function nextStep() {
  if (!timeline.length) return;
  advanceStep();
  updateTimerDisplay();
}

function jumpToStep(index) {
  if (!timeline.length) {
    updateTimerDisplay();
    return;
  }

  currentStepIndex = Math.max(0, Math.min(index, timeline.length - 1));
  setStepTime(currentStepIndex);
  if (timerId) {
    lastTick = performance.now();
    playStepTone(timeline[currentStepIndex].type);
    speakStep(timeline[currentStepIndex]);
  }
  updateTimerDisplay();
}

function advanceStep() {
  currentStepIndex += 1;
  lastCountdownSecond = null;
  if (currentStepIndex >= timeline.length) {
    pauseTimer();
    remainingMs = 0;
    activeDurationMs = 0;
    playFinishTone();
    return;
  }

  setStepTime(currentStepIndex);
  playStepTone(timeline[currentStepIndex].type);
  speakStep(timeline[currentStepIndex]);
}

function setStepTime(index) {
  remainingMs = timeline[index]?.durationSeconds * 1000 || 0;
  activeDurationMs = remainingMs;
  lastCountdownSecond = null;
}

function setPlayButton(isRunning) {
  elements.playPause.innerHTML = isRunning ? "&#10074;&#10074;" : "&#9654;";
  elements.playPause.setAttribute("aria-label", isRunning ? "Pause timer" : "Start timer");
}

function playCountdownTone() {
  const secondsLeft = Math.ceil(remainingMs / 1000);
  if (secondsLeft > 0 && secondsLeft <= 3 && secondsLeft !== lastCountdownSecond) {
    lastCountdownSecond = secondsLeft;
    tone(980, 0.055, 0, 0.1);
  }
}

function speakStep(step) {
  if (!voiceEnabled || !step) {
    return;
  }

  if (playRecordedAnnouncement(step)) return;
  if (!speechAvailable || !canUseSpeech()) return;

  const message = step.type === "work" ? step.exercise : `Rest. Next: ${upcomingExerciseText()}`;
  if (!message || message.endsWith(": -")) return;

  window.speechSynthesis.cancel();
  const utterance = new window.SpeechSynthesisUtterance(message);
  utterance.voice = speechVoice;
  utterance.lang = speechVoice?.lang || "en-US";
  utterance.rate = 1;
  utterance.pitch = 1;
  utterance.volume = 1;
  utterance.onerror = () => {
    setVoiceStatus("Voice failed in this Firefox session.");
  };
  window.speechSynthesis.resume();
  window.speechSynthesis.speak(utterance);
}

function cancelSpeech() {
  announcementToken += 1;
  if (announcementAudio) {
    announcementAudio.pause();
    announcementAudio.currentTime = 0;
    announcementAudio = null;
  }
  if (canUseSpeech()) {
    window.speechSynthesis.cancel();
  }
}

function playRecordedAnnouncement(step) {
  const files =
    step.type === "work"
      ? [audioFileForExercise(step.exercise)]
      : [AUDIO_FILES.rest, AUDIO_FILES.next, audioFileForExercise(upcomingExerciseText())];
  const playableFiles = files.filter(Boolean);
  if (!playableFiles.length) return false;

  playAudioQueue(playableFiles);
  return true;
}

function playAudioQueue(files) {
  cancelSpeech();
  const token = announcementToken;
  let index = 0;

  const playNext = () => {
    if (token !== announcementToken || index >= files.length) return;
    announcementAudio = new Audio(files[index]);
    index += 1;
    announcementAudio.addEventListener("ended", playNext, { once: true });
    announcementAudio.addEventListener("error", playNext, { once: true });
    announcementAudio.play().catch(() => {
      playNext();
    });
  };

  playNext();
}

function audioFileForExercise(name) {
  const key = normalizeAudioKey(name);
  return AUDIO_FILES[key] || AUDIO_FILES[AUDIO_ALIASES[key]] || null;
}

function normalizeAudioKey(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/&/g, "and")
    .replace(/[^a-z0-9]/g, "");
}

function canUseSpeech() {
  return "speechSynthesis" in window && "SpeechSynthesisUtterance" in window;
}

function setVoiceStatus(message) {
  elements.voiceStatus.textContent = message;
}

function updateTimerDisplay() {
  const isComplete = timeline.length > 0 && currentStepIndex >= timeline.length;
  const step = timeline[currentStepIndex];
  const totalSeconds = Math.ceil(remainingMs / 1000);

  elements.timeReadout.textContent = formatSeconds(totalSeconds);
  elements.phaseKind.textContent = isComplete ? "Complete" : step ? step.type : "Ready";
  elements.phasePosition.textContent = timeline.length
    ? `${Math.min(currentStepIndex + 1, timeline.length)} / ${timeline.length}`
    : "0 / 0";
  elements.phaseName.textContent = isComplete ? "Done" : step ? stepTitle(step) : "No template selected";
  elements.upNext.textContent = `Next: ${nextStepText()}`;
  elements.upcoming.textContent = `Upcoming: ${upcomingExerciseText()}`;

  const progress = activeDurationMs ? 1 - remainingMs / activeDurationMs : 0;
  elements.phaseProgress.style.width = isComplete
    ? "100%"
    : `${Math.max(0, Math.min(progress, 1)) * 100}%`;
  elements.previousStep.disabled = !timeline.length;
  elements.nextStep.disabled = !timeline.length || isComplete;
  elements.reset.disabled = !timeline.length;
  elements.playPause.disabled = !timeline.length;
}

function stepTitle(step) {
  return step.type === "rest" ? `Rest: ${step.exercise}` : step.exercise;
}

function nextStepText() {
  const next = timeline[currentStepIndex + 1];
  if (!next) return "-";
  return `${stepTitle(next)} - ${formatSeconds(next.durationSeconds)}`;
}

function upcomingExerciseText() {
  for (let index = currentStepIndex + 1; index < timeline.length; index += 1) {
    if (timeline[index].type === "work") return timeline[index].exercise;
  }
  return "-";
}

function getWorkflowStats(item) {
  return item.intervals.reduce(
    (stats, interval) => {
      stats.totalSeconds += (interval.workSeconds + interval.restSeconds) * interval.repeat;
      stats.rounds += interval.repeat;
      return stats;
    },
    { totalSeconds: 0, rounds: 0 },
  );
}

function createInterval(name = "New step", workSeconds = 60, restSeconds = 20, repeat = 3) {
  return {
    id: makeId(),
    name,
    workSeconds,
    restSeconds,
    repeat,
  };
}

function makeId() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  return `interval-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function cloneWorkflow(value) {
  if (globalThis.structuredClone) return globalThis.structuredClone(value);
  return JSON.parse(JSON.stringify(value));
}

function readNumber(input, min, max) {
  const number = Number.parseInt(input.value, 10);
  if (Number.isNaN(number)) return min;
  return Math.max(min, Math.min(max, number));
}

function formatSeconds(totalSeconds) {
  const boundedSeconds = Math.max(0, totalSeconds);
  const minutes = Math.floor(boundedSeconds / 60);
  const seconds = boundedSeconds % 60;
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

function loadWorkflows() {
  try {
    const current = JSON.parse(localStorage.getItem(STORAGE_KEY) || "[]");
    if (Array.isArray(current) && current.length) return current;

    const legacy = JSON.parse(localStorage.getItem(LEGACY_STORAGE_KEY) || "[]");
    if (!Array.isArray(legacy)) return [];
    return legacy.filter((item) => !String(item.id || "").startsWith("preset-") && item.id !== "default-tabata");
  } catch {
    return [];
  }
}

function persistWorkflows() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(savedWorkflows));
  } catch {
    elements.upNext.textContent = "Storage unavailable";
  }
}

function csvEscape(value) {
  const text = String(value ?? "");
  if (!/[",\n\r]/.test(text)) return text;
  return `"${text.replaceAll('"', '""')}"`;
}

function filenameSafe(value) {
  const safe = String(value || "template")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return safe || "template";
}

function playStepTone(type) {
  if (type === "rest") {
    tone(520, 0.12, 0, 0.18);
    tone(390, 0.16, 0.13, 0.16);
    return;
  }
  tone(740, 0.12, 0, 0.18);
  tone(980, 0.18, 0.13, 0.16);
}

function playFinishTone() {
  tone(520, 0.12, 0, 0.18);
  tone(740, 0.12, 0.15, 0.18);
  tone(980, 0.24, 0.3, 0.16);
}

function tone(frequency, duration, delay = 0, volume = 0.14) {
  if (!soundEnabled) return;
  const AudioContext = window.AudioContext || window.webkitAudioContext;
  if (!AudioContext) return;

  const context = getAudioContext(AudioContext);
  const oscillator = context.createOscillator();
  const gain = context.createGain();
  const start = context.currentTime + delay;

  oscillator.frequency.value = frequency;
  oscillator.type = "square";
  gain.gain.setValueAtTime(0.0001, start);
  gain.gain.exponentialRampToValueAtTime(volume, start + 0.01);
  gain.gain.exponentialRampToValueAtTime(0.0001, start + duration);

  oscillator.connect(gain).connect(context.destination);
  oscillator.start(start);
  oscillator.stop(start + duration + 0.03);
}

function getAudioContext(AudioContext) {
  if (!getAudioContext.context) {
    getAudioContext.context = new AudioContext();
  }
  if (getAudioContext.context.state === "suspended") {
    getAudioContext.context.resume();
  }
  return getAudioContext.context;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
