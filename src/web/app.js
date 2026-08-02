(function () {
  var decoder = new TextDecoder();
  var running = false;

  function logConsole(text, cls) {
    var c = document.getElementById("console");
    var line = document.createElement("div");
    line.className = cls || "log-info";
    line.textContent = text;
    c.appendChild(line);
    c.scrollTop = c.scrollHeight;
  }
  window.logConsole = logConsole;

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

  function outToTerm(b64) {
    if (!b64) return;
    var bin = atob(b64), arr = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    window.term.write(decoder.decode(arr));
  }

  var curStatus = "";
  function setStatus(kind, text) {
    var key = kind + "|" + text;
    if (key === curStatus) return;
    curStatus = key;
    document.getElementById("term-dot").className = "dot dot-" + kind;
    document.getElementById("term-state").textContent = text;
  }

  function setRunning(on) {
    running = on;
    document.getElementById("run").disabled = on;
    document.getElementById("stop").disabled = !on;
    window.term.setActive(on);
  }

  function finish(msg, cls) {
    setRunning(false);
    logConsole(msg, cls || "log-muted");
  }

  async function tickOnce() {
    if (!running) return;
    var input = window.term.takeInput();
    var res = await window.emuTick(input ? btoa(input) : "", 200000);
    if (!res) { finish("emulator error", "log-error"); return; }
    outToTerm(res.out);
    window.term.setRaw(res.raw);
    switch (res.state) {
      case "running": setStatus("running", "running"); setTimeout(tickOnce, 0); break;
      case "sleep": setStatus("running", "running"); setTimeout(tickOnce, res.ms || 0); break;
      case "waiting": setStatus("running", "waiting for input"); setTimeout(tickOnce, 16); break;
      case "halted": finish("program halted"); setStatus("idle", "halted"); break;
      case "exited":
        finish("program exited (code " + res.code + ")", res.code === 0 ? "log-ok" : "log-warn");
        setStatus(res.code === 0 ? "ok" : "warn", "exited (" + res.code + ")");
        break;
      case "fault":
        finish("fault " + res.code + " at pc=0x" + (res.pc >>> 0).toString(16), "log-error");
        setStatus("err", "fault");
        break;
      default: finish("stopped"); setStatus("idle", "stopped");
    }
  }

  async function runProgram() {
    if (running) return;
    window.editor.clearError();
    var res = await window.run(window.editor.activeContent());
    if (!res || !res.ok) {
      logConsole(window.editor.activeName() + ":" + (res ? res.line : 0) + ": " + (res ? res.message : "run failed"), "log-error");
      if (res && res.line) window.editor.markError(res.line);
      showPanel("console");
      return;
    }
    window.term.reset();
    showPanel("terminal");
    setRunning(true);
    setStatus("running", "running");
    logConsole("running " + window.editor.activeName(), "log-muted");
    setTimeout(tickOnce, 0);
  }

  function stopProgram() {
    if (!running) return;
    window.emuStop();
    finish("stopped");
    setStatus("idle", "stopped");
  }

  window.editor.init();
  window.term.attach(document.getElementById("term-host"));
  initBottomTabs();
  document.getElementById("assemble").addEventListener("click", runAssemble);
  document.getElementById("run").addEventListener("click", runProgram);
  document.getElementById("stop").addEventListener("click", stopProgram);
  logConsole("tb32emu ready.", "log-muted");
})();
