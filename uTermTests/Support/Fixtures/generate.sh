#!/usr/bin/env bash
# 生成 KeyImportFixtures.swift —— uTerm 私钥导入测试用密钥夹具。
# 依赖系统自带的 ssh-keygen 与 Homebrew 的 openssl（非 LibreSSL）。可重复运行。
#
# 注意：macOS 现代 ssh-keygen 默认生成 OpenSSH 新格式，OpenSSL 3 无法直接读取。
# 解决方案：
#   - RSA PKCS#1/PKCS#8：用 ssh-keygen -m PEM 生成 PKCS#1 格式，再转换。
#   - ECDSA SEC1/PKCS#8：用 ssh-keygen -m PEM 生成 SEC1 格式，再转换。
#   - Ed25519 PKCS#8：直接用 openssl genpkey 生成。
#   - OpenSSH 格式夹具：直接用 ssh-keygen 默认格式（始终为 OpenSSH 新格式）。
set -euo pipefail
cd "$(dirname "$0")"

# macOS 自带 /usr/bin/openssl 是 LibreSSL，不支持 -traditional 等选项。
# 使用 Homebrew 安装的真正 OpenSSL 3。
# 候选路径列表（按优先级）
OPENSSL=""
for candidate in \
    "/opt/homebrew/bin/openssl" \
    "/opt/homebrew/opt/openssl@3/bin/openssl" \
    "/opt/homebrew/opt/openssl/bin/openssl" \
    "/usr/local/bin/openssl" \
    "/usr/local/opt/openssl@3/bin/openssl"; do
  if [ -x "$candidate" ]; then
    # 跳过 LibreSSL
    if "$candidate" version 2>/dev/null | grep -q "LibreSSL"; then
      continue
    fi
    OPENSSL="$candidate"
    break
  fi
done
# 如果还没找到，尝试 brew --prefix
if [ -z "$OPENSSL" ]; then
  BREW_PREFIX="$(brew --prefix openssl@3 2>/dev/null)" || true
  if [ -n "$BREW_PREFIX" ] && [ -x "$BREW_PREFIX/bin/openssl" ]; then
    OPENSSL="$BREW_PREFIX/bin/openssl"
  fi
fi
if [ -z "$OPENSSL" ]; then
  echo "错误：找不到 Homebrew 的 openssl@3（非 LibreSSL），请先运行 brew install openssl@3" >&2
  exit 1
fi
echo "使用 openssl: $OPENSSL ($("$OPENSSL" version))"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="testpass123"
OUT="../KeyImportFixtures.swift"

emit() { # name file
  # Swift 多行字符串要求内容行的缩进不少于闭合 """ 的缩进。
  # 闭合 """ 用 4 个空格（与 static let 对齐），PEM 每行也加 4 个空格前缀。
  # Swift 会自动剥去这 4 个空格，运行时字符串仍是原始 PEM。
  printf '    static let %s = """\n' "$1"
  sed 's/^/    /' "$2"
  printf '\n    """\n\n'
}

# ──────────────────────────────────────────────────────────────────────────────
# RSA
# ──────────────────────────────────────────────────────────────────────────────
# rsaOpenSSHEnc：OpenSSH 新格式（加密）
ssh-keygen -q -t rsa -b 2048 -N "" -f "$WORK/rsa_enc" -C uterm-test
ssh-keygen -q -p -N "$PASS" -P "" -f "$WORK/rsa_enc" >/dev/null
cp "$WORK/rsa_enc" "$WORK/rsa_openssh_enc"

# rsaPKCS1 / rsaPKCS1Enc / rsaPKCS8 / rsaPKCS8Enc：
# 用 -m PEM 生成 PKCS#1 格式，OpenSSL 可直接读取
ssh-keygen -q -t rsa -b 2048 -N "" -f "$WORK/rsa_pem" -m PEM -C uterm-test
"$OPENSSL" pkcs8 -topk8 -nocrypt -in "$WORK/rsa_pem" -out "$WORK/rsa_pkcs8"       2>/dev/null
"$OPENSSL" pkcs8 -topk8 -in "$WORK/rsa_pem" -passout "pass:$PASS" -out "$WORK/rsa_pkcs8_enc" 2>/dev/null
"$OPENSSL" rsa -in "$WORK/rsa_pem" -traditional -aes256 -passout "pass:$PASS" \
              -out "$WORK/rsa_pkcs1_enc" 2>/dev/null
