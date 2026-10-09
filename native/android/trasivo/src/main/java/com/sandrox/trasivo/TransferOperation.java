package com.sandrox.trasivo;

import java.util.Map;

/** Implementations must be reusable: every start creates a fresh execution. */
public interface TransferOperation {
    Cancellation start(TransferContext context, Completion completion) throws Exception;
    interface Cancellation { void cancel(); }
    interface Completion {
        void succeed(Map<String, String> result);
        void fail(String code);
    }
}
