const out = document.getElementById("out");

document.getElementById("ping").addEventListener("click", async () => {
  out.textContent = await window.ping();
});
