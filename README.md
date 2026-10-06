# Warp ZTNA 发布产物

Warp ZTNA 的发布产物仓：控制面五个组件的容器镜像（GHCR），以及客户端与控制面的安装产物。
本页同时作为本仓镜像在 GHCR 包页面展示的说明。

## 容器镜像

| 镜像 | 用途 |
|---|---|
| `ghcr.io/dayu-sec/warp-ztna-api` | 控制面 API（唯一对外服务入口，容器内 8080） |
| `ghcr.io/dayu-sec/warp-ztna-orch` | 内部编排服务（仅 API 调用，容器内 8080） |
| `ghcr.io/dayu-sec/warp-ztna-ssh-ca` | SSH 证书签发适配层（仅内网调用，容器内 8080） |
| `ghcr.io/dayu-sec/warp-ztna-admin` | 运维控制台（静态站点，容器内 8080） |
| `ghcr.io/dayu-sec/warp-ztna-portal` | 用户门户（静态站点，容器内 8080） |

镜像为多架构 manifest（`linux/amd64`、`linux/arm64`）；tag 为发布版本号，不带 `latest`。

### 拉取

包当前为私有：使用 GitHub classic PAT（勾选 `read:packages`）登录后拉取。

```bash
echo "<PAT>" | docker login ghcr.io -u <用户名> --password-stdin
docker pull ghcr.io/dayu-sec/warp-ztna-api:<版本>
```

Kubernetes 里用 imagePullSecret：

```bash
kubectl -n <命名空间> create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=<用户名> --docker-password=<PAT>
helm upgrade --install warp server/k8s/warp-ztna-<版本>.tgz --set 'image.pullSecrets[0].name=ghcr-pull'
```

包转为公开后无需登录即可拉取。

### 校验

每次服务端发布在 `server/images.txt` 给出各镜像多架构 manifest 的摘要（`名称:版本@sha256:…`）：

```bash
docker buildx imagetools inspect ghcr.io/dayu-sec/warp-ztna-api:<版本>
docker pull ghcr.io/dayu-sec/warp-ztna-api@sha256:<摘要>
```

## 安装产物

| 子树 | 内容 |
|---|---|
| `server/` | 控制面：compose 与 Helm 产物、镜像摘要（见 `server/README.md`） |
| `client/` | 客户端：桌面应用安装包、路由节点归档、安装脚本（见 `client/README.md`） |

部署先决：PostgreSQL、Keycloak、NetBird 与 step-ca 均为外部依赖。安全边界：`ssh-ca` 与 `orch` 只在内网可达。

整仓校验：`sha256sum -c <子树>/checksums.txt`（在仓根执行）。

## 版本

- 服务端：tag `server-v<版本>`；客户端：tag `client-v<版本>`。
- 本仓内容由 CI 发布，请勿手工修改。
