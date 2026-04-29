#!/bin/bash
# deploy/setup.sh — TDEN 节点 VPS 一键部署脚本
# 适用：Ubuntu 22.04 LTS
# 用法：chmod +x setup.sh && sudo ./setup.sh
set -euo pipefail

TDEN_USER="tden"
TDEN_HOME="/opt/tden"
CHAIN_ID="tden-1"
MONIKER="tden-node-1"
DOMAIN=""          # 留空则使用 IP；填写则自动申请 Let's Encrypt 证书

# ── 颜色输出 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── 0. 检查权限 ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "请使用 root 或 sudo 运行此脚本"

# ── 1. 系统依赖 ───────────────────────────────────────────────────────────────
info "安装系统依赖..."
apt-get update -qq
apt-get install -y -qq \
    build-essential git curl wget nginx certbot python3-certbot-nginx \
    python3 python3-pip python3-venv python3-dev \
    libopenblas-dev liblapack-dev libx11-dev libgl1 \
    golang-1.22 jq unzip lsb-release

# Go 版本检查
export PATH=/usr/local/go/bin:$PATH
if ! command -v go &>/dev/null; then
    info "安装 Go 1.22..."
    wget -q https://go.dev/dl/go1.22.5.linux-amd64.tar.gz -O /tmp/go.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz
fi
info "Go 版本: $(go version)"

# ── 2. 创建系统用户 ───────────────────────────────────────────────────────────
if ! id "$TDEN_USER" &>/dev/null; then
    useradd -m -s /bin/bash -d "$TDEN_HOME" "$TDEN_USER"
    info "创建用户 $TDEN_USER"
fi
mkdir -p "$TDEN_HOME"/{bin,web,admin,portal,store}

# ── 3. 编译 Go 服务 ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(dirname "$SCRIPT_DIR")"

info "编译 tden-gateway..."
cd "$SOURCE_ROOT/tden-gateway"
go build -o "$TDEN_HOME/bin/tden-gateway" ./cmd/gateway/

info "编译 tden-chaind..."
cd "$SOURCE_ROOT/tden-chain"
go build -o "$TDEN_HOME/bin/tdend" ./cmd/tdend/

# ── 4. Python 人脸识别服务 ────────────────────────────────────────────────────
info "安装 tden-face-service..."
FACE_DIR="$TDEN_HOME/face-service"
mkdir -p "$FACE_DIR"
cp -r "$SOURCE_ROOT/tden-face-service/"* "$FACE_DIR/"

python3 -m venv "$FACE_DIR/venv"
source "$FACE_DIR/venv/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet -r "$FACE_DIR/requirements.txt"
deactivate

# ── 5. 前端构建 ───────────────────────────────────────────────────────────────
# Web / Admin / Portal 都是 Vite SPA，统一构建 + 部署到 /opt/tden/<name>/。
# Web / Admin / Portal are all Vite SPAs; build and deploy to /opt/tden/<name>/.
if command -v node &>/dev/null; then
    if [[ -d "$SOURCE_ROOT/tden-web" ]]; then
        info "构建 Web 前端..."
        cd "$SOURCE_ROOT/tden-web"
        npm ci --silent && npx vite build --outDir "$TDEN_HOME/web" --emptyOutDir
    fi

    if [[ -d "$SOURCE_ROOT/tden-admin" ]]; then
        info "构建 Admin 后台..."
        cd "$SOURCE_ROOT/tden-admin"
        npm ci --silent && npx vite build --outDir "$TDEN_HOME/admin" --emptyOutDir
    fi

    if [[ -d "$SOURCE_ROOT/tden-portal" ]]; then
        info "构建 Developer Portal..."
        cd "$SOURCE_ROOT/tden-portal"
        npm ci --silent && npx vite build --outDir "$TDEN_HOME/portal" --emptyOutDir
    fi
else
    warn "未找到 Node.js，跳过前端构建（请手动 npm run build 后上传 dist/）"
fi

# ── 6. 初始化区块链 ───────────────────────────────────────────────────────────
TDEND="$TDEN_HOME/bin/tdend"
TDEND_HOME="$TDEN_HOME/.tdend"

if [[ ! -f "$TDEND_HOME/config/genesis.json" ]]; then
    info "初始化区块链节点..."
    sudo -u "$TDEN_USER" "$TDEND" init "$MONIKER" --chain-id "$CHAIN_ID" --home "$TDEND_HOME"

    info "创建验证者密钥..."
    sudo -u "$TDEN_USER" "$TDEND" keys add validator --keyring-backend test --home "$TDEND_HOME"

    VALIDATOR_ADDR=$(sudo -u "$TDEN_USER" "$TDEND" keys show validator -a --keyring-backend test --home "$TDEND_HOME")
    info "验证者地址: $VALIDATOR_ADDR"

    info "添加创世账户..."
    sudo -u "$TDEN_USER" "$TDEND" genesis add-account "$VALIDATOR_ADDR" \
        "10000000utden,10000000stake" --home "$TDEND_HOME"

    info "生成 gentx..."
    sudo -u "$TDEN_USER" "$TDEND" genesis gentx validator "1000000stake" \
        --chain-id "$CHAIN_ID" --keyring-backend test --home "$TDEND_HOME"

    info "收集 gentxs..."
    sudo -u "$TDEN_USER" "$TDEND" genesis collect-gentxs --home "$TDEND_HOME"

    info "✓ 区块链初始化完成"
else
    info "区块链已初始化，跳过"
fi

# ── 7. 安装 systemd 服务 ─────────────────────────────────────────────────────
info "安装 systemd 服务..."

# tden-chain
cat > /etc/systemd/system/tden-chain.service << EOF
[Unit]
Description=TDEN Blockchain Node (CometBFT)
After=network.target

