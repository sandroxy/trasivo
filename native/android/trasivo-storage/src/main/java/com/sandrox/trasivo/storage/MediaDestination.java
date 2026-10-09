package com.sandrox.trasivo.storage;

import android.Manifest;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;
import com.sandrox.trasivo.HttpTransfers;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.Collections;
import java.util.Map;

/** Inserts an owned media item, publishes it after copying, and removes failed insertions. */
public final class MediaDestination implements HttpTransfers.DownloadDestination {
    private final Context context;
    private final String displayName, mimeType;
    public MediaDestination(Context context, String displayName, String mimeType) {
        this.context = context.getApplicationContext();
        if (displayName == null || displayName.isEmpty() || displayName.contains("/") || displayName.contains("\\"))
            throw new IllegalArgumentException("A simple file name is required");
        if (mimeType == null || !(mimeType.startsWith("image/") || mimeType.startsWith("video/")))
            throw new IllegalArgumentException("An image or video MIME type is required");
        this.displayName = displayName; this.mimeType = mimeType;
    }
    public Map<String, String> save(File file) throws Exception {
        if (Build.VERSION.SDK_INT >= 23 && Build.VERSION.SDK_INT <= 28
                && context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED)
            throw new SecurityException("The host must request legacy storage permission");
        ContentResolver resolver = context.getContentResolver();
        boolean image = mimeType.startsWith("image/");
        Uri collection = image ? MediaStore.Images.Media.EXTERNAL_CONTENT_URI : MediaStore.Video.Media.EXTERNAL_CONTENT_URI;
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, displayName);
        values.put(MediaStore.MediaColumns.MIME_TYPE, mimeType);
        if (Build.VERSION.SDK_INT >= 29) {
            values.put(MediaStore.MediaColumns.RELATIVE_PATH, image ? "Pictures" : "Movies");
            values.put(MediaStore.MediaColumns.IS_PENDING, 1);
        }
        Uri uri = resolver.insert(collection, values);
        if (uri == null) throw new IOException("Media insertion failed");
        boolean committed = false;
        try {
            long copied = 0;
            try (FileInputStream input = new FileInputStream(file); OutputStream output = resolver.openOutputStream(uri, "w")) {
                if (output == null) throw new IOException("Media output unavailable");
                byte[] buffer = new byte[64 * 1024]; int count;
                while ((count = input.read(buffer)) != -1) { output.write(buffer, 0, count); copied += count; }
                output.flush();
            }
            if (copied != file.length()) throw new IOException("Incomplete media copy");
            if (Build.VERSION.SDK_INT >= 29) {
                ContentValues published = new ContentValues(); published.put(MediaStore.MediaColumns.IS_PENDING, 0);
                if (resolver.update(uri, published, null, null) != 1) throw new IOException("Media publication failed");
            }
            committed = true; return Collections.singletonMap("uri", uri.toString());
        } finally { if (!committed) resolver.delete(uri, null, null); }
    }
}
