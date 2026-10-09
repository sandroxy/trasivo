package com.sandrox.trasivo;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Collections;
import java.util.Map;
import java.util.Objects;
import okhttp3.Call;
import okhttp3.Callback;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;
import okio.BufferedSink;
import okio.Buffer;
import okio.ForwardingSink;
import okio.Okio;

/** Foreground HTTP operations. Request providers are evaluated again on every retry. */
public final class HttpTransfers {
    private HttpTransfers() { }
    public interface RequestProvider { Request create() throws Exception; }
    /** Called on a worker after beginFinalization; return only after the destination is committed. */
    public interface DownloadDestination { Map<String, String> save(File temporaryFile) throws Exception; }
    /** Must validate HTTP and application-level success. Throwing fails the task. */
    public interface UploadResponseHandler { Map<String, String> accept(int status, Map<String, String> headers, byte[] body) throws Exception; }

    public static TransferOperation download(OkHttpClient client, RequestProvider requests,
                                             File temporaryDirectory, DownloadDestination destination) {
        Objects.requireNonNull(client); Objects.requireNonNull(requests);
        Objects.requireNonNull(temporaryDirectory); Objects.requireNonNull(destination);
        return (context, completion) -> {
            Request request = requests.create();
            if (!request.method().equals("GET") || request.header("Range") != null)
                throw new IllegalArgumentException("A fresh GET without Range is required");
            context.checkCanceled();
            Call call = client.newCall(request);
            call.enqueue(new Callback() {
                public void onFailure(Call ignored, IOException error) { completion.fail("network_failed"); }
                public void onResponse(Call ignored, Response response) {
                    File temporary = null;
                    try (Response closed = response) {
                        if (response.code() != 200) { completion.fail("http_" + response.code()); return; }
                        ResponseBody body = response.body();
                        if (body == null) { completion.fail("empty_response"); return; }
                        if (!temporaryDirectory.isDirectory() && !temporaryDirectory.mkdirs())
                            throw new IOException("Cannot create temporary directory");
                        temporary = File.createTempFile("trasivo-", ".part", temporaryDirectory);
                        long expected = body.contentLength(), received = 0;
                        try (InputStream input = body.byteStream(); FileOutputStream output = new FileOutputStream(temporary)) {
                            byte[] buffer = new byte[64 * 1024]; int length;
                            while ((length = input.read(buffer)) != -1) {
                                context.checkCanceled();
                                output.write(buffer, 0, length); received += length;
                                if (expected >= 0 && received > expected) throw new IOException("Unexpected length");
                                context.progress(received, expected);
                            }
                            output.getFD().sync();
                        }
                        if (expected >= 0 && expected != received) { completion.fail("incomplete_download"); return; }
                        context.beginFinalization();
                        Map<String, String> result;
                        try { result = destination.save(temporary); }
                        catch (Exception error) { completion.fail("destination_failed"); return; }
                        completion.succeed(result);
                    } catch (Exception error) { completion.fail("download_failed"); }
                    finally { if (temporary != null) temporary.delete(); }
                }
            });
            return call::cancel;
        };
    }

    /** Upload body may be raw or multipart. It must be repeatable, file-backed, and non-duplex. */
    public static TransferOperation upload(OkHttpClient client, RequestProvider requests,
                                           UploadResponseHandler handler) {
        Objects.requireNonNull(client); Objects.requireNonNull(requests); Objects.requireNonNull(handler);
        return (context, completion) -> {
            Request request = requests.create();
            RequestBody body = request.body();
            if (body == null || body.isDuplex() || body.isOneShot())
                throw new IllegalArgumentException("A repeatable request body is required");
            RequestBody counted = new RequestBody() {
                public okhttp3.MediaType contentType() { return body.contentType(); }
                public long contentLength() throws IOException { return body.contentLength(); }
                public void writeTo(BufferedSink sink) throws IOException {
                    long total = contentLength();
                    BufferedSink progress = Okio.buffer(new ForwardingSink(sink) {
                        long sent;
                        public void write(Buffer source, long count) throws IOException {
                            context.checkCanceled(); super.write(source, count); sent += count;
                            context.progress(sent, total);
                        }
                    });
                    body.writeTo(progress); progress.flush();
                }
            };
            context.checkCanceled();
            Call call = client.newCall(request.newBuilder().method(request.method(), counted).build());
            call.enqueue(new Callback() {
                public void onFailure(Call ignored, IOException error) { completion.fail("network_failed"); }
                public void onResponse(Call ignored, Response response) {
                    try (Response closed = response) {
                        if (!response.isSuccessful()) { completion.fail("http_" + response.code()); return; }
                        byte[] bytes;
                        try (java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream()) {
                            ResponseBody body = response.body();
                            if (body != null) {
                                InputStream input = body.byteStream(); byte[] buffer = new byte[8192]; int count;
                                while ((count = input.read(buffer)) != -1) {
                                    context.checkCanceled();
                                    if (output.size() + count > 1024 * 1024) { completion.fail("response_too_large"); return; }
                                    output.write(buffer, 0, count);
                                }
                            }
                            bytes = output.toByteArray();
                        }
                        context.beginFinalization();
                        Map<String, String> headers = new java.util.LinkedHashMap<>();
                        for (String name : response.headers().names()) headers.put(name, response.header(name));
                        try { completion.succeed(handler.accept(response.code(), Collections.unmodifiableMap(headers), bytes)); }
                        catch (Exception error) { completion.fail("response_rejected"); }
                    } catch (Exception error) { completion.fail("upload_failed"); }
                }
            });
            return call::cancel;
        };
    }

    /** Writes a new file only; existing files are never overwritten or removed. */
    public static DownloadDestination file(File destination) {
        Objects.requireNonNull(destination);
        return source -> {
            if (!destination.createNewFile()) throw new IOException("Destination already exists");
            boolean committed = false;
            try {
                try (FileInputStream input = new FileInputStream(source); FileOutputStream output = new FileOutputStream(destination)) {
                    byte[] buffer = new byte[64 * 1024]; int count;
                    while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
                    output.getFD().sync();
                }
                if (source.length() != destination.length()) throw new IOException("Incomplete file");
                committed = true;
                return Collections.singletonMap("uri", destination.toURI().toString());
            } finally { if (!committed) destination.delete(); }
        };
    }
}
