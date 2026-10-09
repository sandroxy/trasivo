package com.sandrox.trasivo;

import java.util.concurrent.CancellationException;

public final class TransferContext {
    public final String taskId, attemptId;
    private final TransferCenter center;
    TransferContext(TransferCenter center, String taskId, String attemptId) {
        this.center = center; this.taskId = taskId; this.attemptId = attemptId;
    }
    /** totalBytes = -1 means unknown. Values measure bytes, never fabricated percentages. */
    public void progress(long completedBytes, long totalBytes) {
        if (completedBytes < 0 || totalBytes < -1 || (totalBytes >= 0 && completedBytes > totalBytes))
            throw new IllegalArgumentException("Invalid byte counts");
        center.progress(this, completedBytes, totalBytes);
    }
    public boolean isCanceled() { return !center.isCurrent(this); }
    public void checkCanceled() { if (isCanceled()) throw new CancellationException(); }
    /** Atomically ends the cancellable portion before committing externally visible effects. */
    public void beginFinalization() { center.finalizeTask(this); }
}