# rsa_pem 本身已是 PKCS#1 格式
cp "$WORK/rsa_pem" "$WORK/rsa_pkcs1"

# rsaOpenSSH：将同一把 RSA 密钥转换为 OpenSSH 新格式（与 rsaPKCS1 使用相同密钥）
cp "$WORK/rsa_pem" "$WORK/rsa_openssh"
ssh-keygen -q -p -N "" -P "" -f "$WORK/rsa_openssh" >/dev/null   # 原地转换为 OpenSSH 新格式
grep -q "BEGIN OPENSSH PRIVATE KEY" "$WORK/rsa_openssh" || { echo "错误：rsa_openssh 转换失败"; exit 1; }

# 验证 rsaOpenSSH 与 rsaPKCS1 是同一把密钥（比较公钥 blob 前两个字段）
_pub_pem=$(ssh-keygen -y -f "$WORK/rsa_pem"     2>/dev/null | awk '{print $1,$2}')
_pub_ssh=$(ssh-keygen -y -f "$WORK/rsa_openssh" 2>/dev/null | awk '{print $1,$2}')
[ "$_pub_pem" = "$_pub_ssh" ] || { echo "错误：rsa_openssh 与 rsa_pem 公钥不匹配，同一密钥转换失败"; exit 1; }
unset _pub_pem _pub_ssh

