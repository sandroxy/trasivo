'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { withInfoPlist, withAndroidManifest, withDangerousMod } = require('@expo/config-plugins');

module.exports = function withTrasivo(config, options = {}) {
  // Permission wording belongs to the host. This plugin never opts into cleartext networking.
  if (options.photoUsageDescription !== undefined) {
    if (typeof options.photoUsageDescription !== 'string' || !options.photoUsageDescription.trim()) {
      throw new Error('Trasivo photoUsageDescription must be nonempty.');
    }
    config = withInfoPlist(config, value => {
      value.modResults.NSPhotoLibraryAddUsageDescription = options.photoUsageDescription;
      return value;
    });
  }
  if (options.legacyAndroidMediaPermission === true) {
    config = withAndroidManifest(config, value => {
      const manifest = value.modResults.manifest;
      const permissions = manifest['uses-permission'] || [];
      if (!permissions.some(item => item.$['android:name'] === 'android.permission.WRITE_EXTERNAL_STORAGE')) {
        permissions.push({ $: { 'android:name': 'android.permission.WRITE_EXTERNAL_STORAGE', 'android:maxSdkVersion': '28' } });
      }
      manifest['uses-permission'] = permissions;
      return value;
    });
  }
  return withDangerousMod(config, ['ios', async value => {
    const file = path.join(value.modRequest.platformProjectRoot, 'Podfile');
    let source = await fs.promises.readFile(file, 'utf8');
    if (!source.includes('# trasivo-source-pods')) {
      const marker = 'use_expo_modules!';
      if (source.split(marker).length !== 2) throw new Error('Trasivo requires one Expo application target; configure use_trasivo! manually.');
      source = source.replace(marker, `${marker}\n  # trasivo-source-pods\n  require File.join(File.dirname(\`node --print "require.resolve('@sandrox/trasivo/package.json')"\`.strip), 'ios/trasivo_pods')\n  use_trasivo!`);
      await fs.promises.writeFile(file, source);
    }
    return value;
  }]);
};
