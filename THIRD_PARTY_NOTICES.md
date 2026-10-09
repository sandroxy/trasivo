# Dependencies and provenance

Trasivo's task center, storage adapters and presentation code are maintained in this repository. No third-party transfer engine source is vendored.

| Component | Use | License / source |
| --- | --- | --- |
| OkHttp 5.4.0 | Android HTTP transport; repeatable file and multipart request bodies | [Apache-2.0](https://github.com/lysine-dev/okhttp/blob/master/LICENSE.txt) |
| Okio 3.18.2 | Android streaming progress wrapper | [Apache-2.0](https://github.com/lysine-dev/okio/blob/master/LICENSE.txt) |
| Gradle wrapper 8.14.5 | Reproducible Android build bootstrap | [Apache-2.0](https://github.com/gradle/gradle/blob/master/LICENSE) |
| JUnit 4.13.2 | Local Android unit tests | [EPL-1.0](https://github.com/junit-team/junit4/blob/main/LICENSE-junit.txt) |
| MockWebServer 5.4.0 | Local Android HTTP fixtures | [Apache-2.0](https://github.com/lysine-dev/okhttp/blob/master/LICENSE.txt) |

iOS uses Apple's Foundation, URLSession, Photos and UIKit system frameworks. Android storage uses platform MediaStore and document-provider APIs. Transitive dependency licenses remain with their respective distributions; downstream distributors must preserve applicable notices.

The Gradle wrapper is redistributed unmodified. The wrapper launchers retain their original copyright and license headers. Licensed under the Apache License, Version 2.0, reproduced in [LICENSE](LICENSE).
