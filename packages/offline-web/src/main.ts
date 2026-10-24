import "./styles.css";
import {
  init,
  buildVerifyQr,
  OpticalSender,
  OpticalReceiver,
  clientVersion,
  protocolVersion,
  versionLabel,
} from "@offline/core";
import { MeshSession } from "./session";
import {
  loadOrCreateIdentity,
  regenerateIdentity,
  saveNickname,
  getStoredSecrets,
} from "./identity";
import { qrDataUrl, qrDataUrlFromBytes, decodeQrFromImageData } from "./qr";
import {
  blobUrl,
  formatVoiceTime,
  recordVoiceWav,
  VOICE_BARS,
} from "./media";
import { isLinuxDesktop } from "./transport";

type Tab = "mesh" | "optical" | "identity";
type ThemeId = "white" | "dark" | "crazy";

const THEME_KEY = "offline-web-theme";
const THEMES: ThemeId[] = ["white", "dark", "crazy"];

const app = document.querySelector<HTMLDivElement>("#app")!;
const session = new MeshSession();

let tab: Tab = "mesh";
let theme: ThemeId = loadTheme();
let dmMode = false;
/** Connection panel wait: going online or picking a Bluetooth mesh peer. */
let connWait: null | "online" | "phone" = null;
/** Expand “How it works” helper in the mesh sidebar. */
let helpOpen = false;
let bootError: string | null = null;

const BITCHAT_IOS =
  "https://apps.apple.com/us/app/bitchat-mesh/id6748219622";
const BITCHAT_ANDROID =
  "https://play.google.com/store/apps/details?id=com.bitchat.droid";
const BITCHAT_SITE = "https://bitchat.free";
const BITCHAT_GITHUB = "https://github.com/permissionlesstech/bitchat";
let identityReady = false;
let verifyQrUrl = "";
let verifyQrDataUrl = "";
let shareQrDataUrl = "";
let qrMode: "bitchat" | "offline" = "bitchat";
let emojiOpen = false;
let voiceStop: (() => Promise<Uint8Array | null>) | null = null;
let voiceElapsed = 0;
let voiceLevels: number[] = [];
let activeVoice: HTMLAudioElement | null = null;
const mediaUrlCache = new Map<string, string>();

function cachedBlobUrl(id: string, bytes: Uint8Array, mime: string): string {
  const hit = mediaUrlCache.get(id);
  if (hit) return hit;
  const url = blobUrl(bytes, mime);
  mediaUrlCache.set(id, url);
  return url;
}
let opticalMode: "hub" | "send" | "receive" = "hub";
let opticalStatus = "";
let opticalQrUrl = "";
let opticalTimer: ReturnType<typeof setInterval> | null = null;
let shellBooted = false;
let renderQueued = false;
let lastMsgTail = "";
let pendingScroll: "preserve" | "bottom" | "auto" = "auto";
let appVersionLabel = "…";
let appClientVersion = "";
let appProtocolVersion = "";

const EMOJI = ["😀", "😂", "❤️", "🔥", "👍", "🎉", "🙏", "✨", "💯", "😎", "🤝", "📡"];

function loadTheme(): ThemeId {
  try {
    const raw = localStorage.getItem(THEME_KEY);
    if (raw === "white" || raw === "dark" || raw === "crazy") return raw;
  } catch {
    /* private mode */
  }
  return "dark";
}

function applyTheme(next: ThemeId): void {
  theme = next;
  document.documentElement.dataset.theme = next;
  try {
    localStorage.setItem(THEME_KEY, next);
  } catch {
    /* ignore */
  }
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) {
    const bg =
      getComputedStyle(document.documentElement)
        .getPropertyValue("--theme-meta")
        .trim() || "#050506";
    meta.setAttribute("content", bg);
  }
}

applyTheme(theme);

async function boot(): Promise<void> {
  try {
    await init();
    appClientVersion = clientVersion();
    appProtocolVersion = protocolVersion();
    appVersionLabel = versionLabel();
    const { identity, nickname } = await loadOrCreateIdentity();
    await session.start(identity, nickname);
    identityReady = true;
    await refreshIdentityQrs();
  } catch (e) {
    bootError = String(e);
  }
  render();
}

async function refreshIdentityQrs(): Promise<void> {
  const secrets = await getStoredSecrets();
  if (!secrets) return;
  const snap = session.snapshot();
  const nick = snap.nickname || secrets.nickname;
  verifyQrUrl = buildVerifyQr(
    secrets.noiseSecret,
    secrets.signingSecret,
    nick,
    Date.now() / 1000,
  );
  verifyQrDataUrl = await qrDataUrl(verifyQrUrl);
  const share = `offline:noise:${[...session.getIdentity()?.noisePublicKey ?? []]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")}`;
  shareQrDataUrl = await qrDataUrl(share);
}

function scheduleRender(scroll: "preserve" | "bottom" | "auto" = "auto"): void {
  if (scroll === "bottom" || (scroll === "auto" && pendingScroll !== "bottom")) {
    pendingScroll = scroll;
  } else if (scroll === "preserve" && pendingScroll === "auto") {
    pendingScroll = "preserve";
  }
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(() => {
    renderQueued = false;
    render();
  });
}

