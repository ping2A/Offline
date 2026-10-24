import {
  init,
  Identity,
  MeshController,
  type MeshEvent,
  type PeerInfo,
} from "@offline/core";
import { MeshTransport } from "./transport";
import { compressMeshJpeg, peaksFromAudio, peaksFromWav, durationFromWav } from "./media";

export type ChatLine = {
  id: string;
  kind: "message" | "dm" | "system" | "file";
  from: string;
  text: string;
  mine: boolean;
  at: number;
  signed?: string;
  messageId?: string;
  /** Counterparty peer id for private threads (inbound = from; outbound = recipient). */
  withPeer?: string;
  /** Outbound DM / private media: `sending` → `sent` → `delivered` → `read`. */
  deliveryStatus?: "sending" | "sent" | "delivered" | "read" | string;
  /** 0..1 while BLE fragment train is in flight (BitChat block-reveal). */
  sendProgress?: number;
  /** Inbound: we have seen it in the open channel. */
  readByUs?: boolean;
  /** Inbound voice: we have pressed play at least once. */
  listenedByUs?: boolean;
  isPrivate?: boolean;
  mime?: string;
  fileName?: string;
  fileBytes?: Uint8Array;
  /** Waveform envelope 0..1 for voice notes. */
  peaks?: number[];
  durationMs?: number;
};

export type SessionSnapshot = {
  running: boolean;
  peerId: string;
  nickname: string;
  linkCount: number;
  bleDevices: string[];
  peers: PeerInfo[];
  messages: ChatLine[];
  status: string;
  supportsBle: boolean;
  selectedPeerId: string | null;
  /** Newest inbound message id we have marked read in the public channel. */
  lastReadPublicId: string | null;
};

type Listener = () => void;

export class MeshSession {
  private mesh: MeshController | null = null;
  private transport: MeshTransport | null = null;
  private identity: Identity | null = null;
  private messages: ChatLine[] = [];
  private peers: PeerInfo[] = [];
  private linkCount = 0;
  private bleDevices: string[] = [];
  private status = "Idle";
  private nickname = "";
  private peerId = "";
  private supportsBle = false;
  private running = false;
  private selectedPeerId: string | null = null;
  /** Peer whose private thread is currently open in the UI (null = general). */
  private privateViewPeerId: string | null = null;
  /** Read receipts waiting for Noise Transport with that peer. */
  private pendingReadReceipts = new Map<string, Set<string>>();
  private gossipTimer: ReturnType<typeof setInterval> | null = null;
  private announceTimer: ReturnType<typeof setInterval> | null = null;
  private flushChain: Promise<void> = Promise.resolve();
  private listeners = new Set<Listener>();
  private msgSeq = 0;
  private lastReadPublicId: string | null = loadLastReadPublicId();
  private listenedIds = loadListenedIds();
  /** Mine file chat ids waiting for their outbound fragment train to finish. */
  private mediaSendQueue: string[] = [];
  private lastProgressEmitMs = 0;

  subscribe(fn: Listener): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  snapshot(): SessionSnapshot {
    return {
      running: this.running,
      peerId: this.peerId,
      nickname: this.nickname,
      linkCount: this.linkCount,
      bleDevices: [...this.bleDevices],
      peers: [...this.peers],
      messages: [...this.messages],
      status: this.status,
      supportsBle: this.supportsBle,
      selectedPeerId: this.selectedPeerId,
      lastReadPublicId: this.lastReadPublicId,
    };
  }

  getIdentity(): Identity | null {
    return this.identity;
  }

