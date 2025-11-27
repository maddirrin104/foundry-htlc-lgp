#!/usr/bin/env bash
set -euo pipefail

############################################
# 0. CONFIG CHUNG
############################################

RPC=${RPC:-"http://127.0.0.1:8545"}

# Account deploy + receiver = anvil account[0]
PK_DEPLOY=${PRIVATE_KEY:-"0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"}
PK_RECEIVER="$PK_DEPLOY"

# Account sender = anvil account[1]
PK_SENDER="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

# Amount token dùng cho mỗi lock (100 token, 18 decimals)
AMOUNT="100000000000000000000"

# Timelock (giây)
TIMELOCK=1800

# Tham số HTLC-GP
DEPOSIT_REQUIRED="1000000000000000000" # 1 ETH
DEPOSIT_WINDOW=600                     # 10 phút

# Preimage để so sánh với MP-HTLC-LGP
PREIMAGE="${PREIMAGE:-super-secret-preimage}"

############################################
# 1. HÀM TIỆN ÍCH
############################################

log() {
  echo -e "\n==================== $* ====================\n"
}

start_anvil() {
  if pgrep -x "anvil" > /dev/null; then
    echo "[*] anvil đã chạy, bỏ qua bước start."
    return
  fi
  echo "[*] start anvil..."
  anvil --block-time 1 --silent &
  ANVIL_PID=$!
  sleep 3
}

cleanup() {
  if [[ -n "${ANVIL_PID:-}" ]]; then
    echo "[*] stop anvil (PID=$ANVIL_PID)"
    kill "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

############################################
# 2. DEPLOY MOCKTOKEN + HTLC-GP
############################################

deploy_contracts() {
  log "Deploy MockToken + HTLC-GP bằng forge script"

  mkdir -p logs

  export PRIVATE_KEY="$PK_DEPLOY"

  DEPLOY_LOG=$(forge script script/htlc-gp-script.s.sol:htlc_gp_script \
    --rpc-url "$RPC" \
    --private-key "$PK_DEPLOY" \
    --broadcast -vv 2>&1)

  echo "$DEPLOY_LOG" > logs/deploy_htlc_gp.log

  # Lấy tất cả địa chỉ 0x... xuất hiện trong log
  mapfile -t ADDRS < <(grep -Eo "0x[a-fA-F0-9]{40}" logs/deploy_htlc_gp.log)

  # Giả định script log theo thứ tự:
  # 0 -> MockToken_GP, 1 -> HTLC-GP
  ADDR_TOKEN_GP=${ADDRS[0]:-}
  ADDR_HTLC_GP=${ADDRS[1]:-}

  if [[ -z "$ADDR_TOKEN_GP" || -z "$ADDR_HTLC_GP" ]]; then
    echo "[!] Không parse được địa chỉ từ logs/deploy_htlc_gp.log"
    echo "    Hãy mở file log và điều chỉnh lại đoạn mapfile/ADDRS[...] cho đúng thứ tự."
    exit 1
  fi

  echo "[*] ADDR_TOKEN_GP = $ADDR_TOKEN_GP"
  echo "[*] ADDR_HTLC_GP  = $ADDR_HTLC_GP"

  export ADDR_TOKEN_GP
  export ADDR_HTLC_GP
}

############################################
# 3. CONFIG ACCOUNT + PREIMAGE / HASHLOCK
############################################

config_accounts() {
  log "Config account sender/receiver + cấp ETH + mint token"

  export ADDR_RECEIVER
  export ADDR_SENDER

  ADDR_RECEIVER=$(cast wallet address --private-key "$PK_RECEIVER")
  ADDR_SENDER=$(cast wallet address --private-key "$PK_SENDER")

  echo "[*] ADDR_RECEIVER = $ADDR_RECEIVER"
  echo "[*] ADDR_SENDER   = $ADDR_SENDER"

  # Cấp ETH
  cast rpc anvil_setBalance "$ADDR_SENDER"   0x56bc75e2d63100000 --rpc-url "$RPC" || true
  cast rpc anvil_setBalance "$ADDR_RECEIVER" 0x56bc75e2d63100000 --rpc-url "$RPC" || true

  # Mint token cho sender
  cast send "$ADDR_TOKEN_GP" "mint(address,uint256)" \
    "$ADDR_SENDER" 1000000000000000000000 \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  # Preimage + LOCK_ID (sha256)
  export PREIMAGE_HEX
  export LOCK_ID_A
  export LOCK_ID_B
  export LOCK_ID_C

  PREIMAGE_HEX="0x$(echo -n "$PREIMAGE" | xxd -p -c 200)"
  LOCK_ID_A="0x$(echo -n "$PREIMAGE" | openssl dgst -binary -sha256 | xxd -p -c 64)"

  PREIMAGE_B="${PREIMAGE}_gpB"
  LOCK_ID_B="0x$(echo -n "$PREIMAGE_B" | openssl dgst -binary -sha256 | xxd -p -c 64)"

  PREIMAGE_C="${PREIMAGE}_gpC"
  LOCK_ID_C="0x$(echo -n "$PREIMAGE_C" | openssl dgst -binary -sha256 | xxd -p -c 64)"

  echo "[*] PREIMAGE      = $PREIMAGE"
  echo "[*] PREIMAGE_HEX  = $PREIMAGE_HEX"
  echo "[*] LOCK_ID_A     = $LOCK_ID_A"
  echo "[*] LOCK_ID_B     = $LOCK_ID_B"
  echo "[*] LOCK_ID_C     = $LOCK_ID_C"
}

approve_tokens() {
  log "Approve token cho HTLC-GP"

  cast send "$ADDR_TOKEN_GP" "approve(address,uint256)" \
    "$ADDR_HTLC_GP" 1000000000000000000000 \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"
}

############################################
# 4. SCENARIO A – Honest: deposit + claim sớm
############################################

scenario_A() {
  log "Scenario A – Honest: createLock + confirmParticipation + claim sớm"

  echo "[*] createLock..."
  time cast send "$ADDR_HTLC_GP" \
    "createLock(address,address,uint256,bytes32,uint256,uint256,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN_GP" \
    "$AMOUNT" \
    "$LOCK_ID_A" \
    "$TIMELOCK" \
    "$DEPOSIT_REQUIRED" \
    "$DEPOSIT_WINDOW" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] confirmParticipation (deposit)..."
  time cast send "$ADDR_HTLC_GP" "confirmParticipation(bytes32)" \
    "$LOCK_ID_A" \
    --value "$DEPOSIT_REQUIRED" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[*] claim sớm..."
  time cast send "$ADDR_HTLC_GP" "claim(bytes32,bytes)" \
    "$LOCK_ID_A" \
    "$PREIMAGE_HEX" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[*] Balance receiver sau claim (token):"
  cast call "$ADDR_TOKEN_GP" "balanceOf(address)(uint256)" "$ADDR_RECEIVER" --rpc-url "$RPC"

  echo "[*] Balance receiver (ETH) – deposit đã refund:"
  cast balance "$ADDR_RECEIVER" --rpc-url "$RPC"
}

