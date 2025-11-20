## Anvil
```bash
anvil
```

## Deploy 
```bash
export RPC=http://127.0.0.1:8545
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

forge script script/htlc-script.s.sol:htlc_script \
  --rpc-url $RPC \
  --broadcast -vv
```
### Ghi lại 2 địa chỉ:
```bash
export ADDR_TOKEN_TRAD=<MockToken in ra>
export ADDR_HTLC_TRAD=<HTLC_TRAD in ra>
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
cast send $ADDR_TOKEN_TRAD "mint(address,uint256)" \
  $ADDR_SENDER 1000000000000000000000 \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC
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

### 2 PoC flow cho HTLC truyền thống
#### 2.1 Approve trước khi lock
```bash
cast send $ADDR_TOKEN_TRAD "approve(address,uint256)" \
  $ADDR_HTLC_TRAD 100000000000000000000 \
  --private-key $PK_SENDER \
  --rpc-url $RPC

TX_HASH=<hash trả về>
cast receipt $TX_HASH --rpc-url $RPC   # để lấy gasUsed_approve (optional)
```
#### 2.2 Scenario A – Honest lock + claim sớm
> Lock:
```bash
time cast send $ADDR_HTLC_TRAD \
  "lock(address,address,uint256,bytes32,uint256)(bytes32)" \
  $ADDR_RECEIVER \
  $ADDR_TOKEN_TRAD \
  100000000000000000000 \
  $LOCK_ID \
  1800 \
  --private-key $PK_SENDER \
  --rpc-url $RPC
```
> Lưu TX_HASH_LOCK → cast receipt để lấy gasUsed_lock_trad
```bash
TX_HASH_LOCK=<hash lock>
cast receipt $TX_HASH_LOCK --rpc-url $RPC
```
> Claim sớm (trước 1800s):
```bash 
time cast send $ADDR_HTLC_TRAD "claim(bytes32,bytes)" \
  $LOCK_ID \
  $PREIMAGE_HEX \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC
```
> Lưu TX_HASH_CLAIM → cast receipt để lấy gasUsed_claim_trad
```bash
TX_HASH_CLAIM=<hash claim>
cast receipt $TX_HASH_CLAIM --rpc-url $RPC

# Kiểm tra số dư:
cast call $ADDR_TOKEN_TRAD "balanceOf(address)(uint256)" $ADDR_RECEIVER --rpc-url $RPC
```
> Dùng time như trên để có real = xấp xỉ độ trễ end-to-end (từ lúc bạn gửi tx tới lúc tx được mined). Trong phần MP-HTLC-LGP bạn có thêm “thời gian TSS ký”, ở đây TSS time = 0 nên baseline latency = chỉ on-chain.
#### 2.3 Scenario B – Lock + refund (receiver không claim)

> Reset state (anvil ctrl+c rồi anvil lại, hoặc deploy lại + dùng LOCK_ID khác).

> Lặp lại bước approve + lock như Scenario A (có thể re-use script bằng TIMESTAMP khác).

> Sau khi lock, không gọi claim. Thay vào đó:
```bash
# tăng thời gian giả lập vượt timelock = 1800s
cast rpc evm_increaseTime '[1801]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC

time cast send $ADDR_HTLC_TRAD "refund(bytes32)" \
  $LOCK_ID \
  --private-key $PK_SENDER \
  --rpc-url $RPC
```
> Lưu TX_HASH_REFUND → cast receipt để lấy gasUsed_refund_trad
```bash
TX_HASH_REFUND=<hash refund>
cast receipt $TX_HASH_REFUND --rpc-url $RPC

