import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it, beforeAll } from "vitest";
import {
  init,
  Identity,
  MeshController,
  OpticalReceiver,
  OpticalSender,
  fnv1aHash,
} from "../src/index.ts";

beforeAll(async () => {
  // `--target web` uses fetch by default; Node needs the bytes passed in.
  const wasmPath = join(
    dirname(fileURLToPath(import.meta.url)),
    "../pkg/offline_wasm_bg.wasm",
  );
  await init({ module_or_path: readFileSync(wasmPath) });
});

describe("identity", () => {
  it("generates a 16-char peer id and round-trips secrets", () => {
    const id = new Identity();
    expect(id.peerId).toMatch(/^[0-9a-f]{16}$/);
    const secrets = id.exportSecrets();
    expect(secrets.noise_secret.length).toBe(32);
    expect(secrets.signing_secret.length).toBe(32);
    const restored = Identity.fromSecrets(
      secrets.noise_secret,
      secrets.signing_secret,
    );
    expect(restored.peerId).toBe(id.peerId);
  });
});

describe("mesh", () => {
  it("exchanges a public message over a drained loop", () => {
    const alice = new MeshController(new Identity(), "alice");
    const bob = new MeshController(new Identity(), "bob");

    alice.queuePublicMessage("hello mesh");
    const out = alice.drainOutbound();
    expect(out.length).toBeGreaterThan(0);

    for (const f of out) {
      bob.ingestFrame(f.bytes);
    }
    const events = bob.drainEvents();
    const msg = events.find((e) => e.kind === "message");
    expect(msg?.text).toBe("hello mesh");
  });

  it("completes a Noise XX handshake and DM", () => {
    const alice = new MeshController(new Identity(), "alice");
    const bob = new MeshController(new Identity(), "bob");
    alice.setLinkCount(1);
    bob.setLinkCount(1);

    alice.queueAnnounce();
    bob.queueAnnounce();
    pump(alice, bob);
    pump(bob, alice);
    alice.drainEvents();
    bob.drainEvents();

    const bobId = bob.peerId();
    alice.startNoiseHandshake(bobId);
    for (let i = 0; i < 6; i++) {
      pump(alice, bob);
      pump(bob, alice);
      if (
        alice.noiseState(bobId) === "ready" &&
        bob.noiseState(alice.peerId()) === "ready"
      ) {
        break;
      }
    }

    expect(alice.noiseState(bobId)).toBe("ready");
    expect(bob.noiseState(alice.peerId())).toBe("ready");

    alice.drainEvents();
    bob.drainEvents();
    alice.queuePrivateMessage(bobId, "secret dm");
    alice.drainEvents(); // local echo
    for (const f of alice.drainOutbound()) {
      bob.ingestFrame(f.bytes);
    }
    const events = bob.drainEvents();
    const dm = events.find((e) => e.kind === "dm" && e.text === "secret dm");
    expect(dm).toBeTruthy();
  });
});

describe("optical", () => {
  it("reassembles a payload across fountain frames", () => {
    const payload = new TextEncoder().encode("optical hello ".repeat(40));
    const tx = new OpticalSender(payload, 64);
    const rx = new OpticalReceiver();
    let done: Uint8Array | null | undefined;
    for (let i = 0; i < 200 && !done; i++) {
      // Drop ~15% of frames.
      const frame = tx.nextFrame();
      if (i % 7 === 0) continue;
      const progress = rx.ingestFrame(frame);
      done = progress.completePayload;
    }
    expect(done).toBeTruthy();
    expect(new TextDecoder().decode(done!)).toBe(new TextDecoder().decode(payload));
    expect(fnv1aHash(payload)).toBe(fnv1aHash(done!));
  });
});

function pump(from: MeshController, to: MeshController): void {
  for (const f of from.drainOutbound()) {
    to.ingestFrame(f.bytes);
  }
}