function render(): void {
  if (bootError) {
    app.innerHTML = `<div class="shell"><div class="empty"><h1>Failed to start</h1><p>${esc(bootError)}</p></div></div>`;
    return;
  }

  const prevMsg = document.getElementById("messages");
  const prevScrollTop = prevMsg?.scrollTop ?? 0;
  const prevScrollMax = prevMsg
    ? prevMsg.scrollHeight - prevMsg.clientHeight
    : 0;
  const wasNearBottom = !prevMsg || prevScrollMax - prevScrollTop < 48;
  const scrollMode = pendingScroll;
  pendingScroll = "auto";

  const snap = session.snapshot();
  const solo = tab !== "mesh" ? "solo" : "";
  const statusShort = snap.running
    ? `${snap.status.replace(/^online — /i, "").replace(/^LIVE — /, "")}`
    : snap.status;
  const msgTail = snap.messages.length
    ? snap.messages[snap.messages.length - 1]!.id
    : "";
  const newTail = msgTail !== lastMsgTail;
  lastMsgTail = msgTail;

  const bootClass = shellBooted ? "" : "boot";
  app.innerHTML = `
    <div class="shell ${bootClass}">
      <header class="topbar">
        <div class="brand" aria-label="Offline">
          <div class="brand-mark">O</div>
          <div class="brand-text">
            <span class="brand-name">Offline</span>
            <span class="brand-sub" title="${escAttr(appVersionLabel)}">v${esc(appClientVersion || "…")} · ${esc(appProtocolVersion || "…")}</span>
          </div>
        </div>
        <nav class="tabs" aria-label="Sections">
          <button type="button" data-tab="mesh" class="${tab === "mesh" ? "active" : ""}">Mesh</button>
          <button type="button" data-tab="optical" class="${tab === "optical" ? "active" : ""}">Optical</button>
          <button type="button" data-tab="identity" class="${tab === "identity" ? "active" : ""}">Identity</button>
        </nav>
        <div class="status-pill ${snap.running ? "live" : ""}" title="${escAttr(snap.status)}">
          <span class="status-dot" aria-hidden="true"></span>
          ${snap.running ? "LIVE" : "IDLE"}
          · L${snap.linkCount}
          · P${snap.peers.length}
          · ${esc(statusShort)}
        </div>
        <div class="theme-switch" role="group" aria-label="Theme">
          ${THEMES.map(
            (t) =>
              `<button type="button" data-theme-set="${t}" class="${theme === t ? "active" : ""}" title="${t}">${t}</button>`,
          ).join("")}
        </div>
      </header>
      <div class="page ${solo}">${tab === "mesh" ? meshHtml(snap, newTail) : tab === "optical" ? opticalHtml() : identityHtml(snap)}</div>
    </div>
  `;
  shellBooted = true;
  wireCommon();
  if (tab === "mesh") {
    wireMesh(snap);
    wireVoicePlayers();
    const msg = document.getElementById("messages");
    if (msg) {
      if (scrollMode === "bottom" || (scrollMode === "auto" && (newTail || wasNearBottom))) {
        msg.scrollTop = msg.scrollHeight;
      } else {
        msg.scrollTop = prevScrollTop;
      }
    }
  }
  if (tab === "optical") wireOptical();
  if (tab === "identity") wireIdentity();
}

function connWaitHtml(): string {
  if (!connWait) return "";
  const copy =
    connWait === "online"
      ? "Starting mesh… hang on a moment."
      : "Waiting for Bluetooth… pick Offline / BitChat in the system dialog.";
  return `<p class="conn-wait" role="status" aria-live="polite"><span class="conn-wait-dot" aria-hidden="true"></span>${esc(copy)}</p>`;
}

function connectionStepsHtml(
  snap: ReturnType<MeshSession["snapshot"]>,
  linked: boolean,
): string {
  const busy = !!connWait;
  const wait = connWaitHtml();

  if (!snap.running) {
    const step1 =
      connWait === "online"
        ? `<li class="active waiting"><span class="n">…</span><div><strong>Going online</strong><p>Preparing this tab on the mesh.</p></div></li>`
        : `<li class="active"><span class="n">1</span><div><strong>Go online</strong><p>Enable this tab on the mesh.</p></div></li>`;
    return `
      <ol class="conn-steps">
        ${step1}
        <li><span class="n">2</span><div><strong>Connect to the mesh</strong><p>Use this desktop’s Bluetooth to reach Offline / BitChat.</p></div></li>
      </ol>
      ${wait}
      <div class="actions">
        <button type="button" class="primary" id="toggle-mesh" ${busy ? "disabled" : ""}>${
          connWait === "online" ? "Starting…" : "Go online"
        }</button>
      </div>`;
  }

  if (!snap.supportsBle) {
    return `
      <ol class="conn-steps">
        <li class="done"><span class="n">✓</span><div><strong>Online</strong><p>This tab is on the mesh.</p></div></li>
        <li class="warn"><span class="n">!</span><div><strong>No Bluetooth</strong><p>Use Chrome/Edge, or open a second tab.</p></div></li>
      </ol>
      ${wait}
      <div class="actions">
        <button type="button" id="toggle-mesh" ${busy ? "disabled" : ""}>Go offline</button>
      </div>`;
  }

  if (linked) {
    const meshStep =
      connWait === "phone"
        ? `<li class="active waiting"><span class="n">…</span><div><strong>Connecting to the mesh</strong><p>Choose a peer in the Bluetooth picker.</p></div></li>`
        : `<li class="done"><span class="n">✓</span><div><strong>On the mesh</strong><p>${esc(snap.bleDevices.join(", "))}</p></div></li>`;
    return `
      <ol class="conn-steps">
        <li class="done"><span class="n">✓</span><div><strong>Online</strong><p>This tab is on the mesh.</p></div></li>
        ${meshStep}
      </ol>
      ${wait}
      <div class="actions">
        <button type="button" id="join-ble" ${busy ? "disabled" : ""}>${
          connWait === "phone" ? "Waiting…" : "Connect another peer"
        }</button>
        <button type="button" class="ghost" id="join-all" ${busy ? "disabled" : ""}>Browse all devices</button>
        <button type="button" class="ghost" id="toggle-mesh" ${busy ? "disabled" : ""}>Go offline</button>
      </div>`;
  }

  const meshStep =
    connWait === "phone"
      ? `<li class="active waiting"><span class="n">…</span><div><strong>Connecting to the mesh</strong><p>Choose Offline / BitChat in the Bluetooth picker.</p></div></li>`
      : `<li class="active"><span class="n">2</span><div><strong>Connect to the mesh</strong><p>${
          isLinuxDesktop()
            ? "Linux Chrome: enable Experimental Web Platform features, then pick a nearby peer."
            : "Required to chat with Offline / BitChat nearby."
        }</p></div></li>`;

  const linuxTip = isLinuxDesktop()
    ? `<p class="conn-linux-tip" role="note">Chrome on Linux needs <code>chrome://flags/#enable-experimental-web-platform-features</code> set to <strong>Enabled</strong>, then Relaunch. Bluetooth must be on (BlueZ 5.41+). BitChat is often unnamed in the picker.</p>`
    : "";

  return `
    <ol class="conn-steps">
      <li class="done"><span class="n">✓</span><div><strong>Online</strong><p>This tab is on the mesh.</p></div></li>
      ${meshStep}
    </ol>
    ${wait}
    ${linuxTip}
    <div class="actions">
      <button type="button" class="primary" id="join-ble" ${busy ? "disabled" : ""}>${
        connWait === "phone" ? "Waiting…" : "Connect to mesh"
      }</button>
      <button type="button" class="ghost" id="join-all" ${busy ? "disabled" : ""}>Browse all devices</button>
      <button type="button" class="ghost" id="toggle-mesh" ${busy ? "disabled" : ""}>Go offline</button>
    </div>`;
}

