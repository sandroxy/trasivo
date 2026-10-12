# Local verification

The repository has no automatic cloud workflow. Builds and tests below run locally; they do not start an emulator, simulator, device or private backend transfer.

Prerequisites: Python 3, JDK 17, Android SDK 36, and Xcode with an iOS SDK and Swift 5.9 or newer. Android versions and transport dependencies are pinned in `plugin.json` and the Gradle build. Reuse the existing SDK and Gradle caches.

```sh
python3 scripts/sync-ui-resources.py --check
cd native/android
./gradlew testReleaseUnitTest lintRelease assembleRelease
cd ../..
swift test --scratch-path .build/logic
xcodebuild -scheme TrasivoUI -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ios-device CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme TrasivoStorage -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ios-device CODE_SIGNING_ALLOWED=NO build
```

Android unit tests use a loopback HTTP server. Swift logic tests run on macOS, including loopback URLSession tests through `tests/fixtures/server.py`, storage media-type checks using generated images, and temporary resource naming and lifetime checks. Storage tests do not request Photos access or write to a photo library. macOS test execution does not declare a macOS UI or storage product. Generic iOS builds compile the platform code without launching a device. Logic checks cannot verify photo permissions, document providers, gesture handling, lifecycle or visual layout on hardware.

For independent consumption without the UI module, run `./gradlew :trasivo:testReleaseUnitTest :trasivo-storage:assembleRelease` from `native/android`, and `swift build --target Trasivo --scratch-path .build/logic` from the repository root. The `TrasivoStorage` generic iOS build above also compiles the core and storage without a dependency on `TrasivoUI`. These checks verify module independence; switching the overlay off in a consumer exercises the separate presentation-lifecycle contract.

`./gradlew publish` writes Maven output only to the ignored `native/android/build/maven` directory. It does not upload to a remote repository. Release distribution, signing and publication require their own reviewed contract; no published artifacts or immutable release acceptance are declared here.

Native and React Native manual consumers and their shared scenarios are maintained in [Integrated Plugins](https://github.com/sandroxy/integrated-plugins). Its development entry accepts an explicit source path and generates fixed, ignored projects. Build or open those consumers for manual testing; do not copy product implementation into them.

For RN source development, select `react-native-android` or `react-native-ios` through that repository's `development/run.rb`. Both targets share one host and dependency cache. Android preparation builds native AARs; iOS preparation copies canonical Swift sources into three local pods. Host installation, Codegen, CocoaPods and compilation run with `--build`. The shared RN build policy retains precompiled React Native dependencies by default. See the [adapter contract](adapters/react-native/README.md) for runtime lifetimes, permission setup and source-pod installation.

UI strings are authored in `resources/strings.json`. Run `python3 scripts/sync-ui-resources.py` after changing the catalog, then check in the generated Java and Swift tables together. Every locale must provide the same keys.
