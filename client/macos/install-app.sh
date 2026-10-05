#!/bin/sh
set -eu

WARP_VERSION="0.1.1"
BASE_URL="https://dayu-sec.github.io/warp-ztna-pkg/client"
VERSION="$WARP_VERSION"
DRY_RUN=0

usage() {
  cat <<'USAGE'
用法：install-app.sh [选项]

在 macOS 机器上一条命令完成客户端安装：装引擎（Service 包）→ 装应用（Warp ZTNA.app）。
本机已有官方 NetBird 时跳过引擎，只装应用（应用复用既有 daemon）。

选项：
  --version <x.y.z>  覆盖安装的包版本，默认脚本内嵌版本
  --base-url <URL>   分发主机地址，默认 https://dayu-sec.github.io/warp-ztna-pkg/client
  --dry-run          只打印计划，不下载不安装
  --help             显示本帮助
USAGE
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || die "--version 缺少取值"
        VERSION="$2"
        shift 2
        ;;
      --base-url)
        [ $# -ge 2 ] || die "--base-url 缺少取值"
        BASE_URL="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "未知参数：$1"
        ;;
    esac
  done
}

detect_arch() {
  case "$(uname -m)" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64|amd64) ARCH="amd64" ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
}

print_plan() {
  printf '[dry-run] 架构 %s\n' "$ARCH"
  printf '[dry-run] 引擎包 %s\n' "$PKG_URL"
  printf '[dry-run] 已有官方 NetBird 则跳过引擎；否则 installer -pkg <临时目录>/%s -target /\n' "$PKG_NAME"
  printf '[dry-run] 应用镜像 %s\n' "$DMG_URL"
  printf '[dry-run] hdiutil attach -nobrowse -readonly <临时目录>/%s -mountpoint <临时目录>/mnt\n' "$DMG_NAME"
  printf '[dry-run] ditto "<临时目录>/mnt/Warp ZTNA.app" "/Applications/Warp ZTNA.app"\n'
  printf '[dry-run] hdiutil detach <临时目录>/mnt\n'
}

install_engine() {
  if command -v netbird >/dev/null 2>&1; then
    note "检测到官方 NetBird：跳过引擎安装，只装应用（应用会复用既有 daemon）。"
    return 0
  fi
  note "下载引擎包：$PKG_URL"
  curl -fsSL -o "$WORK/$PKG_NAME" "$PKG_URL"
  note "安装引擎（Service 包）…"
  installer -pkg "$WORK/$PKG_NAME" -target /
}

install_app() {
  note "下载应用：$DMG_URL"
  curl -fsSL -o "$WORK/$DMG_NAME" "$DMG_URL"
  mkdir -p "$MNT"
  hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$WORK/$DMG_NAME" >/dev/null
  if [ -d "/Applications/Warp ZTNA.app" ]; then
    note "覆盖既有安装：/Applications/Warp ZTNA.app"
  fi
  ditto "$MNT/Warp ZTNA.app" "/Applications/Warp ZTNA.app"
  hdiutil detach "$MNT" >/dev/null
}

main() {
  parse_args "$@"
  detect_arch
  BASE="${BASE_URL%/}"
  PKG_NAME="WarpZTNA-Service-$VERSION-$ARCH.pkg"
  DMG_NAME="WarpZTNA-App-$VERSION-$ARCH.dmg"
  PKG_URL="$BASE/macos/$ARCH/$PKG_NAME"
  DMG_URL="$BASE/macos/$ARCH/$DMG_NAME"
  if [ "$DRY_RUN" -eq 1 ]; then
    print_plan
    exit 0
  fi
  [ "$(uname -s)" = "Darwin" ] || die "本脚本只能在 macOS 上运行"
  [ "$(id -u)" -eq 0 ] || die "需要 root：请用 sudo sh -s -- --version <版本> 运行"
  need_cmd curl
  need_cmd installer
  need_cmd hdiutil
  need_cmd ditto
  WORK="$(mktemp -d)"
  MNT="$WORK/mnt"
  trap 'rm -rf "$WORK"' EXIT INT TERM
  install_engine
  install_app
  note "安装完成：打开「Warp ZTNA」应用，在欢迎页点击登录，用企业域账号完成 SSO。"
}

main "$@"
