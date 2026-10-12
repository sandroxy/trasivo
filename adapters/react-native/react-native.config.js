'use strict';
module.exports = { dependency: { platforms: {
  android: { sourceDir: './android',
    packageImportPath: 'import com.sandrox.trasivo.reactnative.TrasivoPackage;',
    packageInstance: 'new TrasivoPackage()' },
  ios: { podspecPath: './TrasivoReactNative.podspec' },
} } };
