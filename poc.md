## Anvil
```bash
anvil
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
export ADDR_TSS=0x52165F5Ad3f7a163A724E240C8b894133b62755c     # in ra từ Go MPC: TSS Ethereum Address
```
### Lấy sẵn 1 account làm receiver (acc0 của Anvil)
```bash
export PK_RECEIVER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 
export ADDR_RECEIVER=$(cast wallet address --private-key $PK_RECEIVER)

cast rpc anvil_setBalance 0x52165F5Ad3f7a163A724E240C8b894133b62755c 0x56bc75e2d63100000 --rpc-url http://127.0.0.1:8545
cast balance 0x52165F5Ad3f7a163A724E240C8b894133b62755c --rpc-url http://127.0.0.1:8545
cast rpc anvil_setBalance $(cast wallet address --private-key $PK_RECEIVER) 0x56bc75e2d63100000 --rpc-url http://127.0.0.1:8545
cast send $ADDR_TOKEN "mint(address,uint256)" $ADDR_TSS 1000000000000000000000 \  --private-key $PK_RECEIVER --rpc-url $RPC
cast rpc anvil_impersonateAccount $ADDR_TSS --rpc-url $RPC
cast rpc anvil_setBalance $ADDR_TSS 0x56bc75e2d63100000 --rpc-url $RPC  # 100 ETH
```
### Mượn danh EOA_TSS
```bash
cast rpc anvil_impersonateAccount '["'$ADDR_TSS'"]' --rpc-url $RPC
```
### Approve 100 MTK cho HTLC
```bash
cast send $ADDR_TOKEN "approve(address,uint256)" $ADDR_HTLC 100000000000000000000 \
  --from $ADDR_TSS --rpc-url $RPC
```
### Tạo preimage & lockId (sha256)
```bash
export PREIMAGE_HEX=0x$(echo -n "super-secret-preimage" | xxd -p -c 200)
export LOCK_ID=$(cast sha256 $PREIMAGE_HEX)
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
### Claim sớm
```bash
cast send $ADDR_HTLC "claim(bytes32,bytes)" $LOCK_ID $PREIMAGE_HEX \
  --private-key $PK_RECEIVER --rpc-url $RPC
cast call $ADDR_TOKEN "balanceOf(address)(uint256)" $ADDR_RECEIVER --rpc-url $RPC
```
### Trong penalty window
#### Tua tới giữa penalty window
```bash
cast rpc evm_increaseTime '[1201]' --rpc-url $RPC
cast rpc evm_mine '[]' --rpc-url $RPC

cast send $ADDR_HTLC "claim(bytes32,bytes)" $LOCK_ID $PREIMAGE_HEX \
  --private-key $PK_RECEIVER --rpc-url $RPC
```