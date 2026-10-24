/**
 * Typed wrapper around the `offline-wasm` wasm-bindgen output.
 *
 * Transport is the host's job — feed bytes via `ingest_frame` and drain
 * outbound frames yourself (Web Bluetooth, BroadcastChannel, WebSocket, …).
 *
 * SECURITY: secrets from `exportSecrets()` must not be persisted in clear
 * `localStorage` / IndexedDB. See docs/WASM_JS_PACKAGE.md §7 and
 * docs/SECURITY_IMPROVEMENTS.md S-4.
 */

import initWasm, {
  Identity as WasmIdentity,
  MeshController as WasmMesh,
  OpticalReceiver as WasmOpticalRx,
  OpticalSender as WasmOpticalTx,
  build_verify_qr,
  client_version as wasm_client_version,
  protocol_version as wasm_protocol_version,
  version_label as wasm_version_label,
  set_wasm_log_enabled as wasm_set_log_enabled,
  wasm_log_enabled as wasm_get_log_enabled,
  fnv1a_hash,
  type ExportedSecrets,
} from "../pkg/offline_wasm.js";

export type MeshEvent = {
  kind:
    | "announce"
    | "message"
    | "leave"
    | "noise"
    | "dm"
    | "file"
    | "delivered"
    | "read"
    | "verified"
    | "private_media_legacy"
    | "voice_frame"
    | string;
  peerId: string;
  nickname: string;
  text: string;
  timestampMs: number;
  detail: string;
  isPrivate: boolean;
  fileName: string;
  fileBytes: Uint8Array;
};

export type OutboundFrame = {
  toPeerId?: string | null;
  bytes: Uint8Array;
};

export type PeerInfo = {
  peerId: string;
  nickname: string;
  lastSeenMs: number;
  noiseState: string;
  hasNoiseKey: boolean;
  verified: boolean;
  privateMediaReady: boolean;
  announceCapabilities: number;
};

export type OpticalProgress = {
  framesCollected: number;
  framesTarget: number;
  completePayload?: Uint8Array | null;
};

let initPromise: Promise<unknown> | null = null;

/** Load and instantiate the WASM module. Safe to call multiple times. */
export async function init(
  moduleOrPath?:
    | RequestInfo
    | URL
    | Response
    | BufferSource
    | WebAssembly.Module
    | { module_or_path?: RequestInfo | URL | Response | BufferSource | WebAssembly.Module },
): Promise<void> {
  if (!initPromise) {
    // Prefer the object form expected by newer wasm-bindgen init.
    const arg =
      moduleOrPath == null
        ? undefined
        : typeof moduleOrPath === "object" &&
            "module_or_path" in (moduleOrPath as object)
          ? moduleOrPath
          : { module_or_path: moduleOrPath };
    initPromise = initWasm(arg as never).then((mod) => {
      // Keep `[offline-wasm]` console lines on by default for mesh debugging.
      try {
        wasm_set_log_enabled(true);
      } catch {
        /* older pkg without the export */
      }
      if (typeof console !== "undefined") {
        console.info(
          "[@offline/core] WASM ready — filter DevTools by `[offline-wasm]`",
        );
      }
      return mod;
    });
  }
  await initPromise;
}

/** Toggle Rust WASM `console.log` lines (`[offline-wasm] …`). Default on. */
export function setWasmLogEnabled(enabled: boolean): void {
  wasm_set_log_enabled(enabled);
}

export function wasmLogEnabled(): boolean {
  return wasm_get_log_enabled();
}

export class Identity {
  readonly #inner: WasmIdentity;

  constructor(inner?: WasmIdentity) {
    this.#inner = inner ?? new WasmIdentity();
  }

  static fromSecrets(noiseSecret: Uint8Array, signingSecret: Uint8Array): Identity {
    return new Identity(WasmIdentity.from_secrets(noiseSecret, signingSecret));
  }

  get peerId(): string {
    return this.#inner.peer_id;
  }

  get noisePublicKey(): Uint8Array {
    return this.#inner.noise_public_key;
  }

  get signingPublicKey(): Uint8Array {
    return this.#inner.signing_public_key;
  }

  /** Host must protect these bytes — package never persists them. */
  exportSecrets(): ExportedSecrets {
    return this.#inner.export_secrets();
  }

  /** @internal */
  get _raw(): WasmIdentity {
    return this.#inner;
  }
}

export class MeshController {
  readonly #inner: WasmMesh;

  constructor(identity: Identity, nickname: string) {
    this.#inner = new WasmMesh(identity._raw, nickname);
  }

  peerId(): string {
    return this.#inner.peer_id();
  }

  nickname(): string {
    return this.#inner.nickname();
  }

  setNickname(nickname: string): void {
    this.#inner.set_nickname(nickname);
  }

  setLinkCount(count: number): void {
    this.#inner.set_link_count(count);
  }

  queueAnnounce(): void {
    this.#inner.queue_announce();
  }

  queuePublicMessage(text: string): void {
    this.#inner.queue_public_message(text);
  }

  queuePrivateMessage(peerId: string, text: string): void {
    this.#inner.queue_private_message(peerId, text);
  }

  /** BitChat Noise `readReceipt` for an inbound private message id. */
  queueReadReceipt(peerId: string, messageId: string): void {
    this.#inner.queue_read_receipt(peerId, messageId);
  }

