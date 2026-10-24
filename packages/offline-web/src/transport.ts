/** Browser mesh transport: BroadcastChannel (tabs) + Web Bluetooth (mesh peers). */

export const MESH_SERVICE_UUID = "f47b5e2d-4a9e-4c5a-9b3f-8e1d2c3a4b5c";
export const MESH_SERVICE_UUID_TESTNET = "f47b5e2d-4a9e-4c5a-9b3f-8e1d2c3a4b5a";
export const MESH_CHARACTERISTIC_UUID = "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d";
const CHANNEL = "offline-mesh-v1";
const MESH_SERVICES = [MESH_SERVICE_UUID, MESH_SERVICE_UUID_TESTNET];

export type TransportHandlers = {
  onPacket: (bytes: Uint8Array) => void;
  onLinkCount: (count: number) => void;
  onBleDevices: (names: string[]) => void;
  onLog?: (line: string) => void;
};

type BleDevice = BluetoothDevice;

class BleLink {
  constructor(
    readonly device: BleDevice,
    readonly characteristic: BluetoothRemoteGATTCharacteristic,
    readonly name: string,
    readonly id: string,
    private readonly onPacket: (bytes: Uint8Array) => void,
    private readonly onClosed: () => void,
  ) {}

  private notifyHandler = (ev: Event) => {
    const target = ev.target as BluetoothRemoteGATTCharacteristic;
    const value = target.value;
    if (!value) return;
    const bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    if (bytes.length) this.onPacket(bytes);
  };

  private disconnectHandler = () => this.onClosed();

  async startNotifications(): Promise<void> {
    this.characteristic.addEventListener(
      "characteristicvaluechanged",
      this.notifyHandler,
    );
    await this.characteristic.startNotifications();
    this.device.addEventListener("gattserverdisconnected", this.disconnectHandler);
  }

  /**
   * @param reliable Prefer acknowledged GATT writes. Fragment trains should
   * use this — writeWithoutResponse drops chunks under load and BitChat never
   * reassembles a partial private image.
   */
  async write(bytes: Uint8Array, opts?: { reliable?: boolean }): Promise<void> {
    if (bytes.length > 512) {
      throw new Error(`BLE frame ${bytes.length} exceeds Web Bluetooth 512-byte limit`);
    }
    const payload = bytes.slice();
    const props = this.characteristic.properties;
    const wantReliable = !!opts?.reliable;

    if (wantReliable && props.write) {
      await this.characteristic.writeValueWithResponse(payload);
      return;
    }
    if (props.writeWithoutResponse) {
      try {
        await this.characteristic.writeValueWithoutResponse(payload);
        // Fragment trains need more airtime than tiny control packets.
        await new Promise((r) => setTimeout(r, wantReliable ? 28 : 12));
        return;
      } catch {
        /* fall through */
      }
    }
    if (props.write) {
      await this.characteristic.writeValueWithResponse(payload);
      return;
    }
    await this.characteristic.writeValue(payload);
  }

  async close(): Promise<void> {
    try {
      this.characteristic.removeEventListener(
        "characteristicvaluechanged",
        this.notifyHandler,
      );
      await this.characteristic.stopNotifications();
    } catch {
      /* ignore */
    }
    try {
      this.device.gatt?.disconnect();
    } catch {
      /* ignore */
    }
  }
}

export class MeshTransport {
  private bc: BroadcastChannel | null = null;
  private peerIdHex = "";
  private tabPeers = new Set<string>();
  private bleLinks: BleLink[] = [];
  private presenceTimer: ReturnType<typeof setInterval> | null = null;
  private handlers: TransportHandlers;

  constructor(handlers: TransportHandlers) {
    this.handlers = handlers;
  }

  get bleDeviceNames(): string[] {
    return this.bleLinks.map((l) => l.name);
  }

  linkCount(): number {
    return this.tabPeers.size + this.bleLinks.length;
  }

  get supportsBle(): boolean {
    return (
      typeof navigator !== "undefined" &&
      !!navigator.bluetooth &&
      window.isSecureContext
    );
  }

  async start(peerIdHex: string): Promise<void> {
    await this.stop();
    this.peerIdHex = peerIdHex;
    this.log(`mesh start peer=${peerIdHex.slice(0, 8)}… ble=${this.supportsBle}`);

    this.bc = new BroadcastChannel(CHANNEL);
    this.bc.onmessage = (ev) => this.onBcMessage(ev.data);

    this.broadcastPresence("join");
    this.presenceTimer = setInterval(() => this.broadcastPresence("ping"), 8000);
    this.emitLinks();

    if (this.supportsBle) {
      void this.reconnectPermitted();
    }
  }

