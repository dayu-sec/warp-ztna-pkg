# Warp ZTNA 产物

本仓是 Warp ZTNA 的公开产物仓，**每个组件占一个子树**：

| 子树 | 内容 |
|---|---|
| `client/` | 客户端（桌面应用）、路由节点归档、安装脚本及其校验和 |
| `server/` | 服务端五组件的 compose 与 helm 安装产物、镜像摘要（见同层 server/README.md） |

客户端取件路径（门户按同一约定派生）：

- `client/macos/<arch>/WarpZTNA-App-<版本>-<arch>.dmg`、`client/macos/<arch>/WarpZTNA-Service-<版本>-<arch>.pkg`
- `client/windows/amd64/WarpZTNA-App-<版本>-amd64.msi`
- `client/linux/amd64/WarpZTNA-App-<版本>-amd64.deb` 与 `.rpm`
- `client/<版本>/warp-ztna_<版本>_<系统>_<架构>.tar.gz` 与同层 `checksums.txt`（安装脚本的取件与校验契约）
- `client/{macos,linux}/install.sh`、`client/{macos,linux}/install-app.sh`、`client/windows/install.ps1`
- `client/checksums.txt`：全部产物的 sha256 汇总（含相对路径）

校验：`sha256sum -c client/checksums.txt`（在仓根执行）或对单个目录里的文件用同层清单。

本仓内容由 CI 发布，请勿手工修改。