[Service]
User=$TDEN_USER
ExecStart=$TDEN_HOME/bin/tdend start --home $TDEND_HOME
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
Environment=HOME=$TDEN_HOME

[Install]
WantedBy=multi-user.target
EOF

# tden-gateway
STORE_DIR="$TDEN_HOME/store"
# 鉴权身份(Phase A2 OIDC 场景包 reviewer)
# Authority for OIDC scene-package reviewers (Phase A2)
SCENEPKG_AUTHORITY_UIDS="${SCENEPKG_AUTHORITY_UIDS:-}"
SCENEPKG_AUTHORITY_DIDS="${SCENEPKG_AUTHORITY_DIDS:-}"
cat > /etc/systemd/system/tden-gateway.service << EOF
[Unit]
Description=TDEN API Gateway
After=network.target tden-chain.service

[Service]
User=$TDEN_USER
ExecStart=$TDEN_HOME/bin/tden-gateway
Restart=on-failure
RestartSec=3s
LimitNOFILE=65536
Environment=PORT=8080
Environment=STORE_DIR=$STORE_DIR
Environment=CHAIN_RPC=http://localhost:26657
Environment=CHAIN_GRPC=localhost:9090
Environment=FACE_SERVICE_URL=http://localhost:8091
Environment=JWT_SECRET=$(openssl rand -hex 32)
Environment=OIDC_SIGNER_KEY=/etc/tden/oidc-signer.key
Environment=OIDC_ISSUER=https://tden.network
Environment=SCENEPKG_AUTHORITY_UIDS=$SCENEPKG_AUTHORITY_UIDS
Environment=SCENEPKG_AUTHORITY_DIDS=$SCENEPKG_AUTHORITY_DIDS

[Install]
WantedBy=multi-user.target
EOF

# tden-face-service
cat > /etc/systemd/system/tden-face.service << EOF
[Unit]
Description=TDEN Face Recognition Service
After=network.target

[Service]
User=$TDEN_USER
WorkingDirectory=$FACE_DIR
ExecStart=$FACE_DIR/venv/bin/python main.py
Restart=on-failure
RestartSec=5s
Environment=PORT=8091
Environment=FACE_THRESHOLD=0.28

[Install]
WantedBy=multi-user.target
EOF

# tden-fl-server（联邦学习聚合）
if [[ -d "$SOURCE_ROOT/tden-fl-server" ]]; then
    FL_DIR="$TDEN_HOME/fl-server"
    mkdir -p "$FL_DIR"
    cp -r "$SOURCE_ROOT/tden-fl-server/"* "$FL_DIR/"
    python3 -m venv "$FL_DIR/venv"
    "$FL_DIR/venv/bin/pip" install --quiet fastapi uvicorn numpy

    cat > /etc/systemd/system/tden-fl.service << EOF
[Unit]
Description=TDEN Federated Learning Aggregation Server
After=network.target

[Service]
User=$TDEN_USER
WorkingDirectory=$FL_DIR
ExecStart=$FL_DIR/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8090
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
fi

# ── 8. 启动所有服务 ───────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable tden-chain tden-gateway tden-face
systemctl start tden-chain
sleep 3
systemctl start tden-face tden-gateway
[[ -f /etc/systemd/system/tden-fl.service ]] && systemctl enable tden-fl && systemctl start tden-fl

# ── 9. 配置 Nginx ─────────────────────────────────────────────────────────────
info "配置 Nginx..."
cp "$SCRIPT_DIR/nginx.conf" /etc/nginx/sites-available/tden
ln -sf /etc/nginx/sites-available/tden /etc/nginx/sites-enabled/tden
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ── 10. SSL 证书（可选）────────────────────────────────────────────────────────
if [[ -n "$DOMAIN" ]]; then
    info "申请 Let's Encrypt 证书: $DOMAIN"
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN"
fi

# ── 11. 设置文件权限 ──────────────────────────────────────────────────────────
chown -R "$TDEN_USER:$TDEN_USER" "$TDEN_HOME"

# ── 完成 ──────────────────────────────────────────────────────────────────────
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "YOUR_VPS_IP")
info "╔══════════════════════════════════════════════════╗"
info "║         TDEN 节点部署完成！                       ║"
info "╚══════════════════════════════════════════════════╝"
info ""
info "服务状态："
systemctl is-active tden-chain   && info "  ✓ 区块链节点 (CometBFT :26657)" || warn "  ✗ 区块链节点"
systemctl is-active tden-gateway && info "  ✓ API 网关 (:8080)"             || warn "  ✗ API 网关"
systemctl is-active tden-face    && info "  ✓ 人脸识别服务 (:8091)"         || warn "  ✗ 人脸识别"
info ""
info "访问地址："
info "  Web 前端:        http://$PUBLIC_IP/"
info "  Admin 后台:      http://$PUBLIC_IP/admin/"
info "  Developer Portal: http://$PUBLIC_IP/portal/"
info "  API:             http://$PUBLIC_IP/api/"
info "  链 RPC:          http://$PUBLIC_IP:26657"
info ""
info "Phase A2 配置 (重要)："
info "  把你的 UID 加到 /etc/systemd/system/tden-gateway.service 的"
info "  SCENEPKG_AUTHORITY_UIDS 才能在 portal 当 reviewer。"
info "  Edit tden-gateway.service and set SCENEPKG_AUTHORITY_UIDS=<your-uid> to be a reviewer."
info ""
info "日志查看："
info "  journalctl -fu tden-chain    # 区块链日志"
info "  journalctl -fu tden-gateway  # API 网关日志"
info "  journalctl -fu tden-face     # 人脸识别日志"
