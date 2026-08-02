(function () {
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

  window.editor.init();
  initBottomTabs();
  document.getElementById("assemble").addEventListener("click", runAssemble);
  logConsole("tb32emu ready.", "log-muted");
})();
