# Changelog

## 1.0.1 - 2026-05-12

### 改进

- 默认缓存目录调整为系统 Caches 下的 `HTTPMediaCache`，不再使用 Documents 作为媒体缓存目录。
- 缓存索引改为首次访问时懒加载磁盘缓存，避免初始化阶段同步扫描大缓存目录。
- 空间不足错误新增结构化 `CacheError.insufficientCacheSpace(requiredLength:maxCacheLength:)`，便于调用方按错误类型处理。
- 本地代理 NIO EventLoop 默认按处理器数量配置线程数，并收敛代理运行状态维护。
- 简化预加载完成、取消和失败路径的公共清理逻辑。
- 缓存空间淘汰策略升级为 LRU：成功写入、读取缓存数据和获取完整缓存文件路径会刷新缓存单元的最近访问时间；缓存状态查询不改变淘汰顺序。
- 拆分代理路由内部职责，提取请求解析、缓存响应、回源下载、响应校验、HLS playlist 响应和代理响应写入适配，降低 `HTTPRequestRouter` 维护复杂度。
- 拆分 `URLSessionDownloader` 内部职责，提取 streaming delegate、下载配置、响应校验、重试策略和后台任务协调。
- 补充架构维护文档，明确代理播放、HLS、预加载、缓存淘汰和下载器组件边界。

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
