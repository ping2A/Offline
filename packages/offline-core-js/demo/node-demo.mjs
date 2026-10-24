#!/usr/bin/env node
/**
 * Tiny Node smoke demo for @offline/core.
 * Run after `npm run build` (or `./scripts/setup_js.sh`).
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  init,
  Identity,
  MeshController,
  OpticalReceiver,
  OpticalSender,
} from "../dist/index.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const wasm = readFileSync(join(root, "pkg/offline_wasm_bg.wasm"));

await init({ module_or_path: wasm });

const alice = new MeshController(new Identity(), "alice");
const bob = new MeshController(new Identity(), "bob");
alice.setLinkCount(1);
bob.setLinkCount(1);

alice.queueAnnounce();
bob.queueAnnounce();
for (const f of alice.drainOutbound()) bob.ingestFrame(f.bytes);
for (const f of bob.drainOutbound()) alice.ingestFrame(f.bytes);

alice.queuePublicMessage("hello from wasm");
for (const f of alice.drainOutbound()) bob.ingestFrame(f.bytes);
const msg = bob.drainEvents().find((e) => e.kind === "message");
console.log("public message:", msg?.text ?? "(missing)");

const payload = new TextEncoder().encode("qr-fountain-ok");
const tx = new OpticalSender(payload, 32);
const rx = new OpticalReceiver();
let done;
for (let i = 0; i < 80 && !done; i++) {
  done = rx.ingestFrame(tx.nextFrame()).completePayload;
}
console.log("optical payload:", done ? new TextDecoder().decode(done) : "(incomplete)");
console.log("alice peer id:", alice.peerId());
console.log("ok");
