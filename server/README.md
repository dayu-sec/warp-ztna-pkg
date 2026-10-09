# Warp ZTNA 服务端产物

本子树是 Warp ZTNA 控制面五个组件（serve-api、serve-orch、serve-ssh-ca、web-admin、web-portal）的安装产物。

| 路径 | 内容 |
|---|---|
| `server/compose/docker-compose.yml` | 容器编排（镜像已钉到本版本；容器内统一 8080） |
| `server/compose/env.example` | 环境变量样例（复制为 `.env` 后按需修改；每一项的含义见 §2.2–§2.4） |
| `server/compose/validate-shutdown.sh` | 优雅退出窗口校验（容器窗口必须大于应用窗口） |
| `server/compose/portal-config.js`、`server/compose/admin-config.js` | 门户与管理台的运行时配置（apiUrl 与 OIDC），按部署域名修改 |
| `server/k8s/warp-ztna-<版本>.tgz` | Helm chart（镜像仓库与 tag 已配好） |
| `server/images.txt` | 五个镜像的 `名称:版本@sha256:摘要` 清单 |
| `server/checksums.txt` | 本子树文件的 sha256 汇总（含相对路径） |

镜像当前为私有包：部署机先 `echo "<PAT>" | docker login ghcr.io -u <用户名> --password-stdin`
（classic PAT，勾选 `read:packages`）。包转为公开后无需登录。

## 1 部署前：四个外部系统

PostgreSQL、Keycloak、NetBird 与 step-ca 都不在本产物里，需要在部署前各自就绪。

**PostgreSQL**——库与角色要先建好，`migrate` 只建表、不建库也不建角色。

- 连接串形如 `postgres://用户:口令@主机:5432/库名`，写进 `WARP_DATABASE_URL`。
- 升级前先备份生产库。
- 建议给库设一次时区（工单的天边界取自它，未设置时回退 UTC）：

  ```sql
  ALTER DATABASE warp_ztna SET warp.ticket_timezone = 'Asia/Shanghai';
  ```

**Keycloak**——需要一个 realm 与若干 client。

- Issuer 必须是 `https://<主机>/realms/<realm>`，且与 `{issuer}/.well-known/openid-configuration`
  返回的 `issuer` **逐字符相同**（仅末尾斜杠可容忍）。API 启动时会做一次 discovery，不可达或
  不匹配都会导致 api 反复重启。
- `WARP_OIDC_AUDIENCE` 是**资源服务的 audience**，不是 Keycloak client 名；取值须出现在 access token 的
  `aud` 里（本产品用 `warp-ztna-api`）。
- 五个 realm role——`super_admin`、`security_admin`、`operator`、`auditor`、`user`——**必须预先手工创建**，
  Keycloak 不会因为程序识别就自动生成。
- 管理台与门户各要一个 public client（本产品用 `warp-ztna-admin`、`warp-ztna-portal`），**不配 client secret**。
- 要启用身份同步（`WARP_KEYCLOAK_*` / `orch.keycloak*`）时，另需一个 confidential client 及其 secret；
  它的服务账号在目标 realm 的 `realm-management` 下需要四个角色：`view-users`、`query-users`、
  `query-groups`、`manage-users`。**缺 `manage-users` 的症状很好认：读全过、第一个写操作 403。**
- Keycloak 24+ 默认丢弃管理端写入的未声明属性（`unmanagedAttributePolicy` 为 `null`），身份同步会写
  `<provider>_*` 属性，需要在 realm 上放开。

**NetBird**——需要一个 Management API 地址与一枚 PAT。

- 目标为与 0.76.2 兼容的 NetBird Management API；PAT 请求头形如 `Authorization: Token <PAT>`。
- 该 token 的权限面要覆盖 products 实际用到的部分：users、groups、网络与资源（networks / resources）、
  policies、audit events；签发与吊销类操作还涉及 `ManagePolicies`。
- 该 token **只注入 orch**，不会出现在 api 或前端侧。

**step-ca**——SSH 证书由它签发，ssh-ca 组件只是适配层。

- 在 `ca.json` 里为适配器登记一个 JWK provisioner：带 `claims.enableSSHCA`、`claims.disableRenewal`，
  以及两个时长上限（`maxUserSSHCertDuration`、`maxHostSSHCertDuration`），并指向 SSH 模板文件。
  **改完必须重启 step-ca**，运行中的 CA 不会热加载 `ca.json`。
