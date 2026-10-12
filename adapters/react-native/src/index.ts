import { NativeEventEmitter, PermissionsAndroid, Platform } from 'react-native';
import native from './specs/NativeTrasivo';
import type {
  DownloadOptions, TransferTask, TransferUIConfiguration, UploadOptions, UploadResponse,
} from './types';
export type * from './types';

type Registration = { options: DownloadOptions | UploadOptions; id?: string };
type Snapshot = { revision: number; tasks: TransferTask[] };
type Event = Snapshot & {
  session: string; kind: 'snapshot' | 'prepare' | 'validate' | 'expired';
  token: string; clientId: string; taskId: string; attemptId: string; response: UploadResponse;
};

/** One owner per RN runtime. Import this singleton outside screen components. */
class TransferClient {
  private readonly session = `rn-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  private ready?: Promise<void>;
  private revision = -1;
  private sequence = 0;
  private tasks: readonly TransferTask[] = Object.freeze([]);
  private readonly registrations = new Map<string, Registration>();
  private readonly callbacks = new Map<string, AbortController>();
  private readonly observers = new Set<(tasks: readonly TransferTask[]) => void>();
  private subscription?: ReturnType<NativeEventEmitter['addListener']>;

  private async initialize(): Promise<void> {
    if (!native) throw new Error('Trasivo native adapter is not installed. Rebuild the native application.');
    if (!this.ready) {
      this.subscription = new NativeEventEmitter(native).addListener('TrasivoEvent', (json: string) => {
        const event = JSON.parse(json) as Event;
        if (event.session !== this.session) return;
        if (event.kind === 'snapshot') this.accept(event);
        else if (event.kind === 'expired') {
          this.callbacks.get(event.token)?.abort(); this.callbacks.delete(event.token);
        }
        else void this.handle(event);
      });
      this.ready = this.invoke<Snapshot>('open').then(snapshot => { this.accept(snapshot); }).catch(error => {
        this.subscription?.remove(); this.subscription = undefined; this.ready = undefined;
        throw error;
      });
    }
    await this.ready;
  }

  private async invoke<T>(op: string, value: object = {}): Promise<T> {
    if (!native) throw new Error('Trasivo native adapter is not installed.');
    return JSON.parse(await native.execute(JSON.stringify({ ...value, op, session: this.session }))) as T;
  }

  private accept(snapshot: Snapshot): void {
    if (snapshot.revision <= this.revision) return;
    this.revision = snapshot.revision;
    this.tasks = Object.freeze(snapshot.tasks.map(task => Object.freeze({ ...task, result: Object.freeze(task.result) })));
    this.releaseRemoved();
    for (const observer of this.observers) {
      try { observer(this.tasks); } catch { /* observers are isolated */ }
    }
  }

  private releaseRemoved(): void {
    const ids = new Set(this.tasks.map(task => task.id));
    for (const [clientId, registration] of this.registrations) {
      if (registration.id && !ids.has(registration.id)) {
        this.registrations.delete(clientId);
        // A host cleanup error must not break snapshots or other task callbacks.
        try { registration.options.onRemoved?.(); } catch { /* host-owned cleanup */ }
      }
    }
  }

  private async handle(event: Event): Promise<void> {
    const registration = this.registrations.get(event.clientId);
    const controller = new AbortController();
    this.callbacks.set(event.token, controller);
    const attempt = { taskId: event.taskId, attemptId: event.attemptId, signal: controller.signal };
    try {
      if (!registration) throw new Error('No host operation');
      const value = event.kind === 'prepare'
        ? await registration.options.prepare(attempt)
        : await (registration.options as UploadOptions).validate(event.response, attempt);
      if (!controller.signal.aborted) await this.invoke('reply', { token: event.token, value });
    } catch {
      if (!controller.signal.aborted) {
        await this.invoke('reply', { token: event.token,
          errorCode: event.kind === 'prepare' ? 'request_failed' : 'response_rejected' }).catch(() => undefined);
      }
    } finally { this.callbacks.delete(event.token); }
  }

  private async enqueue(direction: 'download' | 'upload', options: DownloadOptions | UploadOptions): Promise<string> {
    await this.initialize();
    if (!options.title.trim() || typeof options.prepare !== 'function' ||
        (direction === 'upload' && typeof (options as UploadOptions).validate !== 'function')) {
      throw new Error('A title, request provider and upload validator are required.');
    }
    const clientId = `${this.session}-${++this.sequence}`;
    const registration: Registration = { options };
    this.registrations.set(clientId, registration);
    try {
      const { id, snapshot } = await this.invoke<{ id: string; snapshot: Snapshot }>('enqueue', { clientId, title: options.title, direction });
      registration.id = id;
      this.accept(snapshot);
      // Events may have removed a very short task before the enqueue promise
      // arrives. Reconcile against the newest snapshot after binding its ID.
      this.releaseRemoved();
      return id;
    } catch (error) {
      if (!registration.id) this.registrations.delete(clientId);
      throw error;
    }
  }

  download(options: DownloadOptions): Promise<string> { return this.enqueue('download', options); }
  upload(options: UploadOptions): Promise<string> { return this.enqueue('upload', options); }

  /** Subscribe synchronously; call refresh() to initialize and report native installation errors. */
  subscribe(observer: (tasks: readonly TransferTask[]) => void): () => void {
    this.observers.add(observer);
    observer(this.tasks);
    return () => { this.observers.delete(observer); };
  }
  getSnapshot(): readonly TransferTask[] { return this.tasks; }
  async refresh(): Promise<void> { await this.initialize(); this.accept(await this.invoke<Snapshot>('snapshot')); }
  async retry(id: string): Promise<boolean> { await this.initialize(); return this.invoke('retry', { id }); }
  async cancel(id: string): Promise<boolean> { await this.initialize(); return this.invoke('cancel', { id }); }
  async remove(id: string): Promise<boolean> { await this.initialize(); return this.invoke('remove', { id }); }
  /** Account switches must first cancel/wait for active tasks; reset never interrupts a destination commit. */
  async clearHistory(): Promise<void> { await this.initialize(); await this.invoke('clear'); await this.refresh(); }

  async requestMediaPermission(): Promise<boolean> {
    await this.initialize();
    if (Platform.OS === 'android' && Number(Platform.Version) >= 23 && Number(Platform.Version) <= 28) {
      return await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.WRITE_EXTERNAL_STORAGE) === PermissionsAndroid.RESULTS.GRANTED;
    }
    return this.invoke('mediaPermission');
  }
  async setPresentation(visible: boolean, configuration: TransferUIConfiguration = {}): Promise<void> {
    await this.initialize(); await this.invoke('presentation', { visible, configuration });
  }
  async showPanel(): Promise<void> { await this.initialize(); await this.invoke('panel'); }
}

export const trasivo = new TransferClient();