function meshHtml(snap: ReturnType<MeshSession["snapshot"]>, animateTail: boolean): string {
  const selected = snap.selectedPeerId
    ? snap.peers.find((p) => p.peerId === snap.selectedPeerId)
    : null;
  const showPrivate = dmMode && !!selected;
  const peerLabel = selected
    ? selected.nickname || selected.peerId.slice(0, 8)
    : "";
  const lines = snap.messages.filter((m) => {
    if (showPrivate) {
      // Peer-scoped private thread only (no global system noise).
      if (m.kind === "system") return false;
      if (!(m.kind === "dm" || (m.kind === "file" && !!m.isPrivate))) return false;
      const peer = snap.selectedPeerId!;
      if (m.mine) return m.withPeer === peer;
      return m.from === peer;
    }
    if (m.kind === "system") return true;
    return m.kind === "message" || (m.kind === "file" && !m.isPrivate);
  });
  const tailId = lines.length ? lines[lines.length - 1]!.id : "";

  const firstUnreadIdx = lines.findIndex(
    (m) => m.kind !== "system" && !m.mine && !m.readByUs,
  );

  const bubbles = lines
    .map((m, idx) => {
      const divider =
        idx === firstUnreadIdx
          ? `<div class="read-divider" role="separator"><span>Last read</span></div>`
          : "";
      if (m.kind === "system") {
        const fresh = animateTail && m.id === tailId ? " fresh" : "";
        return `${divider}<div class="bubble system${fresh}">${esc(m.text)}</div>`;
      }
      const who =
        m.mine
          ? "you"
          : snap.peers.find((p) => p.peerId === m.from)?.nickname || m.from.slice(0, 8);
      const fresh = animateTail && m.id === tailId ? "fresh" : "";
      const isDm = m.kind === "dm" || !!m.isPrivate;
      const isVoice = !!(m.kind === "file" && m.mime?.startsWith("audio/"));
      const cls = [
        "bubble",
        m.mine ? "mine" : "",
        isDm ? "dm" : "",
        !m.mine && !m.readByUs ? "unread-msg" : "",
        isVoice && !m.mine && !m.listenedByUs ? "unheard" : "",
        fresh,
      ]
        .filter(Boolean)
        .join(" ");
      let body = esc(m.text);
      if (m.kind === "file" && m.fileBytes && m.mime?.startsWith("image/")) {
        const url = cachedBlobUrl(m.id, m.fileBytes, m.mime);
        body = imageBubbleHtml(url, m.fileName || "photo", m);
      } else if (m.kind === "file" && m.fileBytes && m.mime?.startsWith("audio/")) {
        body = voicePlayerHtml(m);
      }
      const time = formatChatTime(m.at);
      const receipt =
        m.mine &&
        (isDm || m.kind === "file") &&
        (m.kind === "dm" || m.messageId || m.deliveryStatus === "sending")
          ? receiptHtml(m.deliveryStatus || "sent", m.sendProgress)
          : "";
      const listenHint =
        isVoice && !m.mine
          ? m.listenedByUs
            ? `<span class="listen-dot heard" title="Listened"></span>`
            : `<span class="listen-dot" title="Not listened yet"></span>`
          : "";
      const sig =
        m.kind === "message" && m.signed
          ? `<span class="sig ${m.signed === "signed" ? "" : "unsigned"}">${esc(m.signed)}</span>`
          : "";
      return `${divider}<div class="${cls}" data-msg-id="${escAttr(m.id)}">
        <div class="meta">
          <span class="meta-who">${esc(who)}</span>
          ${sig}
        </div>
        <div class="bubble-body">${body}</div>
        <div class="bubble-foot">
          ${listenHint}
          <time datetime="${new Date(m.at).toISOString()}">${esc(time)}</time>
          ${receipt}
        </div>
      </div>`;
    })
    .join("");

  const peerRows = [...snap.peers]
    .sort((a, b) => {
      const rank = (p: typeof a) =>
        p.peerId === snap.selectedPeerId ? 0 : p.noiseState === "ready" ? 1 : 2;
      return rank(a) - rank(b) || a.nickname.localeCompare(b.nickname);
    })
    .map((p) => {
      const active = snap.selectedPeerId === p.peerId;
      const label = p.nickname || p.peerId.slice(0, 8);
      const initial = (label.trim()[0] || "?").toUpperCase();
      const unread = session.unreadCount(p.peerId);
      return `<li class="${active ? "selected" : ""}">
        <div class="peer-head">
          <div class="avatar" style="background:${peerHue(p.peerId)}">${esc(initial)}</div>
          <div style="min-width:0">
            <div class="name">${esc(label)}${p.verified ? '<span class="badge ok">verified</span>' : ""}${
              unread > 0 ? `<span class="badge unread">${unread}</span>` : ""
            }</div>
            <div class="sub">${esc(p.peerId.slice(0, 8))} · ${esc(noiseLabel(p.noiseState))}</div>
          </div>
        </div>
        <div class="row">
          <button type="button" data-select="${escAttr(p.peerId)}">${active && showPrivate ? "In DM" : "Open DM"}</button>
          <button type="button" data-noise="${escAttr(p.peerId)}" ${p.noiseState === "ready" ? "disabled" : ""}>Noise</button>
          <button type="button" data-verify="${escAttr(p.peerId)}" ${!p.hasNoiseKey || p.verified ? "disabled" : ""}>Verify</button>
        </div>
      </li>`;
    })
    .join("");

  const linked = snap.bleDevices.length > 0;
  const emptyCopy = !snap.running
    ? "Go online first, then connect to the mesh over Bluetooth."
    : linked
      ? "Waiting for peers — messages appear here."
      : snap.supportsBle
        ? "Online locally. Connect to the mesh to chat with Offline / BitChat."
        : "Open this page in a second tab to chat (no Bluetooth in this browser).";

  const emptyTitle = !snap.running
    ? "You’re offline"
    : showPrivate
      ? `No messages with ${peerLabel} yet`
      : linked
        ? "Quiet on the mesh"
        : "Connect to the mesh";
  const emptyPrivateCopy = selected
    ? selected.noiseState === "ready"
      ? `Encrypted DM with ${peerLabel}. Messages stay between you two.`
      : `Start Noise with ${peerLabel} before private messages will deliver.`
    : emptyCopy;

  const scopeBanner = showPrivate
    ? `<div class="chat-scope private" role="status">
         <span class="scope-kicker">Direct message</span>
         <strong class="scope-title">${esc(peerLabel)}</strong>
         <span class="scope-sub">${esc(selected!.peerId.slice(0, 12))}… · ${esc(noiseLabel(selected!.noiseState))}</span>
       </div>`
    : `<div class="chat-scope general" role="status">
         <span class="scope-kicker">Channel</span>
         <strong class="scope-title">General</strong>
         <span class="scope-sub">${
           session.unreadPublicCount() > 0
             ? `${session.unreadPublicCount()} new below last read`
             : "Everyone on the mesh"
         }</span>
       </div>`;

  return `
    <main class="chat ${showPrivate ? "chat-dm" : "chat-general"}">
      ${scopeBanner}
      <div class="messages" id="messages">${
        bubbles ||
        `<div class="empty"><h1>${esc(emptyTitle)}</h1><p>${esc(showPrivate ? emptyPrivateCopy : emptyCopy)}</p></div>`
      }</div>
      <form class="composer ${showPrivate ? "composer-dm" : "composer-general"}" id="composer">
        <div class="composer-row">
          <div class="seg" role="group" aria-label="Channel">
            <button type="button" id="mode-pub" class="${!showPrivate ? "active" : ""}">General</button>
            <button type="button" id="mode-dm" class="${showPrivate ? "active" : ""}" ${selected ? "" : "disabled"} title="${selected ? escAttr(peerLabel) : "Select a peer"}">${
              selected ? esc(peerLabel.length > 10 ? peerLabel.slice(0, 10) + "…" : peerLabel) : "DM"
            }</button>
          </div>
          <span class="hint">${
            showPrivate
              ? `Private with <strong>${esc(peerLabel)}</strong>`
              : session.unreadPublicCount() > 0
                ? `General · <strong>${session.unreadPublicCount()} new</strong>`
                : "General mesh chat"
          }</span>
          ${
            voiceStop
              ? `<span class="rec">${(voiceElapsed / 1000).toFixed(1)}s</span>
                 <div class="rec-meter" aria-hidden="true">${recMeterHtml(voiceLevels)}</div>`
              : ""
          }
        </div>
        <div class="composer-row tools">
          <button type="button" class="ghost" id="emoji-btn" title="Emoji">☺</button>
          <label class="file-btn" title="Send photo">Photo<input id="photo" type="file" accept="image/*" hidden /></label>
          <button type="button" class="ghost ${voiceStop ? "rec-active" : ""}" id="voice-btn">${voiceStop ? "Stop" : "Voice"}</button>
        </div>
        ${
          emojiOpen
            ? `<div class="emoji-row">${EMOJI.map((e) => `<button type="button" class="emoji" data-emoji="${e}">${e}</button>`).join("")}</div>`
            : ""
        }
        <input id="text" type="text" maxlength="2000" placeholder="${showPrivate ? `Message ${peerLabel}…` : "Message everyone…"}" autocomplete="off" ${snap.running ? "" : "disabled"} />
        <button class="primary" type="submit" ${snap.running ? "" : "disabled"}>Send</button>
      </form>
    </main>
    <aside class="sidebar">
      <div class="panel">
        <h2>Connection</h2>
        ${connectionStepsHtml(snap, linked)}
        <div class="nick-row" style="margin-top:0.85rem">
          <input id="nick" type="text" maxlength="32" value="${escAttr(snap.nickname)}" aria-label="Nickname" />
          <button type="button" id="save-nick">Save</button>
        </div>
        <div class="peer-id">${esc(snap.peerId)}</div>
      </div>
      ${howItWorksHtml()}
      <div class="panel">
        <h2>Peers · ${snap.peers.length}</h2>
        <ul class="peer-list">${peerRows || `<li><div class="sub">Waiting for announces…</div></li>`}</ul>
      </div>
    </aside>
  `;
}

