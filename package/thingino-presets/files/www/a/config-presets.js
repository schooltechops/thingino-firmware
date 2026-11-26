(function () {
  const API = "/x/json-config-presets.cgi";
  const $ = (id) => document.getElementById(id);
  let selected = null;

  function esc(s) {
    const d = document.createElement("div");
    d.textContent = s == null ? "" : String(s);
    return d.innerHTML;
  }

  async function call(method, body) {
    const opts = { method, headers: { Accept: "application/json" } };
    if (body) {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(API, opts);
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data.error) throw new Error((data.error && data.error.message) || res.statusText);
    return data;
  }

  function render(data) {
    $("presets-status").textContent = data.status || "none";
    $("presets-undo").disabled = !data.undo;
    $("presets-list").innerHTML = (data.presets || []).map((p) => `
      <div class="col-12 col-md-6 col-xl-4">
        <div class="card h-100 ${p.active ? "border-success" : ""}">
          <div class="card-body">
            <h5 class="card-title">${esc(p.name)}
              ${p.active ? '<span class="badge text-bg-success ms-1">active</span>' : ""}
              <span class="badge text-bg-secondary ms-1">${p.source === "user" ? "user" : "built-in"}</span>
            </h5>
            <p class="small text-secondary">${esc(p.description)}</p>
            <button type="button" class="btn btn-outline-primary btn-sm" data-preset="${esc(p.id)}">
              <i class="bi bi-list-check"></i> Show changes
            </button>
          </div>
        </div>
      </div>`).join("");
    document.querySelectorAll("[data-preset]").forEach((b) =>
      b.addEventListener("click", () => showDiff(b.dataset.preset, b.closest(".card").querySelector(".card-title").firstChild.textContent.trim())));
  }

  async function load() {
    try {
      render(await call("GET"));
    } catch (e) {
      showAlert("danger", e.message || "Unable to load presets.");
    }
  }

  async function showDiff(id, name) {
    try {
      const d = await call("POST", { action: "diff", id });
      selected = { id, name, reboot: d.reboot, count: d.changes.length };
      $("presets-diff-title").textContent = `Changes for ${name}`;
      $("presets-diff-body").innerHTML = d.changes.length
        ? d.changes.map((c) => `<tr><td>${esc(c.file)}</td><td><code>${esc(c.key)}</code></td><td>${esc(c.current)}</td><td><strong>${esc(c.new)}</strong></td></tr>`).join("")
        : '<tr><td colspan="4" class="text-secondary">Nothing to change: the camera already has these settings.</td></tr>';
      $("presets-diff-reboot").classList.toggle("d-none", !d.reboot);
      $("presets-apply").disabled = false;
      $("presets-diff").classList.remove("d-none");
      $("presets-diff").scrollIntoView({ behavior: "smooth" });
    } catch (e) {
      showAlert("danger", e.message || "Unable to compare settings.");
    }
  }

  async function apply() {
    if (!selected) return;
    const ok = await showConfirmDialog({
      title: `Apply ${selected.name}?`,
      message: selected.reboot
        ? `${selected.count} setting(s) change and the camera reboots. You can undo this afterwards.`
        : `${selected.count} setting(s) change. You can undo this afterwards.`,
      confirmLabel: "Apply",
    });
    if (!ok) return;
    $("presets-apply").disabled = true;
    try {
      const r = await call("POST", { action: "apply", id: selected.id });
      if (r.reboot) {
        showAlert("info", "Applied. The camera is rebooting…", 0);
        setTimeout(() => (window.location.href = "/wait.html"), 1500);
      } else {
        showAlert("success", "Preset applied.");
        $("presets-diff").classList.add("d-none");
        load();
      }
    } catch (e) {
      showAlert("danger", e.message || "Apply failed.");
      $("presets-apply").disabled = false;
    }
  }

  async function undo() {
    const ok = await showConfirmDialog({ title: "Undo last apply?", message: "The settings saved before the last preset are restored.", confirmLabel: "Undo" });
    if (!ok) return;
    try {
      const r = await call("POST", { action: "undo" });
      if (r.reboot) {
        showAlert("info", "Restored. The camera is rebooting…", 0);
        setTimeout(() => (window.location.href = "/wait.html"), 1500);
      } else {
        showAlert("success", "Settings restored.");
        load();
      }
    } catch (e) {
      showAlert("danger", e.message || "Undo failed.");
    }
  }

  async function save() {
    const id = $("preset-save-id").value.trim();
    if (!/^[a-z0-9_-]+$/.test(id)) return showAlert("danger", "ID: lowercase letters, digits, - and _ only.");
    try {
      await call("POST", { action: "save", id, name: $("preset-save-name").value.trim() || id });
      showAlert("success", "Preset saved.");
      load();
    } catch (e) {
      showAlert("danger", e.message || "Save failed.");
    }
  }

  document.addEventListener("DOMContentLoaded", () => {
    $("presets-reload").addEventListener("click", load);
    $("presets-apply").addEventListener("click", apply);
    $("presets-diff-close").addEventListener("click", () => $("presets-diff").classList.add("d-none"));
    $("presets-undo").addEventListener("click", undo);
    $("preset-save").addEventListener("click", save);
    load();
  });
})();