  async start(identity: Identity, nickname: string): Promise<void> {
    if (this.running) await this.stop();
    await init();
    // Keep a live Identity handle for UI (QR / pubkey display). MeshController
    // copies key material and must not invalidate this handle.
    this.identity = identity;
    this.nickname = nickname.trim() || identity.peerId.slice(0, 8);
    this.mesh = new MeshController(identity, this.nickname);
    this.peerId = this.mesh.peerId();
    this.messages = [];
    this.peers = [];

    this.transport = new MeshTransport({
      onPacket: (bytes) => this.onInbound(bytes),
      onLinkCount: (n) => {
        this.linkCount = n;
        this.mesh?.setLinkCount(n);
        this.emit();
      },
      onBleDevices: (names) => {
        this.bleDevices = names;
        console.info("[offline-web] ble devices", names);
        this.emit();
      },
      onLog: (line) => {
        console.info(line);
        this.pushSystem(line);
      },
    });
    this.supportsBle = this.transport.supportsBle;

    await this.transport.start(this.peerId);
    console.info(
      `[offline-web] mesh session start peer=${this.peerId.slice(0, 8)}… nick=${this.nickname} ble=${this.supportsBle}`,
    );
    this.mesh.setLinkCount(this.linkCount);
    this.mesh.queueAnnounce();
    this.scheduleFlush();
    this.running = true;

    this.status = this.supportsBle
      ? "online — connect to the mesh over Bluetooth"
      : "online — open another tab (Bluetooth needs Chrome/Edge)";
    this.pushSystem(
      `You are ${this.nickname} (${this.peerId.slice(0, 8)}…). Connect to the mesh over Bluetooth to reach Offline / BitChat.`,
    );

    this.gossipTimer = setInterval(() => {
      try {
        this.mesh?.maintainGossipSync();
        this.scheduleFlush();
      } catch {
        /* soft-fail */
      }
    }, 5000);
    this.announceTimer = setInterval(() => {
      try {
        this.mesh?.queueAnnounce();
        this.scheduleFlush();
      } catch {
        /* soft-fail */
      }
    }, 12_000);

    this.refreshPeers();
    this.emit();
  }

  async stop(): Promise<void> {
    if (this.gossipTimer) clearInterval(this.gossipTimer);
    if (this.announceTimer) clearInterval(this.announceTimer);
    this.gossipTimer = null;
    this.announceTimer = null;
    try {
      this.mesh?.queueLeave();
      await this.flushOutbound();
    } catch {
      /* ignore */
    }
    await this.transport?.stop();
    this.mesh = null;
    this.transport = null;
    this.running = false;
    this.status = "IDLE";
    this.linkCount = 0;
    this.bleDevices = [];
    this.privateViewPeerId = null;
    this.pendingReadReceipts.clear();
    this.mediaSendQueue = [];
    this.emit();
  }

  selectPeer(peerId: string | null): void {
    this.selectedPeerId = peerId;
    this.emit();
  }

  /** Tell the session which private thread the UI is viewing (null = general). */
  setPrivateView(peerId: string | null): void {
    this.privateViewPeerId = peerId;
  }

  setNickname(nickname: string): void {
    const n = nickname.trim().slice(0, 32);
    if (!n) return;
    this.nickname = n;
    if (this.mesh) {
      this.mesh.setNickname(n);
      this.mesh.queueAnnounce();
      this.scheduleFlush();
    }
    this.emit();
  }

  sendPublic(text: string): void {
    const t = text.trim();
    if (!t || !this.mesh) return;
    this.mesh.queuePublicMessage(t);
    this.drainEvents();
    this.scheduleFlush();
    this.emit();
  }

  sendPrivate(peerId: string, text: string): void {
    const t = text.trim();
    if (!t || !this.mesh || !peerId) return;
    const prev = this.selectedPeerId;
    this.selectedPeerId = peerId;
    this.mesh.queuePrivateMessage(peerId, t);
    this.drainEvents();
    this.selectedPeerId = prev;
    this.scheduleFlush();
    this.emit();
  }

  startNoise(peerId: string): void {
    if (!this.mesh) return;
    this.mesh.startNoiseHandshake(peerId);
    this.pushSystem(`Noise handshake → ${peerId.slice(0, 8)}…`);
    this.scheduleFlush();
  }

  startQrVerification(peerId: string): void {
    if (!this.mesh) return;
    this.mesh.startQrVerification(peerId);
    this.pushSystem(`QR verify challenge → ${peerId.slice(0, 8)}…`);
    this.scheduleFlush();
  }