function howItWorksHtml(): string {
  return `
    <div class="panel help-panel">
      <button type="button" class="help-toggle" id="help-toggle" aria-expanded="${helpOpen}">
        <span>How it works</span>
        <span class="help-chevron" aria-hidden="true">${helpOpen ? "▴" : "▾"}</span>
      </button>
      ${
        helpOpen
          ? `<div class="help-body">
        <ol class="help-steps">
          <li><strong>Go online</strong> — this tab joins the local mesh as a peer (no account).</li>
          <li><strong>Connect to the mesh</strong> — use this computer’s Bluetooth to link a nearby phone running Offline or BitChat.</li>
          <li><strong>General</strong> — public messages flood the mesh; anyone in range can read them.</li>
          <li><strong>DM</strong> — pick a peer, start Noise if needed, then chat end-to-end. Delivery/read receipts follow BitChat’s Noise protocol.</li>
          <li><strong>Photos &amp; voice</strong> — private media is encrypted over Noise and split into BLE fragments; watch the block-reveal while sending.</li>
          <li><strong>Verify</strong> — Identity tab shows a BitChat verify QR once you’re visible on their mesh.</li>
        </ol>
        <p class="help-note">Offline speaks the same Bluetooth mesh wire format as BitChat. No internet is required for mesh chat. Linux Chrome needs Experimental Web Platform features for Web Bluetooth.</p>
        <div class="store-links" aria-label="Get BitChat">
          <span class="store-label">Official BitChat apps</span>
          <a class="store-btn ios" href="${BITCHAT_IOS}" target="_blank" rel="noopener noreferrer">iPhone · App Store</a>
          <a class="store-btn android" href="${BITCHAT_ANDROID}" target="_blank" rel="noopener noreferrer">Android · Google Play</a>
          <a class="store-btn ghost" href="${BITCHAT_SITE}" target="_blank" rel="noopener noreferrer">bitchat.free</a>
          <a class="store-btn ghost" href="${BITCHAT_GITHUB}" target="_blank" rel="noopener noreferrer">Source on GitHub</a>
        </div>
      </div>`
          : `<p class="help-teaser">Mesh chat with Offline / BitChat over Bluetooth — no internet, no accounts. <button type="button" class="linkish" id="help-open">Show guide</button></p>
        <div class="store-links compact" aria-label="Get BitChat">
          <a class="store-btn ios" href="${BITCHAT_IOS}" target="_blank" rel="noopener noreferrer">iOS</a>
          <a class="store-btn android" href="${BITCHAT_ANDROID}" target="_blank" rel="noopener noreferrer">Android</a>
        </div>`
      }
    </div>`;
}