  queueFile(
    name: string,
    mime: string,
    content: Uint8Array,
    to?: string | null,
    allowLegacyPrivate = false,
  ): void {
    this.#inner.queue_file(
      name,
      mime,
      content,
      to ?? undefined,
      allowLegacyPrivate,
    );
  }

  /** True when Noise `0x21` proved PRIVATE_MEDIA for this peer. */
  privateMediaReady(peerId: string): boolean {
    return this.#inner.private_media_ready(peerId);
  }

  /** Live PTT: encoded `VoiceBurstPacket` bytes; `to` null = public `0x29`. */
  queueVoiceBurst(burst: Uint8Array, to?: string | null): void {
    this.#inner.queue_voice_burst(burst, to ?? undefined);
  }

  queueLeave(): void {
    this.#inner.queue_leave();
  }

  startNoiseHandshake(peerId: string): void {
    this.#inner.start_noise_handshake(peerId);
  }

  startQrVerification(peerId: string): void {
    this.#inner.start_qr_verification(peerId);
  }

  maintainGossipSync(): void {
    this.#inner.maintain_gossip_sync();
  }

  queueRequestSync(toPeerId?: string | null): void {
    this.#inner.queue_request_sync(toPeerId ?? undefined);
  }

  noiseState(peerId: string): string {
    return this.#inner.noise_state(peerId);
  }

  isVerified(peerId: string): boolean {
    return this.#inner.is_verified(peerId);
  }

  ingestFrame(bytes: Uint8Array): void {
    this.#inner.ingest_frame(bytes);
  }

  drainOutbound(): OutboundFrame[] {
    const raw = this.#inner.drain_outbound() as Array<{
      toPeerId?: string | null;
      bytes: Uint8Array;
    }>;
    return raw.map((f) => ({
      toPeerId: f.toPeerId,
      bytes: f.bytes instanceof Uint8Array ? f.bytes : new Uint8Array(f.bytes as ArrayBuffer),
    }));
  }

  drainEvents(): MeshEvent[] {
    const raw = this.#inner.drain_events() as Array<Record<string, unknown>>;
    return raw.map((e) => ({
      kind: String(e.kind ?? ""),
      peerId: String(e.peerId ?? ""),
      nickname: String(e.nickname ?? ""),
      text: String(e.text ?? ""),
      timestampMs: Number(e.timestampMs ?? 0),
      detail: String(e.detail ?? ""),
      isPrivate: Boolean(e.isPrivate),
      fileName: String(e.fileName ?? ""),
      fileBytes:
        e.fileBytes instanceof Uint8Array
          ? e.fileBytes
          : new Uint8Array((e.fileBytes as ArrayBuffer) ?? []),
    }));
  }

  listPeers(): PeerInfo[] {
    const raw = this.#inner.list_peers() as Array<Record<string, unknown>>;
    return raw.map((p) => ({
      peerId: String(p.peerId ?? ""),
      nickname: String(p.nickname ?? ""),
      lastSeenMs: Number(p.lastSeenMs ?? 0),
      noiseState: String(p.noiseState ?? ""),
      hasNoiseKey: Boolean(p.hasNoiseKey),
      verified: Boolean(p.verified),
      privateMediaReady: Boolean(p.privateMediaReady),
      announceCapabilities: Number(p.announceCapabilities ?? 0),
    }));
  }
}

export class OpticalSender {
  readonly #inner: WasmOpticalTx;

  constructor(payload: Uint8Array, blockLen = 200) {
    this.#inner = WasmOpticalTx.start(payload, blockLen);
  }

  nextFrame(): Uint8Array {
    return this.#inner.next_frame();
  }
}

export class OpticalReceiver {
  readonly #inner: WasmOpticalRx;

  constructor() {
    this.#inner = new WasmOpticalRx();
  }

  ingestFrame(frame: Uint8Array): OpticalProgress {
    const raw = this.#inner.ingest_frame(frame) as Record<string, unknown>;
    const payload = raw.completePayload;
    return {
      framesCollected: Number(raw.framesCollected ?? 0),
      framesTarget: Number(raw.framesTarget ?? 0),
      completePayload:
        payload == null
          ? null
          : payload instanceof Uint8Array
            ? payload
            : new Uint8Array(payload as ArrayBuffer),
    };
  }
}

export function buildVerifyQr(
  noiseSecret: Uint8Array,
  signingSecret: Uint8Array,
  nickname: string,
  nowUnix: number,
): string {
  return build_verify_qr(noiseSecret, signingSecret, nickname, nowUnix);
}

/** App release version (e.g. `0.1.0`). Requires `init()`. */
export function clientVersion(): string {
  return wasm_client_version();
}

/** Wire protocol label (e.g. `bitchat-mesh/1`). Requires `init()`. */
export function protocolVersion(): string {
  return wasm_protocol_version();
}

/** Combined UI label (e.g. `0.1.0 · bitchat-mesh/1`). Requires `init()`. */
export function versionLabel(): string {
  return wasm_version_label();
}

export function fnv1aHash(bytes: Uint8Array): number {
  return fnv1a_hash(bytes);
}

export { WasmIdentity, WasmMesh, WasmOpticalRx, WasmOpticalTx };
export default init;
