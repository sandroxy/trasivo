package com.sandrox.trasivo.ui;

import android.app.Activity;
import android.app.Dialog;
import android.content.res.ColorStateList;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Looper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ProgressBar;
import android.widget.TextView;
import com.sandrox.trasivo.TransferCenter;
import com.sandrox.trasivo.TransferTask;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/** App-contained overlay. Attach, update, showPanel and close must run on the main thread. */
public final class TransferOverlay implements AutoCloseable {
    private final Activity activity;
    private final FrameLayout parent;
    private final TransferCenter center;
    private final Bubble bubble;
    private final TransferCenter.Subscription subscription;
    private TransferUIConfiguration configuration;
    private List<TransferTask> tasks = Collections.emptyList();
    private Dialog panel;
    private LinearLayout panelRoot;
    private TaskAdapter adapter;
    private TextView empty;
    private int filter;
    private boolean closed;
    private boolean positioned;
    private final View.OnLayoutChangeListener layoutListener = (v, l, t, r, b, ol, ot, or, ob) -> placeBubble();

    public TransferOverlay(Activity activity, FrameLayout parent, TransferCenter center, TransferUIConfiguration configuration) {
        mainThread(); this.activity = activity; this.parent = parent; this.center = center;
        this.configuration = configuration == null ? new TransferUIConfiguration() : configuration;
        bubble = new Bubble();
        parent.addView(bubble, new FrameLayout.LayoutParams(dp(58), dp(58)));
        parent.addOnLayoutChangeListener(layoutListener);
        bubble.setElevation(dp(8)); bubble.setOnClickListener(v -> showPanel());
        parent.post(this::placeBubble);
        subscription = center.observe(value -> activity.runOnUiThread(() -> {
            if (closed) return;
            tasks = value; refresh();
        }));
    }
    public void updateConfiguration(TransferUIConfiguration configuration) {
        mainThread(); if (closed) return;
        this.configuration = configuration == null ? new TransferUIConfiguration() : configuration;
        if (panel != null) buildPanel(); refresh();
    }
    public void showPanel() {
        mainThread(); if (closed || activity.isFinishing()) return;
        if (panel == null) {
            panel = new Dialog(activity); panel.requestWindowFeature(Window.FEATURE_NO_TITLE);
            panel.setOnDismissListener(ignored -> { panel = null; panelRoot = null; adapter = null; empty = null; });
            buildPanel(); panel.show();
            Window window = panel.getWindow();
            if (window != null) {
                window.setBackgroundDrawableResource(android.R.color.transparent);
                window.setGravity(Gravity.BOTTOM);
                window.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, Math.round(parent.getHeight() * .78f));
                window.setNavigationBarColor(configuration.theme.background);
            }
        } else panel.show();
    }
    public void close() {
        mainThread(); if (closed) return;
        closed = true; subscription.close(); parent.removeOnLayoutChangeListener(layoutListener);
        parent.removeView(bubble); if (panel != null) panel.dismiss();
    }
    private void buildPanel() {
        panelRoot = vertical(); panelRoot.setPadding(dp(16), dp(16), dp(16), dp(16));
        panelRoot.setBackground(round(configuration.theme.background, 24));
        LinearLayout header = horizontal();
        TextView title = label(configuration.title(), 21, configuration.theme.text); title.setTypeface(null, android.graphics.Typeface.BOLD);
        header.addView(title, new LinearLayout.LayoutParams(0, -2, 1));
        Button close = button(configuration.text("close"), configuration.theme.mutedText); close.setOnClickListener(v -> panel.dismiss());
        header.addView(close); panelRoot.addView(header);
        LinearLayout tabs = horizontal(); String[] keys = {"all", "active", "attention", "completed"};
        for (int i = 0; i < keys.length; i++) {
            final int selected = i;
            Button tab = button(configuration.text(keys[i]), filter == i ? configuration.theme.primary : configuration.theme.mutedText);
            tab.setTextSize(12); tab.setPadding(0, 0, 0, 0);
            tab.setOnClickListener(v -> { filter = selected; buildPanel(); });
            tabs.addView(tab, new LinearLayout.LayoutParams(0, dp(48), 1));
        }
        panelRoot.addView(tabs);
        FrameLayout listContainer = new FrameLayout(activity);
        ListView list = new ListView(activity); list.setDivider(null); list.setDividerHeight(dp(8));
        adapter = new TaskAdapter(); list.setAdapter(adapter);
        empty = label(configuration.text("empty"), 16, configuration.theme.mutedText); empty.setGravity(Gravity.CENTER);
        listContainer.addView(list, new FrameLayout.LayoutParams(-1, -1));
        listContainer.addView(empty, new FrameLayout.LayoutParams(-1, -1));
        panelRoot.addView(listContainer, new LinearLayout.LayoutParams(-1, 0, 1));
        panel.setContentView(panelRoot);
        if (panel.getWindow() != null) panel.getWindow().setNavigationBarColor(configuration.theme.background);
        refresh();
    }
    private void refresh() {
        bubble.setVisibility(tasks.isEmpty() ? View.GONE : View.VISIBLE); bubble.invalidate();
        long active = 0; for (TransferTask task : tasks) if (task.isActive()) active++;
        bubble.setContentDescription(configuration.text("bubble").replace("{count}", String.valueOf(active)));
        if (adapter != null) { adapter.reload(); empty.setVisibility(adapter.getCount() == 0 ? View.VISIBLE : View.GONE); }
    }
    private void placeBubble() {
        if (closed || parent.getWidth() == 0 || parent.getHeight() == 0) return;
        if (!positioned) {
            bubble.setX(parent.getWidth() - dp(74)); bubble.setY(parent.getHeight() * .68f); positioned = true;
        }
        float top = parent.getPaddingTop() + dp(8), bottom = parent.getHeight() - parent.getPaddingBottom() - dp(66);
        if (Build.VERSION.SDK_INT >= 23) {
            WindowInsets insets = parent.getRootWindowInsets();
            if (insets != null) { top += insets.getSystemWindowInsetTop(); bottom -= insets.getSystemWindowInsetBottom(); }
        }
        bubble.setX(Math.max(dp(8), Math.min(parent.getWidth() - dp(66), bubble.getX())));
        bubble.setY(Math.max(top, Math.min(Math.max(top, bottom), bubble.getY())));
    }
    private final class Bubble extends View {
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final RectF ring = new RectF();
        float downX, downY, startX, startY; boolean moved;
        Bubble() { super(activity); setFocusable(true); setClickable(true); }
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            float radius = getWidth() / 2f;
            paint.setStyle(Paint.Style.FILL); paint.setColor(configuration.theme.surface); canvas.drawCircle(radius, radius, radius, paint);
            int active = 0, failed = 0, canceled = 0; double bytes = 0, total = 0; boolean unknown = false;
            for (TransferTask task : tasks) {
                if (task.isActive()) { active++; bytes += task.completedBytes; if (task.totalBytes <= 0) unknown = true; else total += task.totalBytes; }
                if (task.state == TransferTask.State.FAILED) failed++;
                if (task.state == TransferTask.State.CANCELED) canceled++;
            }
            paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(dp(3)); paint.setColor(configuration.theme.border);
            ring.set(dp(4), dp(4), getWidth() - dp(4), getHeight() - dp(4)); canvas.drawOval(ring, paint);
            paint.setColor(active > 0 ? configuration.theme.primary : failed > 0 ? configuration.theme.danger : canceled > 0 ? configuration.theme.mutedText : configuration.theme.success);
            float fraction = active == 0 ? 1f : unknown || total <= 0 ? .25f : (float) Math.min(.99, bytes / total);
            canvas.drawArc(ring, -90, fraction * 360, false, paint);
            paint.setStyle(Paint.Style.FILL); paint.setTextAlign(Paint.Align.CENTER); paint.setTextSize(dp(19));
            String text = active > 0 ? (active > 99 ? "99+" : String.valueOf(active)) : failed > 0 ? "!" : canceled > 0 ? "–" : "✓";
            canvas.drawText(text, radius, radius - (paint.ascent() + paint.descent()) / 2f, paint);
        }
        public boolean onTouchEvent(MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    downX = event.getRawX(); downY = event.getRawY(); startX = getX(); startY = getY(); moved = false; return true;
                case MotionEvent.ACTION_MOVE:
                    float dx = event.getRawX() - downX, dy = event.getRawY() - downY;
                    if (Math.abs(dx) + Math.abs(dy) > dp(8)) moved = true;
                    if (moved) { getParent().requestDisallowInterceptTouchEvent(true); setX(startX + dx); setY(startY + dy); placeBubble(); }
                    return true;
                case MotionEvent.ACTION_UP:
                    if (moved) { setX(getX() + getWidth() / 2f < parent.getWidth() / 2f ? dp(8) : parent.getWidth() - dp(66)); placeBubble(); }
                    else performClick();
                    getParent().requestDisallowInterceptTouchEvent(false); return true;
                case MotionEvent.ACTION_CANCEL: getParent().requestDisallowInterceptTouchEvent(false); return true;
                default: return super.onTouchEvent(event);
            }
        }
        public boolean performClick() { super.performClick(); return true; }
    }
    private final class TaskAdapter extends BaseAdapter {
        final List<TransferTask> visible = new ArrayList<>();
        void reload() {
            visible.clear();
            for (TransferTask task : tasks) {
                if (filter == 0 || (filter == 1 && task.isActive()) || (filter == 2 && task.canRetry()) || (filter == 3 && task.state == TransferTask.State.SUCCEEDED)) visible.add(task);
            }
            Collections.reverse(visible); notifyDataSetChanged();
        }
        public int getCount() { return visible.size(); }
        public Object getItem(int position) { return visible.get(position); }
        public long getItemId(int position) { return visible.get(position).id.hashCode(); }
        public View getView(int position, View recycled, ViewGroup container) {
            TaskRow row = recycled instanceof TaskRow ? (TaskRow) recycled : new TaskRow();
            row.bind(visible.get(position)); return row;
        }
    }
    private final class TaskRow extends LinearLayout {
        final TextView name = label("", 16, 0), status = label("", 13, 0), error = label("", 13, 0), bytes = label("", 12, 0);
        final ProgressBar progress = new ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal);
        final LinearLayout actions = horizontal();
        final Button retry = button("", 0), cancel = button("", 0), remove = button("", 0);
        TaskRow() {
            super(activity); setOrientation(VERTICAL); setPadding(dp(14), dp(12), dp(14), dp(12));
            name.setMaxLines(2); addView(name); addView(status); addView(error);
            progress.setMax(1000); addView(progress, new LinearLayout.LayoutParams(-1, dp(12))); addView(bytes);
            actions.setGravity(Gravity.END); actions.addView(retry); actions.addView(cancel); actions.addView(remove); addView(actions);
        }
        void bind(TransferTask task) {
            setBackground(round(configuration.theme.surface, 16));
            name.setText(task.title); name.setTextColor(configuration.theme.text);
            String direction = task.direction == TransferTask.Direction.UPLOAD ? "upload" : "download";
            String state = task.state == TransferTask.State.FINALIZING ? "finalizing_" + direction : task.state.name().toLowerCase(Locale.ROOT);
            status.setText(configuration.text("task_status").replace("{direction}", configuration.text(direction)).replace("{state}", configuration.text(state))); status.setTextColor(configuration.theme.mutedText);
            error.setText(configuration.error(task.errorCode)); error.setTextColor(configuration.theme.danger);
            error.setVisibility(task.state == TransferTask.State.FAILED ? VISIBLE : GONE);
            progress.setVisibility(task.isActive() ? VISIBLE : GONE);
            progress.setIndeterminate(task.totalBytes <= 0 || task.state == TransferTask.State.FINALIZING);
            progress.setProgress(task.totalBytes <= 0 ? 0 : (int) Math.min(990, task.completedBytes * 1000.0 / task.totalBytes));
            progress.setProgressTintList(ColorStateList.valueOf(configuration.theme.primary));
            progress.setIndeterminateTintList(ColorStateList.valueOf(configuration.theme.primary));
            progress.setProgressBackgroundTintList(ColorStateList.valueOf(configuration.theme.border));
            bytes.setText(configuration.text("byte_progress").replace("{completed}", size(task.completedBytes)).replace("{total}", task.totalBytes < 0 ? configuration.text("unknown") : size(task.totalBytes)));
            bytes.setTextColor(configuration.theme.mutedText);
            bindAction(retry, "retry", configuration.theme.primary, task.canRetry(), v -> center.retry(task.id));
            bindAction(cancel, "cancel", configuration.theme.danger, task.canCancel(), v -> center.cancel(task.id));
            bindAction(remove, "remove", configuration.theme.mutedText, !task.isActive(), v -> center.remove(task.id));
            actions.setVisibility(task.canRetry() || task.canCancel() || !task.isActive() ? VISIBLE : GONE);
        }
        void bindAction(Button button, String key, int color, boolean visible, View.OnClickListener listener) {
            button.setText(configuration.text(key)); button.setTextColor(color); button.setVisibility(visible ? VISIBLE : GONE);
            button.setOnClickListener(listener);
        }
    }
    private String size(long bytes) {
        if (bytes < 1024) return bytes + " B";
        String[] units = {"KiB", "MiB", "GiB", "TiB"}; double value = bytes / 1024.0; int unit = 0;
        while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
        return String.format(Locale.forLanguageTag(configuration.language.tag), "%.1f %s", value, units[unit]);
    }
    private Button button(String text, int color) {
        Button view = new Button(activity); view.setText(text); view.setTextColor(color); view.setAllCaps(false);
        view.setMinWidth(0); view.setMinimumWidth(0); view.setTextSize(13); view.setBackgroundColor(android.graphics.Color.TRANSPARENT); return view;
    }
    private TextView label(String text, int size, int color) { TextView view = new TextView(activity); view.setText(text); view.setTextSize(size); view.setTextColor(color); view.setPadding(0, dp(4), 0, dp(4)); return view; }
    private LinearLayout vertical() { LinearLayout view = new LinearLayout(activity); view.setOrientation(LinearLayout.VERTICAL); return view; }
    private LinearLayout horizontal() { LinearLayout view = new LinearLayout(activity); view.setOrientation(LinearLayout.HORIZONTAL); view.setGravity(Gravity.CENTER_VERTICAL); return view; }
    private GradientDrawable round(int color, int radius) { GradientDrawable value = new GradientDrawable(); value.setColor(color); value.setCornerRadius(dp(radius)); return value; }
    private int dp(int value) { return Math.round(value * activity.getResources().getDisplayMetrics().density); }
    private static void mainThread() { if (Looper.myLooper() != Looper.getMainLooper()) throw new IllegalStateException("Trasivo UI requires the main thread"); }
}
