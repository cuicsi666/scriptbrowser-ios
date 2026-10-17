# 脚本浏览器（ScriptBrowser）V1

一个自带用户脚本引擎 + Chrome 密码导入 + 本地 Cookie API 端口的 iOS 浏览器。

## 功能

### 1. 用户脚本（Userscript）
- 解析 `// ==UserScript==` 元数据：`@name` `@namespace` `@version` `@description` `@match` `@include` `@exclude` `@run-at`
- 注入时机：`document-start` / `document-end` / `document-idle`
- 支持 GM API 子集：`GM_info` `GM_setValue` `GM_getValue` `GM_deleteValue` `GM_listValues` `GM_addStyle` `GM_log` `GM_notification` `GM_xmlhttpRequest`（基于 fetch）`unsafeWindow`
- 安装方式：
  1. App 内「脚本」页 → + → 粘贴源码 / 从网址下载 / 从文件选择
  2. 本地 API：`POST /api/userscripts`（body 直接放源码）
- 匹配在 JS 运行时完成，增删脚本即时重载生效
- 脚本 `console.log` 与报错回传到 App「运行日志」

### 2. 谷歌密码导入
- 支持 Chrome 导出的 `passwords.csv`（`name,url,username,password` 或带 `note`）
- RFC4180 引号/逗号解析，UTF-8 BOM 兼容
- 存储：AES-GCM 加密后落盘（`Documents/ScriptBrowser/credentials.enc`）
- 浏览网页时点地址栏钥匙 → 自动列出当前域名匹配凭据 → 一键填充（兼容 React/Vue 受控表单，触发 input/change 事件）

### 3. 本地 HTTP API 端口
- 默认 `8899`，App 内可改；默认要求令牌（`X-Token` 头或 `?token=`）
- 支持静音音频后台保活，App 退到后台端口仍在线
- 接口：
  - `GET /health` 健康检查（免鉴权）
  - `GET /api/cookies?domain=` 读取全部 Cookie（**含 HttpOnly**），返回 `cookie_header` 可直接塞给 curl
  - `POST /api/cookies` 写入 Cookie
  - `DELETE /api/cookies?domain=` 清除
  - `GET /api/page` / `GET /api/html` 当前页面信息 / 完整 HTML
  - `POST /api/js` 在当前页执行 JS
  - `POST /api/open` 让 App 打开指定网址
  - `GET/POST /api/userscripts` 列出 / 安装脚本（POST body 即源码，自动解析元数据）
  - `GET/DELETE /api/userscripts/{id}`、`POST /api/userscripts/{id}/toggle`
  - `GET /api/passwords?domain=` 按域名匹配密码
- `/` 提供一个网页控制台：查 Cookie、装脚本、执行 JS，全部可视化

## 使用示例

```bash
# 读某站 Cookie
curl -H 'X-Token: <令牌>' 'http://192.168.1.10:8899/api/cookies?domain=example.com'

# 自动安装用户脚本
curl -X POST -H 'X-Token: <令牌>' --data-binary @my.user.js \
     'http://192.168.1.10:8899/api/userscripts'

# 在 App 当前页执行 JS
curl -X POST -H 'X-Token: <令牌>' -H 'Content-Type: application/json' \
     -d '{"script":"document.title"}' 'http://192.168.1.10:8899/api/js'
```

## 构建

GitHub Actions（macos-15 + Xcode 16）自动构建未签名 IPA：
- `xcodegen generate`
- `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO`
- `ldid -S` 伪签名 → 打包 `脚本浏览器_V1.ipa`

## 目录

- `Sources/` Swift 源码
  - `Models.swift` 数据模型 / 加密存储 / CSV 解析
  - `ScriptEngine.swift` 用户脚本注入引擎（JS 模板）
  - `BrowserModel.swift` WKWebView 封装 / Cookie / 填充
  - `Server/HTTPServer.swift` 基于 Network.framework 的 HTTP/1.1 服务
  - `Server/APIRouter.swift` 路由 + 网页控制台
  - `Views/` 界面
- `Resources/` Info.plist、AppIcon

## 注意

- 未签名包需用全能签/AltStore 等自签安装；首次启动会请求局域网权限（用于开放端口）
- 本地 API 默认带令牌，切勿在公共网络关闭鉴权
- 密码库密钥由固定盐派生（保证重装可读），请自行保管设备
