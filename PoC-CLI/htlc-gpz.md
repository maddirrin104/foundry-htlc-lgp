## Anvil
```bash
anvil
```
## Deploy 
```bash
export RPC=http://127.0.0.1:8545
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

forge script script/htlc-gpz-script.s.sol:htlc_gpz_script \
  --rpc-url $RPC \
  --broadcast -vv
```
### Ghi lại 2 địa chỉ:
```bash
export ADDR_TOKEN_GPZ=<MockToken in ra>
export ADDR_HTLC_GPZ=<htlc_gpz in ra>
```

## Config
### 1. Cấu hình account + preimage/hashlock
#### 1.1 Sender / Receiver
```bash
# Anvil account 0 – RECEIVER (Bob)
export PK_RECEIVER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ADDR_RECEIVER=$(cast wallet address --private-key $PK_RECEIVER)

# Anvil account 1 – SENDER (Alice)
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
cast send $ADDR_TOKEN_GPZ "mint(address,uint256)" \
  $ADDR_SENDER 1000000000000000000000 \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC

TX_HASH_MINT=<hash mint>
cast receipt $TX_HASH_MINT --rpc-url $RPC
```
#### 1.2 Preimage + hashlock (LOCK_ID)
```bash
export PREIMAGE="super-secret-preimage"
export PREIMAGE_HEX=0x$(echo -n "$PREIMAGE" | xxd -p -c 200)

# LOCK_ID = sha256(preimage)
export LOCK_ID=0x$(echo -n "$PREIMAGE" | openssl dgst -binary -sha256 | xxd -p -c 64)
echo $LOCK_ID
```

### 2. Approve trước khi createLock
> Sender (Alice) approve token cho HTLC-GP:
```bash
cast send $ADDR_TOKEN_GPZ "approve(address,uint256)" \
  $ADDR_HTLC_GPZ 100000000000000000000 \
  --private-key $PK_SENDER \
  --rpc-url $RPC

TX_HASH_APPROVE_GPZ=<hash approve>
cast receipt $TX_HASH_APPROVE_GPZ --rpc-url $RPC   # gasUsed_approve_gpz
```
### 3. Các tham số lock
```bash
export AMOUNT=100000000000000000000          # 100 * 1e18
export TIMELOCK=1800                         # 30 phút
export TIMEBASED=600                         # penalty window 10 phút cuối
export DEPOSIT_REQUIRED=1000000000000000000  # 1 ETH
export DEPOSIT_WINDOW=600                    # 10 phút cho confirmParticipation

```
### 4. PoC flow cho HTLC-GP
#### 4.1 Scenario 1 – Claim sớm (trước penalty window, penalty = 0)
Mục tiêu: block.timestamp < unlockTime - timeBased ⇒ không có penalty, receiver nhận đủ deposit.
> Bước 1 – Sender createLock
```bash
time cast send $ADDR_HTLC_GPZ \
  "createLock(address,address,uint256,bytes32,uint256,uint256,uint256,uint256)(bytes32)" \
  $ADDR_RECEIVER \
  $ADDR_TOKEN_GPZ \
  $AMOUNT \
  $LOCK_ID \
  $TIMELOCK \
  $TIMEBASED \
  $DEPOSIT_REQUIRED \
  $DEPOSIT_WINDOW \
  --private-key $PK_SENDER \
  --rpc-url $RPC

TX_HASH_LOCK_GPZ_S1=<hash lock>
cast receipt $TX_HASH_LOCK_GPZ_S1 --rpc-url $RPC   # gasUsed_lock_gpz
```
> Bước 2 – Receiver confirmParticipation (đặt cọc)
```bash 
time cast send $ADDR_HTLC_GPZ "confirmParticipation(bytes32)" \
  $LOCK_ID \
  --value $DEPOSIT_REQUIRED \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC

TX_HASH_DEPOSIT_GPZ_S1=<hash deposit>
cast receipt $TX_HASH_DEPOSIT_GPZ_S1 --rpc-url $RPC   # gasUsed_confirm_gpz

```
> Bước 3 – Claim ngay (trước penalty window)
```bash
time cast send $ADDR_HTLC_GPZ "claim(bytes32,bytes)" \
  $LOCK_ID \
  $PREIMAGE_HEX \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC

TX_HASH_CLAIM_GPZ_S1=<hash claim>
cast receipt $TX_HASH_CLAIM_GPZ_S1 --rpc-url $RPC   # gasUsed_claim_gpz
```
> Kiểm tra số dư & deposit refund: 
``` bash
# Receiver nhận token
cast call $ADDR_TOKEN_GPZ "balanceOf(address)(uint256)" $ADDR_RECEIVER --rpc-url $RPC

# Deposit được refund đầy đủ cho receiver (trừ gas)
cast balance $ADDR_RECEIVER --rpc-url $RPC
```
#### 4.2 Scenario 2 – Claim trong penalty window (penalty tuyến tính 0 < penalty < deposit)
> Penalty window: penaltyWindowStart = unlockTime - timeBased = now + (TIMELOCK - TIMEBASED) = now + 1200.

Quy trình: giống S1 tới confirmParticipation, sau đó tăng thời gian để vào penalty-window.
> Bước 1 – createLock + confirmParticipation

Dùng lại các lệnh ở S1 (hoặc reset anvil + redeploy + LOCK_ID khác nếu muốn “sạch”).

