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
export LOCK_ID=<lockId in ra từ Go>
export SIG=<ethSig(65) in ra từ Go>
```

## Deploy 
```bash
# deploy với account đầu tiên lấy từ anvil (blockchain chạy local)
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/htlc-lgp-script.s.sol:htlc_lgp_script \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast -vv
```

## Config
#### Cấu hình địa chỉ
```bash
export RPC=http://127.0.0.1:8545
export ADDR_TOKEN=0x5FbDB2315678afecb367f032d93F642f64180aa3 # MockToken từ script deploy
export ADDR_HTLC=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 # htlc_lgp từ script deploy
export ADDR_TSS=$TSS_SIGNER # chính là TSS Ethereum Address
```

#### Lấy sẵn 1 account làm receiver (acc0 của Anvil)
```bash
export PK_RECEIVER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 
export ADDR_RECEIVER=$(cast wallet address --private-key $PK_RECEIVER)

cast rpc anvil_setBalance $ADDR_TSS 0x56bc75e2d63100000 --rpc-url $RPC
cast balance $ADDR_TSS --rpc-url $RPC

cast rpc anvil_setBalance $ADDR_RECEIVER 0x56bc75e2d63100000 --rpc-url $RPC

cast send $ADDR_TOKEN "mint(address,uint256)" $ADDR_TSS 1000000000000000000000 \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC

## Sau mỗi lệnh cast send, thêm một bước lấy receipt:
TX_HASH=<hash tx lock/claim/refund>
cast receipt $TX_HASH --rpc-url $RPC
```

#### Mượn danh EOA_TSS
```bash
cast rpc anvil_impersonateAccount $ADDR_TSS --rpc-url $RPC
cast rpc anvil_setBalance $ADDR_TSS 0x56bc75e2d63100000 --rpc-url $RPC  # 100 ETH
```

#### Approve 100 MTK cho HTLC
```bash
cast send $ADDR_TOKEN "approve(address,uint256)" $ADDR_HTLC 100000000000000000000 \
  --from $ADDR_TSS --rpc-url $RPC

## Sau mỗi lệnh cast send, thêm một bước lấy receipt:
TX_HASH=<hash tx lock/claim/refund>
cast receipt $TX_HASH --rpc-url $RPC
```

#### Tạo preimage & lockId (sha256)
```bash
export PREIMAGE_HEX=0x$(echo -n "super-secret-preimage" | xxd -p -c 200)
# LOCK_ID và SIG đã export từ bước chạy Go ở trên
```

#### lock: amount=100e18, timelock=1800, timeBased=600, deposit=1 ETH, depositWindow=600
```bash
cast send $ADDR_HTLC "lock(address,address,bytes32,uint256,uint256,uint256,uint256,uint256)(bytes32)" \
  $ADDR_RECEIVER $ADDR_TOKEN $LOCK_ID 100000000000000000000 1800 600 1000000000000000000 600 \
  --from $ADDR_TSS --rpc-url $RPC

## Sau mỗi lệnh cast send, thêm một bước lấy receipt:
TX_HASH=<hash tx lock/claim/refund>
cast receipt $TX_HASH --rpc-url $RPC
```

#### Receiver nộp deposit
```bash
cast send $ADDR_HTLC "confirmParticipation(bytes32)" $LOCK_ID \
  --value 1000000000000000000 \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC

## Sau mỗi lệnh cast send, thêm một bước lấy receipt:
TX_HASH=<hash tx lock/claim/refund>
cast receipt $TX_HASH --rpc-url $RPC
```

## PoC
### Scenario 1: Claim sớm (không penalty)
> Chạy flow trên đến bước confirmParticipation
```bash
time cast send $ADDR_HTLC "claimWithSig(bytes32,bytes,bytes)" \
  $LOCK_ID $PREIMAGE_HEX $SIG \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC

## Sau mỗi lệnh cast send, thêm một bước lấy receipt:
TX_HASH=<hash tx lock/claim/refund>
cast receipt $TX_HASH --rpc-url $RPC

cast call $ADDR_TOKEN "balanceOf(address)(uint256)" $ADDR_RECEIVER --rpc-url $RPC
```

### Scenario 2: Claim trong penalty window (penalty > 0)
> Khởi động lại (hoặc tạo lock mới) và lặp lại các bước đến confirmParticipation, không chạy Scenario 1 trên cùng lock.
```bash 
cast rpc evm_increaseTime '[1201]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC

time cast send $ADDR_HTLC "claimWithSig(bytes32,bytes,bytes)" \
  $LOCK_ID $PREIMAGE_HEX $SIG \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC

## Sau mỗi lệnh cast send, thêm một bước lấy receipt:
TX_HASH=<hash tx lock/claim/refund>
cast receipt $TX_HASH --rpc-url $RPC
```

### Scenario 3: Deposit đã confirm nhưng không claim, sender refund
> Khởi động lại (hoặc lock mới), chạy đến bước confirmParticipation
```bash
cast rpc evm_increaseTime '[1801]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC

time cast send $ADDR_HTLC "refund(bytes32)" $LOCK_ID \
  --from $ADDR_TSS --rpc-url $RPC

## Sau mỗi lệnh cast send, thêm một bước lấy receipt:
TX_HASH=<hash tx lock/claim/refund>
cast receipt $TX_HASH --rpc-url $RPC

cast call $ADDR_TOKEN "balanceOf(address)(uint256)" $ADDR_TSS --rpc-url $RPC
cast balance $ADDR_TSS --rpc-url $RPC
```

### Scenario 4: Không confirm deposit, refund sau depositWindow
> Khởi động lại, chỉ lock, không gọi confirmParticipation.
```bash
cast rpc evm_increaseTime '[601]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC

time cast send $ADDR_HTLC "refund(bytes32)" $LOCK_ID \
  --from $ADDR_TSS --rpc-url $RPC

## Sau mỗi lệnh cast send, thêm một bước lấy receipt:
TX_HASH=<hash tx lock/claim/refund>
cast receipt $TX_HASH --rpc-url $RPC

cast call $ADDR_TOKEN "balanceOf(address)(uint256)" $ADDR_TSS --rpc-url $RPC
```