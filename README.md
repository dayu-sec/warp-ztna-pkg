# Warp ZTNA 发布产物

Warp ZTNA 的发布产物仓，按两件套组织：**服务端**（控制面部署）与**客户端**（终端用户与路由节点）。

| 产物 | 位置 | 面向 |
|---|---|---|
| 服务端 | `server/` 子树 + GHCR 镜像 `ghcr.io/dayu-sec/warp-ztna-*` | 控制面部署（运维） |
| 客户端 | `client/` 子树 | 桌面安装（终端用户）与路由节点入网（机器） |

两类产物都由 CI 发布，各自带 `checksums.txt`（校验见文末「通用」）。

## 服务端

控制面五个组件的容器镜像与安装产物。部署先决：PostgreSQL、Keycloak、NetBird 与 step-ca 均为外部依赖。

### 镜像（GHCR）

| 镜像 | 用途 |
|---|---|
| `ghcr.io/dayu-sec/warp-ztna-api` | 控制面 API（唯一对外服务入口，容器内 8080） |
| `ghcr.io/dayu-sec/warp-ztna-orch` | 内部编排服务（仅 API 调用，容器内 8080） |
| `ghcr.io/dayu-sec/warp-ztna-ssh-ca` | SSH 证书签发适配层（仅内网调用，容器内 8080） |
| `ghcr.io/dayu-sec/warp-ztna-admin` | 运维控制台（静态站点，容器内 8080） |
| `ghcr.io/dayu-sec/warp-ztna-portal` | 用户门户（静态站点，容器内 8080） |

镜像为多架构 manifest（`linux/amd64`、`linux/arm64`）；tag 为发布版本号，不带 `latest`。
目前为**私有包**：使用 GitHub classic PAT（勾选 `read:packages`）登录后拉取；转为公开后无需登录。

```bash
echo "<PAT>" | docker login ghcr.io -u <用户名> --password-stdin
docker pull ghcr.io/dayu-sec/warp-ztna-api:<版本>
```

Kubernetes 里用 imagePullSecret（`kubectl create secret docker-registry ghcr-pull …`，安装 chart 时
`--set 'image.pullSecrets[0].name=ghcr-pull'`）。摘要校验：`server/images.txt` 给出各镜像多架构
manifest 的摘要（`名称:版本@sha256:…`），用 `docker buildx imagetools inspect` 对照或按摘要直拉。

### 安装产物（`server/` 子树）

| 路径 | 内容 |
|---|---|
| `server-v<版本>.tar.gz`（Release 资产） | **部署整包**：`server/` 子树 + 本 README；`curl -fsSLO` 直链下载，解包后按 `server/checksums.txt` 校验 |
| `server/compose/` | Docker Compose 编排与环境样例（本地 / 单机部署） |
| `server/k8s/warp-ztna-<版本>.tgz` | Helm chart（整包内的单个文件） |
| `server/images.txt` | 镜像摘要清单 |
| `server/README.md` | 安装步骤与环境变量 |

安全边界：`ssh-ca` 与 `orch` 只在内网可达。

## 客户端

桌面应用（app 模式，带 UI）与路由节点（routing-peer 模式，无 UI 常驻）的安装产物；载荷是官方
`netbird` 二进制（未修改）。

| 路径 | 内容 |
|---|---|
| `client/macos/<arch>/`、`client/windows/amd64/`、`client/linux/amd64/` | 桌面安装包（`.dmg` / `.msi` / `.deb` / `.rpm`） |
| `client/<版本>/warp-ztna_<版本>_<系统>_<架构>.tar.gz` | 路由节点归档（六组合）与同层 `checksums.txt` |
| `client/{macos,linux}/install*.sh`、`client/windows/install.ps1` | 一键安装脚本 |
| `client/README.md` | 取件路径与校验 |

## 通用

- **版本**：服务端 `server-v<版本>`、客户端 `client-v<版本>`；本仓内容由 CI 发布，请勿手工修改。
- **校验**：在仓根执行 `sha256sum -c <子树>/checksums.txt`（如 `server/checksums.txt`）。