  async sendPhoto(file: File, toPeerId?: string | null): Promise<void> {
    if (!this.mesh) return;
    const compressed = await compressMeshJpeg(file);
    if (!compressed) {
      this.pushSystem("Photo too large after compress");
      this.emit();
      return;
    }
    await this.queueFileWithLegacyConsent(
      compressed.name,
      "image/jpeg",
      compressed.bytes,
      toPeerId,
    );
  }

  async sendVoice(wav: Uint8Array, toPeerId?: string | null): Promise<void> {
    if (!this.mesh) return;
    await this.queueFileWithLegacyConsent(
      "voice.wav",
      "audio/wav",
      wav,
      toPeerId,
    );
  }

  /** Private-media v1: try Noise path; prompt before legacy directed `0x22`. */
  private async queueFileWithLegacyConsent(
    name: string,
    mime: string,
    content: Uint8Array,
    toPeerId?: string | null,
  ): Promise<void> {
    if (!this.mesh) return;
    const trySend = (allowLegacy: boolean) => {
      this.mesh!.queueFile(name, mime, content, toPeerId ?? undefined, allowLegacy);
    };
    try {
      trySend(false);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (
        toPeerId &&
        msg.includes("legacy private media requires consent")
      ) {
        const ok =
          typeof window !== "undefined" &&
          window.confirm(
            "This peer’s client looks older and may not support end-to-end encrypted media.\n\nSend without end-to-end encryption?",
          );
        if (!ok) {
          this.pushSystem("Private media cancelled (needs E2E or consent)");
          this.emit();
          return;
        }
        trySend(true);
      } else {
        this.pushSystem(`File send failed: ${msg}`);
        this.emit();
        return;
      }
    }
    const prev = this.selectedPeerId;
    if (toPeerId) this.selectedPeerId = toPeerId;
    this.drainEvents();
    this.selectedPeerId = prev;
    this.scheduleFlush();
    this.emit();
  }

  async joinPhone(showAll = false): Promise<void> {
    if (!this.transport || !this.running) return;
    this.status = "Waiting for Bluetooth… pick a mesh peer";
    this.emit();
    try {
      await this.transport.connectNearby({ showAll });
      this.status = `On mesh: ${this.bleDevices.join(", ") || "peer"}`;
      this.mesh?.queueAnnounce();
      this.mesh?.setLinkCount(this.linkCount);
      this.scheduleFlush();
      // Flutter: delayed gossip sync ~5s after Join.
      setTimeout(() => {
        try {
          this.mesh?.maintainGossipSync();
          this.scheduleFlush();
        } catch {
          /* ignore */
        }
      }, 5000);
    } catch (e) {
      this.status = String(e);
      this.pushSystem(String(e));
      throw e;
    } finally {
      this.emit();
    }
  }

  private onInbound(bytes: Uint8Array): void {
    if (!this.mesh) return;
    try {
      this.mesh.ingestFrame(bytes);
    } catch (e) {
      this.pushSystem(`ingest soft-fail: ${e}`);
      return;
    }
    this.drainEvents();
    this.scheduleFlush();
    this.refreshPeers();
    this.emit();
  }

  private scheduleFlush(): void {
    this.flushChain = this.flushChain
      .then(() => this.flushOutbound())
      .catch(() => undefined);
  }