function opticalHtml(): string {
  if (opticalMode === "send") {
    return `<div class="optical">
      <button type="button" class="ghost" id="opt-back">← Back</button>
      <h1>Send by light</h1>
      <p class="hint">${esc(opticalStatus || "Pick a file — frames stream as a QR fountain.")}</p>
      <label class="file-btn primary-label">Choose file<input id="opt-file" type="file" hidden /></label>
      ${opticalQrUrl ? `<div><img class="opt-qr" src="${opticalQrUrl}" alt="optical frame" /></div>` : ""}
    </div>`;
  }
  if (opticalMode === "receive") {
    return `<div class="optical">
      <button type="button" class="ghost" id="opt-back">← Back</button>
      <h1>Receive by light</h1>
      <p class="hint">${esc(opticalStatus || "Point the camera at the sender’s QR stream.")}</p>
      <video id="opt-video" playsinline autoplay muted></video>
      <canvas id="opt-canvas" class="hidden"></canvas>
      <button type="button" class="ghost" id="opt-stop-cam">Stop camera</button>
    </div>`;
  }
  return `<div class="optical hub">
    <h1>Optical transfer</h1>
    <p class="hint">Move a file with only a screen and a camera — no radio required.</p>
    <div class="hub-actions">
      <button type="button" class="primary" id="opt-send">Send</button>
      <button type="button" id="opt-recv">Receive</button>
    </div>
  </div>`;
}

function identityHtml(snap: ReturnType<MeshSession["snapshot"]>): string {
  const id = session.getIdentity();
  const noise = id ? hex(id.noisePublicKey) : "";
  const sign = id ? hex(id.signingPublicKey) : "";
  const qr = qrMode === "bitchat" ? verifyQrDataUrl : shareQrDataUrl;
  const caption =
    qrMode === "bitchat"
      ? "BitChat verify QR — signed, refresh every few minutes"
      : "Offline share — noise public key as URI";
  return `<div class="identity">
    <h1>Identity</h1>
    <p class="peer-id">${esc(snap.peerId)}</p>
    <div class="seg" role="group" aria-label="QR mode">
      <button type="button" id="qr-bitchat" class="${qrMode === "bitchat" ? "active" : ""}">BitChat</button>
      <button type="button" id="qr-offline" class="${qrMode === "offline" ? "active" : ""}">Offline</button>
    </div>
    <p class="hint">${esc(caption)}</p>
    ${qr ? `<img class="id-qr" src="${qr}" alt="identity qr" />` : "<p class='hint'>Loading QR…</p>"}
    <div class="id-actions">
      <button type="button" id="copy-peer">Copy peer ID</button>
      <button type="button" id="copy-noise">Noise pub</button>
      <button type="button" id="copy-sign">Signing pub</button>
      <button type="button" class="ghost" id="refresh-qr">Refresh</button>
      <button type="button" class="danger" id="regen">New identity…</button>
    </div>
    <pre class="mono-block"><strong>Noise</strong>\n${esc(noise)}\n\n<strong>Signing</strong>\n${esc(sign)}</pre>
    <p class="hint">Keys are stored in IndexedDB for this origin. See docs/CLIENT_FEATURES.md.</p>
    <p class="version-foot" title="${escAttr(appVersionLabel)}">
      Client <strong>${esc(appClientVersion || "…")}</strong>
      · Protocol <strong>${esc(appProtocolVersion || "…")}</strong>
    </p>
  </div>`;
}

function wireCommon(): void {
  app.querySelectorAll<HTMLButtonElement>("[data-tab]").forEach((btn) => {
    btn.addEventListener("click", () => {
      tab = btn.dataset.tab as Tab;
      stopOptical();
      scheduleRender("auto");
    });
  });
  app.querySelectorAll<HTMLButtonElement>("[data-theme-set]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const next = btn.dataset.themeSet as ThemeId;
      if (!THEMES.includes(next) || next === theme) return;
      applyTheme(next);
      scheduleRender("preserve");
    });
  });
}

function wireMesh(snap: ReturnType<MeshSession["snapshot"]>): void {
  document.getElementById("toggle-mesh")?.addEventListener("click", () => {
    void (async () => {
      if (snap.running) {
        connWait = null;
        await session.stop();
      } else {
        connWait = "online";
        scheduleRender("preserve");
        try {
          const { identity, nickname } = await loadOrCreateIdentity(snap.nickname);
          await session.start(identity, nickname);
        } finally {
          connWait = null;
        }
      }
      scheduleRender("bottom");
    })();
  });

  document.getElementById("join-ble")?.addEventListener("click", () => {
    connWait = "phone";
    scheduleRender("preserve");
    void session
      .joinPhone(false)
      .finally(() => {
        connWait = null;
        scheduleRender("preserve");
      });
  });
  document.getElementById("join-all")?.addEventListener("click", () => {
    connWait = "phone";
    scheduleRender("preserve");
    void session
      .joinPhone(true)
      .finally(() => {
        connWait = null;
        scheduleRender("preserve");
      });
  });

  document.getElementById("save-nick")?.addEventListener("click", () => {
    const nick = (document.getElementById("nick") as HTMLInputElement).value;
    session.setNickname(nick);
    void saveNickname(session.snapshot().nickname);
    void refreshIdentityQrs().then(() => scheduleRender("preserve"));
  });

  const openHelp = () => {
    helpOpen = true;
    scheduleRender("preserve");
  };
  document.getElementById("help-toggle")?.addEventListener("click", () => {
    helpOpen = !helpOpen;
    scheduleRender("preserve");
  });
  document.getElementById("help-open")?.addEventListener("click", openHelp);

  document.getElementById("mode-pub")?.addEventListener("click", () => {
    if (!dmMode) return;
    dmMode = false;
    session.setPrivateView(null);
    scheduleRender("preserve");
    // Mark public as read shortly after opening so the "Last read" line is visible first.
    window.setTimeout(() => {
      if (!dmMode) session.markPublicMessagesRead();
    }, 1200);
  });
  document.getElementById("mode-dm")?.addEventListener("click", () => {
    const peer = session.snapshot().selectedPeerId;
    if (!peer || dmMode) return;
    dmMode = true;
    session.setPrivateView(peer);
    session.markPeerMessagesRead(peer);
    scheduleRender("preserve");
  });

  const msgBox = document.getElementById("messages");
  msgBox?.addEventListener(
    "scroll",
    () => {
      const el = msgBox;
      if (el.scrollHeight - el.scrollTop - el.clientHeight < 64) {
        if (dmMode) {
          const peer = session.snapshot().selectedPeerId;
          if (peer) session.markPeerMessagesRead(peer);
        } else {
          session.markPublicMessagesRead();
        }
      }
    },
    { passive: true },
  );

  document.getElementById("composer")?.addEventListener("submit", (e) => {
    e.preventDefault();
    const input = document.getElementById("text") as HTMLInputElement;
    const text = input.value;
    if (!text.trim()) return;
    const s = session.snapshot();
    if (dmMode && s.selectedPeerId) session.sendPrivate(s.selectedPeerId, text);
    else session.sendPublic(text);
    input.value = "";
    scheduleRender("bottom");
  });

  document.getElementById("emoji-btn")?.addEventListener("click", () => {
    emojiOpen = !emojiOpen;
    scheduleRender("preserve");
  });
  app.querySelectorAll<HTMLButtonElement>("[data-emoji]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const input = document.getElementById("text") as HTMLInputElement;
      input.value += btn.dataset.emoji || "";
      input.focus();
    });
  });

  document.getElementById("photo")?.addEventListener("change", (e) => {
    const file = (e.target as HTMLInputElement).files?.[0];
    if (!file) return;
    const s = session.snapshot();
    const to = dmMode ? s.selectedPeerId : null;
    void session.sendPhoto(file, to).finally(() => scheduleRender("bottom"));
  });

  document.getElementById("voice-btn")?.addEventListener("click", () => {
    void (async () => {
      if (voiceStop) {
        const wav = await voiceStop();
        voiceStop = null;
        voiceElapsed = 0;
        voiceLevels = [];
        if (wav) {
          const s = session.snapshot();
          await session.sendVoice(wav, dmMode ? s.selectedPeerId : null);
        }
        scheduleRender("bottom");
        return;
      }
      voiceLevels = Array.from({ length: VOICE_BARS }, () => 0.08);
      const rec = await recordVoiceWav(10_000, {
        onTick: (ms) => {
          voiceElapsed = ms;
          const el = document.querySelector(".rec");
          if (el) el.textContent = `${(ms / 1000).toFixed(1)}s`;
        },
        onLevel: (level) => {
          voiceLevels = [...voiceLevels.slice(1), Math.max(0.08, level)];
          const meter = document.querySelector(".rec-meter");
          if (meter) meter.innerHTML = recMeterHtml(voiceLevels);
        },
      });
      voiceStop = rec.stop;
      scheduleRender("preserve");
    })().catch((err) => {
      voiceStop = null;
      voiceLevels = [];
      alert(String(err));
      scheduleRender("preserve");
    });
  });

  app.querySelectorAll<HTMLButtonElement>("[data-select]").forEach((btn) => {
    btn.addEventListener("click", () => {
      dmMode = true;
      const peerId = btn.dataset.select || null;
      session.selectPeer(peerId);
      session.setPrivateView(peerId);
      if (peerId) session.markPeerMessagesRead(peerId);
      // selectPeer emits → subscribe schedules render; keep scroll stable
      pendingScroll = "preserve";
    });
  });
  app.querySelectorAll<HTMLButtonElement>("[data-noise]").forEach((btn) => {
    btn.addEventListener("click", () => {
      if (btn.dataset.noise) session.startNoise(btn.dataset.noise);
      scheduleRender("preserve");
    });
  });
  app.querySelectorAll<HTMLButtonElement>("[data-verify]").forEach((btn) => {
    btn.addEventListener("click", () => {
      if (btn.dataset.verify) session.startQrVerification(btn.dataset.verify);
      scheduleRender("preserve");
    });
  });
}

