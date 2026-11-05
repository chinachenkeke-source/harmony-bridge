import { socket } from '@kit.NetworkKit';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { common } from '@kit.AbilityKit';
import { wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { util } from '@kit.ArkTS';
import nativeBridge from 'libbridge.so';

class VideoStatus {
  stage: number = 0;
  state: number = -1;
  error: number = 0;
  frames: number = 0;
  bytes: number = 0;
}

class SharedFile {
  id: string = '';
  name: string = '';
  size: number = 0;
  received: boolean = false;
  ready: boolean = true;
}
class RequestBody {
  id: string = '';
  name: string = '';
  offset: number = 0;
  data: string = '';
  final: boolean = false;
  transport: string = '';
}
class Reply {
  ok: boolean = true;
  error: string = '';
  files: SharedFile[] = [];
  id: string = '';
  data: string = '';
  size: number = 0;
  eof: boolean = false;
  video: VideoStatus = new VideoStatus();
}

// Only listens on phone loopback. USB/wireless HDC port forwarding carries requests.
class FileService {
  server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
  token: string = util.generateRandomUUID().replace(/-/g, '');
  files: SharedFile[] = [];
  directory: string = '';
  changed: () => void = () => {};
  base64: util.Base64Helper = new util.Base64Helper();
  started: boolean = false;
  lastTransport: string = '';
  lastTransportAt: number = 0;

  async start(directory: string): Promise<void> {
    if (this.started) { return; }
    this.directory = directory + '/bridge';
    try { fs.mkdirSync(this.directory); } catch (_) {}
    // Metadata is rebuilt only from this app's own manifest, never by scanning user files.
    try {
      const manifest = fs.readTextSync(this.directory + '/manifest.json');
      this.files = JSON.parse(manifest) as SharedFile[];
      this.files = this.files.filter((item: SharedFile) => item.ready && /^[a-f0-9-]{36}$/.test(item.id));
    } catch (_) { this.files = []; }
    await this.server.listen({ address: '127.0.0.1', port: 28765, family: 1 });
    this.server.on('connect', (connection: socket.TCPSocketConnection) => {
      let buffer = '';
      let handled = false;
      const timer = setTimeout(() => { connection.close().catch(() => {}); }, 20000);
      connection.on('message', (message: socket.SocketMessageInfo) => {
        if (handled) { return; }
        buffer += util.TextDecoder.create('utf-8').decodeWithStream(new Uint8Array(message.message));
        if (buffer.length > 600000) { handled = true; clearTimeout(timer); connection.close().catch(() => {}); return; }
        const boundary = buffer.indexOf('\r\n\r\n');
        if (boundary < 0) { return; }
        const header = buffer.substring(0, boundary);
        const lengthMatch = /content-length:\s*(\d+)/i.exec(header);
        const length = lengthMatch ? Number(lengthMatch[1]) : 0;
        if (length > 550000) { handled = true; clearTimeout(timer); connection.close().catch(() => {}); return; }
        // JSON request bodies are ASCII because Mac uses escaped Unicode JSON.
        const body = buffer.substring(boundary + 4);
        if (body.length < length) { return; }
        handled = true;
        clearTimeout(timer);
        this.respond(connection, header, body.substring(0, length));
      });
    });
    this.started = true;
    // Only the authorized HDC debug channel can read this private app-sandbox file.
    // The session credential is exchanged automatically; it is never shown to the user.
    const session = fs.openSync(this.directory + '/usb-session', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(session.fd, this.token); } finally { fs.closeSync(session); }
  }

  persist(): void {
    const file = fs.openSync(this.directory + '/manifest.json', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, JSON.stringify(this.files.filter((item: SharedFile) => item.ready))); }
    finally { fs.closeSync(file); }
    this.changed();
  }
  async respond(connection: socket.TCPSocketConnection, header: string, body: string): Promise<void> {
    let reply = new Reply();
    let code = 200;
    const auth = /authorization:\s*Bearer ([^\r\n]+)/i.exec(header);
    if (!auth || auth[1].trim() !== this.token) { reply.ok = false; reply.error = 'USB 会话已更新，请重新连接'; code = 401; }
    else {
      try {
        const meta = JSON.parse(body) as RequestBody;
        if (meta.transport === 'USB' || meta.transport === 'Wi-Fi') {
          const changed = this.lastTransport !== meta.transport;
          this.lastTransport = meta.transport;
          this.lastTransportAt = Date.now();
          if (changed) { this.changed(); }
        }
        const route = header.split('\r\n')[0].split(' ')[1];
        if (route === '/video-status') { reply.video = JSON.parse(nativeBridge.status()) as VideoStatus; }
        else if (route === '/list') { reply.files = this.files.filter((item: SharedFile) => item.ready); }
        else if (route === '/upload') {
          const request = JSON.parse(body) as RequestBody;
          if (!Number.isSafeInteger(request.offset) || request.offset < 0 || request.data.length > 400000) { throw new Error('无效分块'); }
          let item: SharedFile | undefined = this.files.find((file: SharedFile) => file.id === request.id);
          if (!item) {
            if (request.id || request.offset !== 0) { throw new Error('无效传输 ID'); }
            item = new SharedFile(); item.id = util.generateRandomUUID();
            item.name = request.name.replace(/[\/\\\r\n]/g, '_').substring(0, 200) || 'file';
            item.received = true; item.ready = false; this.files.push(item);
          }
          if (item.ready || request.offset !== item.size) { throw new Error('分块顺序错误'); }
          const bytes = this.base64.decodeSync(request.data);
          const handle = fs.openSync(this.directory + '/' + item.id, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
          try { fs.writeSync(handle.fd, bytes.buffer, { offset: request.offset, length: bytes.byteLength }); }
          finally { fs.closeSync(handle); }
          item.size += bytes.byteLength;
          reply.id = item.id; reply.size = item.size;
          if (request.final) { item.ready = true; this.persist(); }
        } else if (route === '/download') {
          const request = JSON.parse(body) as RequestBody;
          const item = this.files.find((file: SharedFile) => file.id === request.id && file.ready);
          if (!item || !Number.isSafeInteger(request.offset) || request.offset < 0 || request.offset > item.size) { throw new Error('文件或偏移无效'); }
          const handle = fs.openSync(this.directory + '/' + item.id, fs.OpenMode.READ_ONLY);
          const chunk = new ArrayBuffer(Math.min(196608, item.size - request.offset));
          let count = 0;
          try { if (chunk.byteLength > 0) { count = fs.readSync(handle.fd, chunk, { offset: request.offset, length: chunk.byteLength }); } }
          finally { fs.closeSync(handle); }
          reply.data = this.base64.encodeToStringSync(new Uint8Array(chunk, 0, count));
          reply.size = item.size; reply.eof = request.offset + count >= item.size;
        } else if (route === '/remove') {
          const request = JSON.parse(body) as RequestBody;
          this.remove(request.id);
        } else { reply.ok = false; reply.error = '未知接口'; code = 404; }
      } catch (error) { reply.ok = false; reply.error = String(error); code = 400; }
    }
    const payload = JSON.stringify(reply);
    const bytes = new util.TextEncoder().encodeInto(payload);
    try {
      await connection.send({ data: `HTTP/1.1 ${code} Result\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: ${bytes.byteLength}\r\nConnection: close\r\n\r\n${payload}` });
    } finally { await connection.close(); }
  }
  async add(uri: string): Promise<void> {
    const source = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const item = new SharedFile(); item.id = util.generateRandomUUID();
    try {
      item.name = new fileUri.FileUri(uri).name || 'shared-file';
      item.size = fs.statSync(source.fd).size;
      const destination = fs.openSync(this.directory + '/' + item.id, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try { await fs.copyFile(source.fd, destination.fd); } finally { fs.closeSync(destination); }
    } finally { fs.closeSync(source); }
    this.files.push(item); this.persist();
  }
  remove(id: string): void {
    const index = this.files.findIndex((item: SharedFile) => item.id === id && item.ready);
    if (index < 0) { throw new Error('共享文件不存在'); }
    fs.unlinkSync(this.directory + '/' + this.files[index].id);
    this.files.splice(index, 1);
    this.persist();
  }
}
const service = new FileService();
let screenShareBackgroundRunning = false;

@Entry
@Component
struct Index {
  @State status: string = '正在启动传输服务…';
  @State entries: SharedFile[] = [];
  @State busy: boolean = false;
  @State ready: boolean = false;
  @State videoMessage: string = '在 Mac 上显示手机画面';
  @State transportLabel: string = '等待 Mac 连接';
  @State videoDiagnostics: string = '';
  @State showDiagnostics: boolean = false;
  @State benchmarkOffset: number = 0;
  @State benchmark: boolean = false;
  private videoTimer: number = -1;
  private transportTimer: number = -1;
  private previousFrames: number = 0;
  private previousTime: number = 0;

  aboutToAppear(): void {
    service.changed = () => {
      this.entries = service.files.filter((item: SharedFile) => item.ready).slice();
      this.transportLabel = this.currentTransportLabel();
    };
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    service.start(context.filesDir).then(() => {
      this.ready = true; service.changed(); this.status = '连接已就绪 · 开启共享后 Mac 将自动显示画面';
    }).catch((error: Error) => { this.status = String(error); });
    if (this.transportTimer !== -1) { clearInterval(this.transportTimer); }
    this.transportTimer = setInterval(() => {
      const label = this.currentTransportLabel();
      if (label !== this.transportLabel) { this.transportLabel = label; }
    }, 2000);
  }
  aboutToDisappear(): void {
    if (this.transportTimer !== -1) { clearInterval(this.transportTimer); this.transportTimer = -1; }
  }
  currentTransportLabel(): string {
    return service.lastTransport && Date.now() - service.lastTransportAt < 10000
      ? 'Mac 当前使用：' + service.lastTransport : '等待 Mac 连接';
  }
  async startVideo(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!screenShareBackgroundRunning) {
        try {
          const agent = await wantAgent.getWantAgent({
            wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: 'EntryAbility' }],
            actionType: wantAgent.OperationType.START_ABILITY,
            requestCode: 1,
            actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
          });
          await backgroundTaskManager.startBackgroundRunning(context,
            backgroundTaskManager.BackgroundMode.MULTI_DEVICE_CONNECTION, agent);
          screenShareBackgroundRunning = true;
        } catch (error) { this.videoDiagnostics = `后台保持连接未启用：${String(error)}`; }
      }
      const result = nativeBridge.start(service.token);
      if (result !== 0) { const diagnostic = JSON.parse(nativeBridge.status()) as VideoStatus; this.videoMessage = '无法开启共享，请查看诊断信息'; this.videoDiagnostics = `阶段 ${diagnostic.stage} · 错误 ${result}`; await this.stopBackgroundTask(); return; }
      if (this.videoTimer !== -1) { clearInterval(this.videoTimer); }
      this.previousFrames = 0; this.previousTime = Date.now();
      this.videoMessage = '请在系统提示中允许共享整个屏幕';
      this.videoTimer = setInterval(() => {
        const status = JSON.parse(nativeBridge.status()) as VideoStatus;
        const now = Date.now();
        const fps = (status.frames - this.previousFrames) * 1000 / Math.max(1, now - this.previousTime);
        this.previousTime = now; this.previousFrames = status.frames;
        this.videoDiagnostics = `默认 60 FPS · 编码 ${fps.toFixed(1)} FPS · 状态 ${status.state} · 错误 ${status.error}`;
        if (status.error !== 0) { this.videoMessage = '共享出现异常，请查看诊断信息'; }
        else if (status.state === 1) { this.videoMessage = '已取消屏幕共享'; this.stopBackgroundTask(); }
        else if ([2, 3, 4, 10].includes(status.state)) { this.videoMessage = '屏幕共享已结束'; this.stopBackgroundTask(); }
        else if ([11, 13].includes(status.state)) { this.videoMessage = '屏幕共享已暂停'; }
        else if (status.state >= 0) { this.videoMessage = '正在共享屏幕'; }
      }, 1000);
    } catch (error) { this.videoMessage = String(error); }
  }
  async stopBackgroundTask(): Promise<void> {
    if (!screenShareBackgroundRunning) { return; }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try { await backgroundTaskManager.stopBackgroundRunning(context); }
    catch (error) { this.videoDiagnostics = `停止后台任务失败：${String(error)}`; }
    screenShareBackgroundRunning = false;
  }
  async choose(photos: boolean): Promise<void> {
    if (this.busy || !service.started) { return; }
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let uris: string[] = [];
      if (photos) {
        const result = await new photoAccessHelper.PhotoViewPicker().select({ MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE, maxSelectNumber: 20 });
        uris = result.photoUris;
      } else { uris = await new picker.DocumentViewPicker(context).select({ maxSelectNumber: 20 }); }
      for (const uri of uris) { await service.add(uri); }
      this.status = `已添加 ${uris.length} 个文件，在 Mac 刷新即可接收`;
    } catch (error) { this.status = String(error); }
    finally { this.busy = false; }
  }
  async save(item: SharedFile): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const uris = await new picker.DocumentViewPicker(context).save({ newFileNames: [item.name] });
      if (uris.length === 0) { return; }
      const input = fs.openSync(service.directory + '/' + item.id, fs.OpenMode.READ_ONLY);
      try {
        const output = fs.openSync(uris[0], fs.OpenMode.READ_WRITE);
        try { await fs.copyFile(input.fd, output.fd); } finally { fs.closeSync(output); }
      } finally { fs.closeSync(input); }
      this.status = '已保存：' + item.name;
    } catch (error) { this.status = String(error); }
    finally { this.busy = false; }
  }
  remove(item: SharedFile): void {
    try { service.remove(item.id); this.status = '已移除共享：' + item.name; }
    catch (error) { this.status = String(error); }
  }
  build() {
    Scroll() {
      Column({ space: 18 }) {
        Text('Harmony Bridge').fontSize(30).fontWeight(FontWeight.Bold)
        Text('与 Mac 互传照片、视频和文档').fontSize(16).fontColor('#667085')
        Text(this.status).fontSize(14).fontColor('#2468e8')
        Text(this.transportLabel).fontSize(18).fontWeight(FontWeight.Medium).fontColor('#2468e8')
        Column({ space: 10 }) {
          Text('流畅投屏').fontSize(22).fontWeight(FontWeight.Bold)
          Text(this.videoMessage).fontSize(14).fontColor('#2468e8')
          Row({ space: 12 }) {
            Button('开启屏幕共享').onClick(() => { this.startVideo(); }).enabled(this.ready)
            Button('停止共享').onClick(() => {
              nativeBridge.stop();
              this.stopBackgroundTask();
              if (this.videoTimer !== -1) { clearInterval(this.videoTimer); this.videoTimer = -1; }
              this.videoMessage = '屏幕共享已停止';
            })
          }
          Button(this.showDiagnostics ? '收起诊断' : '查看诊断').type(ButtonType.Normal).backgroundColor(Color.Transparent).fontColor('#667085').fontSize(13).onClick(() => { this.showDiagnostics = !this.showDiagnostics; })
          if (this.showDiagnostics) {
          Text(this.videoDiagnostics).fontSize(13).fontColor('#667085')
          Row({ space: 12 }) {
            Text('帧率测试动画').fontSize(14)
            Toggle({ type: ToggleType.Switch, isOn: this.benchmark }).onChange((enabled: boolean) => {
              this.benchmark = enabled;
              this.getUIContext().animateTo({ duration: enabled ? 1000 : 1, iterations: enabled ? -1 : 1, playMode: PlayMode.Alternate, curve: Curve.Linear }, () => {
                this.benchmarkOffset = enabled ? 160 : 0;
              });
            })
          }
          Row().width(48).height(16).backgroundColor('#2468e8').borderRadius(8).translate({ x: this.benchmarkOffset })
          }
        }.padding(16).width('100%').backgroundColor('#f0f6ff').borderRadius(16)
        Text('通过 USB 或无线调试连接 Mac，允许共享整个屏幕后即可返回桌面。').fontSize(13).fontColor('#667085')
        Row({ space: 12 }) {
          Button('选择照片 / 视频').onClick(() => { this.choose(true); }).enabled(!this.busy && this.ready)
          Button('选择文档').onClick(() => { this.choose(false); }).enabled(!this.busy && this.ready)
        }
        Text('共享文件 · ' + this.entries.length).fontSize(20).fontWeight(FontWeight.Bold).width('100%')
        ForEach(this.entries, (item: SharedFile) => {
          Column({ space: 8 }) {
            Text(item.name).fontSize(16).width('100%')
            Text(`${(item.size / 1024 / 1024).toFixed(2)} MB · ${item.received ? '来自 Mac' : '已选给 Mac'}`).fontSize(13).fontColor('#667085')
            Row({ space: 10 }) {
              if (item.received) { Button('保存到文件管理…').onClick(() => { this.save(item); }).enabled(!this.busy) }
              Button('移除共享').type(ButtonType.Normal).onClick(() => { this.remove(item); }).enabled(!this.busy)
            }
          }.padding(16).width('100%').backgroundColor('#f5f6f8').borderRadius(12)
        }, (item: SharedFile) => item.id)
      }.padding(24).width('100%')
    }.width('100%').height('100%').align(Alignment.Top).backgroundColor(Color.White)
  }
}
