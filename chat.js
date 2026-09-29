(() => {
  const FUNCTION_URL = "https://lhfzvwlbnfvictowzvmp.supabase.co/functions/v1/mama-sto-chat";
  const MAMA_URL = "https://lhfzvwlbnfvictowzvmp.supabase.co";
  const MAMA_KEY = "sb_publishable_xnF9H_s77aMohEhxmBA_PQ_t8ggXhl0";
  const STO_URL = "https://lurjmjgtqogwlxkyauso.supabase.co";
  const STO_KEY = "sb_publishable_CwQfxteL0l2-xO7UiclS6g_kJ7IcBvk";
  const allowed = new Set(["gutfeeling3@gmail.com","komarov.aleksandr.1@gmail.com"]);
  const isMama = !!document.getElementById("app");
  const CHAT_TITLE = isMama ? "Чат с Admin" : "Чат с Mama";

  let client = null;
  let role = null;
  let timer = null;
  let opened = false;
  let lastSignature = "";

  function esc(v) {
    return String(v ?? "").replace(/[&<>"']/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));
  }

  function fmt(v) {
    try {
      return new Date(v).toLocaleString("ru-RU", {day:"2-digit",month:"2-digit",hour:"2-digit",minute:"2-digit"});
    } catch (_) { return ""; }
  }

  function css() {
    if (document.getElementById("mamaStoChatStyle")) return;
    const s = document.createElement("style");
    s.id = "mamaStoChatStyle";
    s.textContent = `
      #mamaStoChatButton{display:none;margin-top:8px;width:100%;min-height:54px;font-size:17px;font-weight:800}
      .mama-sto-chat-bg{position:fixed;inset:0;background:rgba(15,23,42,.55);display:none;align-items:center;justify-content:center;z-index:100000;padding:16px;box-sizing:border-box}
      .mama-sto-chat-bg.open{display:flex}
      .mama-sto-chat{width:min(620px,100%);max-height:min(760px,92vh);background:#fff;border-radius:18px;box-shadow:0 18px 50px rgba(0,0,0,.25);display:flex;flex-direction:column;overflow:hidden}
      .mama-sto-chat-head{display:flex;align-items:center;justify-content:space-between;padding:14px 16px;border-bottom:1px solid #e5e7eb;font-weight:900;font-size:18px}
      .mama-sto-chat-close{background:transparent!important;font-size:26px!important;padding:2px 8px!important}
      .mama-sto-chat-list{padding:14px;overflow:auto;display:flex;flex-direction:column;gap:9px;min-height:260px}
      .mama-sto-msg{max-width:82%;padding:9px 11px;border-radius:13px;background:#f1f5f9;align-self:flex-start;white-space:pre-wrap;overflow-wrap:anywhere}
      .mama-sto-msg.mine{align-self:flex-end;background:#dbeafe}
      .mama-sto-meta{font-size:11px;color:#64748b;margin-top:4px}
      .mama-sto-chat-form{display:flex;gap:8px;padding:12px;border-top:1px solid #e5e7eb}
      .mama-sto-chat-input{flex:1;min-height:44px;max-height:120px;resize:vertical;padding:9px 10px;border:1px solid #cbd5e1;border-radius:10px;box-sizing:border-box}
      .mama-sto-chat-status{font-size:12px;color:#64748b;padding:0 14px 8px;min-height:16px}
    `;
    document.head.appendChild(s);
  }

  function addButton() {
    if (document.getElementById("mamaStoChatButton")) return;
    let host = null;
    if (isMama) host = document.querySelector(".actions");
    else host = document.querySelector(".sanechka-main-buttons");
    if (!host) return;
    const b = document.createElement("button");
    b.id = "mamaStoChatButton";
    b.className = isMama ? "btn secondary" : "sanechka-main-button";
    b.textContent = "💬 " + CHAT_TITLE;
    if (!isMama) b.style.cssText = "min-height:80px;font-size:22px;font-weight:900;background:#374151;color:#fff;";
    b.type = "button";
    b.onclick = openChat;
    host.appendChild(b);
  }

  function addModal() {
    if (document.getElementById("mamaStoChatModal")) return;
    const bg = document.createElement("div");
    bg.id = "mamaStoChatModal";
    bg.className = "mama-sto-chat-bg";
    bg.innerHTML = `
      <div class="mama-sto-chat" role="dialog" aria-modal="true" aria-label="${esc(CHAT_TITLE)}">
        <div class="mama-sto-chat-head"><span>${esc(CHAT_TITLE)}</span><button class="mama-sto-chat-close" type="button">✕</button></div>
        <div id="mamaStoChatList" class="mama-sto-chat-list"></div>
        <div id="mamaStoChatStatus" class="mama-sto-chat-status"></div>
        <form id="mamaStoChatForm" class="mama-sto-chat-form">
          <textarea id="mamaStoChatInput" class="mama-sto-chat-input" maxlength="4000" placeholder="Сообщение..." required></textarea>
          <button class="btn primary" type="submit">📨</button>
        </form>
      </div>`;
    document.body.appendChild(bg);
    bg.querySelector(".mama-sto-chat-close").onclick = closeChat;
    bg.addEventListener("click", e => { if (e.target === bg) closeChat(); });
    bg.querySelector("#mamaStoChatForm").addEventListener("submit", async e => {
      e.preventDefault();
      const input = document.getElementById("mamaStoChatInput");
      const text = input.value.trim();
      if (!text) return;
      setStatus("Отправляем...");
      try {
        const token = await getToken();
        const r = await fetch(FUNCTION_URL, {method:"POST",headers:{"Content-Type":"application/json","Authorization":"Bearer "+token},body:JSON.stringify({body:text})});
        const data = await r.json().catch(()=>({}));
        if (!r.ok) throw new Error(data.error || "Не удалось отправить сообщение");
        input.value = "";
        await loadMessages();
        setStatus("");
      } catch (err) { setStatus(err.message || "Ошибка отправки"); }
    });
  }

  function setStatus(v) {
    const el = document.getElementById("mamaStoChatStatus");
    if (el) el.textContent = v || "";
  }

  async function getToken() {
    if (!client) {
      client = window.supabase.createClient(isMama ? MAMA_URL : STO_URL, isMama ? MAMA_KEY : STO_KEY);
    }
    const {data,error} = await client.auth.getSession();
    if (error || !data.session?.access_token) throw new Error("Сессия не найдена. Войдите в приложение.");
    return data.session.access_token;
  }

  async function refreshAccess() {
    try {
      const token = await getToken();
      const r = await fetch(FUNCTION_URL, {headers:{Authorization:"Bearer "+token}});
      const data = await r.json().catch(()=>({}));
      if (!r.ok) throw new Error(data.error || "Нет доступа");
      role = data.role;
      const b = document.getElementById("mamaStoChatButton");
      if (b) b.style.display = "block";
      return data.messages || [];
    } catch (_) {
      const b = document.getElementById("mamaStoChatButton");
      if (b) b.style.display = "none";
      return null;
    }
  }

  async function loadMessages() {
    const messages = await refreshAccess();
    if (!messages) return;
    const sig = messages.map(x => x.id + ":" + x.created_at).join("|");
    if (sig === lastSignature && !opened) return;
    lastSignature = sig;
    const list = document.getElementById("mamaStoChatList");
    if (!list) return;
    list.innerHTML = messages.length ? messages.map(m => `
      <div class="mama-sto-msg ${m.sender_role === role ? "mine" : ""}">
        <div>${esc(m.body)}</div>
        <div class="mama-sto-meta">${m.sender_role === role ? "Вы" : (isMama ? "Admin" : "Mama")} · ${esc(fmt(m.created_at))}</div>
      </div>`).join("") : '<div style="color:#64748b;text-align:center;padding:40px 10px;">Пока сообщений нет.</div>';
    list.scrollTop = list.scrollHeight;
  }

  async function openChat() {
    addModal();
    const bg = document.getElementById("mamaStoChatModal");
    bg.classList.add("open");
    opened = true;
    await loadMessages();
    document.getElementById("mamaStoChatInput")?.focus();
  }

  function closeChat() {
    const bg = document.getElementById("mamaStoChatModal");
    if (bg) bg.classList.remove("open");
    opened = false;
  }

  async function init() {
    if (!window.supabase) return;
    css();
    addButton();
    addModal();
    await loadMessages();
    if (timer) clearInterval(timer);
    timer = setInterval(() => loadMessages(), 1800);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") loadMessages();
    });
  }

  window.mamaStoChat = {open:openChat, close:closeChat, refresh:loadMessages};
  setInterval(() => { if (!document.getElementById("mamaStoChatButton")) addButton(); }, 1000);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init, {once:true});
  else init();
})();