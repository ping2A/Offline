/** Photo + voice helpers matching Flutter mesh limits. */

export const MAX_MESH_IMAGE_BYTES = 45 * 1024;
export const MAX_MESH_IMAGE_EDGE = 448;
export const MAX_VOICE_BYTES = 512 * 1024;
export const VOICE_BARS = 48;

/** BitChat `ImageUtils`: `img_yyyyMMdd_HHmmss_<UUID>.jpg` (receipt-eligible). */
export function meshImageFileName(now = new Date()): string {
  const p = (n: number) => n.toString().padStart(2, "0");
  const stamp =
    `${now.getFullYear()}${p(now.getMonth() + 1)}${p(now.getDate())}_` +
    `${p(now.getHours())}${p(now.getMinutes())}${p(now.getSeconds())}`;
  return `img_${stamp}_${crypto.randomUUID()}.jpg`;
}

export async function compressMeshJpeg(
  file: Blob,
  maxBytes = MAX_MESH_IMAGE_BYTES,
  maxEdge = MAX_MESH_IMAGE_EDGE,
): Promise<{ bytes: Uint8Array; name: string } | null> {
  const bitmap = await createImageBitmap(file);
  let w = bitmap.width;
  let h = bitmap.height;
  if (w > maxEdge || h > maxEdge) {
    if (w >= h) {
      h = Math.round((h * maxEdge) / w);
      w = maxEdge;
    } else {
      w = Math.round((w * maxEdge) / h);
      h = maxEdge;
    }
  }
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");
  if (!ctx) return null;
  ctx.drawImage(bitmap, 0, 0, w, h);
  bitmap.close();

  for (const q of [0.82, 0.7, 0.55, 0.4, 0.3]) {
    const blob = await canvasToJpeg(canvas, q);
    if (blob && blob.size <= maxBytes) {
      return {
        bytes: new Uint8Array(await blob.arrayBuffer()),
        name: meshImageFileName(),
      };
    }
  }

  let edge = Math.floor(maxEdge / 2);
  while (edge >= 160) {
    const scale = edge / Math.max(w, h);
    const cw = Math.max(1, Math.round(w * scale));
    const ch = Math.max(1, Math.round(h * scale));
    canvas.width = cw;
    canvas.height = ch;
    ctx.drawImage(await createImageBitmap(file), 0, 0, cw, ch);
    for (const q of [0.4, 0.3, 0.22]) {
      const blob = await canvasToJpeg(canvas, q);
      if (blob && blob.size <= maxBytes) {
        return {
          bytes: new Uint8Array(await blob.arrayBuffer()),
          name: meshImageFileName(),
        };
      }
    }
    edge = Math.floor(edge / 2);
  }
  return null;
}

function canvasToJpeg(canvas: HTMLCanvasElement, quality: number): Promise<Blob | null> {
  return new Promise((resolve) => canvas.toBlob((b) => resolve(b), "image/jpeg", quality));
}

export type VoiceRecordOpts = {
  onTick?: (elapsedMs: number) => void;
  /** Live RMS level 0..1 for recording meter. */
  onLevel?: (level: number) => void;
};

/** Capture mono PCM and wrap as 8 kHz WAV (Flutter web path). */
export async function recordVoiceWav(
  maxMs = 10_000,
  opts: VoiceRecordOpts | ((elapsedMs: number) => void) = {},
): Promise<{ stop: () => Promise<Uint8Array | null> }> {
  const onTick = typeof opts === "function" ? opts : opts.onTick;
  const onLevel = typeof opts === "function" ? undefined : opts.onLevel;
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true },
  });
  const ctx = new AudioContext({ sampleRate: 8000 });
  const source = ctx.createMediaStreamSource(stream);
  const processor = ctx.createScriptProcessor(4096, 1, 1);
  const samples: Float32Array[] = [];
  const started = performance.now();
  let tickTimer: ReturnType<typeof setInterval> | null = setInterval(() => {
    onTick?.(Math.min(maxMs, performance.now() - started));
  }, 200);

  processor.onaudioprocess = (ev) => {
    const ch = ev.inputBuffer.getChannelData(0);
    samples.push(new Float32Array(ch));
    if (onLevel) {
      let sum = 0;
      for (let i = 0; i < ch.length; i++) sum += ch[i] * ch[i];
      onLevel(Math.min(1, Math.sqrt(sum / ch.length) * 3.2));
    }
    if (performance.now() - started >= maxMs) {
      void stop();
    }
  };
  source.connect(processor);
  processor.connect(ctx.destination);

  let stopped = false;
  const stop = async (): Promise<Uint8Array | null> => {
    if (stopped) return null;
    stopped = true;
    if (tickTimer) clearInterval(tickTimer);
    tickTimer = null;
    processor.disconnect();
    source.disconnect();
    stream.getTracks().forEach((t) => t.stop());
    await ctx.close();
    const pcm = concatFloat(samples);
    if (pcm.length < 8000 * 0.35) return null; // ~0.35s min
    const wav = encodeWav(pcm, 8000);
    if (wav.byteLength > MAX_VOICE_BYTES) return null;
    return wav;
  };

  return { stop };
}

