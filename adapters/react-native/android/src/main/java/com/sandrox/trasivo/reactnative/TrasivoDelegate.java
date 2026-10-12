package com.sandrox.trasivo.reactnative;

import android.app.Activity;
import android.graphics.Color;
import android.os.Handler;
import android.os.Looper;
import android.widget.FrameLayout;
import com.facebook.react.bridge.LifecycleEventListener;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.modules.core.DeviceEventManagerModule;
import com.sandrox.trasivo.*;
import com.sandrox.trasivo.storage.MediaDestination;
import com.sandrox.trasivo.ui.TransferOverlay;
import com.sandrox.trasivo.ui.TransferUIConfiguration;
import java.io.File;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import okhttp3.*;
import org.json.*;

/** Runtime-scoped owner. All bridge/presentation state is confined to the main looper. */
final class TrasivoDelegate implements LifecycleEventListener {
    private final ReactApplicationContext react;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService workers = Executors.newCachedThreadPool();
    private final TransferCenter center = new TransferCenter(3, 200, workers, main::post);
    private final OkHttpClient http = new OkHttpClient.Builder().retryOnConnectionFailure(false).build();
    private final Map<String, String> clients = new HashMap<>();
    private final Map<String, Pending> pending = new HashMap<>();
    private final TransferCenter.Subscription subscription;
    private TransferOverlay overlay;
    private Activity overlayActivity;
    private TransferUIConfiguration configuration = new TransferUIConfiguration();
    private boolean visible, closed;
    private String session;
    private long revision;

    TrasivoDelegate(ReactApplicationContext react) {
        this.react = react;
        subscription = center.observe(ignored -> { if (!closed && session != null) emit(snapshotEvent()); });
        react.addLifecycleEventListener(this);
    }

    void execute(String payload, Promise promise) {
        main.post(() -> {
            try {
                if (closed || payload.length() > 2 * 1024 * 1024) throw new IllegalArgumentException();
                JSONObject command = new JSONObject(payload);
                String op = command.getString("op"), owner = text(command, "session", 200);
                if (op.equals("open") && session == null) session = owner;
                if (!owner.equals(session)) { promise.reject("runtime_mismatch", "Trasivo belongs to another runtime."); return; }
                Object result;
                switch (op) {
                    case "open": case "snapshot": result = snapshotEvent(); break;
                    case "enqueue": {
                        String clientId = text(command, "clientId", 240);
                        if (clients.containsValue(clientId)) throw new IllegalArgumentException();
                        String direction = command.getString("direction");
                        if (!direction.equals("upload") && !direction.equals("download")) throw new IllegalArgumentException();
                        boolean upload = direction.equals("upload");
                        String id = center.enqueue(new TransferTask.Request(text(command, "title", 512),
                            upload ? TransferTask.Direction.UPLOAD : TransferTask.Direction.DOWNLOAD),
                            (context, completion) -> {
                                Attempt attempt = new Attempt(context, completion, clientId, upload);
                                main.post(() -> attempt.prepare());
                                return attempt::cancel;
                            });
                        clients.put(id, clientId); result = json("id", id, "snapshot", snapshotEvent()); break;
                    }
                    case "reply": {
                        Pending callback = pending.remove(command.getString("token"));
                        result = callback != null;
                        if (callback != null) {
                            main.removeCallbacks(callback.timeout);
                            if (command.has("errorCode")) callback.attempt.fail(code(command.getString("errorCode")));
                            else {
                                try { callback.accept.accept(command.getJSONObject("value")); }
                                catch (Exception error) { callback.attempt.fail(callback.kind.equals("prepare") ? "request_failed" : "response_rejected"); }
                            }
                        }
                        break;
                    }
                    case "retry": result = center.retry(command.getString("id")); break;
                    case "cancel": result = center.cancel(command.getString("id")); break;
                    case "remove": result = center.remove(command.getString("id")); break;
                    case "clear": {
                        if (center.snapshot().stream().anyMatch(TransferTask::isActive)) {
                            promise.reject("tasks_active", "Wait for active tasks before clearing history."); return;
                        }
                        for (TransferTask task : center.snapshot()) center.remove(task.id);
                        result = JSONObject.NULL; break;
                    }
                    case "mediaPermission": result = true; break; // RN requests legacy runtime permission explicitly.
                    case "presentation":
                        configuration = configuration(command.getJSONObject("configuration"));
                        visible = command.getBoolean("visible");
                        if (visible) { attach(); overlay.updateConfiguration(configuration); } else detach();
                        result = JSONObject.NULL; break;
                    case "panel":
                        if (!visible) throw new IllegalStateException();
                        attach(); overlay.showPanel(); result = JSONObject.NULL; break;
                    default: throw new IllegalArgumentException();
                }
                String encoded = new JSONArray().put(result).toString();
                promise.resolve(encoded.substring(1, encoded.length() - 1));
            } catch (Exception error) {
                // Do not expose URLs, credentials, response bodies or local paths through bridge errors.
                promise.reject("invalid_operation", "Trasivo could not perform this operation.");
            }
        });
    }

