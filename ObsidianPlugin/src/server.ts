import net, { AddressInfo, Socket } from "node:net";
import Bonjour, { Service } from "bonjour-service";
import {
  ClientMessage,
  DRAW_PAD_PROTOCOL_VERSION,
  DRAW_PAD_SERVICE_TYPE,
  FrameDecoder,
  ServerMessage,
  decodeJSON,
  frameJSON,
  isHello,
} from "./protocol";

export interface PairingRequest {
  deviceName: string;
  accept(): void;
  reject(): void;
}

export class DrawPadServer {
  private readonly tcpServer = net.createServer((socket) => this.handleConnection(socket));
  private bonjour: Bonjour | null = null;
  private bonjourService: Service | null = null;
  private pending: { socket: Socket; deviceName: string; decided: boolean } | null = null;
  private active: { socket: Socket; deviceName: string } | null = null;
  private rememberedDevices = new Set<string>();
  private port = 0;

  onPairingRequest: ((request: PairingRequest) => void) | null = null;
  onClientConnected: ((deviceName: string) => void) | null = null;
  onClientDisconnected: ((deviceName: string | null) => void) | null = null;
  onMessage: ((message: ClientMessage) => void) | null = null;
  onError: ((error: Error) => void) | null = null;

  constructor(private readonly serverName: string) {
    this.tcpServer.on("error", (error) => this.onError?.(error));
  }

  get clientName(): string | null {
    return this.active?.deviceName ?? null;
  }

  get advertisedPort(): number {
    return this.port;
  }

  start(): Promise<void> {
    if (this.tcpServer.listening) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const onError = (error: Error) => {
        this.tcpServer.off("listening", onListening);
        reject(error);
      };
      const onListening = () => {
        this.tcpServer.off("error", onError);
        const address = this.tcpServer.address() as AddressInfo;
        this.port = address.port;
        this.bonjour ??= new Bonjour();
        // `_drawpad._tcp` -> `drawpad`. bonjour-service 会自行补齐 `_` 和协议后缀。
        const serviceType = DRAW_PAD_SERVICE_TYPE.replace(/^_/, "").replace(/\._tcp$/, "");
        this.bonjourService = this.bonjour.publish({
          name: this.serverName,
          type: serviceType,
          protocol: "tcp",
          port: this.port,
        });
        resolve();
      };
      this.tcpServer.once("error", onError);
      this.tcpServer.once("listening", onListening);
      this.tcpServer.listen(0, "0.0.0.0");
    });
  }

  stop(): void {
    this.bonjourService?.stop();
    this.bonjourService = null;
    this.bonjour?.destroy();
    this.bonjour = null;
    this.pending?.socket.destroy();
    this.active?.socket.destroy();
    this.pending = null;
    this.active = null;
    if (this.tcpServer.listening) this.tcpServer.close();
    this.port = 0;
  }

  send(message: ServerMessage): void {
    if (this.active) this.sendTo(this.active.socket, message);
  }

  disconnectClient(): void {
    const active = this.active;
    if (!active) return;
    this.sendTo(active.socket, { sessionEnded: { reason: "Obsidian 已断开连接" } });
    active.socket.end();
  }

  private handleConnection(socket: Socket): void {
    socket.setNoDelay(true);
    if (this.active || this.pending) {
      this.sendTo(socket, { rejected: { reason: "已有其他设备连接此 Obsidian Vault" } });
      socket.end();
      return;
    }

    const pending = { socket, deviceName: "未知设备", decided: false };
    this.pending = pending;
    setTimeout(() => {
      if (this.pending?.socket === socket && !pending.decided) this.rejectPending(pending);
    }, 30_000);
    const decoder = new FrameDecoder();

    socket.on("data", (chunk: Buffer) => {
      for (const payload of decoder.feed(chunk)) {
        const message = decodeJSON<ClientMessage>(payload);
        if (!message) {
          socket.destroy();
          return;
        }
        if (!this.active) {
          this.handleHello(pending, message);
        } else if (this.active.socket === socket) {
          this.onMessage?.(message);
        }
      }
    });
    socket.on("close", () => {
      if (this.pending?.socket === socket) this.pending = null;
      if (this.active?.socket === socket) {
        const name = this.active.deviceName;
        this.active = null;
        this.onClientDisconnected?.(name);
      }
    });
    socket.on("error", () => socket.destroy());
  }

  private handleHello(pending: { socket: Socket; deviceName: string; decided: boolean }, message: ClientMessage): void {
    if (!isHello(message)) {
      pending.socket.destroy();
      return;
    }
    const { deviceName, protocolVersion } = message.hello;
    pending.deviceName = deviceName;
    if (protocolVersion !== DRAW_PAD_PROTOCOL_VERSION) {
      this.sendTo(pending.socket, { rejected: { reason: "版本不兼容，请更新 DrawPad 或插件" } });
      pending.socket.end();
      this.pending = null;
      return;
    }
    const request: PairingRequest = {
      deviceName,
      accept: () => this.acceptPending(pending),
      reject: () => this.rejectPending(pending),
    };
    if (this.rememberedDevices.has(deviceName)) request.accept();
    else if (this.onPairingRequest) this.onPairingRequest(request);
    else request.reject();
  }

  private acceptPending(pending: { socket: Socket; deviceName: string; decided: boolean }): void {
    if (pending.decided || this.pending?.socket !== pending.socket) return;
    pending.decided = true;
    this.pending = null;
    this.active = { socket: pending.socket, deviceName: pending.deviceName };
    this.rememberedDevices.add(pending.deviceName);
    this.sendTo(pending.socket, { helloAccepted: { serverName: this.serverName } });
    this.onClientConnected?.(pending.deviceName);
  }

  private rejectPending(pending: { socket: Socket; deviceName: string; decided: boolean }): void {
    if (pending.decided || this.pending?.socket !== pending.socket) return;
    pending.decided = true;
    this.pending = null;
    this.sendTo(pending.socket, { rejected: { reason: "Obsidian 拒绝了连接请求" } });
    pending.socket.end();
  }

  private sendTo(socket: Socket, message: ServerMessage): void {
    if (!socket.destroyed) socket.write(frameJSON(message));
  }
}