# 验证 RSA PEM 标签
grep -q "BEGIN RSA PRIVATE KEY"      "$WORK/rsa_pkcs1"      || { echo "错误：rsa_pkcs1 PEM 标签不正确";     exit 1; }
grep -q "BEGIN PRIVATE KEY"           "$WORK/rsa_pkcs8"      || { echo "错误：rsa_pkcs8 PEM 标签不正确";     exit 1; }
grep -q "BEGIN ENCRYPTED PRIVATE KEY" "$WORK/rsa_pkcs8_enc"  || { echo "错误：rsa_pkcs8_enc PEM 标签不正确"; exit 1; }
grep -q "BEGIN RSA PRIVATE KEY"      "$WORK/rsa_pkcs1_enc"  || { echo "错误：rsa_pkcs1_enc PEM 标签不正确"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# Ed25519
# ──────────────────────────────────────────────────────────────────────────────
# ed25519OpenSSH：OpenSSH 新格式（明文）
ssh-keygen -q -t ed25519 -N "" -f "$WORK/ed_openssh" -C uterm-test

# ed25519PKCS8 / ed25519PKCS8Enc：
# ssh-keygen 生成的 Ed25519 OpenSSH 新格式无法被 OpenSSL 3 直接转换，
# 改用 openssl genpkey 直接生成 PKCS#8 格式。
"$OPENSSL" genpkey -algorithm ed25519 -out "$WORK/ed_pkcs8" 2>/dev/null
"$OPENSSL" pkcs8 -topk8 -in "$WORK/ed_pkcs8" -passout "pass:$PASS" \
                 -out "$WORK/ed_pkcs8_enc" 2>/dev/null

# 验证 Ed25519 PKCS#8 标签
grep -q "BEGIN PRIVATE KEY"           "$WORK/ed_pkcs8"     || { echo "错误：ed_pkcs8 PEM 标签不正确";     exit 1; }
grep -q "BEGIN ENCRYPTED PRIVATE KEY" "$WORK/ed_pkcs8_enc" || { echo "错误：ed_pkcs8_enc PEM 标签不正确"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# ECDSA P-256/384/521
# ──────────────────────────────────────────────────────────────────────────────
# OpenSSH 格式夹具：用 ssh-keygen 默认格式
for c in 256 384 521; do
  ssh-keygen -q -t ecdsa -b "$c" -N "" -f "$WORK/ec${c}_openssh" -C uterm-test
done

# SEC1：用 -m PEM 生成 SEC1 格式（OpenSSL 可直接读取）
for c in 256 384 521; do
  ssh-keygen -q -t ecdsa -b "$c" -N "" -f "$WORK/ec${c}_pem" -m PEM -C uterm-test
  # SEC1 就是 -m PEM 生成的原始格式
  cp "$WORK/ec${c}_pem" "$WORK/ec${c}_sec1"
done

# PKCS#8：仅 P-256（其他曲线的 PKCS#8 夹具暂未被测试用例使用）
"$OPENSSL" pkcs8 -topk8 -nocrypt -in "$WORK/ec256_pem" -out "$WORK/ec256_pkcs8" 2>/dev/null

# 加密 SEC1（仅 P-256）
"$OPENSSL" ec -in "$WORK/ec256_pem" -aes256 -passout "pass:$PASS" \
              -out "$WORK/ec256_sec1_enc" 2>/dev/null

# 命名曲线 SEC1（P-256，含 namedCurve OID，用于覆盖 DERKeyDecoder 命名曲线解码路径）
"$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$WORK/ec256_sec1_named"
grep -q "BEGIN EC PRIVATE KEY" "$WORK/ec256_sec1_named" || { echo "错误：ec256_sec1_named 标签不正确"; exit 1; }

# 加密 ECDSA OpenSSH（P-256，用于覆盖 OpenSSHECDSADecoder 加密分支）
ssh-keygen -q -t ecdsa -b 256 -N "" -f "$WORK/ec256_openssh_enc" -C uterm-test
ssh-keygen -q -p -N "$PASS" -P "" -f "$WORK/ec256_openssh_enc" >/dev/null
grep -q "BEGIN OPENSSH PRIVATE KEY" "$WORK/ec256_openssh_enc" || { echo "错误：ec256_openssh_enc 标签不正确"; exit 1; }

# 验证 EC SEC1 标签
grep -q "BEGIN EC PRIVATE KEY" "$WORK/ec256_sec1"     || { echo "错误：ec256_sec1 PEM 标签不正确";     exit 1; }
grep -q "BEGIN EC PRIVATE KEY" "$WORK/ec256_sec1_enc" || { echo "错误：ec256_sec1_enc PEM 标签不正确"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# DSA（用于"应被拒绝"测试）
# ──────────────────────────────────────────────────────────────────────────────
"$OPENSSL" dsaparam -out "$WORK/dsap" 1024 2>/dev/null
"$OPENSSL" gendsa -out "$WORK/dsa_pkcs8" "$WORK/dsap" 2>/dev/null
# 转换为传统 DSA 格式（BEGIN DSA PRIVATE KEY）
"$OPENSSL" pkey -in "$WORK/dsa_pkcs8" -traditional -out "$WORK/dsa" 2>/dev/null
grep -q "BEGIN DSA PRIVATE KEY" "$WORK/dsa" || { echo "错误：dsa PEM 标签不正确"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# 输出 Swift 文件
# ──────────────────────────────────────────────────────────────────────────────
{
  echo "// 本文件由 uTermTests/Fixtures/generate.sh 生成 —— 请勿手改。"
  echo "// 密钥仅供单元测试；口令固定为 \"$PASS\"。"
  echo "nonisolated enum KeyImportFixtures {"
  echo "    static let passphrase = \"$PASS\""
  echo ""
  emit rsaOpenSSH        "$WORK/rsa_openssh"
  emit rsaOpenSSHEnc     "$WORK/rsa_openssh_enc"
  emit rsaPKCS1          "$WORK/rsa_pkcs1"
  emit rsaPKCS1Enc       "$WORK/rsa_pkcs1_enc"
  emit rsaPKCS8          "$WORK/rsa_pkcs8"
  emit rsaPKCS8Enc       "$WORK/rsa_pkcs8_enc"
  emit ed25519OpenSSH    "$WORK/ed_openssh"
  emit ed25519PKCS8      "$WORK/ed_pkcs8"
  emit ed25519PKCS8Enc   "$WORK/ed_pkcs8_enc"
  emit ecP256OpenSSH     "$WORK/ec256_openssh"
  emit ecP384OpenSSH     "$WORK/ec384_openssh"
  emit ecP521OpenSSH     "$WORK/ec521_openssh"
  emit ecP256SEC1        "$WORK/ec256_sec1"
  emit ecP384SEC1        "$WORK/ec384_sec1"
  emit ecP521SEC1        "$WORK/ec521_sec1"
  emit ecP256SEC1Enc     "$WORK/ec256_sec1_enc"
  emit ecP256SEC1Named   "$WORK/ec256_sec1_named"
  emit ecP256PKCS8       "$WORK/ec256_pkcs8"
  emit ecP256OpenSSHEnc  "$WORK/ec256_openssh_enc"
  emit dsaPEM            "$WORK/dsa"
  echo "}"
} > "$OUT"
echo "已写入 $OUT"
