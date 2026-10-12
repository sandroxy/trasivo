package com.sandrox.trasivo.reactnative;

import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.module.annotations.ReactModule;

@ReactModule(name = TrasivoModule.NAME)
public final class TrasivoModule extends ReactContextBaseJavaModule {
    static final String NAME = "Trasivo";
    private final TrasivoDelegate delegate;
    public TrasivoModule(ReactApplicationContext context) { super(context); delegate = new TrasivoDelegate(context); }
    @Override public String getName() { return NAME; }
    @ReactMethod public void execute(String payload, Promise promise) { delegate.execute(payload, promise); }
    @ReactMethod public void addListener(String name) { }
    @ReactMethod public void removeListeners(double count) { }
    @Override public void invalidate() { delegate.close(); super.invalidate(); }
}
