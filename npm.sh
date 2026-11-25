#!/bin/bash

# ==================== 调试日志设置 ====================
LOG="${HY_LOG:-/tmp/hysteria-debug.log}"
: > "$LOG" 2>/dev/null || true
log() { local m="[$(date '+%F %T')] $*"; echo "$m"; echo "$m" >>"$LOG" 2>/dev/null; }
# 需要命令级逐条追踪可这样跑： TRACE=1 bash npm.sh
[ "${TRACE:-0}" = "1" ] && set -x
log "==================== 开始执行 npm.sh ===================="
log "PWD=$PWD"
log "USER=$(id -un 2>/dev/null)  ARCH=$(uname -m)  KERNEL=$(uname -r)"
log "调试日志文件: $LOG"

# ✅ 获取 hyp 变量：从环境变量 HYP 或第一个参数 $1 中取
hyp="${HYP:-$1}"
log "原始 hyp=[$hyp]  (HYP=[$HYP], 参数1=[$1])"

# 检查是否设置了 hyp
if [ -z "$hyp" ]; then
  echo "错误：未提供 hyp 端口号，请通过 HYP 环境变量或脚本参数传入"
  exit 1
fi

# ✅ 如果 hyp 是纯数字端口，自动补上冒号
#    Hysteria 的 listen 需要 “:端口” 或 “host:port”，裸端口号会导致启动失败
if [[ "$hyp" =~ ^[0-9]+$ ]]; then
  hyp=":$hyp"
  log "hyp 是纯数字端口，已补冒号 -> [$hyp]"
fi

# ✅ 如果 realm 地址里写了 lport=0（Hysteria 会判为非法、导致启动失败），
#    自动去掉 lport=0 这个参数 —— 不写 lport 即表示使用随机 UDP 端口
if [[ "$hyp" == *"lport=0"* ]]; then
  _base="${hyp%%\?*}"                        # ? 之前的部分
  if [[ "$hyp" == *"?"* ]]; then
    _query="${hyp#*\?}"                      # ? 之后的查询串
    _newq=""
    _oldifs="$IFS"; IFS='&'
    for _p in $_query; do
      [[ -z "$_p" || "$_p" == "lport=0" ]] && continue
      _newq="${_newq:+$_newq&}$_p"
    done
    IFS="$_oldifs"
    if [[ -z "$_newq" ]]; then hyp="$_base"; else hyp="${_base}?${_newq}"; fi
  else
    hyp="$_base"
  fi
  unset _base _query _newq _p _oldifs
  log "检测到 lport=0（非法），已移除该参数 -> [$hyp]"
fi

# ✅ 创建 .npm 文件夹（如果不存在）
log "创建工作目录 .npm 并进入"
mkdir -p .npm || { log "❌ 创建 .npm 失败"; exit 1; }
cd .npm || { log "❌ 进入 .npm 失败"; exit 1; }
log "当前工作目录: $PWD"

# ✅ 根据当前机器架构选择对应的 Hysteria 二进制
case "$(uname -m)" in
  x86_64|amd64)
    HY_BIN="hysteria-linux-amd64" ;;
  aarch64|arm64)
    HY_BIN="hysteria-linux-arm64" ;;
  i386|i686)
    HY_BIN="hysteria-linux-386" ;;
  armv7l|armv7)
    HY_BIN="hysteria-linux-arm" ;;
  *)
    log "❌ 无法识别当前架构 $(uname -m)，请手动指定 Hysteria 二进制"
    exit 1 ;;
esac
log "架构映射: $(uname -m) -> $HY_BIN"

# ✅ 下载 Hysteria 最新版本（对应架构），并命名为 npm
#    依次尝试多种下载工具，任一成功即可（某个命令不存在或下载失败会自动回退到下一个）
URL="https://github.com/apernet/hysteria/releases/latest/download/${HY_BIN}"

# 尝试用某个命令下载：命令存在、且生成了非空的 npm 文件，才算成功
_try_dl() {
  local tool="$1"; shift
  command -v "$tool" >/dev/null 2>&1 || return 1   # 命令不存在，直接跳过
  rm -f npm
  "$@" >/dev/null 2>&1 || true
  [ -s npm ]                                        # 产物非空才算成功
}

DL_OK=0
if   _try_dl curl    curl -fL --connect-timeout 20 --retry 2 -o npm "$URL"; then DL_OK=1; echo "使用 curl 下载成功"
elif _try_dl wget    wget -q --timeout=20 --tries=2 -O npm "$URL";          then DL_OK=1; echo "使用 wget 下载成功"
elif _try_dl aria2c  aria2c -q --allow-overwrite=true --auto-file-renaming=false -o npm "$URL"; then DL_OK=1; echo "使用 aria2c 下载成功"
elif _try_dl axel    axel -q -o npm "$URL";                                  then DL_OK=1; echo "使用 axel 下载成功"
elif _try_dl busybox busybox wget -q -O npm "$URL";                          then DL_OK=1; echo "使用 busybox wget 下载成功"
elif _try_dl fetch   fetch -q -o npm "$URL";                                then DL_OK=1; echo "使用 fetch 下载成功"
elif _try_dl python3 python3 -c 'import socket,urllib.request,sys; socket.setdefaulttimeout(30); urllib.request.urlretrieve(sys.argv[1],"npm")' "$URL"; then DL_OK=1; echo "使用 python3 下载成功"
elif _try_dl python  python  -c 'import socket,urllib.request,sys; socket.setdefaulttimeout(30); urllib.request.urlretrieve(sys.argv[1],"npm")' "$URL"; then DL_OK=1; echo "使用 python 下载成功"
elif _try_dl http    http --follow --download --output npm "$URL";           then DL_OK=1; echo "使用 httpie 下载成功"
fi