- 两个上限直接决定签发能不能成功：`maxUserSSHCertDuration` 不小于最长的授权窗口（不设则 CA 取内置
  24 小时默认）；`maxHostSSHCertDuration` 决定主机证书能签多久（与 §2.3 的
  `WARP_SSH_HOST_CERT_TTL_SECONDS` 配套）。
- 需要交给部署机的五件文件：CA roots（`step-ca-roots.pem`）、加密的 provisioner 私钥
  （`provisioner.jwk`）、它的口令文件（`provisioner/password`）、`ssh_user_ca_key.pub` 与
  `ssh_host_ca_key.pub`（都是公钥）。**CA 私钥不挂给任何服务**——适配器只在启动时于内存中解密
  自己那份 JWK；口令只走文件，不进环境变量、不进镜像。
- 五件文件放在一个宿主目录里，用 `STEP_CA_SECRETS_DIR` 指过去（见 §2.3）。

## 2 用 Docker Compose 部署

### 2.1 起步

1. `cd server/compose`，`cp env.example .env`，按 §2.2–§2.4 填写（至少是六个必填项，其中
   `WARP_DATABASE_URL` 指向外部库）；
2. 按部署域名改 `portal-config.js` 与 `admin-config.js`（两者的浏览器源站都要列进 API 的
   `WARP_ALLOWED_ORIGINS`，见 §2.5）；
3. 把 step-ca 的密钥文件放到 `STEP_CA_SECRETS_DIR`（默认 `./step-ca-secrets`，五件文件名见 §2.3）；
4. `sh validate-shutdown.sh` 校验优雅退出窗口（改过 `WARP_SHUTDOWN_GRACE_PERIOD_SECONDS` 或容器窗口时必跑），
   然后 `docker compose up -d` —— `migrate` 一次性服务先跑完，`api`/`orch` 才会启动。

### 2.2 必填变量

下列六项在发布 compose 里是强制项，缺失或为空时 compose 直接拒绝启动。

| 变量 | 示例 | 说明 |
|---|---|---|
| `WARP_DATABASE_URL` | `postgres://warp:口令@pg.example.com:5432/warp_ztna` | PostgreSQL 连接串；`migrate`/api/orch 都读它 |
| `WARP_OIDC_ISSUER` | `https://kc.example.com/realms/warp-ztna` | Keycloak realm issuer，见 §1；api 启动前会拉一次 discovery |
| `WARP_OIDC_AUDIENCE` | `warp-ztna-api` | 资源服务 audience，不是 client 名 |
| `WARP_ALLOWED_ORIGINS` | `https://admin.example.com,https://portal.example.com` | 允许跨源调用 API 的浏览器源站，**逗号分隔**；每项要带 scheme，形如 `scheme://host[:port]`，不要尾斜杠与路径，不接受 `*`，不接受空项。管理台与门户**两个源站都要列**；桌面端是本机原生进程，不需要列 |
| `WARP_NETBIRD_BASE_URL` | `https://netbird.example.com` | NetBird Management API 基址；只注入 orch |
| `WARP_NETBIRD_API_TOKEN` | `eyJ…` | NetBird PAT；只注入 orch |

### 2.3 常用变量

有模板默认值，但取值与部署环境相关，通常要改。