> Bước 2 – Nhảy thời gian vào giữa penalty window

Ví dụ: tăng 1300s (nằm giữa 1200–1800):
```bash
cast rpc evm_increaseTime '[1300]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC
```
> Bước 3 – Claim (bị phạt tuyến tính)
```bash
time cast send $ADDR_HTLC_GPZ "claim(bytes32,bytes)" \
  $LOCK_ID \
  $PREIMAGE_HEX \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC

TX_HASH_CLAIM_GPZ_S2=<hash claim>
cast receipt $TX_HASH_CLAIM_GPZ_S2 --rpc-url $RPC
```
Để kiểm tra penalty vs refund:
* Xem event LockClaimed(lockId, receiver, penalty) qua cast logs nếu muốn.
* Hoặc so sánh:
```bash
# Token: receiver nhận amount
cast call $ADDR_TOKEN_GPZ "balanceOf(address)(uint256)" $ADDR_RECEIVER --rpc-url $RPC

# ETH:
cast balance $ADDR_SENDER --rpc-url $RPC   # sender nhận penalty
cast balance $ADDR_RECEIVER --rpc-url $RPC # receiver chỉ nhận phần depositBack
```
Ở S2, penalty = depositRequired * elapsed / timeBased (capped bởi depositPaid)
⇒ vừa minh họa penalty tuyến tính theo thời gian trễ.

#### 4.3 Claim rất trễ, sát unlockTime (penalty ≈ full deposit)
Mục tiêu: cho elapsed ≈ timeBased ⇒ penalty ≈ depositRequired.

Flow giống S2 nhưng:
* Sau khi createLock + confirmParticipation, tăng thời gian ~ TIMELOCK - 1 (ví dụ 1799s):
```bash
cast rpc evm_increaseTime '[1799]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC
```
Vẫn đảm bảo block.timestamp < unlockTime (vì 1799 < 1800) ⇒ claim còn hợp lệ.
Rồi claim:
```bash
time cast send $ADDR_HTLC_GPZ "claim(bytes32,bytes)" \
  $LOCK_ID \
  $PREIMAGE_HEX \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC

TX_HASH_CLAIM_GPZ_S3=<hash claim>
cast receipt $TX_HASH_CLAIM_GPZ_S3 --rpc-url $RPC
```
> Quan sát:
* Token: vẫn vào receiver.
* ETH:
  * sender ≈ + depositRequired (penalty ~ full deposit).
  * receiver ≈ chỉ còn gas (depositBack ≈ 0).
> Đây là case minh họa “griefing TOÁN HỌC”: càng claim trễ gần hết window, receiver mất gần full cọc.

#### 4.4 Scenario 4 – Deposit không confirm, refund sau depositWindow (penalty = 0)
Mục tiêu: nhánh !lk.depositConfirmed trong refund().
> Bước 1 – createLock nhưng KHÔNG gọi confirmParticipation
```bash
time cast send $ADDR_HTLC_GPZ \
  "createLock(address,address,uint256,bytes32,uint256,uint256,uint256,uint256)(bytes32)" \
  $ADDR_RECEIVER \
  $ADDR_TOKEN_GPZ \
  $AMOUNT \
  $LOCK_ID \
  $TIMELOCK \
  $TIMEBASED \
  $DEPOSIT_REQUIRED \
  $DEPOSIT_WINDOW \
  --private-key $PK_SENDER \
  --rpc-url $RPC

TX_HASH_LOCK_GPZ_S4=<hash lock>
cast receipt $TX_HASH_LOCK_GPZ_S4 --rpc-url $RPC
```
> Bước 2 – Nhảy qua depositWindow
```bash
cast rpc evm_increaseTime '[601]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC
```
> Bước 3 – Sender refund, không có penalty
```bash
time cast send $ADDR_HTLC_GPZ "refund(bytes32)" \
  $LOCK_ID \
  --private-key $PK_SENDER \
  --rpc-url $RPC

TX_HASH_REFUND_GPZ_S4=<hash refund>
cast receipt $TX_HASH_REFUND_GPZ_S4 --rpc-url $RPC
```
> check:
```bash
cast call $ADDR_TOKEN_GPZ "balanceOf(address)(uint256)" $ADDR_SENDER --rpc-url $RPC
# penalty = 0, không có ETH penalty chuyển thêm
cast balance $ADDR_SENDER --rpc-url $RPC
```

#### 4.5 Scenario 5 – Deposit đã confirm nhưng receiver không claim, refund sau timelock (griefing chậm / không claim)
Mục tiêu: minh họa nhánh Case B trong refund():
* Deposit đã confirm.
* block.timestamp >= unlockTime.
* Receiver không claim ⇒ toàn bộ depositPaid được chuyển cho sender khi refund.
Flow:
1. createLock + confirmParticipation (giống S1).
2. Không gọi claim.
3. Sau đó:
```bash 
cast rpc evm_increaseTime '[1801]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC

time cast send $ADDR_HTLC_GPZ "refund(bytes32)" \
  $LOCK_ID \
  --private-key $PK_SENDER \
  --rpc-url $RPC

TX_HASH_REFUND_GPZ_S5=<hash refund>
cast receipt $TX_HASH_REFUND_GPZ_S5 --rpc-url $RPC
```

> Quan sát:
* Token: trả lại cho sender.
* ETH: sender nhận full depositPaid (penalty = deposit), receiver mất cọc hoàn toàn.
