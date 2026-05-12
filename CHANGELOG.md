# Changelog

## 1.0.0 - 2026-05-12

### 功能

- 首个开源版本。
- 支持本地 HTTP 代理、Range 缓存、文件预加载、HLS 预加载、HLS 播放列表改写、缓存查询和缓存清理。
- 支持缓存 identity provider，可在 URL converter 之外自定义缓存 key 归一化；设置后优先级高于 URL converter。
- 支持 HLS 下载请求头 provider，可按 playlist、key、init map、segment 等资源类型追加下载请求头。
- 支持 URLSession 下载指标回调，普通资源和 HLS 资源共用 metrics 采集路径。当前回调直接暴露 `URLSessionTaskMetrics`，不额外引入二次封装。
- 支持代理 URL 判断与原始 URL 还原 API，便于播放器链路和业务层区分代理地址。
- 提供 `cacheReader`、`cacheLoader` 与 `cacheHLSLoader`，支持不经过播放器代理时直接读取并复用缓存。
- 支持下载响应 content type 白名单与不可接受类型 disposer，支持业务侧兼容特殊服务端响应。
- 支持下载 Range 长度 provider，缺失区间回源时可按业务策略拆分 Range 请求。
- 支持控制台日志、文件日志和按 URL 记录的错误查询、清理 API。
- 提供 iOS 与 macOS 示例工程。

### HLS 下载策略

- HLS playlist、key 和完整 segment 回源默认不带播放器请求头，也不生成默认 Range。
- HLS init map 与 byte-range segment 使用 playlist 声明的 Range；HLS 下载请求头 provider 返回的 `Range` 会被忽略，避免覆盖 playlist 语义。
- HLS preload 与代理播放共用同一套下载策略、cache identity 和 metrics 采集路径。