function wireOptical(): void {
  document.getElementById("opt-back")?.addEventListener("click", () => {
    stopOptical();
    opticalMode = "hub";
    scheduleRender("auto");
  });
  document.getElementById("opt-send")?.addEventListener("click", () => {
    opticalMode = "send";
    opticalStatus = "";
    scheduleRender("auto");
  });
  document.getElementById("opt-recv")?.addEventListener("click", () => {
    opticalMode = "receive";
    opticalStatus = "";
    scheduleRender("auto");
    void startOpticalReceive();
  });
  document.getElementById("opt-file")?.addEventListener("change", (e) => {
    const file = (e.target as HTMLInputElement).files?.[0];
    if (file) void startOpticalSend(file);
  });
  document.getElementById("opt-stop-cam")?.addEventListener("click", () => {
    stopOptical();
    opticalStatus = "Camera stopped";
    scheduleRender("auto");
  });
}

async function startOpticalSend(file: File): Promise<void> {
  stopOptical();
  const bytes = new Uint8Array(await file.arrayBuffer());
  const sender = new OpticalSender(bytes, 200);
  opticalStatus = `Sending ${file.name} (${bytes.length} bytes)`;
  let i = 0;
  opticalTimer = setInterval(() => {
    void (async () => {
      const frame = sender.nextFrame();
      opticalQrUrl = await qrDataUrlFromBytes(frame);
      i += 1;
      opticalStatus = `Frame ${i} · ${file.name}`;
      const img = document.querySelector<HTMLImageElement>(".opt-qr");
      if (img) img.src = opticalQrUrl;
      else scheduleRender("auto");
    })();
  }, 80);
  scheduleRender("auto");
}

async function startOpticalReceive(): Promise<void> {
  stopOptical();
  const video = document.getElementById("opt-video") as HTMLVideoElement | null;
  const canvas = document.getElementById("opt-canvas") as HTMLCanvasElement | null;
  if (!video || !canvas) return;
  const stream = await navigator.mediaDevices.getUserMedia({
    video: { facingMode: "environment" },
    audio: false,
  });
  video.srcObject = stream;
  const rx = new OpticalReceiver();
  const seen = new Set<string>();
  opticalTimer = setInterval(() => {
    if (video.readyState < 2) return;
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.drawImage(video, 0, 0);
    const image = ctx.getImageData(0, 0, canvas.width, canvas.height);
    const decoded = decodeQrFromImageData(image);
    if (!decoded || typeof decoded === "string") return;
    const key = `${decoded.length}:${decoded[0]}:${decoded[decoded.length - 1]}`;
    if (seen.has(key)) return;
    seen.add(key);
    try {
      const progress = rx.ingestFrame(decoded);
      opticalStatus = `Frames ${progress.framesCollected}/${progress.framesTarget || "?"}`;
      if (progress.completePayload) {
        const blob = new Blob([progress.completePayload.slice()]);
        const a = document.createElement("a");
        a.href = URL.createObjectURL(blob);
        a.download = `optical-${Date.now()}.bin`;
        a.click();
        opticalStatus = `Complete — ${progress.completePayload.length} bytes downloaded`;
        stopOptical();
      }
      const hint = document.querySelector(".optical .hint");
      if (hint) hint.textContent = opticalStatus;
    } catch {
      /* ignore non-optical codes */
    }
  }, 120);
}

function stopOptical(): void {
  if (opticalTimer) clearInterval(opticalTimer);
  opticalTimer = null;
  opticalQrUrl = "";
  const video = document.getElementById("opt-video") as HTMLVideoElement | null;
  const stream = video?.srcObject as MediaStream | null;
  stream?.getTracks().forEach((t) => t.stop());
  if (video) video.srcObject = null;
}

