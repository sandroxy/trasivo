# Trasivo

原生上传下载任务中心，提供可选的应用内悬浮球和任务面板。

[English](README.md) · [行为契约](doc/contract.md) · [Android 接入](doc/android.md) · [iOS 接入](doc/ios.md) · [本地构建](BUILDING.md)

任务管理、HTTP 传输、系统存储和界面分别归属独立模块。宿主负责请求、鉴权、账号隔离及上传响应的业务成功判断；核心不认识聊天、OSS、消息发布或 JavaScript 运行时。

| 平台 | 核心 | 系统保存 | 可选界面 |
| --- | --- | --- | --- |
| Android 5.0+ | `trasivo`，OkHttp | `trasivo-storage`，MediaStore、文档 URI | `trasivo-ui`，原生 Views |
| iOS 13+ | `Trasivo`，URLSession | `TrasivoStorage`，Photos | `TrasivoUI`，UIKit |

中心提供并发队列、本次进程内的记录、字节进度、保存或校验中、成功、失败、取消，以及失败或取消后的从头重试。删除记录不会删除已保存的文件。

宿主可传入品牌色、语义色、标题和语言；未传入时使用内置青色配色和**简体中文**，不自动跟随系统语言。支持简中、繁中、英文、日文，可以在悬浮球和面板打开期间更新配置。悬浮球只存在于应用内部，无需系统悬浮窗权限。

下载在目标位置保存完成后才成功；上传在宿主校验响应通过后才成功。媒体文件以流的方式传输，不整文件读入内存，也不虚构未知总量的百分比。

目前不包含进程结束后的任务恢复、暂停、断点续传、可恢复分片协议或后台持续运行保证。`multipart/form-data` 只是 HTTP 请求编码，不等于断点续传。详细限制和生命周期见[行为契约](doc/contract.md)。

当前提供源码包，`0.1.0` 是源码版本信息，不表示已有 Maven 或 Swift 正式版本发布。原生开发消费者放在 [Integrated Plugins](https://github.com/sandroxy/integrated-plugins)，本仓不包含 RN 或其他跨端桥接层。
