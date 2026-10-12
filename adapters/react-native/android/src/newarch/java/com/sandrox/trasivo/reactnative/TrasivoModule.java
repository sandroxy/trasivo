package com.sandrox.trasivo.reactnative;

import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.module.annotations.ReactModule;

@ReactModule(name = TrasivoModule.NAME)
public final class TrasivoModule extends NativeTrasivoSpec {
    static final String NAME = "Trasivo";
    private final TrasivoDelegate delegate;
    public TrasivoModule(ReactApplicationContext context) { super(context); delegate = new TrasivoDelegate(context); }
    @Override public String getName() { return NAME; }
    @Override public void execute(String payload, Promise promise) { delegate.execute(payload, promise); }
    @Override public void addListener(String name) { }
    @Override public void removeListeners(double count) { }
    @Override public void invalidate() { delegate.close(); super.invalidate(); }
}