function wireIdentity(): void {
  document.getElementById("qr-bitchat")?.addEventListener("click", () => {
    qrMode = "bitchat";
    scheduleRender("preserve");
  });
  document.getElementById("qr-offline")?.addEventListener("click", () => {
    qrMode = "offline";
    scheduleRender("preserve");
  });
  document.getElementById("refresh-qr")?.addEventListener("click", () => {
    void refreshIdentityQrs().then(() => scheduleRender("preserve"));
  });
  document.getElementById("copy-peer")?.addEventListener("click", () => {
    void navigator.clipboard.writeText(session.snapshot().peerId);
  });
  document.getElementById("copy-noise")?.addEventListener("click", () => {
    const id = session.getIdentity();
    if (id) void navigator.clipboard.writeText(hex(id.noisePublicKey));
  });
  document.getElementById("copy-sign")?.addEventListener("click", () => {
    const id = session.getIdentity();
    if (id) void navigator.clipboard.writeText(hex(id.signingPublicKey));
  });
  document.getElementById("regen")?.addEventListener("click", () => {
    if (!confirm("Generate a new identity? Your peer ID will change.")) return;
    void (async () => {
      await session.stop();
      await init();
      const { identity, nickname } = await regenerateIdentity();
      await session.start(identity, nickname);
      await refreshIdentityQrs();
      scheduleRender("auto");
    })();
  });
}

function voicePlayerHtml(m: {
  id: string;
  mime?: string;
  fileBytes?: Uint8Array;
  peaks?: number[];
  durationMs?: number;
  mine: boolean;
  listenedByUs?: boolean;
}): string {
  const url = cachedBlobUrl(m.id, m.fileBytes!, m.mime || "audio/wav");
  const peaks = m.peaks?.length
    ? m.peaks
    : Array.from({ length: VOICE_BARS }, () => 0.2);
  const dur = m.durationMs ?? 0;
  const heard = m.mine || !!m.listenedByUs;
  return `<div class="voice-player ${m.mine ? "mine" : ""} ${heard ? "heard" : "unheard"}" data-voice-id="${escAttr(m.id)}" data-src="${escAttr(url)}" data-duration="${dur}">
    <button type="button" class="voice-play" aria-label="Play voice note">
      <svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true"><path fill="currentColor" d="M8 5v14l11-7z"/></svg>
    </button>
    ${waveSvgHtml(peaks, m.id)}
    <span class="voice-time">${esc(formatVoiceTime(dur))}</span>
  </div>`;
}

function waveSvgHtml(peaks: number[], uid: string): string {
  const W = 168;
  const H = 40;
  const mid = H / 2;
  const n = peaks.length;
  const gap = 1.25;
  const barW = Math.max(1.6, (W - gap * (n - 1)) / n);
  const gid = `wg-${uid.replace(/[^a-zA-Z0-9_-]/g, "")}`;
  const cid = `wc-${uid.replace(/[^a-zA-Z0-9_-]/g, "")}`;
  const rects = peaks
    .map((h, i) => {
      const amp = 0.12 + h * 0.88;
      const bh = Math.max(3, amp * (H - 6));
      const x = i * (barW + gap);
      const y = mid - bh / 2;
      const rx = Math.min(2, barW / 2);
      return `<rect x="${x.toFixed(2)}" y="${y.toFixed(2)}" width="${barW.toFixed(2)}" height="${bh.toFixed(2)}" rx="${rx.toFixed(2)}" />`;
    })
    .join("");
  return `<div class="voice-wave" role="img" aria-label="Waveform">
    <svg class="voice-wave-svg" viewBox="0 0 ${W} ${H}" width="100%" height="${H}" preserveAspectRatio="none">
      <defs>
        <linearGradient id="${gid}" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stop-color="#d4a35c"/>
          <stop offset="55%" stop-color="#c4893a"/>
          <stop offset="100%" stop-color="#e8c27a"/>
        </linearGradient>
        <clipPath id="${cid}"><rect class="wave-clip" x="0" y="0" width="0" height="${H}"/></clipPath>
      </defs>
      <g class="wave-idle">${rects}</g>
      <g class="wave-played" clip-path="url(#${cid})" fill="url(#${gid})">${rects}</g>
    </svg>
  </div>`;
}

function recMeterHtml(levels: number[]): string {
  return waveSvgHtml(
    levels.length ? levels : Array.from({ length: VOICE_BARS }, () => 0.08),
    "rec",
  );
}

