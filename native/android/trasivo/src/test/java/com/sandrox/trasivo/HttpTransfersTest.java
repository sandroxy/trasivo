package com.sandrox.trasivo;

import org.junit.Test;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.MediaType;
import mockwebserver3.MockWebServer;
import mockwebserver3.MockResponse;
import java.nio.file.Files;
import java.io.File;
import java.util.Collections;
import java.util.concurrent.atomic.AtomicInteger;
import static org.junit.Assert.*;

public class HttpTransfersTest {
    private TransferTask await(TransferCenter center) throws Exception {
        long deadline = System.nanoTime() + 10_000_000_000L;
        while (System.nanoTime() < deadline) {
            TransferTask task = center.snapshot().get(0);
            if (!task.isActive()) return task;
            Thread.sleep(10);
        }
        throw new AssertionError("Transfer did not finish");
    }
    @Test public void downloadsActualBytesAndRefusesToOverwrite() throws Exception {
        try (MockWebServer server = new MockWebServer()) {
            server.start(); server.enqueue(new MockResponse.Builder().body("verified bytes").build());
            File directory = Files.createTempDirectory("trasivo-test").toFile();
            File output = new File(directory, "result.bin");
            try {
                TransferCenter center = new TransferCenter(1, 10, Runnable::run, Runnable::run);
                center.enqueue(new TransferTask.Request("file", TransferTask.Direction.DOWNLOAD),
                    HttpTransfers.download(new OkHttpClient(), () -> new Request.Builder().url(server.url("/file")).build(), directory, HttpTransfers.file(output)));
                assertEquals(TransferTask.State.SUCCEEDED, await(center).state);
                assertEquals("verified bytes", new String(Files.readAllBytes(output.toPath()), java.nio.charset.StandardCharsets.UTF_8));
                server.enqueue(new MockResponse.Builder().body("replacement").build());
                TransferCenter another = new TransferCenter(1, 10, Runnable::run, Runnable::run);
                another.enqueue(new TransferTask.Request("file", TransferTask.Direction.DOWNLOAD),
                    HttpTransfers.download(new OkHttpClient(), () -> new Request.Builder().url(server.url("/file")).build(), directory, HttpTransfers.file(output)));
                assertEquals("destination_failed", await(another).errorCode);
                assertEquals("verified bytes", new String(Files.readAllBytes(output.toPath()), java.nio.charset.StandardCharsets.UTF_8));
                assertEquals(1, directory.listFiles().length);
            } finally { output.delete(); directory.delete(); }
        }
    }
    @Test public void successfulHttpStatusStillRequiresBusinessValidation() throws Exception {
        try (MockWebServer server = new MockWebServer()) {
            server.start(); server.enqueue(new MockResponse.Builder().body("{\"success\":false}").build());
            TransferCenter center = new TransferCenter(1, 10, Runnable::run, Runnable::run);
            center.enqueue(new TransferTask.Request("upload", TransferTask.Direction.UPLOAD),
                HttpTransfers.upload(new OkHttpClient(), () -> new Request.Builder().url(server.url("/upload"))
                    .post(RequestBody.create("payload", MediaType.get("application/octet-stream"))).build(),
                    (status, headers, body) -> { throw new IllegalStateException("Application rejected response"); }));
            assertEquals("response_rejected", await(center).errorCode);
        }
    }
    @Test public void httpFailureRetriesSameTaskWithFreshRequest() throws Exception {
        try (MockWebServer server = new MockWebServer()) {
            server.start(); server.enqueue(new MockResponse.Builder().code(503).body("unavailable").build());
            server.enqueue(new MockResponse.Builder().body("recovered bytes").build());
            File directory = Files.createTempDirectory("trasivo-retry").toFile();
            File output = new File(directory, "result.bin");
            try {
                TransferCenter center = new TransferCenter(1, 10, Runnable::run, Runnable::run);
                AtomicInteger requests = new AtomicInteger();
                String id = center.enqueue(new TransferTask.Request("file", TransferTask.Direction.DOWNLOAD),
                    HttpTransfers.download(new OkHttpClient(), () -> {
                        requests.incrementAndGet(); return new Request.Builder().url(server.url("/file")).build();
                    }, directory, HttpTransfers.file(output)));
                TransferTask failed = await(center);
                assertEquals(TransferTask.State.FAILED, failed.state); assertEquals("http_503", failed.errorCode);
                assertTrue(failed.result.isEmpty()); assertFalse(output.exists());
                assertTrue(center.retry(id));
                TransferTask retried = await(center);
                assertEquals(TransferTask.State.SUCCEEDED, retried.state); assertEquals(id, retried.id);
                assertEquals(2, retried.attempt); assertNotEquals(failed.attemptId, retried.attemptId);
                assertNull(retried.errorCode); assertEquals(2, requests.get());
                assertEquals("recovered bytes", new String(Files.readAllBytes(output.toPath()), java.nio.charset.StandardCharsets.UTF_8));
            } finally { output.delete(); directory.delete(); }
        }
    }
    @Test public void completedNetworkBytesDoNotBypassDestinationFailure() throws Exception {
        try (MockWebServer server = new MockWebServer()) {
            server.start(); server.enqueue(new MockResponse.Builder().body("replacement bytes").build());
            server.enqueue(new MockResponse.Builder().body("replacement bytes").build());
            File directory = Files.createTempDirectory("trasivo-save-failure").toFile();
            File output = new File(directory, "result.bin");
            byte[] original = "existing file".getBytes(java.nio.charset.StandardCharsets.UTF_8);
            Files.write(output.toPath(), original);
            try {
                TransferCenter center = new TransferCenter(1, 10, Runnable::run, Runnable::run);
                String id = center.enqueue(new TransferTask.Request("file", TransferTask.Direction.DOWNLOAD),
                    HttpTransfers.download(new OkHttpClient(), () -> new Request.Builder().url(server.url("/file")).build(), directory, HttpTransfers.file(output)));
                TransferTask failed = await(center);
                assertEquals(TransferTask.State.FAILED, failed.state); assertEquals("destination_failed", failed.errorCode);
                assertTrue(failed.completedBytes > 0); assertEquals(failed.totalBytes, failed.completedBytes);
                assertTrue(failed.result.isEmpty()); assertArrayEquals(original, Files.readAllBytes(output.toPath()));
                assertTrue(output.delete()); assertTrue(center.retry(id));
                TransferTask retried = await(center);
                assertEquals(TransferTask.State.SUCCEEDED, retried.state); assertEquals(id, retried.id); assertEquals(2, retried.attempt);
                assertEquals("replacement bytes", new String(Files.readAllBytes(output.toPath()), java.nio.charset.StandardCharsets.UTF_8));
            } finally { output.delete(); directory.delete(); }
        }
    }
    @Test public void fileUploadReportsVerifiedPayloadAndProgress() throws Exception {
        File file = File.createTempFile("trasivo-upload-", ".bin");
        byte[] payload = new byte[192 * 1024]; java.util.Arrays.fill(payload, (byte) 'a');
        Files.write(file.toPath(), payload);
        try (MockWebServer server = new MockWebServer()) {
            server.start(); server.enqueue(new MockResponse.Builder().body("accepted").build());
            TransferCenter center = new TransferCenter(1, 10, Runnable::run, Runnable::run);
            center.enqueue(new TransferTask.Request("upload", TransferTask.Direction.UPLOAD),
                HttpTransfers.upload(new OkHttpClient(), () -> new Request.Builder().url(server.url("/upload"))
                    .post(RequestBody.create(MediaType.get("application/octet-stream"), file)).build(),
                    (status, headers, body) -> Collections.singletonMap("receipt", new String(body, java.nio.charset.StandardCharsets.UTF_8))));
            TransferTask result = await(center);
            assertEquals(TransferTask.State.SUCCEEDED, result.state);
            assertEquals("accepted", result.result.get("receipt"));
            assertArrayEquals(payload, server.takeRequest().getBody().toByteArray());
            assertEquals(payload.length, result.completedBytes); assertEquals(payload.length, result.totalBytes);
        } finally { file.delete(); }
    }
}
