## Anvil
```bash
anvil
```

## Chạy MPC/TSS
```bash
export PREIMAGE="super-secret-preimage"
go run main.go
```
## Copy địa chỉ TSS in ra, rồi:
```bash
export TSS_SIGNER=0xF0B4702B615AAb94c36952e7dFb45520Df8970F0
```
#### Output ví dụ:
```bash
TSS Ethereum Address = 0xF0B4702B615AAb94c36952e7dFb45520Df8970F0
lockId: 0x65f0...eda8
ethSig(65) = 0xf27b85...01
```

## Deploy
```bash
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/htlc-lgp-script.s.sol:htlc_lgp_script --rpc-url http://127.0.0.1:8545 --broadcast -vv
```
## PoC
```bash
export RPC=http://127.0.0.1:8545
export ADDR_TOKEN=0x5FbDB2315678afecb367f032d93F642f64180aa3   # MockToken address từ script deploy
export ADDR_HTLC=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512    # htlc_lgp address từ script deploy
export ADDR_TSS=$TSS_SIGNER   # chính là TSS Ethereum Address từ Go
```
### Lấy sẵn 1 account làm receiver (acc0 của Anvil)
```bash
export PK_RECEIVER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 
export ADDR_RECEIVER=$(cast wallet address --private-key $PK_RECEIVER)

cast rpc anvil_setBalance $ADDR_TSS 0x56bc75e2d63100000 --rpc-url http://127.0.0.1:8545
cast balance $ADDR_TSS --rpc-url http://127.0.0.1:8545
cast rpc anvil_setBalance $(cast wallet address --private-key $PK_RECEIVER) 0x56bc75e2d63100000 --rpc-url http://127.0.0.1:8545
cast send $ADDR_TOKEN "mint(address,uint256)" $ADDR_TSS 1000000000000000000000 \ --private-key $PK_RECEIVER --rpc-url $RPC

### Mượn danh EOA_TSS
cast rpc anvil_impersonateAccount $ADDR_TSS --rpc-url $RPC
cast rpc anvil_setBalance $ADDR_TSS 0x56bc75e2d63100000 --rpc-url $RPC  # 100 ETH
```
### Approve 100 MTK cho HTLC
```bash
cast send $ADDR_TOKEN "approve(address,uint256)" $ADDR_HTLC 100000000000000000000 \
  --from $ADDR_TSS --rpc-url $RPC
```
### Tạo preimage & lockId (sha256)
```bash
export TSS_SIGNER=0xF0B4702B615AAb94c36952e7dFb45520Df8970F0
export LOCK_ID=0x65f0...eda8 # copy từ log Go hoặc cast sha256 
export SIG=0xf27b85...01 # ethSig(65) từ Go
export PREIMAGE_HEX=0x$(echo -n "super-secret-preimage" | xxd -p -c 200)

```
### lock: amount=100e18, timelock=1800, timeBased=600, deposit=1 ETH, depositWindow=600
```bash
cast send $ADDR_HTLC "lock(address,address,bytes32,uint256,uint256,uint256,uint256,uint256)(bytes32)" \
  $ADDR_RECEIVER $ADDR_TOKEN $LOCK_ID 100000000000000000000 1800 600 1000000000000000000 600 \
  --from $ADDR_TSS --rpc-url $RPC
```
### Receiver nộp deposit
```bash
cast send $ADDR_HTLC "confirmParticipation(bytes32)" $LOCK_ID \
  --value 1000000000000000000 --private-key $PK_RECEIVER --rpc-url $RPC
```
## Scenario 1: Claim sớm
```bash
cast send $ADDR_HTLC "claimWithSig(bytes32,bytes,bytes)" \
  $LOCK_ID $PREIMAGE_HEX $SIG \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC
cast call $ADDR_TOKEN "balanceOf(address)(uint256)" $ADDR_RECEIVER --rpc-url $RPC
```
##Scenario 2: Claim trong penalty window (penalty > 0)
### Tua tới giữa penalty window
```bash
cast rpc evm_increaseTime '[1201]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC

cast send $ADDR_HTLC "claimWithSig(bytes32,bytes,bytes)" \
  $LOCK_ID $PREIMAGE_HEX $SIG \
  --private-key $PK_RECEIVER \
  --rpc-url $RPC
```
## Scenario 3: Deposit đã confirm nhưng không claim, sender refund
> Lưu ý: chạy lại từ đầu (anvil, MPC/TSS, deploy, lock, confirmParticipation) 
> như các bước trên, rồi dừng ở bước "Receiver nộp deposit".
```bash
cast rpc evm_increaseTime '[1801]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC
```
### Sender (ADDR_TSS) gọi refund
```bash
cast send $ADDR_HTLC "refund(bytes32)" $LOCK_ID \
  --from $ADDR_TSS --rpc-url $RPC
``` 
### Kiểm tra token quay lại cho sender (ADDR_TSS)
```bash
cast call $ADDR_TOKEN "balanceOf(address)(uint256)" $ADDR_TSS --rpc-url $RPC
```
### Kiểm tra balance ETH (penalty = full depositPaid gửi về sender)
```bash
cast balance $ADDR_TSS --rpc-url $RPC
```

## Scenario 4 – Không confirm deposit, refund sau depositWindow
> Chạy lại từ đầu, chỉ làm tới bước lock, không gọi confirmParticipation.
### depositWindow = 600
```bash
cast rpc evm_increaseTime '[601]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC
```
### Sender refund (không cần depositConfirmed)
```bash
cast send $ADDR_HTLC "refund(bytes32)" $LOCK_ID \
  --from $ADDR_TSS --rpc-url $RPC

cast call $ADDR_TOKEN "balanceOf(address)(uint256)" $ADDR_TSS --rpc-url $RPC
```