if [ "$DL_OK" -ne 1 ]; then
  log "❌ 下载失败：本机没有可用的下载工具（curl/wget/aria2c/axel/busybox/fetch/python3/python/http）或全部下载失败。"
  log "请手动下载后保存为当前目录下的 npm（即 .npm/npm），并 chmod +x npm。URL: $URL"
  exit 1
fi

# ✅ 下载结果检查
log "下载阶段结束: DL_OK=$DL_OK, npm 大小=$(stat -c%s npm 2>/dev/null || echo '?') bytes"
log "npm 文件类型: $(file -b npm 2>/dev/null || echo 'file 命令不可用')"

# ✅ 授予执行权限
chmod +x npm
log "已执行 chmod +x npm"
log "二进制自检 ./npm version: $(./npm version 2>&1 | head -3 | tr '\n' ' ')"

# ✅ 写入 config.yaml 文件
log "写入 config.yaml，listen=[$hyp]"
cat > config.yaml <<EOF
listen: $hyp

realm:
  stunServers:
    - stun.l.google.com:19302
  stunTimeout: 6s
  punchTimeout: 12s
  heartbeatInterval: 25s
  insecure: true
  ipMode: v4
  portMapping:
    enabled: true
    timeout: 3s
    lifetime: 2h

tls:
  cert: cert.pem
  key: private.key
  alpn:
    - h3      
auth:
  type: password
  password: 0ff0350e-c001-495b-a6a1-13b962590375

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

resolver:
  type: udp
  udp:
    addr: 8.8.8.8:53
    timeout: 4s
EOF
log "config.yaml 已写入，内容如下（已同步到调试日志）："
sed 's/^/    /' config.yaml | tee -a "$LOG"

# ✅ 写入 cert.pem 文件
log "写入 cert.pem"
cat > cert.pem <<EOF
-----BEGIN CERTIFICATE-----
MIIBezCCASGgAwIBAgIUC3S5wh4fbyM2ma1AR9U440une14wCgYIKoZIzj0EAwIw
EzERMA8GA1UEAwwIYmluZy5jb20wHhcNMjUwNDIxMDUyMDIxWhcNMzUwNDE5MDUy
MDIxWjATMREwDwYDVQQDDAhiaW5nLmNvbTBZMBMGByqGSM49AgEGCCqGSM49AwEH
A0IABDvAkACytTncW6NLzo9tj6UWbzNYjZM8IM4//dp/qgMGw7T6AWP2Nr9bisNL
/82v0GcqpFTINvYvvyu5doSTQdCjUzBRMB0GA1UdDgQWBBRe98JAp2m/z7u5fCPc
wBSLkTfQuzAfBgNVHSMEGDAWgBRe98JAp2m/z7u5fCPcwBSLkTfQuzAPBgNVHRMB
Af8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIEaMrLQARBhmwz7wJH284Jjo0ZEG
iF+K6vzB+XdVs/CgAiEArZFTAE/HhV60b1TEacNAsr2s6tKa9G0DHk0iMFZJyc0=
-----END CERTIFICATE-----
EOF


# ✅ 写入 private.key 文件
log "写入 private.key"
cat > private.key <<EOF
-----BEGIN EC PARAMETERS-----
BggqhkjOPQMBBw==
-----END EC PARAMETERS-----
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIHpptrtUUKlmyc/l0PdqRTjrTwUiyoihmcgR0o1vya94oAoGCCqGSM49
AwEHoUQDQgAEO8CQALK1Odxbo0vOj22PpRZvM1iNkzwgzj/92n+qAwbDtPoBY/Y2
v1uKw0v/za/QZyqkVMg29i+/K7l2hJNB0A==
-----END EC PRIVATE KEY-----
EOF


# ==================== 启动 Hysteria（调试模式：输出写入 server.log，不再丢 /dev/null）====================
log "启动 Hysteria：./npm server -c config.yaml"
nohup ./npm server -c config.yaml >server.log 2>&1 &
NPM_PID=$!
WAIT_SEC="${WAIT_SEC:-4}"
log "Hysteria 已拉起，PID=$NPM_PID，等待 ${WAIT_SEC} 秒观察启动情况..."
sleep "$WAIT_SEC"

if kill -0 "$NPM_PID" 2>/dev/null; then
  log "✅ Hysteria 进程存活（PID=$NPM_PID）"
  log "---------- server.log 前 60 行 ----------"
  sed -n '1,60p' server.log 2>/dev/null | tee -a "$LOG"
  log "---------- server.log 结束 ----------"
  if command -v ss >/dev/null 2>&1; then
    log "---------- 该进程监听端口(ss -lunp) ----------"
    ss -lunp 2>/dev/null | grep -E "pid=$NPM_PID" | tee -a "$LOG"
  fi
else
  log "❌ Hysteria 进程已退出，启动失败！以下是 server.log 全部内容："
  cat server.log 2>/dev/null | tee -a "$LOG"
  log "常见原因：TLS 证书错误 / listen 非法 / 二进制架构不匹配 / realm 会合或 STUN 服务器不可达 / 端口被占用"
fi

log "===== 调试文件已保留（调试版不自动删除）====="
log "  配置: $PWD/config.yaml"
log "  服务日志: $PWD/server.log"
log "  调试日志: $LOG"
log "确认能正常后，把脚本末尾注释掉的 rm 行取消注释即可恢复用完即删。"

# ⚠️ 调试版：先不自动删除，方便排查。确认无误后取消下面几行注释。
# rm npm
# rm config.yaml
# rm cert.pem
# rm private.key
# rm -- "$0"

