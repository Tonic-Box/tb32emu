(function () {
  var ROWS = 24, COLS = 80;
  var vt = window.TBXVT.createTerminal(COLS, ROWS);
  var pre = null, raw = false, active = false, lineBuf = "", inputBuf = "";

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  function cellClass(row, c) {
    var f = row.f[c], b = row.b[c], a = row.a[c], cls = "";
    if (a & 1) { var t = f; f = b; b = t; if (!f && !b) return (a & 2) ? "vt-rev vt-bold" : "vt-rev"; }
    if (f) cls = "vt-fg-" + f;
    if (b) cls = cls ? cls + " vt-bg-" + b : "vt-bg-" + b;
    if (a & 2) cls = cls ? cls + " vt-bold" : "vt-bold";
    return cls;
  }

  function rowHtml(row, curCol) {
    var n = row.c.length, last = -1;
    for (var c = 0; c < n; c++) if (row.c[c] !== " " || (row.a[c] & 1) || row.f[c] || row.b[c]) last = c;
    if (curCol != null && curCol > last) last = curCol;
    var html = "", i = 0;
    while (i <= last) {
      if (i === curCol) { html += '<span class="vt-cursor">' + esc(row.c[i]) + "</span>"; i++; continue; }
      var cls = cellClass(row, i), text = "", j = i;
      while (j <= last && j !== curCol && cellClass(row, j) === cls) { text += row.c[j]; j++; }
      var e = esc(text);
      html += cls ? '<span class="' + cls + '">' + e + "</span>" : e;
      i = j;
    }
    return html;
  }

  function render() {
    if (!pre) return;
    var vp = vt.viewport(), cur = vt.cursor(), html = "";
    for (var r = 0; r < ROWS; r++) {
      html += rowHtml(vp[r], (cur.visible && r === cur.r) ? cur.c : null);
      if (r < ROWS - 1) html += "\n";
    }
    pre.innerHTML = html;
  }

  function keyBytes(e) {
    var k = e.key;
    if (k.length === 1) {
      if (e.ctrlKey) {
        var cc = k.toLowerCase().charCodeAt(0);
        if (cc >= 97 && cc <= 122) return String.fromCharCode(cc - 96);
      }
      return k;
    }
    switch (k) {
      case "Enter": return "\n";
      case "Backspace": return "\x7f";
      case "Tab": return "\t";
      case "Escape": return "\x1b";
      case "ArrowUp": return "\x1b[A";
      case "ArrowDown": return "\x1b[B";
      case "ArrowRight": return "\x1b[C";
      case "ArrowLeft": return "\x1b[D";
      case "Home": return "\x1b[H";
      case "End": return "\x1b[F";
      case "Delete": return "\x1b[3~";
      default: return "";
    }
  }

  function onKey(e) {
    if (!active) return;
    var b = keyBytes(e);
    if (b === "") return;
    e.preventDefault();
    if (raw) { inputBuf += b; return; }
    if (b === "\n") { vt.write("\r\n"); inputBuf += lineBuf + "\n"; lineBuf = ""; render(); return; }
    if (b === "\x7f") { if (lineBuf.length) { lineBuf = lineBuf.slice(0, -1); vt.write("\b \b"); render(); } return; }
    if (b.length === 1 && b >= " ") { lineBuf += b; vt.write(b); render(); return; }
    inputBuf += b;
  }

  document.addEventListener("keydown", onKey);

  window.term = {
    attach: function (el) {
      el.innerHTML = "";
      pre = document.createElement("pre");
      pre.className = "vt-screen";
      el.appendChild(pre);
      render();
    },
    reset: function () { vt.reset(); lineBuf = ""; inputBuf = ""; raw = false; render(); },
    write: function (s) { vt.write(s); render(); },
    setRaw: function (v) { raw = !!v; },
    setActive: function (v) { active = !!v; },
    takeInput: function () { var s = inputBuf; inputBuf = ""; return s; },
  };
})();
