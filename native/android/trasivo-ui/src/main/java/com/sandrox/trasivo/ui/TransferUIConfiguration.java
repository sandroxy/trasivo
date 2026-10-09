package com.sandrox.trasivo.ui;

/** Immutable host overrides. Apply a new instance to an attached TransferOverlay at any time. */
public final class TransferUIConfiguration {
    public enum Language {
        SIMPLIFIED_CHINESE("zh-Hans"), TRADITIONAL_CHINESE("zh-Hant"), ENGLISH("en"), JAPANESE("ja");
        public final String tag;
        Language(String tag) { this.tag = tag; }
    }
    public static final class Theme {
        public final int primary, background, surface, text, mutedText, border, success, danger;
        public Theme() { this(0xff1f7a8c, 0xfff7f8fa, 0xffffffff, 0xff171a1f, 0xff667085, 0xffd7dee6, 0xff14855f, 0xffc24132); }
        public Theme(int primary, int background, int surface, int text, int mutedText, int border, int success, int danger) {
            this.primary = primary; this.background = background; this.surface = surface; this.text = text;
            this.mutedText = mutedText; this.border = border; this.success = success; this.danger = danger;
        }
        public Theme withPrimary(int color) { return new Theme(color, background, surface, text, mutedText, border, success, danger); }
    }
    public final Language language;
    public final Theme theme;
    public final String title;
    public TransferUIConfiguration() { this(Language.SIMPLIFIED_CHINESE, new Theme(), null); }
    public TransferUIConfiguration(Language language, Theme theme, String title) {
        this.language = language == null ? Language.SIMPLIFIED_CHINESE : language;
        this.theme = theme == null ? new Theme() : theme;
        this.title = title;
    }
    String text(String key) { return Strings.get(language.tag, key); }
    String title() { return title == null ? text("title") : title; }
    String error(String code) {
        if (code == null) return "";
        String value = text(code.startsWith("http_") ? "http_error" : code);
        return value == null ? text("operation_failed") : value;
    }
}