function wireVoicePlayers(): void {
  app.querySelectorAll<HTMLElement>(".voice-player").forEach((root) => {
    const btn = root.querySelector<HTMLButtonElement>(".voice-play");
    const timeEl = root.querySelector<HTMLElement>(".voice-time");
    const src = root.dataset.src;
    if (!btn || !src) return;

    const setPlayingUi = (playing: boolean) => {
      root.classList.toggle("playing", playing);
      btn.innerHTML = playing
        ? `<svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true"><path fill="currentColor" d="M6 5h4v14H6zm8 0h4v14h-4z"/></svg>`
        : `<svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true"><path fill="currentColor" d="M8 5v14l11-7z"/></svg>`;
      btn.setAttribute("aria-label", playing ? "Pause voice note" : "Play voice note");
    };

    const paintProgress = (ratio: number) => {
      const clip = root.querySelector<SVGRectElement>(".wave-clip");
      const svg = root.querySelector<SVGSVGElement>(".voice-wave-svg");
      if (clip && svg) {
        const w = svg.viewBox.baseVal.width || 168;
        clip.setAttribute("width", String(Math.max(0, Math.min(1, ratio)) * w));
      }
      root.style.setProperty("--play-p", `${Math.max(0, Math.min(1, ratio)) * 100}%`);
    };

    // Re-bind progress to surviving Audio element after DOM rebuild
    if (activeVoice && activeVoice.dataset.voiceId === root.dataset.voiceId) {
      const audio = activeVoice;
      const fallbackDur = Number(root.dataset.duration || 0) / 1000;
      const sync = () => {
        const dur = audio.duration && Number.isFinite(audio.duration) ? audio.duration : fallbackDur;
        const ratio = dur > 0 ? audio.currentTime / dur : 0;
        paintProgress(ratio);
        if (timeEl) {
          timeEl.textContent = formatVoiceTime(Math.max(0, (dur - audio.currentTime) * 1000) || dur * 1000);
        }
        setPlayingUi(!audio.paused && !audio.ended);
      };
      audio.ontimeupdate = sync;
      audio.onended = () => {
        setPlayingUi(false);
        paintProgress(0);
        if (timeEl) timeEl.textContent = formatVoiceTime(fallbackDur * 1000);
        if (activeVoice === audio) activeVoice = null;
      };
      sync();
    }

    const markListened = () => {
      const id = root.dataset.voiceId;
      if (id) session.markVoiceListened(id);
      root.classList.add("heard");
      root.classList.remove("unheard");
    };

    btn.addEventListener("click", () => {
      if (activeVoice && activeVoice.dataset.voiceId === root.dataset.voiceId) {
        if (!activeVoice.paused) {
          activeVoice.pause();
          setPlayingUi(false);
          return;
        }
        void activeVoice.play().then(() => {
          markListened();
          setPlayingUi(true);
        });
        return;
      }

      if (activeVoice) {
        activeVoice.pause();
        activeVoice.ontimeupdate = null;
        document
          .querySelectorAll(".voice-player.playing")
          .forEach((el) => el.classList.remove("playing"));
      }

      const audio = new Audio(src);
      audio.dataset.voiceId = root.dataset.voiceId || "";
      activeVoice = audio;
      const fallbackDur = Number(root.dataset.duration || 0) / 1000;

      audio.ontimeupdate = () => {
        const dur = audio.duration && Number.isFinite(audio.duration) ? audio.duration : fallbackDur;
        const ratio = dur > 0 ? audio.currentTime / dur : 0;
        paintProgress(ratio);
        if (timeEl) {
          timeEl.textContent = formatVoiceTime(Math.max(0, (dur - audio.currentTime) * 1000) || dur * 1000);
        }
      };
      audio.onended = () => {
        setPlayingUi(false);
        paintProgress(1);
        window.setTimeout(() => paintProgress(0), 400);
        if (timeEl) timeEl.textContent = formatVoiceTime(fallbackDur * 1000);
        if (activeVoice === audio) activeVoice = null;
      };

      void audio.play().then(() => {
        markListened();
        setPlayingUi(true);
      }).catch(() => setPlayingUi(false));
    });

    root.querySelector(".voice-wave")?.addEventListener("click", (ev) => {
      const wave = ev.currentTarget as HTMLElement;
      const rect = wave.getBoundingClientRect();
      const ratio = Math.min(1, Math.max(0, ((ev as MouseEvent).clientX - rect.left) / rect.width));
      paintProgress(ratio);
      if (activeVoice && activeVoice.dataset.voiceId === root.dataset.voiceId) {
        const dur =
          activeVoice.duration && Number.isFinite(activeVoice.duration)
            ? activeVoice.duration
            : Number(root.dataset.duration || 0) / 1000;
        if (dur > 0) activeVoice.currentTime = ratio * dur;
      }
    });
  });
}

function formatChatTime(ms: number): string {
  if (!ms) return "";
  const d = new Date(ms);
  const now = new Date();
  const hh = d.getHours().toString().padStart(2, "0");
  const mm = d.getMinutes().toString().padStart(2, "0");
  const sameDay =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate();
  if (sameDay) return `${hh}:${mm}`;
  const mon = d.toLocaleString(undefined, { month: "short" });
  return `${mon} ${d.getDate()} ${hh}:${mm}`;
}

function receiptHtml(status?: string, sendProgress?: number): string {
  if (status === "sending") {
    const pct = Math.round(Math.max(0, Math.min(1, sendProgress ?? 0)) * 100);
    return `<span class="receipt-ico sending" title="Sending ${pct}%">${pct}%</span>`;
  }
  if (status === "read") {
    return `<span class="receipt-ico read" title="Read">✓✓</span>`;
  }
  if (status === "delivered") {
    return `<span class="receipt-ico delivered" title="Delivered">✓✓</span>`;
  }
  if (!status || status === "sent") {
    return `<span class="receipt-ico sent" title="Sent">✓</span>`;
  }
  return `<span class="receipt-ico" title="${escAttr(status)}">✓</span>`;
}

/** BitChat-style left-to-right / top-to-bottom block reveal while sending. */
function imageBubbleHtml(
  url: string,
  alt: string,
  m: { mine?: boolean; deliveryStatus?: string; sendProgress?: number },
): string {
  const sending =
    !!m.mine &&
    (m.deliveryStatus === "sending" ||
      (typeof m.sendProgress === "number" && m.sendProgress < 1));
  const fraction = sending
    ? Math.max(0.02, Math.min(1, m.sendProgress ?? 0))
    : 1;
  const mask = sending ? blockRevealMaskUrl(fraction) : "";
  const pct = Math.round(fraction * 100);
  const style = mask
    ? `style="-webkit-mask-image:${mask};mask-image:${mask};-webkit-mask-size:100% 100%;mask-size:100% 100%;-webkit-mask-repeat:no-repeat;mask-repeat:no-repeat"`
    : "";
  return `<div class="chat-img-wrap${sending ? " sending" : ""}">
    <img class="chat-img" src="${url}" alt="${escAttr(alt)}" ${style} />
    ${
      sending
        ? `<span class="img-send-pct" aria-live="polite">${pct}%</span>`
        : ""
    }
  </div>`;
}

function blockRevealMaskUrl(fraction: number, cols = 24, rows = 16): string {
  const total = cols * rows;
  const revealCount = Math.max(
    0,
    Math.min(total, Math.ceil(fraction * total)),
  );
  let rects = "";
  let remaining = revealCount;
  for (let row = 0; row < rows && remaining > 0; row++) {
    for (let col = 0; col < cols && remaining > 0; col++) {
      rects += `<rect x="${col}" y="${row}" width="1" height="1"/>`;
      remaining -= 1;
    }
  }
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${cols} ${rows}" ` +
    `preserveAspectRatio="none"><g fill="#fff">${rects}</g></svg>`;
  return `url("data:image/svg+xml,${encodeURIComponent(svg)}")`;
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function esc(s: string): string {
  return s.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}
function escAttr(s: string): string {
  return esc(s).replaceAll("'", "&#39;");
}
/** Stable peer color (avoid reserved self orange ~35°). */
function peerHue(peerId: string): string {
  let h = 0;
  for (let i = 0; i < peerId.length; i++) h = (h * 33 + peerId.charCodeAt(i)) >>> 0;
  const hue = 50 + (h % 280);
  return `hsl(${hue} 42% 58%)`;
}
function noiseLabel(state: string): string {
  switch (state) {
    case "ready":
      return "secure";
    case "handshaking":
      return "handshaking";
    case "failed":
      return "failed";
    default:
      return "open";
  }
}

session.subscribe(() => {
  if (identityReady) scheduleRender("auto");
});
setInterval(() => {
  if (tab === "identity" && qrMode === "bitchat") {
    void refreshIdentityQrs().then(() => scheduleRender("preserve"));
  }
}, 120_000);

void boot();
window.addEventListener("beforeunload", () => {
  stopOptical();
  void session.stop();
});
