package com.sandrox.trasivo;

import android.os.Handler;
import android.os.Looper;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.CancellationException;
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicBoolean;

/** Application-scoped, in-process task owner. Detaching a UI or observer never cancels work. */
public final class TransferCenter {
    public interface Observer { void onTasks(List<TransferTask> tasks); }
    public interface Subscription extends AutoCloseable { void close(); }
    private final Object lock = new Object();
    private final LinkedHashMap<String, Entry> entries = new LinkedHashMap<>();
    private final List<Watch> watches = new ArrayList<>();
    private final Executor workers, callbacks;
    private final int concurrency, historyLimit;

    public TransferCenter() {
        this(3, 200, Executors.newCachedThreadPool(), runnable -> new Handler(Looper.getMainLooper()).post(runnable));
    }
    public TransferCenter(int concurrency, int historyLimit, Executor workers, Executor callbacks) {
        if (concurrency < 1 || historyLimit < 1) throw new IllegalArgumentException("Limits must be positive");
        this.concurrency = concurrency; this.historyLimit = historyLimit;
        this.workers = Objects.requireNonNull(workers); this.callbacks = Objects.requireNonNull(callbacks);
    }
    public String enqueue(TransferTask.Request request, TransferOperation operation) {
        Entry entry = new Entry(Objects.requireNonNull(request), Objects.requireNonNull(operation));
        synchronized (lock) { entries.put(entry.id, entry); }
        schedule(); return entry.id;
    }
    public List<TransferTask> snapshot() {
        synchronized (lock) {
            List<TransferTask> tasks = new ArrayList<>();
            for (Entry entry : entries.values()) tasks.add(entry.snapshot());
            return Collections.unmodifiableList(tasks);
        }
    }
    public Subscription observe(Observer observer) {
        Watch watch = new Watch(Objects.requireNonNull(observer));
        synchronized (lock) { watches.add(watch); dispatch(watch, snapshot()); }
        return () -> { watch.active.set(false); synchronized (lock) { watches.remove(watch); } };
    }
    public boolean retry(String taskId) {
        synchronized (lock) {
            Entry entry = entries.get(taskId);
            if (entry == null || !entry.snapshot().canRetry()) return false;
            entry.attempt++; entry.attemptId = UUID.randomUUID().toString();
            entry.state = TransferTask.State.QUEUED; entry.bytes = 0; entry.total = -1;
            entry.error = null; entry.result = Collections.emptyMap(); entry.cancellation = null;
            entry.lastProgress = 0;
        }
        schedule(); return true;
    }
    public boolean cancel(String taskId) {
        TransferOperation.Cancellation cancellation;
        synchronized (lock) {
            Entry entry = entries.get(taskId);
            if (entry == null || !entry.snapshot().canCancel()) return false;
            entry.state = TransferTask.State.CANCELED;
            cancellation = entry.cancellation; entry.cancellation = null;
        }
        try { cancelSafely(cancellation); }
        finally { schedule(); }
        return true;
    }
    public boolean remove(String taskId) {
        synchronized (lock) {
            Entry entry = entries.get(taskId);
            if (entry == null || entry.snapshot().isActive()) return false;
            entries.remove(taskId); emit(); return true;
        }
    }
    boolean isCurrent(TransferContext context) {
        synchronized (lock) { return current(context) != null; }
    }
    private Entry current(TransferContext context) {
        Entry entry = entries.get(context.taskId);
        return entry != null && entry.attemptId.equals(context.attemptId)
                && (entry.state == TransferTask.State.RUNNING || entry.state == TransferTask.State.FINALIZING) ? entry : null;
    }
    void progress(TransferContext context, long bytes, long total) {
        synchronized (lock) {
            Entry entry = current(context);
            if (entry == null || entry.state != TransferTask.State.RUNNING || bytes < entry.bytes) return;
            entry.bytes = bytes; entry.total = total;
            long now = System.nanoTime();
            if (now - entry.lastProgress >= 150_000_000L) { entry.lastProgress = now; emit(); }
        }
    }
    void finalizeTask(TransferContext context) {
        synchronized (lock) {
            Entry entry = current(context);
            if (entry == null) throw new CancellationException();
            entry.state = TransferTask.State.FINALIZING; emit();
        }
    }
    private void schedule() {
        List<Runnable> starts = new ArrayList<>();
        synchronized (lock) {
            int active = 0;
            for (Entry entry : entries.values()) if (entry.state == TransferTask.State.RUNNING || entry.state == TransferTask.State.FINALIZING) active++;
            for (Entry entry : entries.values()) {
                if (active >= concurrency) break;
                if (entry.state != TransferTask.State.QUEUED) continue;
                entry.state = TransferTask.State.RUNNING; active++;
                TransferContext context = new TransferContext(this, entry.id, entry.attemptId);
                starts.add(() -> {
                    try { workers.execute(() -> start(entry.operation, context)); }
                    catch (RejectedExecutionException error) { finish(context, null, "operation_failed"); }
                });
            }
            int terminal = 0;
            for (Entry entry : entries.values()) if (!entry.snapshot().isActive()) terminal++;
            java.util.Iterator<Entry> iterator = entries.values().iterator();
            while (terminal > historyLimit && iterator.hasNext()) {
                if (!iterator.next().snapshot().isActive()) { iterator.remove(); terminal--; }
            }
            emit();
        }
        for (Runnable start : starts) start.run();
    }
    private void start(TransferOperation operation, TransferContext context) {
        if (!isCurrent(context)) return;
        AtomicBoolean completed = new AtomicBoolean();
        try {
            TransferOperation.Cancellation cancellation = operation.start(context, new TransferOperation.Completion() {
                public void succeed(Map<String, String> result) { completed.set(true); finish(context, result, null); }
                public void fail(String code) { completed.set(true); finish(context, null, code == null || code.isEmpty() ? "operation_failed" : code); }
            });
            boolean canceled;
            synchronized (lock) {
                Entry entry = current(context);
                canceled = entry == null;
                if (entry != null) entry.cancellation = cancellation;
            }
            if (canceled && !completed.get()) cancelSafely(cancellation);
        } catch (Exception error) { finish(context, null, "operation_failed"); }
    }
    private static void cancelSafely(TransferOperation.Cancellation cancellation) {
        // A broken host cancellation handler must not strand other queued tasks.
        try { if (cancellation != null) cancellation.cancel(); }
        catch (RuntimeException ignored) { }
    }
    private void finish(TransferContext context, Map<String, String> result, String error) {
        synchronized (lock) {
            Entry entry = current(context);
            if (entry == null) return;
            entry.state = error == null ? TransferTask.State.SUCCEEDED : TransferTask.State.FAILED;
            entry.error = error; entry.cancellation = null;
            entry.result = result == null ? Collections.emptyMap() : new LinkedHashMap<>(result);
        }
        schedule();
    }
    private void emit() {
        List<TransferTask> tasks = snapshot();
        for (Watch watch : new ArrayList<>(watches)) dispatch(watch, tasks);
    }
    private void dispatch(Watch watch, List<TransferTask> tasks) {
        callbacks.execute(() -> { if (watch.active.get()) watch.observer.onTasks(tasks); });
    }
    private static final class Watch {
        final Observer observer; final AtomicBoolean active = new AtomicBoolean(true);
        Watch(Observer observer) { this.observer = observer; }
    }
    private static final class Entry {
        final String id = UUID.randomUUID().toString();
        final TransferTask.Request request; final TransferOperation operation;
        String attemptId = UUID.randomUUID().toString(), error;
        TransferTask.State state = TransferTask.State.QUEUED;
        long bytes = 0, total = -1, lastProgress = 0;
        int attempt = 1;
        Map<String, String> result = Collections.emptyMap();
        TransferOperation.Cancellation cancellation;
        Entry(TransferTask.Request request, TransferOperation operation) { this.request = request; this.operation = operation; }
        TransferTask snapshot() { return new TransferTask(id, attemptId, request.title, request.direction, state, bytes, total, attempt, error, result); }
    }
}
