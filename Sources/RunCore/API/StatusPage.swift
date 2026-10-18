/// GET /: what's on, every endpoint, and a place to try running a script or some Flow code
/// (each run still waits for Run on the Mac).
enum StatusPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Tool Mac Tool Run</title>
<style>
  :root { --bg:#f6f6f8; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --line:#e3e3e8; --accent:#3d7bf2; --ok:#2f9e5b; --off:#c4473a; --term:#13151a; --termtext:#e0e0e0; --termerr:#ff7a75; }
  @media (prefers-color-scheme: dark) { :root { --bg:#151517; --card:#1f1f22; --text:#f2f2f4; --muted:#9a9aa1; --line:#2e2e33; --accent:#6b9bff; --ok:#4cc27c; --off:#e8705f; } }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
  main { max-width: 820px; margin: 0 auto; padding: 32px 16px 64px; }
  h1 { font-size: 26px; margin: 0 0 4px; letter-spacing: -0.01em; }
  h2 { font-size: 15px; margin: 0 0 12px; }
  p.sub { color: var(--muted); margin: 0 0 24px; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 18px; margin-bottom: 16px; }
  .pills { display: flex; flex-wrap: wrap; gap: 8px; }
  .pill { border: 1px solid var(--line); border-radius: 999px; padding: 3px 10px; font-size: 13px; }
  .on { color: var(--ok); } .off { color: var(--off); }
  table { width: 100%; border-collapse: collapse; font-size: 14px; }
  td { padding: 6px 4px; border-top: 1px solid var(--line); vertical-align: top; }
  td:first-child { white-space: nowrap; }
  textarea, input[type=text], select { width: 100%; border: 1px solid var(--line); border-radius: 10px; padding: 8px 10px; background: transparent; color: inherit; font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
  textarea { min-height: 120px; resize: vertical; }
  button { border: 0; border-radius: 10px; padding: 8px 16px; background: var(--accent); color: #fff; font: inherit; font-weight: 600; cursor: pointer; }
  button.quiet { background: transparent; color: var(--accent); border: 1px solid var(--line); }
  button:disabled { opacity: .5; cursor: default; }
  .row { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-top: 10px; }
  .row > select, .row > input { flex: 1; min-width: 160px; }
  pre { white-space: pre-wrap; word-break: break-word; background: var(--term); color: var(--termtext); border-radius: 10px; padding: 12px; margin: 10px 0 0; min-height: 2.5em; max-height: 420px; overflow: auto; font: 12.5px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
  pre .err { color: var(--termerr); }
  .state { font-weight: 600; margin-top: 10px; }
  code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
  a { color: var(--accent); }
</style>
</head>
<body>
<main>
  <h1>Tool Mac Tool Run</h1>
  <p class="sub">Your scripts and flows, for other apps: <code id="base"></code> · <a href="/api/health">/api/health</a>. Nothing runs until you click <b>Run</b> on the Mac.</p>

  <section class="card"><h2>Status</h2><div class="pills" id="status">Checking…</div></section>

  <section class="card">
    <h2>Run a script</h2>
    <div class="row"><select id="script"></select><input type="text" id="args" placeholder="arguments, as in a terminal"></div>
    <div class="row"><button id="run">Run</button><span id="runnote" class="sub"></span></div>
    <div class="state" id="runstate" hidden></div>
    <pre id="runout" hidden></pre>
  </section>

  <section class="card">
    <h2>Run Flow code</h2>
    <textarea id="code">// A flow, sent from another app. Check it, then Run it.
print "Hello from the API"
let files = sh "ls | wc -l"
print $"There are {trim files} things in the scripts folder."</textarea>
    <div class="row"><button class="quiet" id="check">Check</button><button id="compose">Run</button></div>
    <div class="state" id="flowstate" hidden></div>
    <pre id="flowout" hidden></pre>
  </section>

  <section class="card">
    <h2>Endpoints</h2>
    <table id="routes"></table>
    <p class="sub" style="margin:12px 0 0">The whole contract: API.md in the repository.</p>
  </section>
</main>
<script>
const $ = id => document.getElementById(id);
$("base").textContent = location.origin;
const routes = [
  ["GET /api/health", "whether it's up, which endpoints are on, the folder"],
  ["GET /api/scripts", "the scripts in the folder: name, language, description"],
  ["GET /api/flows", "the flows in the folder's composer folder"],
  ["POST /api/run", "{\"script\", \"args\", \"stdin\", \"client\"}: runs it once it's allowed on the Mac, and answers with how it went and what it printed (\"stream\": true sends it as it goes; \"wait\": false answers at once)"],
  ["POST /api/compose", "{\"flow\"} or {\"source\"}: runs a flow, or Flow code, the same way"],
  ["POST /api/check", "{\"source\"}: checks Flow code (its types, or its mistake); nothing runs"],
  ["GET /api/runs", "the latest runs"],
  ["GET /api/runs/{id}", "one run, with its output"],
  ["POST /api/runs/{id}/stop", "stops it"],
];
$("routes").innerHTML = routes.map(([r, d]) => `<tr><td><code>${r}</code></td><td>${d.replace(/</g, "&lt;")}</td></tr>`).join("");

async function status() {
  try {
    const h = await (await fetch("/api/health")).json();
    const pill = (name, on) => `<span class="pill">${name} <b class="${on ? "on" : "off"}">${on ? "on" : "off"}</b></span>`;
    $("status").innerHTML = [pill("run", h.run), pill("compose", h.compose), pill("catalog", h.catalog), pill("runs", h.runs),
      `<span class="pill">${h.folder ? `${h.scripts} scripts, ${h.flows} flows` : "no folder chosen yet"}</span>`,
      `<span class="pill">v${h.version}</span>`].join("");
  } catch (e) { $("status").textContent = "Not reachable: " + e; }
  try {
    const r = await fetch("/api/scripts");
    const j = await r.json();
    if (!r.ok) { $("runnote").textContent = j.error; $("run").disabled = true; return; }
    $("script").innerHTML = j.scripts.map(s => `<option value="${s.name}">${s.name}${s.summary ? " — " + s.summary.replace(/</g, "&lt;") : ""}</option>`).join("");
    if (!j.scripts.length) { $("runnote").textContent = "The folder has no scripts yet."; $("run").disabled = true; }
  } catch (e) {}
}

// Streams a run: waiting for Run on the Mac, then its output as it's printed.
async function stream(path, body, stateEl, outEl, button) {
  button.disabled = true;
  stateEl.hidden = false; outEl.hidden = false; outEl.innerHTML = "";
  stateEl.textContent = "Sending…";
  const add = (text, err) => { const s = document.createElement("span"); if (err) s.className = "err"; s.textContent = text; outEl.appendChild(s); outEl.scrollTop = outEl.scrollHeight; };
  try {
    const r = await fetch(path, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({...body, stream: true, client: "the API's page"})});
    if (!r.ok) { const j = await r.json(); stateEl.textContent = "❌ " + j.error; outEl.textContent = j.fix ? "→ fix: " + j.fix : ""; return; }
    const reader = r.body.getReader(), dec = new TextDecoder();
    let buf = "";
    for (;;) {
      const {value, done} = await reader.read();
      if (done) break;
      buf += dec.decode(value, {stream: true});
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        if (!line.trim()) continue;
        const ev = JSON.parse(line);
        if (ev.type === "waiting") stateEl.textContent = "✋ " + ev.message + "…";
        else if (ev.type === "denied") stateEl.textContent = "🚫 " + ev.message;
        else if (ev.type === "started") stateEl.textContent = "👉 Running " + ev.name + "…";
        else if (ev.type === "output") add(ev.text, ev.stream === "err");
        else if (ev.type === "error") stateEl.textContent = "❌ " + ev.message;
        else if (ev.type === "done") {
          const mark = {succeeded: "✅", failed: "❌", stopped: "⏹", could_not_start: "⚠️"}[ev.state] || "";
          stateEl.textContent = `${mark} ${ev.name}: ${ev.state.replace(/_/g, " ")}` + (ev.seconds !== undefined ? ` in ${ev.seconds} s` : "") + (ev.code ? ` (exit code ${ev.code})` : "");
          if (ev.problem) add("\n" + ev.problem + "\n", true);
          if (!outEl.textContent) outEl.textContent = "(It printed nothing.)";
        }
      }
    }
  } catch (e) { stateEl.textContent = "❌ " + e; }
  finally { button.disabled = false; }
}

$("run").onclick = () => stream("/api/run", {script: $("script").value, args: $("args").value}, $("runstate"), $("runout"), $("run"));
$("compose").onclick = () => stream("/api/compose", {source: $("code").value, name: "Flow from the API's page"}, $("flowstate"), $("flowout"), $("compose"));
$("check").onclick = async () => {
  $("flowstate").hidden = false; $("flowout").hidden = false;
  try {
    const j = await (await fetch("/api/check", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({source: $("code").value})})).json();
    if (j.ok) { $("flowstate").textContent = "✅ It checks out."; $("flowout").textContent = j.bindings.map(b => `${b.name} : ${b.type}`).join("\n") || "(It defines nothing at its top level.)"; }
    else { $("flowstate").textContent = "❌ " + (j.message || j.error); $("flowout").textContent = j.error; }
  } catch (e) { $("flowstate").textContent = "❌ " + e; }
};
status();
</script>
</body>
</html>
"""#
}
