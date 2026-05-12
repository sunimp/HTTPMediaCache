# HTTPMediaCache 架构维护说明

HTTPMediaCache 是一个 Swift-only 的本地 HTTP 媒体缓存库。核心路径分为代理播放、主动预加载、HLS playlist 改写、区间缓存存储和 URLSession 回源下载。

## 模块边界

- `API`：暴露 `HTTPMediaCache`、`CacheRequest`、`PreloadTask`、配置和查询入口。
- `Core`：放运行时装配、Range、代理 URL 编解码等基础能力。
- `Proxy`：承接 NIO HTTP 请求，解析代理 URL，按资源类型分发到缓存响应、回源响应或 HLS playlist 改写。
- `Pipeline`：负责把请求区间规划为本地缓存段和远端下载段。
- `Storage`：维护 URL 到缓存单元的索引、元数据、数据文件和缓存空间限制。
- `Network`：定义下载抽象和默认 `URLSessionDownloader` 实现。
- `HLS`：解析、选择、改写 playlist，并为 HLS 预加载生成资源计划。

## 代理播放链路

1. `NIOProxyServer` 接收播放器请求并进入 `HTTPRequestRouter`。
2. `ProxyRequestParser` 解码原始 URL，过滤不能透传的请求头，并规范化 Range。
3. `ProxyRequestClassifier` 区分 HLS playlist、HLS 子资源和普通媒体文件。
4. 普通媒体优先通过 `ProxyCacheResponder` 命中完整缓存或请求区间缓存。
5. 缓存未命中时，router 选择 HEAD、流式回源或拼接式回源路径。
6. 回源数据通过 `ProxyCacheWriter` 写入缓存，响应长度和 Range 由 `ProxyResponseValidator` 校验。
7. `HTTPResponseWriter+Proxy` 负责把缓存响应、数据响应和 HEAD 响应转换为 NIO 输出。

`HTTPRequestRouter` 应只保留请求生命周期、路径选择和 NIO 上下文管理；新增代理行为时优先放到 responder、writer、validator 或 parser 中。

## HLS 链路

HLS playlist 请求由 `HLSProxyResponder` 处理。它缓存原始 playlist，再在返回播放器前通过 `HLSPlaylistRewriter` 改写 URI。改写后的 variant、rendition、segment、key 和 init map URI 会重新进入代理链路。

HLS 下载请求头由 `HLSDownloadPolicy` 统一生成。playlist、key 和完整 segment 默认不继承播放器 Range；init map 与 byte-range segment 使用 playlist 中声明的 `BYTERANGE`。

## 预加载链路

`HTTPMediaCache.preload` 创建 `PreloadTask` 并进入 `PreloadCoordinator`。普通文件由 `FilePreloadExecutor` 规划和下载目标 Range；HLS 由 `HLSPreloadExecutor` 读取 playlist，递归选择子 playlist，并按 segment 数、字节数或时长限制预加载依赖资源。

预加载和代理播放共用 `CacheIndex`、`CacheUnit`、下载器、HLS 下载策略和缓存 identity provider，因此行为变更要同时验证代理和预加载测试。

## 缓存与淘汰

`CacheIndex` 管理 URL 到 `CacheUnit` 的映射。`CacheUnit` 负责 `data.bin`、`metadata.json`、已缓存区间和完整文件路径。

当前空间限制策略是 LRU 淘汰：写入前如果空间不足，`CacheIndex.prepareForWrite` 会按缓存单元的最近访问时间删除未使用中的旧缓存，并跳过正在读取或写入的缓存单元。成功写入、读取缓存数据和获取完整缓存文件路径会刷新最近访问时间；单纯查询 `cacheItem` 或缓存列表不会改变淘汰顺序。

## 下载器拆分

默认下载器由多个小组件组成：

- `URLSessionDownloader`：下载入口和编排。
- `URLSessionStreamingDelegate`：URLSession delegate、响应 continuation、body stream 和取消处理。
- `URLSessionDownloadValidator`：内容类型、内容长度和 Range 响应校验。
- `URLSessionDownloadRetryPolicy`：瞬时网络错误重试。
- `URLSessionDownloaderSettings`：超时、请求头、内容类型和 metrics 配置。
- `URLSessionDownloaderBackgroundTaskCoordinator`：iOS 后台下载任务生命周期。

新增下载行为时优先扩展对应组件，避免把策略重新堆回 `URLSessionDownloader`。

## 验证建议

- 网络层改动：运行 `swift test --scratch-path /tmp/HTTPMediaCache-swiftpm-scratch --filter URLSessionDownloaderTests`。
- 代理层改动：运行 `swift test --scratch-path /tmp/HTTPMediaCache-swiftpm-scratch --filter ProxyRangeResponseTests`。
- HLS 或预加载改动：运行 `swift test --scratch-path /tmp/HTTPMediaCache-swiftpm-scratch --filter PreloadTests` 和 `--filter HLSPlaylistRewriterTests`。
- 收尾验证：运行完整 `swift test --scratch-path /tmp/HTTPMediaCache-swiftpm-scratch`。
