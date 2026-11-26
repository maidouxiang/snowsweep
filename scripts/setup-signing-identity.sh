#!/bin/sh
# 建立雪的固定自签名身份，供 install-selfuse.sh 使用。
#
# 为什么要它：ad-hoc 签名每次构建的 designated requirement 都是 cdhash，
# 重新安装后 TCC（完全磁盘访问）旧授权就失效。固定证书签名的 DR 是
# `identifier + certificate root`，跨版本保持稳定，授权只需给一次。
#
# 这个脚本只动一个专用钥匙串，不使用登录钥匙串，也不需要管理员密码：
#   ~/Library/Keychains/xue-signing.keychain-db
# 证书私钥只用于本机自用签名；钥匙串口令默认 snowsweep，可用
# SNOWSWEEP_SIGN_PASSWORD 覆盖。
#
# 幂等：证书已存在时直接退出，不重复生成。

set -eu

IDENTITY="${SNOWSWEEP_SIGN_IDENTITY-SnowSweep Local Code Signing}"
KEYCHAIN="${SNOWSWEEP_SIGN_KEYCHAIN-$HOME/Library/Keychains/xue-signing.keychain-db}"
PASSWORD="${SNOWSWEEP_SIGN_PASSWORD-snowsweep}"

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "已存在：$IDENTITY"
  echo "钥匙串：$KEYCHAIN"
  exit 0
fi

TMP="$(mktemp -d /tmp/snowsweep-sign.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

cat > "$TMP/codesign.cnf" <<EOF
[ req ]
prompt = no
distinguished_name = dn
x509_extensions = ext
[ dn ]
CN = $IDENTITY
O = Self Use
C = CN
[ ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/codesign.cnf" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -name "$IDENTITY" -passout "pass:$PASSWORD" >/dev/null 2>&1

if [ ! -f "$KEYCHAIN" ]; then
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
fi
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

# 把专用钥匙串加入当前用户的搜索列表；不替代登录钥匙串。
if ! security list-keychains -d user | grep -q "xue-signing.keychain-db"; then
  EXISTING="$(security list-keychains -d user | tr -d ' "' | tr '\n' ' ')"
  security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi

echo "已建立：$IDENTITY"
echo "钥匙串：$KEYCHAIN"
echo "指纹："
security find-certificate -c "$IDENTITY" -Z "$KEYCHAIN" 2>/dev/null | grep "SHA-256 hash" || true
echo
echo "之后运行 ./install-selfuse.sh 会自动使用这个身份。"
echo "TCC 授权只需在首次安装后手动给一次，之后重装保持。"