/** Peak envelope 0..1 for waveform UI (bar count = `bars`). */
export function peaksFromPcm(pcm: Float32Array, bars = VOICE_BARS): number[] {
  if (pcm.length === 0) return Array.from({ length: bars }, () => 0.08);
  const out: number[] = [];
  const step = Math.max(1, Math.floor(pcm.length / bars));
  for (let i = 0; i < bars; i++) {
    const start = i * step;
    const end = Math.min(pcm.length, start + step);
    let peak = 0;
    for (let j = start; j < end; j++) {
      const a = Math.abs(pcm[j]!);
      if (a > peak) peak = a;
    }
    out.push(peak);
  }
  const max = Math.max(...out, 0.02);
  return out.map((v) => Math.max(0.08, Math.min(1, v / max)));
}

/** Sync peaks for RIFF/WAV; null if not a readable WAV. */
export function peaksFromWav(bytes: Uint8Array, bars = VOICE_BARS): number[] | null {
  const pcm = decodeWavPcm(bytes);
  return pcm ? peaksFromPcm(pcm, bars) : null;
}

export function durationFromWav(bytes: Uint8Array): number | null {
  const pcm = decodeWavPcm(bytes);
  if (!pcm) return null;
  const rate = wavSampleRate(bytes) || 8000;
  return (pcm.length / rate) * 1000;
}

/** Decode any browser-supported audio to peaks (WAV uses fast path). */
export async function peaksFromAudio(
  bytes: Uint8Array,
  mime: string,
  bars = VOICE_BARS,
): Promise<{ peaks: number[]; durationMs: number }> {
  if (mime.includes("wav") || mime.includes("wave")) {
    const peaks = peaksFromWav(bytes, bars);
    const durationMs = durationFromWav(bytes) ?? 0;
    if (peaks) return { peaks, durationMs };
  }
  const ctx = new AudioContext();
  try {
    const copy = bytes.slice().buffer as ArrayBuffer;
    const audio = await ctx.decodeAudioData(copy);
    const ch = audio.getChannelData(0);
    return {
      peaks: peaksFromPcm(ch, bars),
      durationMs: audio.duration * 1000,
    };
  } finally {
    await ctx.close();
  }
}

export function formatVoiceTime(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  const m = Math.floor(s / 60);
  const r = s % 60;
  return `${m}:${r.toString().padStart(2, "0")}`;
}

function wavSampleRate(bytes: Uint8Array): number | null {
  if (bytes.length < 28) return null;
  if (bytes[0] !== 0x52 || bytes[1] !== 0x49 || bytes[2] !== 0x46 || bytes[3] !== 0x46) return null;
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(24, true);
}

function decodeWavPcm(bytes: Uint8Array): Float32Array | null {
  if (bytes.length < 44) return null;
  if (bytes[0] !== 0x52 || bytes[1] !== 0x49 || bytes[2] !== 0x46 || bytes[3] !== 0x46) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 12;
  let dataOff = -1;
  let dataLen = 0;
  let bits = 16;
  let channels = 1;
  while (offset + 8 <= bytes.length) {
    const id =
      String.fromCharCode(bytes[offset]!, bytes[offset + 1]!, bytes[offset + 2]!, bytes[offset + 3]!);
    const size = view.getUint32(offset + 4, true);
    const body = offset + 8;
    if (id === "fmt " && size >= 16) {
      channels = view.getUint16(body + 2, true);
      bits = view.getUint16(body + 14, true);
    } else if (id === "data") {
      dataOff = body;
      dataLen = size;
      break;
    }
    offset = body + size + (size % 2);
  }
  if (dataOff < 0 || bits !== 16) return null;
  const samples = Math.floor(dataLen / 2);
  const pcm = new Float32Array(Math.floor(samples / Math.max(1, channels)));
  let o = 0;
  for (let i = 0; i + 1 < dataLen && o < pcm.length; i += 2 * channels, o++) {
    const s = view.getInt16(dataOff + i, true);
    pcm[o] = s / (s < 0 ? 0x8000 : 0x7fff);
  }
  return pcm;
}

function concatFloat(chunks: Float32Array[]): Float32Array {
  let n = 0;
  for (const c of chunks) n += c.length;
  const out = new Float32Array(n);
  let o = 0;
  for (const c of chunks) {
    out.set(c, o);
    o += c.length;
  }
  return out;
}

function encodeWav(pcm: Float32Array, sampleRate: number): Uint8Array {
  const dataLen = pcm.length * 2;
  const buf = new ArrayBuffer(44 + dataLen);
  const view = new DataView(buf);
  const writeStr = (off: number, s: string) => {
    for (let i = 0; i < s.length; i++) view.setUint8(off + i, s.charCodeAt(i));
  };
  writeStr(0, "RIFF");
  view.setUint32(4, 36 + dataLen, true);
  writeStr(8, "WAVE");
  writeStr(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeStr(36, "data");
  view.setUint32(40, dataLen, true);
  let off = 44;
  for (let i = 0; i < pcm.length; i++, off += 2) {
    const s = Math.max(-1, Math.min(1, pcm[i]));
    view.setInt16(off, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
  return new Uint8Array(buf);
}

export function blobUrl(bytes: Uint8Array, mime: string): string {
  return URL.createObjectURL(new Blob([new Uint8Array(bytes)], { type: mime }));
}