  private async flushOutbound(): Promise<void> {
    if (!this.mesh || !this.transport) return;
    const frames = this.mesh.drainOutbound();
    let activeChatId: string | null = null;
    let activeFragKey: string | null = null;

    for (let i = 0; i < frames.length; i++) {
      const bytes = frames[i].bytes;
      const frag = parseFragmentMeta(bytes);
      const isFragment = !!frag;
      if (frag) {
        const key = frag.idHex;
        if (key !== activeFragKey) {
          activeFragKey = key;
          activeChatId =
            this.mediaSendQueue.shift() ??
            this.messages.find(
              (m) =>
                m.mine &&
                m.kind === "file" &&
                (m.deliveryStatus === "sending" || m.sendProgress !== undefined),
            )?.id ??
            null;
          if (activeChatId) this.setSendProgress(activeChatId, 0, "sending");
        }
        const progress = (frag.index + 1) / frag.total;
        if (activeChatId) this.setSendProgress(activeChatId, progress, "sending");
      }

      await this.transport.send(bytes, { reliable: isFragment });

      if (frag && activeChatId && frag.index + 1 >= frag.total) {
        this.setSendProgress(activeChatId, 1, "sent");
        activeChatId = null;
        activeFragKey = null;
      } else if (!frag && (bytes[1] === 0x11 || bytes[1] === 0x22)) {
        // Whole Noise/file packet fit in one BLE frame (tiny media).
        const id = this.mediaSendQueue.shift();
        if (id) this.setSendProgress(id, 1, "sent");
      } else if (isFragment && i + 1 < frames.length) {
        // Extra gap between chunks even with acknowledged writes — phones
        // need time to notify / reassemble under SoftDevice load.
        await new Promise((r) => setTimeout(r, 18));
      }
    }
  }

  private setSendProgress(
    chatId: string,
    progress: number,
    status: "sending" | "sent",
  ): void {
    const m = this.messages.find((x) => x.id === chatId);
    if (!m) return;
    const p = Math.max(0, Math.min(1, progress));
    const changed =
      m.sendProgress !== p ||
      m.deliveryStatus !== status ||
      (status === "sent" && m.sendProgress !== 1);
    m.sendProgress = p;
    if (status === "sending") m.deliveryStatus = "sending";
    else if (m.deliveryStatus === "sending" || !m.deliveryStatus) {
      m.deliveryStatus = "sent";
    }
    if (!changed) return;
    const now = Date.now();
    // Throttle UI while a long train is in flight; always emit on completion.
    if (status === "sent" || now - this.lastProgressEmitMs > 80) {
      this.lastProgressEmitMs = now;
      this.emit();
    }
  }

  private drainEvents(): void {
    if (!this.mesh) return;
    for (const ev of this.mesh.drainEvents()) this.handleEvent(ev);
  }