    private JSONObject snapshotEvent() {
        List<TransferTask> tasks = center.snapshot();
        Set<String> ids = new HashSet<>(); JSONArray values = new JSONArray();
        for (TransferTask task : tasks) {
            ids.add(task.id);
            values.put(json("id", task.id, "attemptId", task.attemptId, "clientId", clients.get(task.id),
                "title", task.title, "direction", task.direction.name().toLowerCase(Locale.ROOT),
                "state", task.state.name().toLowerCase(Locale.ROOT), "completedBytes", task.completedBytes,
                "totalBytes", task.totalBytes < 0 ? JSONObject.NULL : task.totalBytes, "attempt", task.attempt,
                "errorCode", task.errorCode, "result", new JSONObject(task.result),
                "canRetry", task.canRetry(), "canCancel", task.canCancel(), "isActive", task.isActive()));
        }
        clients.keySet().retainAll(ids);
        return json("kind", "snapshot", "revision", ++revision, "tasks", values);
    }

    private void emit(JSONObject event) {
        if (closed || session == null) return;
        try {
            event.put("session", session);
            react.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class).emit("TrasivoEvent", event.toString());
        } catch (RuntimeException | JSONException ignored) { /* runtime invalidation races with queued events */ }
    }

    private interface Reply { void accept(JSONObject value) throws Exception; }
    private final class Pending {
        final Attempt attempt; final String kind; final Reply accept; final Runnable timeout;
        Pending(Attempt attempt, String kind, Reply accept, Runnable timeout) {
            this.attempt = attempt; this.kind = kind; this.accept = accept; this.timeout = timeout;
        }
    }

    private final class Attempt {
        final TransferContext context; final TransferOperation.Completion completion;
        final String clientId; final boolean upload;
        final AtomicBoolean canceled = new AtomicBoolean();
        final AtomicReference<TransferOperation.Cancellation> network = new AtomicReference<>();
        boolean finished;
        Attempt(TransferContext context, TransferOperation.Completion completion, String clientId, boolean upload) {
            this.context = context; this.completion = completion; this.clientId = clientId; this.upload = upload;
        }
        void prepare() { ask("prepare", null, value -> workers.execute(() -> start(value))); }
        void ask(String kind, JSONObject response, Reply reply) {
            if (finished || canceled.get()) return;
            if (closed) { fail("host_unavailable"); return; }
            try { context.checkCanceled(); } catch (Exception error) { cancel(); return; }
            String token = UUID.randomUUID().toString();
            Runnable timeout = () -> {
                if (pending.remove(token) != null) {
                    emit(json("kind", "expired", "token", token)); fail("host_timeout");
                }
            };
            pending.put(token, new Pending(this, kind, reply, timeout));
            main.postDelayed(timeout, 30_000);
            emit(json("kind", kind, "token", token, "clientId", clientId, "taskId", context.taskId,
                "attemptId", context.attemptId, "response", response));
        }
        void start(JSONObject value) {
            try {
                context.checkCanceled();
                Request.Builder request = request(value);
                TransferOperation operation;
                AtomicReference<JSONObject> response = new AtomicReference<>();
                if (upload) {
                    JSONObject body = value.getJSONObject("body");
                    File source = localFile(body.getString("uri"));
                    if (!source.isFile() || !source.canRead()) throw new IllegalArgumentException();
                    String mime = text(body, "mimeType", 200);
                    RequestBody bytes = RequestBody.create(MediaType.get(mime), source);
                    if (body.has("multipart")) {
                        JSONObject form = body.getJSONObject("multipart");
                        MultipartBody.Builder multipart = new MultipartBody.Builder().setType(MultipartBody.FORM);
                        Map<String, String> fields = strings(optionalObject(form, "fields"));
                        for (Map.Entry<String, String> field : fields.entrySet()) multipart.addFormDataPart(field.getKey(), field.getValue());
                        multipart.addFormDataPart(text(form, "fieldName", 200), filename(form.getString("filename")), bytes);
                        bytes = multipart.build();
                    }
                    String method = value.has("method") ? text(value, "method", 10) : "POST";
                    if (!Arrays.asList("POST", "PUT", "PATCH").contains(method)) throw new IllegalArgumentException();
                    Request prepared = request.method(method, bytes).build();
                    operation = HttpTransfers.upload(http, () -> prepared, (status, headers, data) -> {
                        response.set(json("status", status, "headers", new JSONObject(headers), "body", new String(data, StandardCharsets.UTF_8)));
                        return Collections.emptyMap();
                    });
                } else {
                    JSONObject destination = value.getJSONObject("destination");
                    HttpTransfers.DownloadDestination target;
                    if (destination.getString("kind").equals("file")) {
                        target = HttpTransfers.file(localFile(destination.getString("uri")));
                    } else if (destination.getString("kind").equals("media")) {
                        String media = destination.getString("media"), mime = text(destination, "mimeType", 200);
                        if ((!media.equals("image") && !media.equals("video")) || !mime.startsWith(media + "/")) throw new IllegalArgumentException();
                        target = new MediaDestination(react, filename(destination.getString("filename")), mime);
                    } else throw new IllegalArgumentException();
                    Request prepared = request.get().build();
                    operation = HttpTransfers.download(http, () -> prepared, new File(react.getCacheDir(), "trasivo"), target);
                }
                TransferOperation.Cancellation running = operation.start(context, new TransferOperation.Completion() {
                    public void fail(String code) { main.post(() -> Attempt.this.fail(code)); }
                    public void succeed(Map<String, String> result) {
                        main.post(() -> {
                            if (upload) ask("validate", response.get(), value -> Attempt.this.succeed(strings(value)));
                            else Attempt.this.succeed(result);
                        });
                    }
                });
                network.set(running);
                if (canceled.get() && running != null) running.cancel();
            } catch (Exception error) { main.post(() -> fail("request_failed")); }
        }
        void succeed(Map<String, String> result) {
            if (finished || canceled.get()) return;
            finished = true; release(); completion.succeed(result);
        }
        void fail(String error) {
            if (finished || canceled.get()) return;
            finished = true; release(); completion.fail(error);
        }
        void release() {
            network.set(null);
            for (String token : new ArrayList<>(pending.keySet())) {
                Pending callback = pending.get(token);
                if (callback.attempt == this) {
                    pending.remove(token); main.removeCallbacks(callback.timeout);
                    emit(json("kind", "expired", "token", token));
                }
            }
        }
        void cancel() {
            canceled.set(true);
            TransferOperation.Cancellation running = network.getAndSet(null);
            if (running != null) running.cancel();
            main.post(this::release);
        }
    }

    private static Request.Builder request(JSONObject value) throws Exception {
        String url = text(value, "url", 16_384);
        URI uri = new URI(url);
        if (!Arrays.asList("http", "https").contains(uri.getScheme()) || uri.getHost() == null || uri.getUserInfo() != null) throw new IllegalArgumentException();
        Request.Builder request = new Request.Builder().url(url);
        for (Map.Entry<String, String> header : strings(optionalObject(value, "headers")).entrySet()) {
            String name = header.getKey();
            if (Arrays.asList("range", "content-length", "content-type", "host", "transfer-encoding").contains(name.toLowerCase(Locale.ROOT))) throw new IllegalArgumentException();
            request.header(name, header.getValue());
        }
        return request;
    }
    private static File localFile(String value) throws Exception {
        URI uri = new URI(value);
        if (!"file".equals(uri.getScheme()) || uri.getQuery() != null || uri.getFragment() != null || uri.getAuthority() != null) throw new IllegalArgumentException();
        return new File(uri);
    }
    private static String filename(String value) {
        if (value.isEmpty() || value.length() > 255 || value.equals(".") || value.equals("..") || value.contains("/") || value.contains("\\")) throw new IllegalArgumentException();
        for (int i = 0; i < value.length(); i++) if (Character.isISOControl(value.charAt(i))) throw new IllegalArgumentException();
        return value;
    }
    private static String text(JSONObject object, String name, int limit) throws JSONException {
        Object value = object.get(name);
        if (!(value instanceof String) || ((String) value).trim().isEmpty() || ((String) value).length() > limit) throw new IllegalArgumentException();
        return (String) value;
    }
    private static String code(String value) { return value.matches("[a-z][a-z0-9_]{0,127}") ? value : "operation_failed"; }
    private static JSONObject optionalObject(JSONObject value, String key) throws JSONException {
        return value.has(key) ? value.getJSONObject(key) : null;
    }
    private static Map<String, String> strings(JSONObject object) throws JSONException {
        Map<String, String> values = new LinkedHashMap<>();
        if (object == null) return values;
        if (object.length() > 64 || object.toString().length() > 16_384) throw new IllegalArgumentException();
        Iterator<String> keys = object.keys();
        while (keys.hasNext()) {
            String key = keys.next(); Object value = object.get(key);
            if (key.isEmpty() || key.length() > 200 || !(value instanceof String) || ((String) value).length() > 4096) throw new IllegalArgumentException();
            values.put(key, (String) value);
        }
        return values;
    }
    private static JSONObject json(Object... pairs) {
        JSONObject value = new JSONObject();
        try { for (int i = 0; i < pairs.length; i += 2) value.put((String) pairs[i], pairs[i + 1] == null ? JSONObject.NULL : pairs[i + 1]); }
        catch (JSONException error) { throw new IllegalArgumentException(); }
        return value;
    }
    private static TransferUIConfiguration configuration(JSONObject value) throws JSONException {
        TransferUIConfiguration.Language language = TransferUIConfiguration.Language.SIMPLIFIED_CHINESE;
        String tag = value.has("language") ? text(value, "language", 20) : "zh-Hans";
        boolean known = false;
        for (TransferUIConfiguration.Language candidate : TransferUIConfiguration.Language.values()) {
            if (candidate.tag.equals(tag)) { language = candidate; known = true; }
        }
        if (!known) throw new IllegalArgumentException();
        JSONObject theme = optionalObject(value, "theme");
        TransferUIConfiguration.Theme defaults = new TransferUIConfiguration.Theme();
        return new TransferUIConfiguration(language, new TransferUIConfiguration.Theme(
            color(theme, "primary", defaults.primary), color(theme, "background", defaults.background),
            color(theme, "surface", defaults.surface), color(theme, "text", defaults.text),
            color(theme, "mutedText", defaults.mutedText), color(theme, "border", defaults.border),
            color(theme, "success", defaults.success), color(theme, "danger", defaults.danger)),
            value.has("title") ? text(value, "title", 200) : null);
    }
    private static int color(JSONObject theme, String key, int fallback) throws JSONException {
        if (theme == null || !theme.has(key)) return fallback;
        String color = theme.getString(key);
        if (!color.matches("#[0-9a-fA-F]{6}")) throw new IllegalArgumentException();
        return Color.parseColor(color);
    }
    private void attach() {
        Activity activity = react.getCurrentActivity();
        if (activity == null || activity.isFinishing() || activity.isDestroyed()) throw new IllegalStateException();
        if (overlay != null && overlayActivity == activity) return;
        detach();
        FrameLayout parent = activity.findViewById(android.R.id.content);
        if (parent == null) throw new IllegalStateException();
        overlay = new TransferOverlay(activity, parent, center, configuration); overlayActivity = activity;
    }
    private void detach() { if (overlay != null) overlay.close(); overlay = null; overlayActivity = null; }
    @Override public void onHostResume() { main.post(() -> { if (!closed && visible) { try { attach(); } catch (RuntimeException ignored) { } } }); }
    @Override public void onHostPause() { }
    @Override public void onHostDestroy() { main.post(this::detach); }
    void close() {
        main.post(() -> {
            if (closed) return;
            closed = true; visible = false; detach(); subscription.close(); react.removeLifecycleEventListener(this);
            for (TransferTask task : center.snapshot()) if (task.canCancel()) center.cancel(task.id);
            for (Pending callback : new ArrayList<>(pending.values())) callback.attempt.fail("host_unavailable");
            pending.clear(); clients.clear(); workers.shutdown(); http.dispatcher().cancelAll();
            http.connectionPool().evictAll(); http.dispatcher().executorService().shutdown();
        });
    }
}
