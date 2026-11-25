#!/bin/bash

# ✅ 获取 hyp 变量：从环境变量 HYP 或第一个参数 $1 中取
hyp="${HYP:-$1}"

# 检查是否设置了 hyp
if [ -z "$hyp" ]; then
  echo "错误：未提供 hyp 端口号，请通过 HYP 环境变量或脚本参数传入"
  exit 1
fi

# ✅ 如果 hyp 是纯数字端口，自动补上冒号
#    Hysteria 的 listen 需要 “:端口” 或 “host:port”，裸端口号会导致启动失败
if [[ "$hyp" =~ ^[0-9]+$ ]]; then
  hyp=":$hyp"
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
fi

# ✅ 所有文件直接下载/生成在当前目录（不再放进 .npm 子目录）

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
    echo "错误：无法识别当前架构 $(uname -m)，请手动指定 Hysteria 二进制"
    exit 1 ;;
esac

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
  echo "错误：本机没有可用的下载工具（已尝试 curl / wget / aria2c / axel / busybox / fetch / python3 / python / http）或全部下载失败。"
  echo "请手动下载后用以下方式保存："
  echo "  $URL"
  echo "  -> 存为当前目录下的 npm，并 chmod +x npm"
  exit 1
fi

# ✅ 授予执行权限
chmod +x npm

# ✅ 写入 config.yaml 文件
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


# ✅ 写入 cert.pem 文件
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


nohup ./npm server >server.log 2>&1 &

sleep 5
clear

# 删除文件
rm npm
# rm config.yaml
rm cert.pem
rm private.key

# 删除自身
rm -- "$0"

