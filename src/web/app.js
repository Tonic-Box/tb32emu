(function () {
  var decoder = new TextDecoder();
  var emuState = "idle";

  function hx(n) { return (n >>> 0).toString(16); }

  function logConsole(text, cls) {
    var c = document.getElementById("console");
    var line = document.createElement("div");
    line.className = cls || "log-info";
    line.textContent = text;
    c.appendChild(line);
    c.scrollTop = c.scrollHeight;
  }
  window.logConsole = logConsole;

  var curStatus = "";
  function setStatus(kind, text) {
    var key = kind + "|" + text;
    if (key === curStatus) return;
    curStatus = key;
    document.getElementById("term-dot").className = "dot dot-" + kind;
    document.getElementById("term-state").textContent = text;
  }

  function showPanel(name) {
    document.querySelectorAll(".btab").forEach(function (b) {
      b.classList.toggle("active", b.dataset.panel === name);
    });
    document.querySelectorAll("#bottom-body .panel").forEach(function (p) {
      p.classList.toggle("active", p.id === name);
    });
    document.getElementById("bottom").classList.toggle("bottom-tall", name === "terminal");
  }

  function initBottomTabs() {
    document.querySelectorAll(".btab").forEach(function (b) {
      b.addEventListener("click", function () { showPanel(b.dataset.panel); });
    });
  }

  function setState(s) {
    emuState = s;
    document.getElementById("run").disabled = s === "running";
    document.getElementById("stop").disabled = !(s === "running" || s === "paused");
    window.term.setActive(s === "running");
    window.dbg.setControls(s);
  }

  async function runAssemble() {
    window.editor.clearError();
    var res = await window.assemble(window.editor.activeContent());
    if (res && res.ok) {
      logConsole("assembled " + window.editor.activeName() + " -> " + res.bytes + " bytes", "log-ok");
    } else if (res) {
      logConsole(window.editor.activeName() + ":" + res.line + ": " + res.message, "log-error");
      window.editor.markError(res.line);
      showPanel("console");
    } else {
      logConsole("assemble failed", "log-error");
    }
  }
  window.runAssemble = runAssemble;

  var cfg = { rawArgs: "", rawEnv: "", rawSeed: "", args: [], env: [], seed: null };

  function parseConfig() {
    cfg.args = cfg.rawArgs.trim() ? cfg.rawArgs.trim().split(/\s+/) : [];
    cfg.env = cfg.rawEnv.split("\n").map(function (l) { return l.trim(); }).filter(Boolean).map(function (l) {
      var i = l.indexOf("=");
      return i < 0 ? [l, ""] : [l.slice(0, i), l.slice(i + 1)];
    });
    var s = cfg.rawSeed.trim();
    cfg.seed = s === "" ? null : (Number.isFinite(Number(s)) ? Math.floor(Number(s)) : null);
  }

  function openConfig() {
    document.getElementById("cfg-args").value = cfg.rawArgs;
    document.getElementById("cfg-env").value = cfg.rawEnv;
    document.getElementById("cfg-seed").value = cfg.rawSeed;
    document.getElementById("config-modal").classList.remove("hidden");
  }

  function saveConfig() {
    cfg.rawArgs = document.getElementById("cfg-args").value;
    cfg.rawEnv = document.getElementById("cfg-env").value;
    cfg.rawSeed = document.getElementById("cfg-seed").value;
    parseConfig();
    document.getElementById("config-modal").classList.add("hidden");
    logConsole("run config saved" + (cfg.seed !== null ? " (seed " + cfg.seed + ")" : ""), "log-muted");
  }

  function closeConfig() {
    document.getElementById("config-modal").classList.add("hidden");
  }

  function buildRunReq() {
    return {
      src: window.editor.activeContent(),
      args: [window.editor.activeName()].concat(cfg.args),
      env: cfg.env,
      seed: cfg.seed,
    };
  }

  function logRunStart() {
    var extra = [];
    if (cfg.seed !== null) extra.push("seed=" + cfg.seed);
    if (cfg.args.length) extra.push("args: " + cfg.args.join(" "));
    logConsole("running " + window.editor.activeName() + (extra.length ? " (" + extra.join(", ") + ")" : ""), "log-muted");
  }

  function outToTerm(b64) {
    if (!b64) return;
    var bin = atob(b64), arr = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    window.term.write(decoder.decode(arr));
  }

  function showError(res) {
    logConsole(window.editor.activeName() + ":" + (res ? res.line : 0) + ": " + (res ? res.message : "failed to start"), "log-error");
    if (res && res.line) window.editor.markError(res.line);
    showPanel("console");
  }

  function endRun(msg, logcls, kind, text) {
    setState("ended");
    logConsole(msg, logcls);
    setStatus(kind, text);
    window.dbg.refresh();
  }

  function applyEnd(res) {
    switch (res.state) {
      case "halted": endRun("program halted", "log-muted", "idle", "halted"); return true;
      case "exited": endRun("program exited (code " + res.code + ")", res.code === 0 ? "log-ok" : "log-warn", res.code === 0 ? "ok" : "warn", "exited (" + res.code + ")"); return true;
      case "fault": endRun("fault " + res.code + " at pc=0x" + hx(res.pc), "log-error", "err", "fault"); return true;
      default: return false;
    }
  }

  async function tickOnce() {
    if (emuState !== "running") return;
    var input = window.term.takeInput();
    var res = await window.emuTick(input ? btoa(input) : "", 200000);
    if (!res) { endRun("emulator error", "log-error", "err", "error"); return; }
    outToTerm(res.out);
    window.term.setRaw(res.raw);
    switch (res.state) {
      case "running": setStatus("running", "running"); setTimeout(tickOnce, 0); break;
      case "sleep": setStatus("running", "running"); setTimeout(tickOnce, res.ms || 0); break;
      case "waiting": setStatus("running", "waiting for input"); setTimeout(tickOnce, 16); break;
      case "breakpoint":
        setState("paused");
        setStatus("warn", "paused (breakpoint 0x" + hx(res.pc) + ")");
        logConsole("breakpoint at 0x" + hx(res.pc), "log-warn");
        window.dbg.refresh();
        break;
      default: applyEnd(res);
    }
  }

  async function runProgram() {
    if (emuState === "running") return;
    window.editor.clearError();
    var res = await window.run(buildRunReq());
    if (!res || !res.ok) { showError(res); return; }
    window.term.reset();
    showPanel("terminal");
    setState("running");
    setStatus("running", "running");
    logRunStart();
    setTimeout(tickOnce, 0);
  }

  function continueRun() {
    if (emuState !== "paused") return;
    setState("running");
    setStatus("running", "running");
    setTimeout(tickOnce, 0);
  }

  function pauseRun() {
    if (emuState !== "running") return;
    setState("paused");
    setStatus("warn", "paused");
    window.dbg.refresh();
  }

  async function stepProgram() {
    if (emuState === "running") return;
    if (emuState !== "paused") {
      window.editor.clearError();
      var r = await window.run(buildRunReq());
      if (!r || !r.ok) { showError(r); return; }
      window.term.reset();
      showPanel("terminal");
      setState("paused");
      setStatus("warn", "paused (entry)");
      logConsole("debugging " + window.editor.activeName(), "log-muted");
      window.dbg.refresh();
      return;
    }
    var res = await window.dbgStep();
    if (!res) { endRun("emulator error", "log-error", "err", "error"); return; }
    outToTerm(res.out);
    window.term.setRaw(res.raw);
    if (!applyEnd(res)) {
      setStatus("warn", res.state === "waiting" ? "paused (needs input)" : "paused");
      window.dbg.refresh();
    }
  }

  function stopProgram() {
    if (emuState === "idle") return;
    window.emuStop();
    setState("idle");
    setStatus("idle", "stopped");
    logConsole("stopped", "log-muted");
    window.dbg.clear();
  }

  window.editor.init();
  window.term.attach(document.getElementById("term-host"));
  window.dbg.attach(document.getElementById("debug-pane"));
  initBottomTabs();
  document.getElementById("assemble").addEventListener("click", runAssemble);
  document.getElementById("run").addEventListener("click", runProgram);
  document.getElementById("stop").addEventListener("click", stopProgram);
  document.getElementById("config").addEventListener("click", openConfig);
  document.getElementById("cfg-save").addEventListener("click", saveConfig);
  document.getElementById("cfg-cancel").addEventListener("click", closeConfig);
  document.getElementById("clear-console").addEventListener("click", function () {
    document.getElementById("console").innerHTML = "";
  });
  window.emuControls = { step: stepProgram, cont: continueRun, pause: pauseRun, run: runProgram, stop: stopProgram };
  setState("idle");
  logConsole("tb32emu ready.", "log-muted");
})();