| 变量 | 默认 | 说明 |
|---|---|---|
| `WARP_LOCAL_SESSION_SECURE` | 模板默认 `true` | 只接受字面 `true`/`false`。管理台走 HTTPS 时保持 `true`；**若管理台是 http 访问，必须改 `false`**，否则浏览器不回传会话 Cookie，表现为「登录不上」 |
| `WARP_LOCAL_SESSION_TTL_HOURS` | `12` | 本地管理员会话时长（小时） |
| `WARP_API_PORT` / `WARP_ADMIN_PORT` / `WARP_PORTAL_PORT` / `WARP_SSH_CA_PORT` | `8080` / `5173` / `5174` / `8091` | **宿主**端口（容器内一律 8080，不可改）。ssh-ca 的映射只绑 `127.0.0.1` |
| `WARP_CLIENT_PKG_BASE_URL` | 官方产物站点 | 客户端安装包的下载基址，API 通过 `/api/v1/client-package` 把它发给门户；门户据此拼安装命令与校验码链接。只有自建镜像站点时才改——**改了门户上的安装命令会整体跟着变** |
| `STEP_CA_SECRETS_DIR` | `./step-ca-secrets` | 存放五件 step-ca 文件的宿主目录（roots、provisioner.jwk、provisioner/password、ssh_user_ca_key.pub、ssh_host_ca_key.pub） |
| `STEP_CA_NETWORK` | `step-ca_step_ca_internal` | step-ca 那套 compose 创建的外部网络名；**必须已存在**，否则 ssh-ca 起不来 |
| `STEP_CA_URL` | `https://step-ca:9000` | step-ca 端点。用默认编排时不用改；换部署方式时改 |
| `STEP_CA_SSH_USER_CA_FILE` / `STEP_CA_SSH_HOST_CA_FILE` | `./step-ca-secrets/ssh_{user,host}_ca_key.pub` | 两个公钥的宿主路径，单独覆盖时用 |
| `WARP_KEYCLOAK_BASE_URL` / `_REALM` / `_CLIENT_ID` / `_CLIENT_SECRET` | 空 / `warp-ztna` / 空 / 空 | 身份同步（Keycloak → NetBird）。**规则：三件里任一非空则三件全必填；全空＝关闭身份同步**（Mesh 准入、资源与策略仍可用）。`BASE_URL` 只填到主机（如 `https://kc.example.com`），**不要带 `/realms`** |
| `WARP_SSH_HOST_CERT_TTL_SECONDS` | `15552000`（180 天） | 主机证书有效期（秒）。**必须落在 step-ca 的两个边界之间**：下限是 CA 内置的 5 分钟，上限是 `claims.maxHostSSHCertDuration`（CA 未改时只有 30 天）。超出边界时每次签发都失败；要么抬高 CA 上限，要么把这个值降到上限以内 |

### 2.4 调参变量

都带默认值，起步不用动。**这些键不在 `env.example` 里**——要改就直接往 `.env` 追加。唯一例外：`WARP_POLICY_POSTURE_CHECK_JSON` 缺省即启用，已随 `env.example` 给出。

| 变量 | 默认 | 说明 |
|---|---|---|
| `WARP_IDENTITY_SYNC_INTERVAL_SECONDS` | `14400` | Keycloak → NetBird 身份对账周期；外部身份源同步共用同一拍 |
| `WARP_AUDIT_POLL_INTERVAL_SECONDS` | `900` | NetBird 审计事件轮询周期；syslog 外发也挂在这一拍上 |
| `WARP_AUTHZ_APPLY_INTERVAL_SECONDS` | `120` | 已批准但尚未建 peer 的工单重试周期 |
| `WARP_AUTHZ_RECONCILE_INTERVAL_SECONDS` | `900` | 回收过期/吊销的 JIT 策略与孤儿 peer 组 |
| `WARP_ASSET_SYNC_INTERVAL_SECONDS` | `43200` | 资产中心快照拉取周期 |
| `WARP_AUDIT_RETENTION_DAYS` | `90` | 审计台账保留天数（按时间删，不看投递状态） |
| `WARP_AUTHZ_AUTO_APPROVE_ENABLED` / `_MAX_SECONDS` | `true` / `604800` | 自动批准开关与上限（秒）：**严格短于**该时长的租约自动批准，等于该值仍走人工。门户与管理台读同一值 |
| `WARP_AUTO_APPROVE_INITIAL_ENABLED` | `false` | 只在**首次初始化**时写初值，之后改动存库、重启不覆盖 |
| `WARP_NETBIRD_MANAGED_PREFIX` | `warp-ztna` | NetBird 侧受管对象的命名前缀（1–64 字符，仅字母数字与 `-`）。**改它不会迁移既有对象**，旧对象会「看不见」 |
| `WARP_POLICY_TEMPLATES_JSON` | `[]` | 策略模板（JSON 数组）；`[]` 即关闭，管理台仍可手工建策略。格式非法会让进程拒绝启动 |
| `WARP_POLICY_POSTURE_CHECK_JSON` | 引擎 + UI 双条目 | 终端姿态检查（JSON 对象）；缺省启用（`env.example` 已带出），空即关闭。口径与可复制值见下方 |
| `WARP_ASSET_CENTER_BASE_URL` / `_TOKEN` / `_SNAPSHOT_PATH` | 空 / 空 / `/api/v1/ztna/asset-graph/snapshot` | 资产中心接入；`BASE_URL` 空即关闭 |
| `WARP_IDENTITY_SOURCE_*`（9 项） | `WARP_IDENTITY_SOURCE_ENABLED=false` | 外部身份源（钉钉）同步；关闭时半填也不报错，一旦置 `true`，provider、App Key/Secret、部门 id 等全部必填 |
| `WARP_LOG_FORMAT` / `RUST_LOG` | `full` / `info` | 日志格式（`full`/`json`/`compact`/`pretty`）与 tracing 过滤串 |
| `WARP_SHUTDOWN_GRACE_PERIOD_SECONDS` / `WARP_CONTAINER_STOP_GRACE_PERIOD_SECONDS` | `25` / `30` | 应用侧排水窗口与容器侧宽限窗口（秒）。**容器窗口必须严格大于应用窗口**（见 §2.6） |
| `WARP_AUTHZ_REQUEST_TIMEOUT_SECONDS` / `WARP_SSH_CA_REQUEST_TIMEOUT_SECONDS` / `STEP_CA_REQUEST_TIMEOUT_SECONDS` | `120` / `30` / `30` | api→orch、api/orch→ssh-ca、ssh-ca→step-ca 的调用超时（秒） |

