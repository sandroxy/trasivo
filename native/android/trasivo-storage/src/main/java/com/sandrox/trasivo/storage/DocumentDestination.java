package com.sandrox.trasivo.storage;

import android.content.ContentResolver;
import android.net.Uri;
import android.provider.DocumentsContract;
import com.sandrox.trasivo.HttpTransfers;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.Collections;
import java.util.Map;

/** Supply a newly created ACTION_CREATE_DOCUMENT result, never an existing user document. */
public final class DocumentDestination implements HttpTransfers.DownloadDestination {
    private final ContentResolver resolver;
    private final Uri newDocument;
    public DocumentDestination(ContentResolver resolver, Uri newDocument) {
        if (!"content".equals(newDocument.getScheme())) throw new IllegalArgumentException("A document content URI is required");
        this.resolver = resolver; this.newDocument = newDocument;
    }
    public Map<String, String> save(File source) throws Exception {
        // An existing selection is host-owned: on failure keep its URI so retry can reuse it.
        try (FileInputStream input = new FileInputStream(source); OutputStream output = resolver.openOutputStream(newDocument, "wt")) {
            if (output == null) throw new IOException("Document output unavailable");
            byte[] buffer = new byte[64 * 1024]; int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            output.flush();
        }
        return Collections.singletonMap("uri", newDocument.toString());
    }
}
