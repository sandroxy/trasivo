package com.sandrox.trasivo;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

/** Immutable snapshot. A task keeps its ID across retries; each attempt has a new ID. */
public final class TransferTask {
    public enum Direction { UPLOAD, DOWNLOAD }
    public enum State { QUEUED, RUNNING, FINALIZING, SUCCEEDED, FAILED, CANCELED }
    public final String id, attemptId, title;
    public final Direction direction;
    public final State state;
    public final long completedBytes, totalBytes;
    public final int attempt;
    public final String errorCode;
    public final Map<String, String> result;

    TransferTask(String id, String attemptId, String title, Direction direction, State state,
                 long completedBytes, long totalBytes, int attempt, String errorCode, Map<String, String> result) {
        this.id = id; this.attemptId = attemptId; this.title = title; this.direction = direction;
        this.state = state; this.completedBytes = completedBytes; this.totalBytes = totalBytes;
        this.attempt = attempt; this.errorCode = errorCode;
        this.result = Collections.unmodifiableMap(new LinkedHashMap<>(result));
    }
    public boolean isActive() { return state == State.QUEUED || state == State.RUNNING || state == State.FINALIZING; }
    public boolean canRetry() { return state == State.FAILED || state == State.CANCELED; }
    public boolean canCancel() { return state == State.QUEUED || state == State.RUNNING; }
    public static final class Request {
        public final String title;
        public final Direction direction;
        public Request(String title, Direction direction) {
            if (title == null || title.trim().isEmpty()) throw new IllegalArgumentException("A task title is required");
            this.title = title; this.direction = Objects.requireNonNull(direction);
        }
    }
}