cast call $ADDR_TOKEN_TRAD "balanceOf(address)(uint256)" $ADDR_SENDER --rpc-url $RPC
```

#### 2.4 Scenario C – Mô phỏng griefing trong HTLC truyền thống

**Mục tiêu:** minh họa rằng **receiver** có thể "**grief**" bằng cách **giữ im lặng**, làm vốn của **sender** bị khóa đến hết **timelock**, mà **không chịu penalty on-chain** (phạt = 0) – đúng ý mô phỏng trong tài liệu.

---

>  Các bước thực hiện

1.  **Deploy lại + lock Scenario B.**
2.  **Xem như receiver "cố ý không claim" (griefing):**
    * **Không gửi tx claim nào.**
    * Chỉ đến khi thêm `evm_increaseTime` qua **1800s** thì **sender** mới **refund** như ở Scenario B.
3.  **Ghi lại:**
    * **`t_lock_to_refund = blockTimestamp(refund) – blockTimestamp(lock)`**
        * (có thể lấy từ `cast receipt` (field `blockNumber` rồi `cast block`), hoặc đơn giản là kiểm soát via `evm_increaseTime`).
    * **`gasUsed_lock_trad`, `gasUsed_refund_trad`**
    * Số lượng **token bị đóng băng** trong khoảng thời gian đó.
4.  **So sánh với PoC MP-HTLC-LGP:**

    * Trong **MP-HTLC-LGP**: **receiver delay claim** $\rightarrow$ **penalty** tăng **tuyến tính** theo thời gian, được trả cho **sender**.

    * Trong **HTLC truyền thống**: **receiver delay claim** $\rightarrow$ **penalty = 0**, chỉ phí chí là **gas** và **opportunity cost**, **không được bảo vệ on-chain**.

---

> Đồ thị "thời gian vốn bị lock" vs "penalty"

Bạn có thể lặp lại với các giá trị **timelock** khác nhau (1800, 3600, 7200s...) để **vẽ đồ thị** "**thời gian vốn bị lock**" vs "**penalty**":

* **HTLC truyền thống:** đường nằm ngang (**penalty** luôn 0).
* **MP-HTLC-LGP:** đường tuyến tính tăng theo thời gian.

### 3. Đo & log số liệu một cách có hệ thống

Theo phần 5.4 trong PDF, bạn cần đo **3 nhóm KPI chính**: **gas**, **latency**, **griefing**.


---

#### 3.1. Gas on-chain

Cho mỗi function:

* **lock, claim, refund** của **HTLC truyền thống**
* **lock, claimWithSig, refund** của **MP-HTLC-LGP**

Lặp lại mỗi function **N lần** (ví dụ **10**) trên cùng cấu hình, log:

```text
protocol, fn, gasUsed, timelock, timeBased, deposit, N_parties
```
Gas lấy từ cast receipt ... | grep gasUsed

#### 3.2. Độ trễ end-to-end
* Đối với **HTLC truyền thống**:
    * Dùng `time cast send ...` $\rightarrow$ lấy làm **`t_onchain_trad`**.

* Đối với **MP-HTLC-LGP**:
    * (i) Đo **`t_TSS_sign`** bằng log trong `go run main.go` (bằng `time go run main.go` hoặc log **timestamp** khi bắt đầu/kết thúc signing).
    * (ii) Đo **`t_onchain_lgp`** bằng `time cast send claimWithSig ...`.
    * **`t_total_lgp = t_TSS_sign + t_onchain_lgp`**.

---

> Khi vẽ biểu đồ:

* So sánh **`t_onchain_trad`** vs **`t_onchain_lgp`** $\rightarrow$ **chi phí thêm** (nếu có) do logic phức tạp hơn.
* So sánh **`t_total_lgp`** vs **`t_onchain_trad`** $\rightarrow$ **overhead** do **TSS off-chain**.

#### 3.3. Griefing

Kết hợp **Scenario B/C** ở **HTLC truyền thống** và **Scenario penalty** trong **MP-HTLC-LGP**:

* **Truyền thống:**
    * Đo **`t_vốn_bị_khóa`** và **`cost_sender = gas_lock + gas_refund`**.
    * **`penalty_receiver = 0`**.

* **MP-HTLC-LGP:**
    * Đo **`penalty_paid`** (từ event/hàm trong contract) tương ứng với **delay**.
    * Vẽ **đồ thị** **delay** vs **penalty** vs **`cost_sender`**.