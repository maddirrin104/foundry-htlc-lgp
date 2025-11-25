## Anvil
```bash
anvil
```
## Chạy MPC/TSS
```bash
# PREIMAGE="super-secret-preimage"
go run main.go
# Output:
## 2025/11/18 08:36:07 [P1] KEYGEN DONE
## 2025/11/18 08:36:07 [P3] KEYGEN DONE
## 2025/11/18 08:36:07 [P2] KEYGEN DONE
## 2025/11/18 08:36:07 ==> pubkey X=""
## Y=""
## TSS Ethereum Address = ""
## lockId: ""
## 2025/11/18 08:36:07 [P1] SIGN DONE
## 2025/11/18 08:36:07 [P2] SIGN DONE
## ==> TSS signature:
## r = ""
## s = ""
## v(recid) = [0]
## ECDSA verify = true
## ethSig(65) = ""
## DONE.
```
## Copy địa chỉ TSS & lockId, signature in ra, rồi:
```bash
export TSS_SIGNER=<TSS Ethereum Address in ra từ Go>
export LOCK_ID=<lockId in ra từ Go>          # sha256(preimage)
export SIG=<ethSig(65) in ra từ Go>          # 65 bytes
export PREIMAGE_HEX=0x$(echo -n "super-secret-preimage" | xxd -p -c 200)
```

## Deploy 
```bash
# deploy với account đầu tiên lấy từ anvil (blockchain chạy local)
export RPC=http://127.0.0.1:8545
# Dùng account đầu tiên của anvil
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

forge script script/mp-htlc-script.s.sol:mp_htlc_script \
  --rpc-url $RPC \
  --broadcast \
  --private-key $PRIVATE_KEY -vv
```

## Config
### Cấu hình địa chỉ
```bash
export ADDR_TOKEN=0x5FbDB2315678afecb367f032d93F642f64180aa3 # MockToken từ script deploy
export ADDR_HTLC=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 # mp-htlc từ script deploy
export ADDR_TSS=$TSS_SIGNER # chính là TSS Ethereum Address
```

### Chọn 3 party (P1, P2, P3)
> Dùng 3 private key mặc định của anvil:
```bash
# P1
export PK_P1=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ADDR_P1=$(cast wallet address --private-key $PK_P1)

# P2
export PK_P2=0x59c6995e998f97a5a0044966f9d86d5b1b8b9c5e6e4a7a5b0b5d8f5d5c1e3b6
export ADDR_P2=$(cast wallet address --private-key $PK_P2)

# P3
export PK_P3=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
export ADDR_P3=$(cast wallet address --private-key $PK_P3)
```

### Mint token cho các sender
Ta coi đây là 1 token dùng cho tất cả leg (PoC đơn giản):
* Leg1: P1 → P2: 100 MTK
* Leg2: P2 → P3: 200 MTK
* Leg3: P3 → P1: 300 MTK
```bash
# Mint bằng deployer (owner của MockToken)
cast send $ADDR_TOKEN "mint(address,uint256)" $ADDR_P1 100000000000000000000 \
  --private-key $PK_DEPLOYER --rpc-url $RPC
cast send $ADDR_TOKEN "mint(address,uint256)" $ADDR_P2 200000000000000000000 \
  --private-key $PK_DEPLOYER --rpc-url $RPC
cast send $ADDR_TOKEN "mint(address,uint256)" $ADDR_P3 300000000000000000000 \
  --private-key $PK_DEPLOYER --rpc-url $RPC
```
### Approve cho contract MP-HTLC
```bash
# P1 approve 100
cast send $ADDR_TOKEN "approve(address,uint256)" $ADDR_HTLC 100000000000000000000 \
  --private-key $PK_P1 --rpc-url $RPC

# P2 approve 200
cast send $ADDR_TOKEN "approve(address,uint256)" $ADDR_HTLC 200000000000000000000 \
  --private-key $PK_P2 --rpc-url $RPC

# P3 approve 300
cast send $ADDR_TOKEN "approve(address,uint256)" $ADDR_HTLC 300000000000000000000 \
  --private-key $PK_P3 --rpc-url $RPC
```

### Tạo 3 leg dùng chung LOCK_ID (đa bên)
> Đặt timelock 30 phút (1800s):
```bash
# Leg 1: P1 -> P2 (100 MTK)
cast send $ADDR_HTLC \
  "lock(address,address,bytes32,uint256,uint256)(bytes32)" \
  $ADDR_P2 $ADDR_TOKEN $LOCK_ID 100000000000000000000 1800 \
  --private-key $PK_P1 --rpc-url $RPC

# Leg 2: P2 -> P3 (200 MTK)
cast send $ADDR_HTLC \
  "lock(address,address,bytes32,uint256,uint256)(bytes32)" \
  $ADDR_P3 $ADDR_TOKEN $LOCK_ID 200000000000000000000 1800 \
  --private-key $PK_P2 --rpc-url $RPC

# Leg 3: P3 -> P1 (300 MTK)
cast send $ADDR_HTLC \
  "lock(address,address,bytes32,uint256,uint256)(bytes32)" \
  $ADDR_P1 $ADDR_TOKEN $LOCK_ID 300000000000000000000 1800 \
  --private-key $PK_P3 --rpc-url $RPC
```