  private handleEvent(ev: MeshEvent): void {
    switch (ev.kind) {
      case "announce":
        this.pushSystem(`${ev.nickname || ev.peerId.slice(0, 8)} announced`);
        break;
      case "message": {
        const mine = ev.peerId === this.peerId;
        this.pushChat({
          kind: "message",
          from: ev.peerId,
          text: ev.text,
          mine,
          at: ev.timestampMs || Date.now(),
          signed: ev.detail,
          readByUs: mine,
        });
        break;
      }
      case "dm": {
        const mine = ev.peerId === this.peerId;
        const withPeer = mine ? this.selectedPeerId || undefined : ev.peerId;
        this.pushChat({
          kind: "dm",
          from: ev.peerId,
          text: ev.text,
          mine,
          at: ev.timestampMs || Date.now(),
          isPrivate: true,
          withPeer,
          messageId: ev.detail || undefined,
          deliveryStatus: mine ? "sent" : undefined,
          readByUs: false,
        });
        // Auto-ack only while that peer's DM thread is open.
        if (
          !mine &&
          this.privateViewPeerId === ev.peerId &&
          ev.detail
        ) {
          this.sendReadReceipts(ev.peerId, [ev.detail]);
        }
        break;
      }
      case "delivered":
      case "read":
        this.applyReceipt(ev.detail, ev.kind);
        break;
      case "leave":
        if (this.selectedPeerId === ev.peerId) this.selectedPeerId = null;
        if (this.privateViewPeerId === ev.peerId) this.privateViewPeerId = null;
        this.pendingReadReceipts.delete(ev.peerId);
        this.pushSystem(`${ev.peerId.slice(0, 8)}… left`);
        break;
      case "noise":
        this.pushSystem(`noise ${ev.peerId.slice(0, 8)}… ${ev.detail}`);
        if (ev.detail.startsWith("ready")) {
          this.flushPendingReadReceipts(ev.peerId);
          // If the DM thread is open, re-send receipts now that Transport works
          // (covers earlier silent failures that never entered the pending set).
          if (this.privateViewPeerId === ev.peerId) {
            this.markPeerMessagesRead(ev.peerId);
          }
        }
        break;
      case "file": {
        const mime = ev.detail || "";
        const fileBytes = ev.fileBytes?.length ? ev.fileBytes : undefined;
        const voice =
          mime.startsWith("audio/") && fileBytes
            ? attachVoiceMeta(fileBytes, mime)
            : { peaks: undefined as number[] | undefined, durationMs: undefined as number | undefined };
        const mine = ev.peerId === this.peerId;
        const at = ev.timestampMs || Date.now();
        const fileName = ev.fileName || ev.text;
        // WASM maps stable private-media id into `nickname` for file events.
        const messageId = ev.nickname || undefined;
        const listenKey = voiceListenKey(ev.peerId, at, fileName, fileBytes?.length ?? 0);
        const withPeer = ev.isPrivate
          ? mine
            ? this.selectedPeerId || undefined
            : ev.peerId
          : undefined;
        const id = this.pushChat({
          kind: "file",
          from: ev.peerId,
          text: fileName,
          mine,
          at,
          isPrivate: ev.isPrivate,
          withPeer,
          messageId,
          deliveryStatus: mine ? "sending" : undefined,
          sendProgress: mine ? 0 : undefined,
          mime,
          fileName,
          fileBytes,
          peaks: voice.peaks,
          durationMs: voice.durationMs,
          readByUs: mine,
          listenedByUs: mine || this.listenedIds.has(listenKey),
        });
        if (mine) this.mediaSendQueue.push(id);
        if (
          !mine &&
          ev.isPrivate &&
          messageId &&
          this.privateViewPeerId === ev.peerId
        ) {
          this.sendReadReceipts(ev.peerId, [messageId]);
        }
        if (mime.startsWith("audio/") && fileBytes && !voice.peaks) {
          void this.hydrateVoicePeaks(id, fileBytes, mime);
        }
        break;
      }
      case "verified":
        this.pushSystem(`✓ Verified ${ev.nickname || ev.peerId.slice(0, 8)} (QR challenge)`);
        break;
      case "private_media_legacy":
        if (ev.detail === "needs_consent") {
          this.pushSystem(
            `Private media to ${ev.peerId.slice(0, 8)}… needs consent (peer lacks E2E media)`,
          );
        } else {
          this.pushSystem(
            `Sent ${ev.fileName || "file"} without E2E encryption → ${ev.peerId.slice(0, 8)}…`,
          );
        }
        break;
      default:
        break;
    }
  }

  private applyReceipt(messageId: string, kind: string): void {
    if (!messageId) return;
    const rank = (s?: string) =>
      s === "read"
        ? 3
        : s === "delivered"
          ? 2
          : s === "sent"
            ? 1
            : s === "sending"
              ? 0
              : -1;
    let changed = false;
    for (let i = this.messages.length - 1; i >= 0; i--) {
      const m = this.messages[i];
      if (
        m.mine &&
        m.messageId === messageId &&
        (m.kind === "dm" || (m.kind === "file" && m.isPrivate))
      ) {
        if (rank(kind) >= rank(m.deliveryStatus)) {
          m.deliveryStatus = kind;
          changed = true;
        }
        break;
      }
    }
    if (changed) this.emit();
  }

  /** Mark inbound DMs / private media from `peerId` as read and send receipts. */
  markPeerMessagesRead(peerId: string): void {
    if (!peerId || !this.mesh) return;
    // Always (re)queue receipts for this peer's inbound private messages.
    // BitChat treats duplicate read ACKs as idempotent; this recovers from
    // earlier silent failures when Noise was not ready yet.
    const ids: string[] = [];
    const seen = new Set<string>();
    for (const m of this.messages) {
      if (
        !m.mine &&
        m.from === peerId &&
        m.messageId &&
        !seen.has(m.messageId) &&
        (m.kind === "dm" || (m.kind === "file" && m.isPrivate))
      ) {
        seen.add(m.messageId);
        ids.push(m.messageId);
      }
    }
    if (!ids.length) return;
    this.sendReadReceipts(peerId, ids);
    this.emit();
  }

