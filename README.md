# TDEN 节点部署指南

## 最小配置要求

| 项目 | 最低配置 | 推荐配置 |
|------|---------|---------|
| CPU | 2 核 | 4 核 |
| 内存 | **4 GB** | 8 GB |
| 磁盘 | 40 GB SSD | 100 GB SSD |
| 系统 | Ubuntu 22.04 LTS | Ubuntu 22.04 LTS |
| 带宽 | 10 Mbps | 100 Mbps |

> **内存说明**：InsightFace 模型加载约需 1.5 GB，区块链节点约需 512 MB，网关约需 256 MB。

---

## 一键部署

```bash
# 1. 将代码上传到 VPS（在开发机上执行）
rsync -avz --exclude='node_modules' --exclude='.git' \
    /path/to/source/ root@YOUR_VPS_IP:/tmp/tden-source/

# 2. 在 VPS 上执行部署脚本
ssh root@YOUR_VPS_IP
cd /tmp/tden-source/deploy
chmod +x setup.sh
./setup.sh
```

---

## 分步手动部署

如需更精细控制，可按以下步骤手动操作：

### 步骤 1：编译

```bash
# 编译网关
cd tden-gateway
go build -o /usr/local/bin/tden-gateway ./cmd/gateway/

# 编译链节点
cd ../tden-chain
go build -o /usr/local/bin/tdend ./cmd/tdend/
```

### 步骤 2：初始化区块链

```bash
# 初始化（生成 genesis.json、节点密钥、配置文件）
tdend init mynode --chain-id tden-1

# 创建验证者密钥
tdend keys add validator --keyring-backend test

# 查看验证者地址
VALIDATOR_ADDR=$(tdend keys show validator -a --keyring-backend test)
echo $VALIDATOR_ADDR

# 向创世文件添加初始账户
tdend genesis add-account $VALIDATOR_ADDR "10000000utden,10000000stake"

# 生成验证者质押交易
tdend genesis gentx validator 1000000stake \
    --chain-id tden-1 --keyring-backend test

# 收集质押交易
tdend genesis collect-gentxs

# 验证创世文件
tdend genesis validate-genesis
```

### 步骤 3：安装 Python 人脸服务

```bash
cd tden-face-service
python3 -m venv venv
source venv/bin/activate

# 安装依赖（首次运行会下载约 300MB InsightFace 模型）
pip install -r requirements.txt

# 测试启动
python main.py
```

### 步骤 4：配置环境变量

创建 `/opt/tden/.env`：
```bash
PORT=8080
STORE_DIR=/opt/tden/store
CHAIN_RPC=http://localhost:26657
CHAIN_GRPC=localhost:9090
FACE_SERVICE_URL=http://localhost:8091
JWT_SECRET=your-random-256bit-secret-here
```

### 步骤 5：启动所有服务

```bash
systemctl start tden-chain   # 区块链节点（必须先启动）
sleep 5
systemctl start tden-face    # 人脸识别（首次启动会加载模型，约 30 秒）
systemctl start tden-gateway # API 网关
systemctl start nginx
```

---

## 验证部署

```bash
# 检查节点同步状态
curl http://localhost:26657/status | jq '.result.sync_info'

# 检查 API 网关
curl http://localhost:8080/health

# 检查人脸服务
curl http://localhost:8091/health

# 检查区块高度（正常出块则持续增加）
watch -n 1 'curl -s http://localhost:26657/status | jq .result.sync_info.latest_block_height'
```

---

## 手机 App 配置

编译 Android APK 前，修改 `tden-android/app/src/main/java/com/tden/app/data/api/NetworkModule.kt`：

```kotlin
private const val BASE_URL = "https://YOUR_VPS_IP/"  // 替换为你的 VPS IP 或域名
```

然后用 Android Studio 编译：
```
Build → Generate Signed APK → Release
```

---

## 服务端口一览

| 服务 | 端口 | 说明 |
|------|------|------|
| Nginx | 80 / 443 | Web + Admin + API 入口 |
| tden-gateway | 8080 | API 网关（内部） |
| tden-face | 8091 | 人脸识别（内部） |
| tden-fl | 8090 | 联邦学习（内部） |
| CometBFT RPC | 26657 | 区块链 RPC |
| CometBFT P2P | 26656 | 节点间通信 |
| Cosmos gRPC | 9090 | gRPC 查询 |
| Cosmos REST | 1317 | REST 查询 |

> 防火墙只需开放 80、443、26656（P2P，若需多节点）。其余端口仅本机内部使用。

---

## 常见问题

**Q：人脸服务启动慢**  
A：首次启动需下载 InsightFace buffalo_l 模型（约 300MB），正常现象。后续重启无需重新下载。

**Q：区块链节点一直在 `sync_info.catching_up: true`**  
A：单节点时不会 catching_up，直接出块。若显示 true 说明还未初始化完成。

**Q：手机 App 连接失败**  
A：检查 `BASE_URL` 是否正确，VPS 防火墙是否开放 80/443，Nginx 是否运行。

**Q：人脸识别提示"未检测到人脸"**  
A：确保光线充足，正面面对摄像头，距离 30-60cm。可调低 `FACE_THRESHOLD`（默认 0.28）。
