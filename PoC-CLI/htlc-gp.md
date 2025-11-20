## Anvil
```bash
anvil
```

## Deploy 
```bash
export RPC=http://127.0.0.1:8545
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

forge script script/htlc-gp-script.s.sol:htlc_gp_script \
  --rpc-url $RPC \
  --broadcast -vv
```
### Ghi lại 2 địa chỉ:
```bash
export ADDR_TOKEN_GP=<MockToken in ra>
export ADDR_HTLC_GP=<HTLC_TRAD in ra>
```

## Config
### 1. Cấu hình account + preimage/hashlock
#### 1.1 Sender / Receiver
> Giữ chung style với PoC MP-HTLC-LGP:
```bash
# Anvil account 0 – làm RECEIVER (giống kịch bản MP-HTLC-LGP)
export PK_RECEIVER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ADDR_RECEIVER=$(cast wallet address --private-key $PK_RECEIVER)

# Anvil account 1 – làm SENDER
# (nếu bạn dùng default của Anvil / Hardhat)
export PK_SENDER=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
export ADDR_SENDER=$(cast wallet address --private-key $PK_SENDER)
```
> Cấp ETH đủ:
```bash
cast rpc anvil_setBalance $ADDR_SENDER 0x56bc75e2d63100000 --rpc-url $RPC
cast rpc anvil_setBalance $ADDR_RECEIVER 0x56bc75e2d63100000 --rpc-url $RPC
```
> Mint token cho SENDER:
```bash
cast send $ADDR_TOKEN_GP "mint(address,uint256)" \
  $ADDR_SENDER 1000000000000000000000 \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC

TX_HASH_MINT=<hash trả về>
cast receipt $TX_HASH_MINT --rpc-url $RPC
```
#### 1.2 Preimage + hashlock (LOCK_ID)
> Dùng cùng preimage với PoC MP-HTLC-LGP để so sánh:
```bash
export PREIMAGE="super-secret-preimage"
export PREIMAGE_HEX=0x$(echo -n "$PREIMAGE" | xxd -p -c 200)

# LOCK_ID = sha256(preimage) (HTLC dùng sha256 chứ không phải keccak)
export LOCK_ID=0x$(echo -n "$PREIMAGE" | openssl dgst -binary -sha256 | xxd -p -c 64)
echo $LOCK_ID
```

### 2. Approve trước khi createLock
> Sender (Alice) approve token cho HTLC-GP:
```bash
cast send $ADDR_TOKEN_GP "approve(address,uint256)" \
  $ADDR_HTLC_GP 100000000000000000000 \
  --private-key $PK_SENDER \
  --rpc-url $RPC

TX_HASH_APPROVE_GP=<hash trả về>
cast receipt $TX_HASH_APPROVE_GP --rpc-url $RPC   # gasUsed_approve_gp
```
### 3. Các tham số lock
```bash
export AMOUNT=100000000000000000000        # 100 * 1e18
export TIMELOCK=1800                       # 30 phút
export DEPOSIT_REQUIRED=1000000000000000000 # 1 ETH
export DEPOSIT_WINDOW=600                  # 10 phút
```
### 4. PoC flow cho HTLC-GP
#### 4.1 Scenario A – Honest: deposit + claim sớm (không penalty)
> Bước 1 – Sender createLock
```bash
time cast send $ADDR_HTLC_GP \
  "createLock(address,address,uint256,bytes32,uint256,uint256,uint256)(bytes32)" \
  $ADDR_RECEIVER \
  $ADDR_TOKEN_GP \
  $AMOUNT \
  $LOCK_ID \
  $TIMELOCK \
  $DEPOSIT_REQUIRED \
  $DEPOSIT_WINDOW \
  --private-key $PK_SENDER \
  --rpc-url $RPC
```
> Lưu TX hash:
```bash
TX_HASH_LOCK_GP_A=<hash lock>
cast receipt $TX_HASH_LOCK_GP_A --rpc-url $RPC   # gasUsed_lock_gp
```
> Bước 2 – Receiver confirmParticipation (đặt cọc penalty)
```bash 
time cast send $ADDR_HTLC_GP "confirmParticipation(bytes32)" \
  $LOCK_ID \
  --value $DEPOSIT_REQUIRED \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC

TX_HASH_DEPOSIT_GP_A=<hash deposit>
cast receipt $TX_HASH_DEPOSIT_GP_A --rpc-url $RPC   # gasUsed_confirm_gp
```
> Bước 3 – Receiver claim sớm, trước unlockTime
```bash
time cast send $ADDR_HTLC_GP "claim(bytes32,bytes)" \
  $LOCK_ID \
  $PREIMAGE_HEX \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC

TX_HASH_CLAIM_GP_A=<hash claim>
cast receipt $TX_HASH_CLAIM_GP_A --rpc-url $RPC    # gasUsed_claim_gp
```
> Kiểm tra số dư & deposit refund: 
``` bash
# Receiver nhận 100 MTK
cast call $ADDR_TOKEN_GP "balanceOf(address)(uint256)" $ADDR_RECEIVER --rpc-url $RPC

# ETH của receiver sẽ về lại (deposit được refund), bạn có thể so sánh trước/sau:
cast balance $ADDR_RECEIVER --rpc-url $RPC

```
#### 4.2 Scenario B – Griefing: deposit đã confirm, nhưng receiver KHÔNG claim, sender refund sau timelock → có penalty
> Reset state (anvil restart + redeploy hoặc dùng LOCK_ID khác + mint lại token, approve lại). Quy trình giống Scenario A tới Bước 2 (createLock + confirmParticipation), nhưng không claim.
> Bước 1 – Sau khi confirmParticipation, giả lập trễ > timelock
```bash
# tăng thời gian quá unlockTime = now + TIMELOCK
cast rpc evm_increaseTime '[1801]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC
```
> Bước 2 – Sender refund
```bash
time cast send $ADDR_HTLC_GP "refund(bytes32)" \
  $LOCK_ID \
  --private-key $PK_SENDER \
  --rpc-url $RPC

TX_HASH_REFUND_GP_B=<hash refund>
cast receipt $TX_HASH_REFUND_GP_B --rpc-url $RPC   # gasUsed_refund_gp
```
> Kiểm tra “penalty paid” cho sender:
* Về logic Về logic contract:
    * Token amount được trả về lk.sender (Alice).
    * lk.depositPaid (depositRequired) được chuyển cho lk.sender luôn → đó chính là penalty mà receiver phải mất.