缺省启用值（引擎 + 客户端 UI 两条目；`.env` 里保持单引号包裹。升级的旧 `.env` 里没有这一行时仍是关闭，补上即启用）：

```
WARP_POLICY_POSTURE_CHECK_JSON='{"processes":[{"linux_path":"/usr/local/lib/warp-ztna/netbird","mac_path":"/usr/local/lib/warp-ztna/netbird","windows_path":"C:\\Program Files\\Warp ZTNA\\netbird.exe"},{"linux_path":"/usr/bin/warp-ztna-app","mac_path":"/Applications/Warp ZTNA.app/Contents/MacOS/warp-ztna-app","windows_path":"C:\\Program Files\\Warp ZTNA\\warp-ztna-app.exe"}]}'
```

- **条目之间是与关系**：引擎与客户端 UI 都要在跑——只装引擎不装 UI、或把 UI 完全退出的机器会不过检查（策略不下发）；这类部署把该变量置空即关闭。
- **机队复用官方 NetBird** 时，把第一条目（引擎）换成官方路径 `/usr/local/bin/netbird`、`/Applications/NetBird.app/Contents/MacOS/netbird`、`C:\Program Files\NetBird\netbird.exe`；第二条目（UI）不变。

以下三类**不要改**，它们是与编排/挂载绑定的契约，发布 compose 里已按容器内形态写死：
`WARP_API_BIND_ADDR`、`WARP_ORCH_BIND_ADDR`、`WARP_SSH_CA_BIND_ADDR`（容器内一律 `0.0.0.0:8080`）；
`WARP_ORCH_BASE_URL`、`WARP_SSH_CA_BASE_URL`（容器网络内的服务名）；`STEP_CA_ROOTS_FILE`、
`STEP_CA_PROVISIONER_JWK_FILE`、`STEP_CA_PROVISIONER_JWK_PASSWORD_FILE`（容器内挂载点）。

另有一项本套产物**没有接线**、两处部署方式都改不了：`WARP_SSH_MANUAL_CERT_MAX_TTL_SECONDS`
（手工签发用户证书的有效期上限，程序内默认 86400 秒）。

### 2.5 运行时配置：`portal-config.js` 与 `admin-config.js`

两个文件由 compose 只读挂载，覆盖镜像内的 `/usr/share/nginx/html/config.js`，改完需重建容器
（用编辑器改名保存的文件在新 inode 上，容器仍看旧的，`docker compose up -d --force-recreate` 可解）。

