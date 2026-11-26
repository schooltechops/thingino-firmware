(function () {
  const API = "/x/json-config-unifi.cgi";
  const $ = (id) => document.getElementById(id);
  let state = null;

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

  function render(d) {
    state = d;
    $("unifi-enabled").checked = !!d.enabled;
    $("unifi-status").textContent = d.status || "none";
    $("unifi-checks").innerHTML = (d.checks || []).map((c) => `
      <li class="list-group-item d-flex gap-2">
        <i class="bi ${c.ok ? "bi-check-circle-fill text-success" : "bi-exclamation-circle-fill text-warning"}"></i>
        <div>${esc(c.label)}${c.detail ? `<div class="small text-secondary">${esc(c.detail)}</div>` : ""}</div>
      </li>`).join("");
    const a = d.adopt || {};
    $("unifi-adopt").innerHTML = [
      ["Address", a.host], ["ONVIF port", a.onvif_port], ["Username", a.username],
      ["Main stream", a.rtsp_main], ["Sub stream", a.rtsp_sub],
    ].map(([k, v]) => `<tr><th class="fw-normal text-secondary">${k}</th><td><code>${esc(v)}</code></td></tr>`).join("");
  }

  async function load() {
    try {
      render(await call("GET"));
    } catch (e) {
      showAlert("danger", e.message || "Unable to load UniFi Protect settings.");
    }
  }

  async function toggle(ev) {
    const enable = ev.target.checked;
    const ok = await showConfirmDialog({
      title: enable ? "Turn on UniFi Protect mode?" : "Turn off UniFi Protect mode?",
      message: enable
        ? "The UniFi Protect preset is applied (see Settings > Presets for the exact changes). The camera reboots if streamer settings change."
        : "The settings from before UniFi Protect mode was turned on are restored. The camera may reboot.",
      confirmLabel: enable ? "Turn on" : "Turn off",
    });
    if (!ok) { ev.target.checked = !enable; return; }
    ev.target.disabled = true;
    try {
      const r = await call("POST", { enable });
      if (r.reboot) {
        showAlert("info", "Done. The camera is rebooting…", 0);
        setTimeout(() => (window.location.href = "/wait.html"), 1500);
        return;
      }
      showAlert("success", enable ? "UniFi Protect mode is on." : "UniFi Protect mode is off.");
      load();
    } catch (e) {
      ev.target.checked = !enable;
      showAlert("danger", e.message || "Change failed.");
    } finally {
      ev.target.disabled = false;
    }
  }

  document.addEventListener("DOMContentLoaded", () => {
    $("unifi-reload").addEventListener("click", load);
    $("unifi-enabled").addEventListener("change", toggle);
    load();
  });
})();