  /** Mark public-channel inbound messages as seen (up through the latest). */
  markPublicMessagesRead(): void {
    let lastId: string | null = null;
    let changed = false;
    for (const m of this.messages) {
      if (m.kind === "system") continue;
      if (m.kind === "dm" || m.isPrivate) continue;
      if (!m.mine && !m.readByUs) {
        m.readByUs = true;
        changed = true;
      }
      if (m.kind === "message" || m.kind === "file") lastId = m.id;
    }
    if (lastId && lastId !== this.lastReadPublicId) {
      this.lastReadPublicId = lastId;
      saveLastReadPublicId(lastId);
      changed = true;
    }
    if (changed) this.emit();
  }

  /** Mark a voice note as listened (persists across reloads via stable key). */
  markVoiceListened(chatId: string): void {
    const m = this.messages.find((x) => x.id === chatId);
    if (!m || m.listenedByUs) return;
    m.listenedByUs = true;
    m.readByUs = true;
    const key = voiceListenKey(m.from, m.at, m.fileName || m.text, m.fileBytes?.length ?? 0);
    this.listenedIds.add(key);
    saveListenedIds(this.listenedIds);
    this.emit();
  }

  unreadCount(peerId: string): number {
    return this.messages.filter(
      (m) =>
        !m.mine &&
        m.kind === "dm" &&
        m.from === peerId &&
        !m.readByUs,
    ).length;
  }

  unreadPublicCount(): number {
    return this.messages.filter(
      (m) =>
        !m.mine &&
        !m.readByUs &&
        (m.kind === "message" || (m.kind === "file" && !m.isPrivate)),
    ).length;
  }

  private sendReadReceipts(peerId: string, messageIds: string[]): void {
    if (!this.mesh || !messageIds.length) return;
    let queued = 0;
    for (const id of messageIds) {
      if (!id) continue;
      try {
        this.mesh.queueReadReceipt(peerId, id);
        queued += 1;
        this.clearPendingReadReceipt(peerId, id);
        for (const m of this.messages) {
          if (
            m.messageId === id &&
            !m.mine &&
            (m.kind === "dm" || (m.kind === "file" && m.isPrivate))
          ) {
            m.readByUs = true;
          }
        }
      } catch {
        // Noise not ready — retry when the session reaches Transport.
        this.enqueuePendingReadReceipt(peerId, id);
      }
    }
    if (queued > 0) this.scheduleFlush();
  }

  private enqueuePendingReadReceipt(peerId: string, messageId: string): void {
    let set = this.pendingReadReceipts.get(peerId);
    if (!set) {
      set = new Set();
      this.pendingReadReceipts.set(peerId, set);
    }
    set.add(messageId);
  }

  private clearPendingReadReceipt(peerId: string, messageId: string): void {
    const set = this.pendingReadReceipts.get(peerId);
    if (!set) return;
    set.delete(messageId);
    if (set.size === 0) this.pendingReadReceipts.delete(peerId);
  }

  private flushPendingReadReceipts(peerId: string): void {
    const set = this.pendingReadReceipts.get(peerId);
    if (!set?.size) return;
    this.sendReadReceipts(peerId, [...set]);
  }

  private refreshPeers(): void {
    if (!this.mesh) return;
    this.peers = this.mesh.listPeers();
  }

  private pushChat(line: Omit<ChatLine, "id">): string {
    this.msgSeq += 1;
    const id = `m${this.msgSeq}`;
    this.messages.push({ ...line, id });
    this.messages.sort((a, b) => a.at - b.at || a.id.localeCompare(b.id));
    if (this.messages.length > 400) this.messages = this.messages.slice(-300);
    return id;
  }