| 字段 | 适用 | 说明 |
|---|---|---|
| `apiUrl` | 两个文件 | 浏览器访问 API 的基址（绝对地址，跨源直连 API）。**两个文件的源站都要出现在 `WARP_ALLOWED_ORIGINS` 里**；若在外围用 ingress 把 `/api` 路由到 api 服务，可留空走同源 |
| `oidcIssuer` / `oidcClientId` / `oidcScope` | 两个文件 | 与 §1 的 Keycloak realm 和各自 public client 对应（默认分别是 `warp-ztna-admin`、`warp-ztna-portal`） |
| `desktopVersion` | portal | 客户端版本，**打包时注入，不要手改** |
| `desktopWindowsUrl` / `desktopMacosUrl` / `desktopMacosArm64Url` / `desktopMacosAmd64Url` / `desktopLinuxUrl` | portal | 下载地址的**显式覆盖**；`"#"`（或空）＝不使用覆盖、按 `clientPkgBaseUrl` + `desktopVersion` 派生（macOS 按架构、Windows/Linux 按 amd64）；只有 `desktopVersion` 为空时按钮才显示「下载地址未配置」 |
| `desktopChecksumsUrl` / `clientPkgBaseUrl` | portal | 校验码清单与安装包基址；自建镜像站时一并改 |
| `adminConsoleUrl` | portal | 门户里「进管理台」的链接；留空即隐藏该入口 |
| `netbirdManagementUrl` | portal | 门户「路由节点」安装命令里的 `--management-url`，**取值与 `WARP_NETBIRD_BASE_URL` 相同**；留空则命令里渲染成 `<management-url>` 占位符，抄走的人会漏填、节点脚本直接报错 |

### 2.6 启动、停止与优雅退出

- `migrate` 是一次性服务，`api`/`orch` 等它成功退出后才启动；`admin` 只保证在 api 之后启动，
  不等 api 健康。
- api/orch/ssh-ca 收到 `SIGTERM` 后先停止接纳新工作，再排空已建立的连接；超过应用侧窗口即终止剩余工作。
- 因此两个窗口必须满足**容器窗口 > 应用窗口**（默认 30s > 25s）。改动任一个之后都要先校验：

  ```bash
  set -a; . ./.env; set +a     # 脚本只读当前 shell 环境，不解析 .env
  sh validate-shutdown.sh
  ```

  脚本拒绝非正值，以及不大于应用窗口的容器窗口。Helm 侧在模板渲染时做同样的校验。

### 2.7 端口与暴露面

| 组件 | 宿主端口 | 说明 |
|---|---|---|
| api | `${WARP_API_PORT:-8080}` → 容器 8080 | 唯一对外入口；宿主侧绑所有网卡，对外暴露前请自行加反向代理或防火墙 |
| admin | `${WARP_ADMIN_PORT:-5173}` → 容器 8080 | 同上，绑所有网卡 |
| portal | `${WARP_PORTAL_PORT:-5174}` → 容器 8080 | 同上，绑所有网卡 |
| ssh-ca | `127.0.0.1:${WARP_SSH_CA_PORT:-8091}` → 容器 8080 | **只绑回环**，见 §5 |
| orch | 不发布宿主端口 | 只在容器网络内被 api 调用 |

## 3 用 Kubernetes（Helm）部署

chart 在 `server/k8s/warp-ztna-<版本>.tgz`；镜像仓库与 tag 已经配好，置好 Secret 即可安装。

### 3.1 前置 Secret

三张 Secret **用固定名**（不带 release 前缀，可用 values 里的 `*.existingSecret` 改成别的名字）。
命名空间里没有它们，Pod 不会起来。

| Secret（默认名） | 键 | 用途 |
|---|---|---|
| `warp-ztna-api` | `database-url` | PostgreSQL 连接串（`WARP_DATABASE_URL`） |
| `warp-ztna-orch` | `database-url`、`netbird-api-token`、`keycloak-client-secret`、`asset-center-token`、`identity-source-dingtalk-app-secret` | orch 的全部凭据。**五个键是无条件引用的**：相关功能没开也照样引用，**少任何一个键，orch Pod 会卡在 `CreateContainerConfigError`** |
| `step-ca-ssh-ca` | `step-ca-roots.pem`、`provisioner.jwk`、`provisioner.password`、`ssh_user_ca_key.pub`、`ssh_host_ca_key.pub` | §1 的五件文件。键名可用 values 的 `sshCa.*Key` 改；**键名与容器内文件名不同名**，容器内固定挂到 `/run/secrets/` 下。`provisioner.password` 留空即明文 JWK 模式（仅调试用） |

migrate 是一次性 Job（`pre-install,pre-upgrade` hook），**首次安装前 Secret 就必须就位**——
它读 `warp-ztna-api` 的 `database-url`。

### 3.2 必改的 values