> Có thể quan sát:
```bash
# Token của SENDER được trả lại
cast call $ADDR_TOKEN_GP "balanceOf(address)(uint256)" $ADDR_SENDER --rpc-url $RPC

# ETH của SENDER tăng thêm ~ DEPOSIT_REQUIRED (trừ gas)
cast balance $ADDR_SENDER --rpc-url $RPC
```
> Đây chính là case HTLC-GP “phạt cố định”: receiver đã cọc, nhưng im lặng → sau timelock, sender lấy lại token + ăn luôn deposit.
#### 4.3 Scenario C – Không confirm deposit, refund sau depositWindow (penalty = 0)
Mục tiêu: minh họa nhánh “Case A” trong refund():

Deposit không confirm, depositWindowEnd đã qua → sender refund ngay, không có penalty.

Reset state (anvil lại / deploy lại / dùng LOCK_ID khác).

> Bước 1 – createLock nhưng KHÔNG gọi confirmParticipation
```bash
# giống Scenario B nhưng dừng sau createLock
time cast send $ADDR_HTLC_GP \
  "createLock(address,address,uint256,bytes32,uint256,uint256,uint256)(bytes32)" \
  $ADDR_RECEIVER \
  $ADDR_TOKEN_GP \
  $AMOUNT \
  $LOCK_ID \
  $TIMELOCK \
  $DEPOSIT_REQUIRED \
  $DEPOSIT_WINDOW \
  --private-key $PK_SENDER \
  --rpc-url $RPC

TX_HASH_LOCK_GP_C=<hash lock>
cast receipt $TX_HASH_LOCK_GP_C --rpc-url $RPC
```
> Bước 2 – Giả lập quá depositWindow, nhưng chưa hết timelock
```bash
# tăng thời gian > depositWindow (600s), có thể < timelock
cast rpc evm_increaseTime '[601]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC
```
> Bước 3 – Sender gọi refund
Ở nhánh !lk.depositConfirmed, điều kiện là block.timestamp > lk.depositWindowEnd:   
```bash
time cast send $ADDR_HTLC_GP "refund(bytes32)" \
  $LOCK_ID \
  --private-key $PK_SENDER \
  --rpc-url $RPC

TX_HASH_REFUND_GP_C=<hash refund>
cast receipt $TX_HASH_REFUND_GP_C --rpc-url $RPC
```
> Quan sát:
```bash
# Token quay lại cho sender
cast call $ADDR_TOKEN_GP "balanceOf(address)(uint256)" $ADDR_SENDER --rpc-url $RPC

# Penalty = 0 (không có ETH chuyển cho sender vì depositPaid = 0)

```