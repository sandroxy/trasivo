package com.sandrox.trasivo;

import org.junit.Test;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.Executor;
import static org.junit.Assert.*;

public class TransferCenterTest {
    private TransferCenter center(int concurrency) { return new TransferCenter(concurrency, 20, Runnable::run, Runnable::run); }
    private TransferTask.Request request() { return new TransferTask.Request("sample.bin", TransferTask.Direction.DOWNLOAD); }
    private static final class Manual implements TransferOperation {
        final List<TransferContext> contexts = new ArrayList<>();
        final List<Completion> completions = new ArrayList<>();
        int canceled;
        public Cancellation start(TransferContext context, Completion completion) {
            contexts.add(context); completions.add(completion); return () -> canceled++;
        }
    }
    @Test public void retryRejectsLateCallbacksAndStartsAtZero() {
        TransferCenter center = center(1); Manual operation = new Manual();
        String id = center.enqueue(request(), operation);
        operation.contexts.get(0).progress(80, 100);
        assertTrue(center.cancel(id)); assertTrue(center.retry(id));
        operation.completions.get(0).succeed(Collections.singletonMap("uri", "wrong"));
        operation.contexts.get(0).progress(100, 100);
        TransferTask task = center.snapshot().get(0);
        assertEquals(TransferTask.State.RUNNING, task.state); assertEquals(0, task.completedBytes);
        assertNotEquals(operation.contexts.get(0).attemptId, operation.contexts.get(1).attemptId);
        operation.completions.get(1).succeed(Collections.singletonMap("uri", "correct"));
        assertEquals("correct", center.snapshot().get(0).result.get("uri"));
    }
    @Test public void queuedCancellationDoesNotStartAndSlotIsReused() {
        TransferCenter center = center(1); Manual one = new Manual(), two = new Manual(), three = new Manual();
        center.enqueue(request(), one); String second = center.enqueue(request(), two); center.enqueue(request(), three);
        assertTrue(center.cancel(second)); one.completions.get(0).fail("network_failed");
        assertEquals(0, two.contexts.size()); assertEquals(1, three.contexts.size());
    }
    @Test public void committingDestinationCannotBeCanceledOrRetried() {
        TransferCenter center = center(1); Manual operation = new Manual(); String id = center.enqueue(request(), operation);
        operation.contexts.get(0).beginFinalization();
        assertFalse(center.cancel(id)); assertFalse(center.retry(id));
        operation.completions.get(0).fail("destination_failed");
        assertTrue(center.retry(id)); assertEquals(2, operation.contexts.size());
    }
    @Test public void duplicateCompletionDoesNotReplaceCommittedResult() {
        TransferCenter center = center(1); Manual operation = new Manual(); center.enqueue(request(), operation);
        operation.completions.get(0).succeed(Collections.singletonMap("uri", "saved"));
        operation.completions.get(0).fail("late_error");
        assertEquals(TransferTask.State.SUCCEEDED, center.snapshot().get(0).state);
    }
    @Test public void closingObservationSuppressesAlreadyQueuedNotifications() {
        List<Runnable> callbacks = new ArrayList<>();
        TransferCenter center = new TransferCenter(1, 10, Runnable::run, callbacks::add);
        List<List<TransferTask>> received = new ArrayList<>();
        TransferCenter.Subscription subscription = center.observe(received::add);
        center.enqueue(request(), new Manual()); subscription.close();
        new ArrayList<>(callbacks).forEach(Runnable::run); assertTrue(received.isEmpty());
        assertEquals(TransferTask.State.RUNNING, center.snapshot().get(0).state);
    }
    @Test public void historyLimitNeverEvictsActiveTasks() {
        TransferCenter center = new TransferCenter(2, 1, Runnable::run, Runnable::run);
        Manual one = new Manual(), two = new Manual();
        center.enqueue(request(), one); center.enqueue(request(), two);
        one.completions.get(0).fail("failed"); two.completions.get(0).fail("failed");
        assertEquals(1, center.snapshot().size());
        center.enqueue(request(), new Manual()); assertEquals(2, center.snapshot().size());
    }
    @Test public void independentObserversReattachToTheSameRetriedTask() {
        TransferCenter center = center(1); Manual operation = new Manual();
        String id = center.enqueue(request(), operation);
        List<List<TransferTask>> resource = new ArrayList<>(), panel = new ArrayList<>();
        TransferCenter.Subscription resourceSubscription = center.observe(resource::add);
        TransferCenter.Subscription panelSubscription = center.observe(panel::add);
        operation.contexts.get(0).progress(40, 100);
        assertEquals(40, resource.get(resource.size() - 1).get(0).completedBytes);
        assertEquals(40, panel.get(panel.size() - 1).get(0).completedBytes);
        panelSubscription.close(); int detachedCount = panel.size();
        assertTrue(center.cancel(id)); assertTrue(center.retry(id));
        assertEquals(2, operation.contexts.size());
        assertEquals(detachedCount, panel.size());
        panelSubscription = center.observe(panel::add);
        TransferTask reattached = panel.get(panel.size() - 1).get(0);
        assertEquals(id, reattached.id); assertEquals(2, reattached.attempt);
        assertEquals(resource.get(resource.size() - 1).get(0).attemptId, reattached.attemptId);
        resourceSubscription.close(); int hiddenCount = resource.size();
        operation.completions.get(1).succeed(Collections.singletonMap("uri", "saved"));
        assertEquals(hiddenCount, resource.size());
        assertEquals(TransferTask.State.SUCCEEDED, panel.get(panel.size() - 1).get(0).state);
        resourceSubscription = center.observe(resource::add);
        assertEquals("saved", resource.get(resource.size() - 1).get(0).result.get("uri"));
        assertEquals(1, center.snapshot().size());
        assertEquals(2, operation.contexts.size());
        resourceSubscription.close(); panelSubscription.close();
    }
    @Test public void synchronousCompletionDoesNotCancelFinishedOperation() {
        TransferCenter center = center(1);
        int[] canceled = {0};
        center.enqueue(request(), (context, completion) -> {
            completion.succeed(Collections.emptyMap());
            return () -> canceled[0]++;
        });
        assertEquals(TransferTask.State.SUCCEEDED, center.snapshot().get(0).state);
        assertEquals(0, canceled[0]);
    }
    @Test public void rejectedWorkerDoesNotLeaveTaskRunning() {
        TransferCenter center = new TransferCenter(1, 10, action -> {
            throw new java.util.concurrent.RejectedExecutionException();
        }, Runnable::run);
        center.enqueue(request(), new Manual());
        assertEquals(TransferTask.State.FAILED, center.snapshot().get(0).state);
    }
}