  private async hydrateVoicePeaks(
    id: string,
    bytes: Uint8Array,
    mime: string,
  ): Promise<void> {
    try {
      const { peaks, durationMs } = await peaksFromAudio(bytes, mime);
      const msg = this.messages.find((m) => m.id === id);
      if (!msg) return;
      msg.peaks = peaks;
      msg.durationMs = durationMs;
      this.emit();
    } catch {
      /* decode failed — keep plain player */
    }
  }

  private pushSystem(text: string): void {
    this.pushChat({
      kind: "system",
      from: "",
      text,
      mine: false,
      at: Date.now(),
    });
  }

  private emit(): void {
    for (const fn of this.listeners) fn();
  }
}

/** Parse BitChat fragment (0x20) index/total from an encoded BLE frame. */
function parseFragmentMeta(
  bytes: Uint8Array,
): { idHex: string; index: number; total: number } | null {
  if (bytes.length < 14 || bytes[1] !== 0x20) return null;
  const version = bytes[0]!;
  if (version !== 1 && version !== 2) return null;
  const flags = bytes[11]!;
  const hasRecipient = (flags & 0x01) !== 0;
  const hasSignature = (flags & 0x02) !== 0;
  const isCompressed = (flags & 0x04) !== 0;
  const hasRoute = (flags & 0x08) !== 0;
  let offset = 12;
  let payloadLen = 0;
  if (version === 2) {
    if (bytes.length < offset + 4) return null;
    payloadLen =
      ((bytes[offset]! << 24) |
        (bytes[offset + 1]! << 16) |
        (bytes[offset + 2]! << 8) |
        bytes[offset + 3]!) >>>
      0;
    offset += 4;
  } else {
    if (bytes.length < offset + 2) return null;
    payloadLen = (bytes[offset]! << 8) | bytes[offset + 1]!;
    offset += 2;
  }
  offset += 8; // sender
  if (hasRecipient) offset += 8;
  if (hasRoute) {
    if (bytes.length < offset + 1) return null;
    const hops = bytes[offset]!;
    offset += 1 + hops * 8;
  }
  if (isCompressed) offset += version === 2 ? 4 : 2;
  if (offset + 13 > bytes.length) return null;
  // Fragment payload: id(8) + index u16 BE + total u16 BE + originalType(1) + data
  const idHex = [...bytes.subarray(offset, offset + 8)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  const index = (bytes[offset + 8]! << 8) | bytes[offset + 9]!;
  const total = (bytes[offset + 10]! << 8) | bytes[offset + 11]!;
  if (!total || index >= total) return null;
  void payloadLen;
  void hasSignature;
  return { idHex, index, total };
}

function attachVoiceMeta(
  bytes: Uint8Array,
  mime: string,
): { peaks?: number[]; durationMs?: number } {
  if (!mime.includes("wav") && !mime.includes("wave")) return {};
  const peaks = peaksFromWav(bytes) ?? undefined;
  const durationMs = durationFromWav(bytes) ?? undefined;
  return { peaks, durationMs };
}

function voiceListenKey(
  from: string,
  at: number,
  name: string,
  byteLen: number,
): string {
  return `${from}|${at}|${name}|${byteLen}`;
}

const READ_PUB_KEY = "offline-web-last-read-pub";
const LISTENED_KEY = "offline-web-listened-voice";

function loadLastReadPublicId(): string | null {
  try {
    return localStorage.getItem(READ_PUB_KEY);
  } catch {
    return null;
  }
}

function saveLastReadPublicId(id: string): void {
  try {
    localStorage.setItem(READ_PUB_KEY, id);
  } catch {
    /* ignore */
  }
}

function loadListenedIds(): Set<string> {
  try {
    const raw = localStorage.getItem(LISTENED_KEY);
    if (!raw) return new Set();
    const arr = JSON.parse(raw) as string[];
    return new Set(Array.isArray(arr) ? arr.slice(-200) : []);
  } catch {
    return new Set();
  }
}

function saveListenedIds(ids: Set<string>): void {
  try {
    localStorage.setItem(LISTENED_KEY, JSON.stringify([...ids].slice(-200)));
  } catch {
    /* ignore */
  }
}
