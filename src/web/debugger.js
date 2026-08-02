(function () {
  var host, regsEl, flagsEl, disasmEl, stackEl, ctlStep, ctlCont, ctlPause;
  var names = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "r12", "sp", "fp", "lr"];

  function hx(n) { return (n >>> 0).toString(16).padStart(8, "0"); }

  function mkbtn(label, fn) {
    var b = document.createElement("button");
    b.className = "tbtn dbg-btn";
    b.textContent = label;
    b.disabled = true;
    b.addEventListener("click", fn);
    return b;
  }

  function section(t) {
    var h = document.createElement("h2");
    h.textContent = t;
    return h;
  }

  function build(el) {
    host = el;
    host.innerHTML = "";
    var ctl = document.createElement("div");
    ctl.className = "dbg-controls";
    ctlStep = mkbtn("Step", function () { if (window.emuControls) window.emuControls.step(); });
    ctlCont = mkbtn("Continue", function () { if (window.emuControls) window.emuControls.cont(); });
    ctlPause = mkbtn("Pause", function () { if (window.emuControls) window.emuControls.pause(); });
    ctl.appendChild(ctlStep);
    ctl.appendChild(ctlCont);
    ctl.appendChild(ctlPause);
    host.appendChild(ctl);

    host.appendChild(section("Registers"));
    regsEl = document.createElement("div");
    regsEl.className = "dbg-regs";
    host.appendChild(regsEl);
    flagsEl = document.createElement("div");
    flagsEl.className = "dbg-flags";
    host.appendChild(flagsEl);

    host.appendChild(section("Disassembly"));
    disasmEl = document.createElement("div");
    disasmEl.className = "dbg-disasm";
    host.appendChild(disasmEl);

    host.appendChild(section("Stack"));
    stackEl = document.createElement("div");
    stackEl.className = "dbg-stack";
    host.appendChild(stackEl);

    clear();
  }

  function clear() {
    regsEl.innerHTML = "";
    flagsEl.innerHTML = "";
    stackEl.innerHTML = "";
    disasmEl.innerHTML = '<p class="hint">Run or step to inspect CPU state.</p>';
  }

  function regCell(name, val, extra) {
    var d = document.createElement("div");
    d.className = "reg" + (extra || "");
    d.innerHTML = '<span class="rn">' + name + '</span><span class="rv">' + hx(val) + "</span>";
    return d;
  }

  async function refresh() {
    var s = await window.dbgSnapshot();
    if (!s || s.pc === undefined) return;
    regsEl.innerHTML = "";
    for (var i = 0; i < 16; i++) regsEl.appendChild(regCell(names[i], s.regs[i], ""));
    regsEl.appendChild(regCell("pc", s.pc, " reg-pc"));

    flagsEl.innerHTML = "";
    ["z", "n", "c", "v"].forEach(function (f) {
      var el = document.createElement("span");
      el.className = "flag" + (s.flags[f] ? " on" : "");
      el.textContent = f.toUpperCase();
      flagsEl.appendChild(el);
    });

    disasmEl.innerHTML = "";
    s.disasm.forEach(function (d) {
      var line = document.createElement("div");
      line.className = "dline" + (d.a === s.pc ? " cur" : "");
      var bp = document.createElement("span");
      bp.className = "bp" + (d.bp ? " on" : "");
      bp.title = "Toggle breakpoint";
      bp.addEventListener("click", function (e) {
        e.stopPropagation();
        window.dbgBreak(d.a, !d.bp).then(refresh);
      });
      var addr = document.createElement("span");
      addr.className = "daddr";
      addr.textContent = hx(d.a);
      var txt = document.createElement("span");
      txt.className = "dtext";
      txt.textContent = d.t;
      line.appendChild(bp);
      line.appendChild(addr);
      line.appendChild(txt);
      disasmEl.appendChild(line);
    });

    stackEl.innerHTML = "";
    s.stack.forEach(function (wd) {
      var line = document.createElement("div");
      line.className = "sline";
      line.innerHTML = '<span class="daddr">' + hx(wd.a) + '</span><span class="dtext">' + hx(wd.v) + "</span>";
      stackEl.appendChild(line);
    });
  }

  function setControls(state) {
    var paused = state === "paused";
    ctlStep.disabled = !paused;
    ctlCont.disabled = !paused;
    ctlPause.disabled = state !== "running";
  }

  window.dbg = { attach: build, refresh: refresh, clear: clear, setControls: setControls };
})();
