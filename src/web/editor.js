(function () {
  var CM = window.CodeMirror;

  var MNEMONICS = "add|sub|and|or|xor|sll|srl|sra|slt|sltu|mul|divu|remu|cmp|tst|div|rem|" +
    "addi|andi|ori|xori|slli|srli|srai|slti|sltiu|lui|cmpi|lb|lbu|lh|lhu|lw|sb|sh|sw|" +
    "bra|beq|bne|blt|bge|bltu|bgeu|call|callr|ret|jmp|sys|hlt|brk|nop|mov|li|push|pop|j";

  CM.defineSimpleMode("tb32", {
    start: [
      { regex: /[;#].*/, token: "comment" },
      { regex: /\/\/.*/, token: "comment" },
      { regex: /"(?:[^"\\]|\\.)*"?/, token: "string" },
      { regex: /[A-Za-z_.$][\w.$]*:/, token: "def" },
      { regex: /\.[A-Za-z_][\w]*/, token: "meta" },
      { regex: /\b(?:r1[0-5]|r[0-9]|zero|sp|fp|lr)\b/, token: "variable-2" },
      { regex: /-?(?:0x[0-9a-fA-F]+|\d+)\b/, token: "number" },
      { regex: new RegExp("\\b(?:" + MNEMONICS + ")\\b", "i"), token: "keyword" },
      { regex: /[A-Za-z_.$][\w.$]*/, token: "variable" },
    ],
    meta: { lineComment: ";" },
  });

  var SAMPLE = [
    ".text",
    ".entry _start",
    "",
    "_start:",
    "    li r1, 5",
    "    li r2, 37",
    "    add r3, r1, r2      ; r3 = 42",
    "    hlt",
    "",
  ].join("\n");

  var cm;
  var tabs = [];
  var active = -1;
  var untitled = 0;

  function nextName() {
    untitled += 1;
    return "untitled-" + untitled + ".s";
  }

  function render() {
    var bar = document.getElementById("tabbar");
    bar.innerHTML = "";
    tabs.forEach(function (t, i) {
      var el = document.createElement("div");
      el.className = "tab" + (i === active ? " active" : "");
      var name = document.createElement("span");
      name.textContent = t.name;
      name.addEventListener("click", function () { select(i); });
      var close = document.createElement("span");
      close.className = "close";
      close.textContent = "×";
      close.title = "Close";
      close.addEventListener("click", function (e) { e.stopPropagation(); closeTab(i); });
      el.appendChild(name);
      el.appendChild(close);
      bar.appendChild(el);
    });
    var add = document.createElement("div");
    add.className = "tab-new";
    add.textContent = "+";
    add.title = "New file";
    add.addEventListener("click", function () { newTab(); });
    bar.appendChild(add);
  }

  function select(i) {
    if (i === active) return;
    active = i;
    cm.swapDoc(tabs[i].doc);
    render();
    cm.focus();
  }

  function newTab(name, content) {
    tabs.push({ name: name || nextName(), doc: CM.Doc(content || "", "tb32") });
    active = -1;
    select(tabs.length - 1);
  }

  function closeTab(i) {
    tabs.splice(i, 1);
    if (tabs.length === 0) {
      active = -1;
      newTab();
      return;
    }
    if (active >= tabs.length) active = tabs.length - 1;
    var target = active;
    active = -1;
    select(target);
  }

  function init() {
    cm = CM(document.getElementById("editor"), {
      mode: "tb32",
      theme: "tb32",
      lineNumbers: true,
      indentUnit: 4,
      tabSize: 4,
      indentWithTabs: false,
    });
    newTab("scratch.s", SAMPLE);
    setTimeout(function () { cm.refresh(); }, 0);
  }

  window.editor = {
    init: init,
    newTab: newTab,
    activeContent: function () { return active >= 0 ? tabs[active].doc.getValue() : ""; },
    activeName: function () { return active >= 0 ? tabs[active].name : ""; },
  };
})();