############################################
# 5. SCENARIO B – Griefing: đã deposit nhưng receiver KHÔNG claim
############################################

scenario_B() {
  log "Scenario B – Griefing: receiver đã cọc nhưng im lặng, sender refund sau timelock"

  echo "[*] createLock (LOCK_ID_B)..."
  time cast send "$ADDR_HTLC_GP" \
    "createLock(address,address,uint256,bytes32,uint256,uint256,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN_GP" \
    "$AMOUNT" \
    "$LOCK_ID_B" \
    "$TIMELOCK" \
    "$DEPOSIT_REQUIRED" \
    "$DEPOSIT_WINDOW" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] confirmParticipation (deposit)..."
  time cast send "$ADDR_HTLC_GP" "confirmParticipation(bytes32)" \
    "$LOCK_ID_B" \
    --value "$DEPOSIT_REQUIRED" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[*] Receiver KHÔNG claim → mô phỏng griefing."
  echo "[*] Tăng thời gian vượt TIMELOCK=$TIMELOCK s..."
  cast rpc evm_increaseTime $((TIMELOCK + 1)) --rpc-url "$RPC"
  cast rpc evm_mine --rpc-url "$RPC"

  echo "[*] Sender refund..."
  time cast send "$ADDR_HTLC_GP" "refund(bytes32)" \
    "$LOCK_ID_B" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] Balance sender (token) sau refund:"
  cast call "$ADDR_TOKEN_GP" "balanceOf(address)(uint256)" "$ADDR_SENDER" --rpc-url "$RPC"

  echo "[*] Balance sender (ETH) – nhận thêm penalty ≈ depositRequired:"
  cast balance "$ADDR_SENDER" --rpc-url "$RPC"
}

############################################
# 6. SCENARIO C – Không confirm deposit, refund sau depositWindow (penalty = 0)
############################################

scenario_C() {
  log "Scenario C – Không confirm deposit, refund sau depositWindow, penalty = 0"

  echo "[*] createLock (LOCK_ID_C) – KHÔNG confirmParticipation..."
  time cast send "$ADDR_HTLC_GP" \
    "createLock(address,address,uint256,bytes32,uint256,uint256,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN_GP" \
    "$AMOUNT" \
    "$LOCK_ID_C" \
    "$TIMELOCK" \
    "$DEPOSIT_REQUIRED" \
    "$DEPOSIT_WINDOW" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] Tăng thời gian qua depositWindow=$DEPOSIT_WINDOW s (nhưng có thể < timelock)..."
  cast rpc evm_increaseTime $((DEPOSIT_WINDOW + 1)) --rpc-url "$RPC"
  cast rpc evm_mine --rpc-url "$RPC"

  echo "[*] Sender refund (nhánh !depositConfirmed)..."
  time cast send "$ADDR_HTLC_GP" "refund(bytes32)" \
    "$LOCK_ID_C" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] Balance sender (token) sau refund:"
  cast call "$ADDR_TOKEN_GP" "balanceOf(address)(uint256)" "$ADDR_SENDER" --rpc-url "$RPC"

  echo "[*] Balance sender (ETH) – không có penalty vì depositPaid = 0:"
  cast balance "$ADDR_SENDER" --rpc-url "$RPC"
}

############################################
# MAIN
############################################

main() {
  start_anvil
  deploy_contracts
  config_accounts
  approve_tokens

  scenario_A
  scenario_B
  scenario_C

  log "Hoàn tất PoC HTLC-GP – Scenario A + B + C"
  echo "Xem thêm logs/deploy_htlc_gp.log để lấy tx hash rồi:"
  echo "  cast receipt <TX_HASH> --rpc-url $RPC"
  echo "để đo gas lock/claim/refund cho bảng kết quả."
}

main "$@"