  async stop(): Promise<void> {
    if (this.presenceTimer) clearInterval(this.presenceTimer);
    this.presenceTimer = null;
    if (this.bc) {
      this.broadcastPresence("leave");
      this.bc.close();
      this.bc = null;
    }
    for (const link of [...this.bleLinks]) await link.close();
    this.bleLinks = [];
    this.tabPeers.clear();
    this.emitLinks();
    this.handlers.onBleDevices([]);
  }

  async send(bytes: Uint8Array, opts?: { reliable?: boolean }): Promise<void> {
    const copy = bytes.slice();
    // Prefer Uint8Array so Flutter web (`offline-mesh-v1`) and our BC listener agree.
    this.bc?.postMessage(copy);

    if (copy.length > 512) {
      this.log(`skip BLE write ${copy.length}B (>512)`);
      return;
    }
    for (const link of [...this.bleLinks]) {
      try {
        await link.write(copy, opts);
      } catch (e) {
        const msg = String(e);
        this.log(`BLE write fail ${link.name}: ${msg}`);
        // One retry with acknowledged write — recovers transient GATT stalls
        // that otherwise leave the peer with a half-assembled image.
        if (opts?.reliable && !msg.includes("512")) {
          try {
            await link.write(copy, { reliable: true });
            continue;
          } catch (e2) {
            this.log(`BLE retry fail ${link.name}: ${e2}`);
          }
        }
        if (msg.includes("512") || msg.includes("InvalidModificationError")) continue;
        await link.close();
        this.bleLinks = this.bleLinks.filter((l) => l !== link);
        this.emitLinks();
        this.handlers.onBleDevices(this.bleDeviceNames);
      }
    }
  }

  async connectNearby({ showAll = false } = {}): Promise<void> {
    if (!this.supportsBle) {
      throw new Error(
        "Web Bluetooth needs Chrome/Edge on https:// or localhost. Safari/Firefox cannot join BLE.",
      );
    }
    await this.ensureBleAvailable();
    // Linux Chrome/BlueZ often fails service-UUID advertisement matching
    // (BitChat is unnamed and may omit the mesh UUID from ADV). Default to
    // the unfiltered chooser there; macOS/Windows keep the tighter filter.
    const preferAll = showAll || isLinuxDesktop();
    const device = await this.requestDevice(preferAll);
    await this.attachDevice(device);
  }

  private async ensureBleAvailable(): Promise<void> {
    const bt = navigator.bluetooth!;
    if (typeof bt.getAvailability !== "function") return;
    let available = false;
    try {
      available = await bt.getAvailability();
    } catch {
      return;
    }
    if (available) return;
    if (isLinuxDesktop()) {
      throw new Error(
        "Bluetooth adapter unavailable on Linux. Turn Bluetooth on, then in Chrome open chrome://flags/#enable-experimental-web-platform-features → Enabled → Relaunch. Also need BlueZ 5.41+.",
      );
    }
    throw new Error(
      "Bluetooth adapter unavailable. Turn Bluetooth on and try again.",
    );
  }

  private async requestDevice(showAll: boolean): Promise<BleDevice> {
    const bt = navigator.bluetooth!;
    const allOpts = {
      acceptAllDevices: true,
      optionalServices: MESH_SERVICES,
    } as const;
    if (showAll) {
      this.log("requestDevice(acceptAllDevices)");
      return bt.requestDevice(allOpts);
    }
    try {
      this.log("requestDevice(mesh service filters)");
      return await bt.requestDevice({
        filters: [
          { services: [MESH_SERVICE_UUID] },
          { services: [MESH_SERVICE_UUID_TESTNET] },
          { namePrefix: "Offline" },
          { namePrefix: "offline" },
        ],
        optionalServices: MESH_SERVICES,
      });
    } catch (e) {
      const msg = String(e).toLowerCase();
      if (msg.includes("abort") || msg.includes("cancel")) throw e;
      // Empty filtered scan → open the full chooser once (Linux BlueZ + BitChat).
      this.log(`filtered scan empty (${e}); falling back to acceptAllDevices`);
      try {
        return await bt.requestDevice(allOpts);
      } catch (e2) {
        const msg2 = String(e2).toLowerCase();
        if (msg2.includes("abort") || msg2.includes("cancel")) throw e2;
        throw new Error(linuxBleHint(String(e2)));
      }
    }
  }

