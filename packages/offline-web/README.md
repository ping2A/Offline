# Offline web UI

Standalone mesh chat UI on `@offline/core` (WASM). Talks to:

- **Other browser tabs** on the same origin via `BroadcastChannel` (`offline-mesh-v1`)
- **Nearby Offline / BitChat phones** via Web Bluetooth (Chrome / Edge, localhost or HTTPS)

## Run

```bash
./scripts/run_js_web.sh
# open http://127.0.0.1:5173
```

(`--setup` forces a full rebuild + tests; `--skip-setup` starts only.)

Then open a **second tab** to the same URL — public messages should appear both ways. On desktop Chrome/Edge, click **Connect to the mesh** with BitChat or Offline advertising nearby.

In the sidebar, **How it works** explains the flow. Official BitChat apps (mesh peers for this UI):

- [iPhone · App Store](https://apps.apple.com/us/app/bitchat-mesh/id6748219622)
- [Android · Google Play](https://play.google.com/store/apps/details?id=com.bitchat.droid)
- [bitchat.free](https://bitchat.free)

Feature requirements and parity vs Flutter: [`docs/CLIENT_FEATURES.md`](../../docs/CLIENT_FEATURES.md).

## Notes

- Browsers cannot advertise BLE; the web app is always a **leaf** on phone mesh.
- Identity secrets are stored in IndexedDB for this origin (not Keychain). Treat XSS on this origin as identity compromise — see `docs/WASM_JS_PACKAGE.md` §7.
- Tabs: **Mesh** (chat, photos, voice, peers, verify) · **Optical** (QR fountain) · **Identity** (keys + BitChat verify QR).
