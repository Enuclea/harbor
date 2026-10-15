// Harbor browser dashboard. Plain ES2020; no inline scripts so the strict CSP holds.
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const state = {
    sessions: [],
    hosts: [],
    current: null,
    socket: null,
    reconnectDelay: 500,
    allowInput: true,
    allowOpening: true,
    pollTimer: null,
  };

  const theme = {
    background: "#0e1117", foreground: "#d7dce5", cursor: "#7aa2f7", cursorAccent: "#0e1117",
    selectionBackground: "#2a3550",
    black: "#1b1f2a", red: "#f2777a", green: "#8bd49c", yellow: "#f1c27d",
    blue: "#7aa2f7", magenta: "#c397f2", cyan: "#6fd3e3", white: "#c8cfda",
    brightBlack: "#4b5468", brightRed: "#ff8e8e", brightGreen: "#a6e3b0", brightYellow: "#ffd59a",
    brightBlue: "#9db8ff", brightMagenta: "#d6b4ff", brightCyan: "#93e4f0", brightWhite: "#f4f6fa",
  };

  const term = new Terminal({
    fontFamily: '"SF Mono", ui-monospace, Menlo, "JetBrains Mono", monospace',
    fontSize: 13,
    lineHeight: 1.15,
    cursorBlink: true,
    allowProposedApi: false,
    scrollback: 10000,
    theme,
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);

  // ---- HTTP helpers ------------------------------------------------------

  async function api(path, options = {}) {
    const response = await fetch(path, {
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      ...options,
    });
    if (response.status === 401) {
      showLogin();
      throw new Error("Signed out");
    }
    if (!response.ok) {
      let message = `Request failed (${response.status})`;
      try { message = (await response.json()).error || message; } catch (_) { /* not JSON */ }
      throw new Error(message);
    }
    return response.status === 204 ? null : response.json();
  }

  // ---- Sign in -----------------------------------------------------------

  function showLogin(message = "") {
    stopPolling();
    disconnect();
    $("app").hidden = true;
    $("login").hidden = false;
    $("login-error").textContent = message;
    $("token").focus();
  }

  async function signIn(token) {
    const response = await fetch("/api/login", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ token }),
    });
    if (response.status === 204) return true;
    let message = "Sign in failed.";
    try { message = (await response.json()).error || message; } catch (_) { /* ignore */ }
    showLogin(message);
    return false;
  }

  $("login-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (await signIn($("token").value.trim())) {
      $("token").value = "";
      start();
    }
  });

  $("sign-out").addEventListener("click", async () => {
    try { await api("/api/logout", { method: "POST" }); } catch (_) { /* already gone */ }
    showLogin();
  });

  // ---- Lists -------------------------------------------------------------

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function renderTabs() {
    const list = $("tab-list");
    list.replaceChildren();
    if (state.sessions.length === 0) {
      list.append(element("li", "muted item-sub", "No open tabs"));
    }
    for (const session of state.sessions) {
      const item = element("li");
      const button = element("button");
      button.setAttribute("aria-current", String(session.id === state.current));
      const kind = element("span", `kind ${session.kind}`, session.kind === "ssh" ? "ssh" : "›_");
      const label = element("span");
      label.append(element("span", "item-title", session.title));
      const detail = session.runningCommand || session.host || session.workingDirectory || session.state;
      label.append(element("span", session.runningCommand ? "item-sub command" : "item-sub", detail));
      const dot = element("span", `dot ${session.activity || session.state}`);
      dot.title = session.activity || session.state;
      button.append(kind, label, dot);
      button.addEventListener("click", () => select(session.id));
      item.append(button);
      list.append(item);
    }
    updateToolbar();
  }

  function renderHosts() {
    const filter = $("host-filter").value.trim().toLowerCase();
    const list = $("host-list");
    list.replaceChildren();
    const hosts = state.hosts.filter((host) =>
      !filter || `${host.name} ${host.destination} ${host.tags.join(" ")}`.toLowerCase().includes(filter));
    if (hosts.length === 0) {
      list.append(element("li", "muted item-sub", state.hosts.length ? "No matches" : "No saved hosts"));
    }
    for (const host of hosts) {
      const item = element("li");
      const button = element("button");
      button.disabled = !state.allowOpening;
      const label = element("span");
      label.append(element("span", "item-title", host.name));
      label.append(element("span", "item-sub", host.destination));
      button.append(element("span", "kind ssh", host.isFavorite ? "★" : "ssh"), label, element("span", "muted", "Connect"));
      button.addEventListener("click", () => openSession({ type: "host", host: host.id }));
      item.append(button);
      list.append(item);
    }
  }

  $("host-filter").addEventListener("input", renderHosts);

  function updateToolbar() {
    const session = state.sessions.find((s) => s.id === state.current);
    $("tab-title").textContent = session ? session.title : "No tab selected";
    $("tab-subtitle").textContent = session
      ? [session.host, session.workingDirectory, `${session.columns}×${session.rows}`].filter(Boolean).join(" · ")
      : "";
    $("focus-on-mac").disabled = !session;
    $("close-tab").disabled = !session;
    $("empty").hidden = Boolean(session);
  }

  async function refresh() {
    try {
      const [sessions, hosts] = await Promise.all([api("/api/sessions"), api("/api/hosts")]);
      state.sessions = sessions;
      state.hosts = hosts;
      setOnline(true);
      if (state.current && !sessions.some((s) => s.id === state.current)) {
        state.current = null;
        disconnect();
        term.reset();
      }
      renderTabs();
      renderHosts();
    } catch (error) {
      if (error.message !== "Signed out") setOnline(false);
    }
  }

  function setOnline(online) {
    const node = $("connection");
    node.classList.toggle("online", online);
    node.textContent = online ? "Connected" : "Reconnecting…";
  }

  function startPolling() {
    stopPolling();
    state.pollTimer = setInterval(refresh, 3000);
  }

  function stopPolling() {
    if (state.pollTimer) clearInterval(state.pollTimer);
    state.pollTimer = null;
  }

  // ---- Terminal stream ---------------------------------------------------

  function select(id) {
    if (state.current === id && state.socket) return;
    state.current = id;
    $("sidebar").classList.remove("open");
    renderTabs();
    connect();
  }

  function disconnect() {
    if (state.socket) {
      state.socket.onclose = null;
      state.socket.close();
    }
    state.socket = null;
  }

  function connect() {
    disconnect();
    if (!state.current) return;
    term.reset();
    const scheme = location.protocol === "https:" ? "wss" : "ws";
    const socket = new WebSocket(`${scheme}://${location.host}/ws/sessions/${encodeURIComponent(state.current)}`);
    socket.binaryType = "arraybuffer";
    state.socket = socket;

    socket.onopen = () => {
      state.reconnectDelay = 500;
      hideBanner();
      sendResize();
      term.focus();
    };
    socket.onmessage = (event) => {
      if (event.data instanceof ArrayBuffer) {
        term.write(new Uint8Array(event.data));
        return;
      }
      try {
        const message = JSON.parse(event.data);
        if (message.type === "closed" || message.type === "error") showBanner(message.message);
      } catch (_) { /* ignore malformed events */ }
    };
    socket.onclose = () => {
      if (state.socket !== socket) return;
      state.socket = null;
      showBanner("Disconnected — reconnecting…");
      setTimeout(() => { if (state.current && !state.socket) connect(); }, state.reconnectDelay);
      state.reconnectDelay = Math.min(state.reconnectDelay * 2, 8000);
    };
  }

  term.onData((data) => {
    if (!state.allowInput || !state.socket || state.socket.readyState !== WebSocket.OPEN) return;
    state.socket.send(JSON.stringify({ type: "input", data }));
  });

  function sendResize() {
    fit.fit();
    if (state.socket && state.socket.readyState === WebSocket.OPEN && state.allowInput) {
      state.socket.send(JSON.stringify({ type: "resize", cols: term.cols, rows: term.rows }));
    }
  }

  let resizeTimer = null;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(sendResize, 120);
  });

  function showBanner(text) {
    const banner = $("banner");
    banner.textContent = text;
    banner.hidden = false;
  }

  function hideBanner() {
    $("banner").hidden = true;
  }

  // ---- Actions -----------------------------------------------------------

  async function openSession(body) {
    try {
      const session = await api("/api/sessions", { method: "POST", body: JSON.stringify(body) });
      await refresh();
      select(session.id);
    } catch (error) {
      showBanner(error.message);
    }
  }

  $("new-tab").addEventListener("click", () => openSession({ type: "local" }));

  $("focus-on-mac").addEventListener("click", async () => {
    if (!state.current) return;
    try { await api(`/api/sessions/${encodeURIComponent(state.current)}/focus`, { method: "POST" }); }
    catch (error) { showBanner(error.message); }
  });

  $("close-tab").addEventListener("click", async () => {
    if (!state.current || !confirm("Close this tab? Its process will end.")) return;
    try {
      await api(`/api/sessions/${encodeURIComponent(state.current)}`, { method: "DELETE" });
      state.current = null;
      disconnect();
      term.reset();
      await refresh();
    } catch (error) {
      showBanner(error.message);
    }
  });

  $("toggle-sidebar").addEventListener("click", () => $("sidebar").classList.toggle("open"));

  // ---- Boot --------------------------------------------------------------

  async function start() {
    $("login").hidden = true;
    $("app").hidden = false;
    term.open($("terminal"));
    fit.fit();
    const status = await (await fetch("/api/status", { credentials: "same-origin" })).json();
    state.allowInput = status.allowInput;
    state.allowOpening = status.allowOpeningSessions;
    $("readonly-badge").hidden = status.allowInput;
    $("new-tab").disabled = !status.allowOpeningSessions;
    term.options.disableStdin = !status.allowInput;
    await refresh();
    startPolling();
    const focused = state.sessions.find((s) => s.isFocused) || state.sessions[0];
    if (focused) select(focused.id);
  }

  async function boot() {
    // A pairing link carries the token in the fragment, which never reaches the server.
    const fragment = new URLSearchParams(location.hash.slice(1));
    const token = fragment.get("token");
    if (token) {
      history.replaceState(null, "", location.pathname);
      if (await signIn(token)) return start();
      return;
    }
    const status = await (await fetch("/api/status", { credentials: "same-origin" })).json();
    if (status.authenticated) start(); else showLogin();
  }

  boot().catch(() => showLogin("Harbor isn't reachable right now."));
})();
