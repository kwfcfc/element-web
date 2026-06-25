# Element Web 部署

[![构建状态](https://crow-ci.goba.ip-dynamic.org/api/v1/badges/8/status.svg?branch=pages)](https://crow-ci.goba.ip-dynamic.org/kwfcfc/element-web)

本仓库通过 [Crow CI](https://crow-ci.goba.ip-dynamic.org/kwfcfc/element-web) 将 Element Web 部署到 Cloudflare Pages。

构建流程不从源码编译，而是下载上游官方发布的、经 GPG 签名的预构建发布包，验证签名后注入自定义配置与 HTTP 头，再用 wrangler 上传。

## 上游

- **上游项目**：[element-hq/element-web](https://github.com/element-hq/element-web)
- **跟踪版本**：`v1.12.21`（在 `.crow.jsonnet` 中修改 `upstreamTag` 即可切换版本）

## 实例

- **前端域名**：`element.recursion-link.eu.org`
- **实例域名**：`matrix.recursion-link.eu.org`
