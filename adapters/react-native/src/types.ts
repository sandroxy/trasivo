export type TransferState = 'queued' | 'running' | 'finalizing' | 'succeeded' | 'failed' | 'canceled';
export type TransferLanguage = 'zh-Hans' | 'zh-Hant' | 'en' | 'ja';
export type TransferResult = Readonly<Record<string, string>>;

export interface TransferTask {
  readonly id: string;
  readonly attemptId: string;
  readonly clientId: string;
  readonly title: string;
  readonly direction: 'upload' | 'download';
  readonly state: TransferState;
  readonly completedBytes: number;
  /** null means the server did not provide a length. */
  readonly totalBytes: number | null;
  readonly attempt: number;
  readonly errorCode: string | null;
  readonly result: TransferResult;
  readonly canRetry: boolean;
  readonly canCancel: boolean;
  readonly isActive: boolean;
}

export interface TransferAttempt {
  readonly taskId: string;
  readonly attemptId: string;
  /** Aborted when native no longer accepts this callback. */
  readonly signal: AbortSignal;
}

export interface HTTPRequest {
  url: string;
  headers?: Record<string, string>;
}

export type DownloadDestination =
  | { kind: 'file'; uri: string }
  | { kind: 'media'; media: 'image' | 'video'; filename: string; mimeType: string };

export interface DownloadRequest extends HTTPRequest {
  destination: DownloadDestination;
}

export interface UploadRequest extends HTTPRequest {
  method?: 'POST' | 'PUT' | 'PATCH';
  body: {
    /** A readable, app-owned file:// URI, retained by the host until history removal. */
    uri: string;
    mimeType: string;
    /** Omit to send the raw file; multipart is an HTTP body format, not resumable upload. */
    multipart?: { fieldName: string; filename: string; fields?: Record<string, string> };
  };
}

export interface UploadResponse {
  readonly status: number;
  readonly headers: Readonly<Record<string, string>>;
  /** UTF-8 response, limited to 1 MiB by the native HTTP operation. Never stored in history. */
  readonly body: string;
}

interface TaskOptions {
  title: string;
  /** Called after this task leaves native history. Release only resources owned by this task. */
  onRemoved?: () => void;
}

export interface DownloadOptions extends TaskOptions {
  /** Invoked for every attempt, including retry from the native panel. */
  prepare(attempt: TransferAttempt): DownloadRequest | Promise<DownloadRequest>;
}

export interface UploadOptions extends TaskOptions {
  prepare(attempt: TransferAttempt): UploadRequest | Promise<UploadRequest>;
  /** Must reject/throw on application-level failure; return only safe, small result metadata. */
  validate(response: UploadResponse, attempt: TransferAttempt): TransferResult | Promise<TransferResult>;
}

export interface TransferUIConfiguration {
  language?: TransferLanguage;
  title?: string;
  /** Six-digit #RRGGBB colors. Missing values use the native default palette. */
  theme?: Partial<Record<'primary' | 'background' | 'surface' | 'text' | 'mutedText' | 'border' | 'success' | 'danger', string>>;
}