| 键 | 默认（占位） | 说明 |
|---|---|---|
| `api.allowedOrigins` | `[https://ztna.example.com]` | 浏览器源站列表，**管理台与门户都要列** |
| `api.oidcIssuer`、`portal.oidcIssuer`、`admin.oidcIssuer` | 示例域名 | 改成你们 Keycloak 的 realm issuer |
| `portal.apiUrl`、`admin.apiUrl` | `https://ztna.example.com` | 浏览器访问 API 的绝对地址；也要在 `api.allowedOrigins` 里 |
| `orch.netbirdBaseUrl` | `https://netbird.example.com` | NetBird Management API 基址 |
| `orch.keycloakBaseUrl` | `https://keycloak.example.com` | Keycloak 基址（不带 `/realms`） |
| `sshCa.stepCaUrl` | `https://step-ca.step-ca.svc:9000` | step-ca 端点 |
| `portal.desktop*Url`（5 项） | `"#"` | `"#"`＝不使用该覆盖值，回退到 clientPkgBaseUrl 派生路径 |
| `portal.netbirdManagementUrl` | 空 | 门户「路由节点」安装命令里的 Management 地址，**填 `orch.netbirdBaseUrl` 的同一个值**；留空则命令里是 `<management-url>` 占位符 |

### 3.3 values 说明

| 键 | 默认 | 影响 | 什么时候改 |
|---|---|---|---|
| `image.{api,orch,sshCa,admin,portal}.repository` / `.tag` | `ghcr.io/dayu-sec/warp-ztna-*` / 本版本号 | 拉取哪个镜像 | **不要手改**（CI 钉住） |
| `image.pullPolicy` | `IfNotPresent` | 镜像拉取策略 | 需要每次校验镜像时改 |
| `image.pullSecrets` | `[]` | 私有包的 `imagePullSecrets` | 私有包时填（见 §3.5） |
| `replicaCount` | `1` | api/admin/portal 的副本数 | 保持 `1`——产品前提是单副本 |
| `shutdown.gracePeriodSeconds` / `.terminationGracePeriodSeconds` | `25` / `30` | 应用侧与容器侧窗口 | 改的话两者要保持「容器 > 应用」，渲染时会校验 |
| `logging.format` / `logging.rustLog` | `full` / `info` | 三个服务的日志格式与过滤串 | 排障时可临时调细 |
| `netbirdManagedPrefix` | `warp-ztna` | NetBird 受管对象前缀 | 改名前请确认没有既有对象（改名不迁移） |
| `api.localSessionSecure` | `true` | 本地管理员会话 Cookie 是否带 `Secure` | 管理台走 http 时改 `false` |
| `api.localSessionTtlHours` | `12` | 会话时长 | 需要时改 |
| `api.authzRequestTimeoutSeconds` | `120` | api→orch 调用超时 | 需要时改 |
| `api.clientPkgBaseUrl` | 官方产物站点 | 门户安装命令的下载基址 | 自建镜像站点时改 |
| `api.policyTemplates` | 三条示例 | 策略模板（JSON）；`[]` 即关闭 | 按部署策略替换或清空 |
| `api.existingSecret` / `api.databaseUrlKey` | `warp-ztna-api` / `database-url` | 库连接串的来源 | 用别的 Secret 名/键名时改 |
| `orch.enabled` / `sshCa.enabled` | `true` | 是否部署 orch / ssh-ca | 单独停用某组件时改 |
| `orch.existingSecret` / `orch.databaseUrlKey` | `warp-ztna-orch` / `database-url` | orch 凭据来源 | 同上 |
| `orch.netbirdTokenKey` / `orch.keycloakClientSecretKey` / `orch.assetCenterTokenKey` / `orch.identitySourceDingtalkAppSecretKey` | 各默认键名 | 上述 Secret 里对应键的名字 | **键名本身是必填引用**，改名要同步 Secret |
| `orch.keycloakRealm` / `orch.keycloakClientId` | `warp-ztna` / `warp-ztna-sync` | 身份同步用的 realm 与 client | 与 §1 的 Keycloak 配置对齐 |
| `orch.identitySyncIntervalSeconds` 等五个间隔 + `orch.auditRetentionDays` | 见 §2.4 同项 | 后台任务周期 | 默认即可起步 |
| `orch.assetCenterBaseUrl` / `.assetCenterSnapshotPath` | 空 / 默认路径 | 资产中心接入 | 空即关闭 |
| `orch.authzAutoApproveEnabled` / `.authzAutoApproveMaxSeconds` | `true` / `604800` | 自动批准开关与上限 | 与 §2.4 同义 |
| `orch.autoApproveInitialEnabled` | `false` | 首次初始化种子 | 只在首装时有影响 |
| `orch.identitySource*`（含 9 项） | `enabled: false` | 外部身份源（钉钉） | 启用时各字段全必填 |
| `orch.postureCheck` | 引擎 + UI 双条目 | 终端姿态检查（JSON 对象）；取值与替换口径见 §2.4 同项 | 置 `null` 即关闭；机队复用官方 NetBird、或只装引擎不装 UI 时替换/关闭 |
| `orch.sshHostCertTtlSeconds` | `15552000`（180 天） | 主机证书有效期 | 与 CA 上限配套，见 §2.3 同项 |
| `sshCa.provisionerName` | `warp-ztna-ssh-ca` | 必须与 `ca.json` 里登记的一致 | 改名时同步 CA |
| `sshCa.requestTimeoutSeconds` | `30` | ssh-ca→step-ca 超时 | 需要时改 |
| `sshCa.existingSecret` / `*Key` | `step-ca-ssh-ca` / 五个默认键名 | §3.1 第三张 Secret | 用别的 Secret 时改 |
| `admin.*` / `portal.*`（OIDC 与 apiUrl 见 §3.2） | — | 两个前端 ConfigMap 的内容 | `portal.desktopVersion` **不要手改**（跟客户端版本，CI 钉住） |
| `service.type` | `ClusterIP` | api/admin/portal 的 Service 类型 | 需要对外时改；**orch 与 ssh-ca 恒为 ClusterIP，不提供对外入口** |
| `service.apiPort` / `.adminPort` / `.portalPort` | `8080` / `80` / `8081` | Service 端口（容器内恒 8080） | 需要时改 |
| `resources.requests` / `.limits` | `100m`/`128Mi` / `1000m`/`512Mi` | 仅 api/admin/ssh-ca | 按集群规格调 |

