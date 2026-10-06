# Warp ZTNA 服务端产物

本子树是 Warp ZTNA 控制面五个组件（serve-api、serve-orch、serve-ssh-ca、web-admin、web-portal）的安装产物。

| 路径 | 内容 |
|---|---|
| `server/compose/docker-compose.yml` | 容器编排（镜像已钉到本版本；容器内统一 8080） |
| `server/compose/env.example` | 环境变量样例（复制为 `.env` 后按需修改） |
| `server/compose/validate-shutdown.sh` | 优雅退出窗口校验（容器窗口必须大于应用窗口） |
| `server/compose/portal-config.js`、`server/compose/admin-config.js` | 门户与管理台的运行时配置（apiUrl 与 OIDC），按部署域名修改 |
| `server/k8s/warp-ztna-<版本>.tgz` | Helm chart（镜像仓库与 tag 已配好） |
| `server/images.txt` | 五个镜像的 `名称:版本@sha256:摘要` 清单 |
| `server/checksums.txt` | 本子树文件的 sha256 汇总（含相对路径） |

Compose 起步（PostgreSQL、Keycloak、NetBird 与 step-ca 都是外部依赖，按接入条件准备）：

1. `cd server/compose`，`cp env.example .env`，按 `env.example` 填写（含外部库的 `WARP_DATABASE_URL`）；
2. 按部署域名改 `portal-config.js` 与 `admin-config.js`（两者的前端源站都要列进 API 的 `WARP_ALLOWED_ORIGINS`）；
3. 把 step-ca 的密钥文件放到 `STEP_CA_SECRETS_DIR`（默认 `./step-ca-secrets`）；
4. `sh validate-shutdown.sh` 校验优雅退出窗口（改过 `WARP_SHUTDOWN_GRACE_PERIOD_SECONDS` 或容器窗口时必跑），然后 `docker compose up -d`（`migrate` 一次性服务先跑完，`api`/`orch` 才会启动）。

Kubernetes 安装（先决：命名空间内已有 `api`、`orch`、`ssh-ca` 三个 Secret）：

1. 校验产物：在仓根执行 `sha256sum -c server/checksums.txt`；
2. `helm upgrade --install warp server/k8s/warp-ztna-<版本>.tgz`（可按需 `-f` 覆盖 values）。

镜像校验：`docker buildx imagetools inspect ghcr.io/dayu-sec/warp-ztna-api:<版本>` 的摘要应与 `server/images.txt` 一致。

升级与回滚：升级前先备份生产库，再替换产物并 `docker compose up -d` 或 `helm upgrade`（migrate 以 Job/一次性服务先行）；回滚用上一版本的同套产物。

安全边界：`ssh-ca` 仅供 `api`/`orch` 内网调用（Compose 只绑 `127.0.0.1`，Kubernetes 只出 ClusterIP）；任何能到达它端口的东西都能让 CA 签出证书。

本仓内容由 CI 发布，请勿手工修改。
