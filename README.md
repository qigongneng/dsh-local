# DSH Local

DSH Local 是为这台 Mac 本机编译的轻量桌面壳。它通过 `WKWebView` 展示 DeepSeek Harness 官方 Web UI，不包含第三方预编译 Harness 核心，也不代表 DeepSeek 官方背书。

当前桌面壳版本：`1.1.0 (Build 12)`。左上角徽标显示当前 DeepSeek Harness 官方运行时版本；主窗口标题显示桌面壳版本，也可通过菜单“DSH Local → 关于 DSH Local 1.1.0”查看完整构建号。

桌面壳为 macOS `WKWebView` 增加图片剪贴板兼容桥：输入框收到 PNG/JPEG/WebP/GIF 时继续使用官方网页逻辑；网页事件拿不到图片文件或收到 TIFF/图片文件时，桌面壳从本机剪贴板读取并转换为 PNG，再交回官方附件流程。该兼容层不修改官方运行时源码，官方版本更新后仍保留。

## 来源与更新

- 唯一上游源码：<https://github.com/deepseek-ai/deepseek-harness>
- 更新信号：上游仓库中不可变的 `dsh-v*` GitHub Release 标签
- 交叉校验：`registry.npmjs.org` 上 `@deepseek-ai/dsh` 的同版本发布及 `dist.integrity`
- 检查频率：登录时一次，之后每 6 小时一次
- 构建方式：优先克隆精确 Release 标签；Git 传输失败时回退到 GitHub 官方标签归档。两条路径都会核对 GitHub 标签 API 的提交、源码版本和 npm 版本，再按仓库声明的 pnpm 版本执行 frozen-lockfile 安装与官方 build
- 切换方式：新版本在隔离 `DSH_HOME` 和独立端口通过 HTTP 健康检查后，才原子切换为下次启动版本
- 更新说明：保存官方 Release 的中文说明；新版本首次启动时自动展示主要新增、改进和修复，也可从应用菜单随时回看
- 回滚方式：保留上一版本和更新前的 `~/.dsh` 本地备份；应用菜单可切回上一版本

更新不会强制终止正在运行的会话。新版本在退出并重新打开 DSH Local 后生效。

## 长会话性能修复

本机额外启用了 `dsh-host-history-lite-local`，源码位于 `plugins/dsh-host-history-lite-local`。它参考社区插件 <https://github.com/GithungDang/dsh-host-history-lite>，只折叠已完成步骤中可由最终消息重建的流式增量，不修改实时生成或磁盘会话数据。

在本机 43 步测试会话上，单页历史从 19,734 个事件、4,237,032 字节降为 360 个事件、837,525 字节；42 条最终消息、投影、分页状态与磁盘源文件哈希均保持一致。

官方更新器会在隔离环境中测试该插件与候选官方版本。兼容时继续启用；不兼容时仍更新官方核心，但临时禁用这一可选性能层，防止桌面端因第三方插件接口变化而无法启动。

## 目录

- 本项目源码：`/Users/qigongneng/Application/CODE/DSH-Local-Official`
- 官方 Release 干净源码：`/Users/qigongneng/Application/CODE/DSH-Local-Official/upstream/<版本标签>`
- 已安装应用：`/Applications/DSH Local.app`
- 应用图标源图：`/Users/qigongneng/Application/CODE/DSH-Local-Official/assets/AppIconSource.png`
- 应用图标成品：`/Users/qigongneng/Application/CODE/DSH-Local-Official/assets/AppIcon.png`
- 官方版本源码与构建产物：`~/Library/Application Support/DSHLocalOfficial/versions`
- 当前版本链接：`~/Library/Application Support/DSHLocalOfficial/current`
- 用户会话与配置：`~/.dsh`
- 更新日志：`~/Library/Application Support/DSHLocalOfficial/logs/update.log`
- Harness 日志：`~/Library/Application Support/DSHLocalOfficial/logs/harness.log`
- 数据备份：`~/Library/Application Support/DSHLocalOfficial/backups`

## 手动命令

```sh
# 检查并构建最新官方 Release
"$HOME/Library/Application Support/DSHLocalOfficial/bin/update.sh" --manual

# 回滚到上一版本（重启应用后生效）
"$HOME/Library/Application Support/DSHLocalOfficial/bin/rollback.sh"

# 重新安装或移除长会话性能层（操作后重启应用）
"/Users/qigongneng/Application/CODE/DSH-Local-Official/scripts/install-history-lite.sh"
"/Users/qigongneng/Application/CODE/DSH-Local-Official/scripts/uninstall-history-lite.sh"
```

## 安全边界

DSH Local 仅将 Web 服务绑定到 `127.0.0.1`，不会开放到局域网。DeepSeek Harness 的 Agent 可以在所选工作区执行工具和修改文件；使用时仍应只选择允许其操作的工作区。