健康检查：api/orch/ssh-ca 各有 `GET /health/live` 与 `GET /health/ready`；admin/portal 只有
readiness（`GET /`）。chart 不含 Ingress，也没有 values schema——建议改完 values 先
`helm template` 干跑一遍再安装。

### 3.4 不要手改的项

`image.*.tag` 与 `image.*.repository`、`Chart.yaml` 的 `version` / `appVersion`、
`portal.desktopVersion` —— 前两组必须与发布版本一致，`desktopVersion` 跟的是**客户端**版本，
它们都由 CI 门禁钉住；手改会让下一次升级对不上。

### 3.5 私有镜像包

包为私有时，节点拉不动镜像。二选一：

- 建 `imagePullSecret` 并传进 chart：

  ```bash
  kubectl -n <命名空间> create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io --docker-username=<用户名> --docker-password=<PAT>
  helm upgrade --install warp server/k8s/warp-ztna-<版本>.tgz \
    --set 'image.pullSecrets[0].name=ghcr-pull'
  ```

  注意：**migrate Job 不使用 `imagePullSecrets`**。私有包场景下要么把它加给命名空间的默认
  ServiceAccount，要么把包转为公开。
- 或者把五个包切为公开（一次性动作，见包设置）。

### 3.6 安装与升级

```bash
helm upgrade --install warp server/k8s/warp-ztna-<版本>.tgz
```

- 迁移由 api 镜像以 Job 形式执行（`pre-install`/`pre-upgrade` hook），不需要手工跑。
- **api 与 orch 必须同批升级**：库结构变了而 orch 还是旧版，会在重启前读不到新表。
- 升级前先备份生产库；回滚用上一版本的同套产物（`helm upgrade` 指回旧 tgz，或
  `docker compose up -d` 用旧目录）。

## 4 镜像与产物校验

- 本子树的完整性：在仓根执行 `sha256sum -c server/checksums.txt`。
- 镜像：`server/images.txt` 给出五个镜像多架构 manifest 的摘要（`名称:版本@sha256:…`），
  用 `docker buildx imagetools inspect ghcr.io/dayu-sec/warp-ztna-api:<版本>` 对照，或按摘要直拉。

## 5 安全边界

`ssh-ca` 仅供 `api`/`orch` 调用、`orch` 仅供 `api` 调用，两者都只在内网可达——Compose 里 ssh-ca 只绑
`127.0.0.1`、orch 不发布宿主端口；Kubernetes 里两者都只出 ClusterIP。两者对内部调用均不加凭据：
任何能到达其端口的进程都能让 CA 签出证书（ssh-ca），或驱动 Mesh/策略操作与签发链（orch）。

本仓内容由 CI 发布，请勿手工修改。
