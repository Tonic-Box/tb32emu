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

  function initBottomTabs() {
    var tabs = document.querySelectorAll(".btab");
    tabs.forEach(function (b) {
      b.addEventListener("click", function () {
        tabs.forEach(function (x) { x.classList.remove("active"); });
        b.classList.add("active");
        document.querySelectorAll("#bottom-body .panel").forEach(function (p) {
          p.classList.remove("active");
        });
        document.getElementById(b.dataset.panel).classList.add("active");
      });
    });
  }

  window.editor.init();
  initBottomTabs();
  logConsole("tb32emu ready.", "log-muted");
  if (window.ping) {
    window.ping().then(function (r) { logConsole("backend: " + r, "log-ok"); });
  }
})();