  private async reconnectPermitted(): Promise<void> {
    try {
      if (!navigator.bluetooth?.getDevices) return;
      const list = await navigator.bluetooth.getDevices();
      for (const device of list) {
        try {
          await this.attachDevice(device);
        } catch {
          /* skip */
        }
      }
    } catch {
      /* ignore */
    }
  }

  private async attachDevice(device: BleDevice): Promise<void> {
    const name = device.name || "(unnamed BitChat/Offline)";
    const id = device.id || "";
    if (id && this.bleLinks.some((l) => l.id === id)) {
      this.log(`already linked ${name}`);
      return;
    }
    const gatt = device.gatt;
    if (!gatt) throw new Error(`No GATT on ${name}`);
    if (!gatt.connected) {
      this.log(`GATT connect ${name}…`);
      await gatt.connect();
    }

    let service: BluetoothRemoteGATTService | null = null;
    let lastErr: unknown;
    for (let attempt = 0; attempt < 4 && !service; attempt++) {
      if (attempt > 0) await new Promise((r) => setTimeout(r, 200 * attempt));
      for (const uuid of MESH_SERVICES) {
        try {
          service = await gatt.getPrimaryService(uuid);
          break;
        } catch (e) {
          lastErr = e;
        }
      }
    }
    if (!service) {
      try {
        gatt.disconnect();
      } catch {
        /* ignore */
      }
      throw new Error(`Mesh GATT service missing on ${name} (last=${lastErr})`);
    }

    const characteristic = await service.getCharacteristic(MESH_CHARACTERISTIC_UUID);
    const link = new BleLink(
      device,
      characteristic,
      name,
      id,
      (bytes) => this.handlers.onPacket(bytes),
      () => {
        this.bleLinks = this.bleLinks.filter((l) => l.device !== device);
        this.emitLinks();
        this.handlers.onBleDevices(this.bleDeviceNames);
        this.log(`BLE disconnected ${name}`);
      },
    );
    await link.startNotifications();
    this.bleLinks.push(link);
    this.log(`mesh peer linked ${name}`);
    this.emitLinks();
    this.handlers.onBleDevices(this.bleDeviceNames);
  }

  private onBcMessage(data: unknown): void {
    if (typeof data === "string") {
      this.onPresence(data);
      return;
    }
    if (data instanceof ArrayBuffer) {
      const bytes = new Uint8Array(data);
      if (bytes.length) this.handlers.onPacket(bytes);
      return;
    }
    if (data instanceof Uint8Array) {
      this.handlers.onPacket(data);
    }
  }

  private broadcastPresence(kind: string): void {
    this.bc?.postMessage(`presence:${kind}:${this.peerIdHex}`);
  }

  private onPresence(s: string): void {
    if (!s.startsWith("presence:")) return;
    const parts = s.split(":");
    if (parts.length < 3) return;
    const kind = parts[1];
    const peer = parts.slice(2).join(":");
    if (peer === this.peerIdHex) return;
    if (kind === "leave") this.tabPeers.delete(peer);
    else this.tabPeers.add(peer);
    this.emitLinks();
  }

  private emitLinks(): void {
    this.handlers.onLinkCount(this.linkCount());
  }

  private log(line: string): void {
    this.handlers.onLog?.(`[transport] ${line}`);
  }
}

/** Chrome Linux desktop (not Android). Web Bluetooth is experimental there. */
export function isLinuxDesktop(): boolean {
  if (typeof navigator === "undefined") return false;
  const ua = navigator.userAgent || "";
  return /Linux/i.test(ua) && !/Android/i.test(ua);
}

function linuxBleHint(detail: string): string {
  if (isLinuxDesktop()) {
    return (
      "No Bluetooth devices visible on Linux. In Chrome: " +
      "chrome://flags/#enable-experimental-web-platform-features → Enabled → Relaunch. " +
      "Keep BitChat/Offline advertising nearby, Bluetooth on, BlueZ 5.41+. " +
      `(${detail})`
    );
  }
  return (
    "No mesh device found. Keep BitChat/Offline open nearby, then try again — " +
    `or use “Browse all devices”. (${detail})`
  );
}
