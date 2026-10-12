package com.sandrox.trasivo.reactnative;

import com.facebook.react.BaseReactPackage;
import com.facebook.react.bridge.NativeModule;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.module.model.ReactModuleInfo;
import com.facebook.react.module.model.ReactModuleInfoProvider;
import java.util.Collections;

public final class TrasivoPackage extends BaseReactPackage {
    @Override public NativeModule getModule(String name, ReactApplicationContext context) {
        return TrasivoModule.NAME.equals(name) ? new TrasivoModule(context) : null;
    }
    @Override public ReactModuleInfoProvider getReactModuleInfoProvider() {
        return () -> Collections.singletonMap(TrasivoModule.NAME, new ReactModuleInfo(
            TrasivoModule.NAME, TrasivoModule.class.getName(), false, false, false,
            BuildConfig.IS_NEW_ARCHITECTURE_ENABLED));
    }
}
