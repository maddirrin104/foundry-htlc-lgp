#!/usr/bin/env bash
set -euo pipefail

############################################
# 0. PATH & CONFIG CHUNG
############################################

# Lấy đường dẫn thư mục chứa script (utils/)
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# Thư mục project = thư mục cha của utils/
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Thư mục logs
LOG_DIR="$PROJECT_ROOT/logs"

# Đảm bảo logs/ tồn tại
mkdir -p "$LOG_DIR"

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
# 2. DEPLOY MOCKTOKEN + HTLC_TRAD
############################################

deploy_contracts() {
  log "Deploy MockToken + HTLC_TRAD bằng forge script"

  DEPLOY_LOG=$(forge script script/htlc-script.s.sol:htlc_script \
    --rpc-url "$RPC" \
    --private-key "$PK_DEPLOY" \
    --broadcast -vv 2>&1)

  # ghi log vào logs/deploy_htlc_trad.log (tuyệt đối)
  echo "$DEPLOY_LOG" > "$LOG_DIR/deploy_htlc_trad.log"

  # parse địa chỉ từ file log
  ADDR_TOKEN_TRAD=$(grep "MockToken" "$LOG_DIR/deploy_htlc_trad.log" | awk '{print $2}' | tail -1)
  ADDR_HTLC_TRAD=$(grep "HTLC_TRAD" "$LOG_DIR/deploy_htlc_trad.log" | awk '{print $2}' | tail -1)

  if [[ -z "$ADDR_TOKEN_TRAD" || -z "$ADDR_HTLC_TRAD" ]]; then
    echo "[!] Không parse được địa chỉ từ $LOG_DIR/deploy_htlc_trad.log. Kiểm tra lại console.log trong script deploy."
    exit 1
  fi

  echo "[*] ADDR_TOKEN_TRAD = $ADDR_TOKEN_TRAD"
  echo "[*] ADDR_HTLC_TRAD  = $ADDR_HTLC_TRAD"

  export ADDR_TOKEN_TRAD
  export ADDR_HTLC_TRAD
}

############################################
# 3. CONFIG ACCOUNT + PREIMAGE / HASHLOCK
############################################

config_accounts() {
  log "Config account sender/receiver + cấp ETH + mint token"

  ADDR_RECEIVER=$(cast wallet address --private-key "$PK_RECEIVER")
  ADDR_SENDER=$(cast wallet address --private-key "$PK_SENDER")
  export ADDR_RECEIVER ADDR_SENDER

  echo "[*] ADDR_RECEIVER = $ADDR_RECEIVER"
  echo "[*] ADDR_SENDER   = $ADDR_SENDER"

  cast rpc anvil_setBalance "$ADDR_SENDER" 0x56bc75e2d63100000 --rpc-url "$RPC"
  cast rpc anvil_setBalance "$ADDR_RECEIVER" 0x56bc75e2d63100000 --rpc-url "$RPC"

  cast send "$ADDR_TOKEN_TRAD" "mint(address,uint256)" \
    "$ADDR_SENDER" 1000000000000000000000 \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  PREIMAGE_HEX="0x$(echo -n "$PREIMAGE" | xxd -p -c 200)"
  LOCK_ID_A="0x$(echo -n "$PREIMAGE" | openssl dgst -binary -sha256 | xxd -p -c 64)"

  PREIMAGE_B="${PREIMAGE}_grief"
  LOCK_ID_B="0x$(echo -n "$PREIMAGE_B" | openssl dgst -binary -sha256 | xxd -p -c 64)"

  export PREIMAGE_HEX LOCK_ID_A LOCK_ID_B

  echo "[*] PREIMAGE      = $PREIMAGE"
  echo "[*] PREIMAGE_HEX  = $PREIMAGE_HEX"
  echo "[*] LOCK_ID_A     = $LOCK_ID_A"
  echo "[*] LOCK_ID_B     = $LOCK_ID_B"
}

approve_tokens() {
  log "Approve token cho HTLC_TRAD"

  cast send "$ADDR_TOKEN_TRAD" "approve(address,uint256)" \
    "$ADDR_HTLC_TRAD" 1000000000000000000000 \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"
}

############################################
# 4. SCENARIO A – LOCK + CLAIM SỚM
############################################

scenario_A() {
  log "Scenario A – honest lock + claim sớm"

  echo "[*] Lock..."
  time cast send "$ADDR_HTLC_TRAD" \
    "lock(address,address,uint256,bytes32,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN_TRAD" \
    "$AMOUNT" \
    "$LOCK_ID_A" \
    "$TIMELOCK" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] Claim sớm (trước timelock)..."
  time cast send "$ADDR_HTLC_TRAD" "claim(bytes32,bytes)" \
    "$LOCK_ID_A" \
    "$PREIMAGE_HEX" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[*] Balance receiver sau claim:"
  cast call "$ADDR_TOKEN_TRAD" "balanceOf(address)(uint256)" "$ADDR_RECEIVER" --rpc-url "$RPC"
}

############################################
# 5. SCENARIO B/C – LOCK + INCREASETIME + REFUND
############################################

scenario_BC() {
  log "Scenario B/C – lock, receiver im lặng, sender refund sau timelock"

  echo "[*] Lock lần 2 (dùng LOCK_ID_B)..."
  time cast send "$ADDR_HTLC_TRAD" \
    "lock(address,address,uint256,bytes32,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN_TRAD" \
    "$AMOUNT" \
    "$LOCK_ID_B" \
    "$TIMELOCK" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] Timestamp hiện tại:"
  cast block latest --rpc-url "$RPC" | grep timestamp || true

  echo "[*] Receiver KHÔNG claim → mô phỏng griefing."
  echo "[*] Tăng thời gian qua timelock = $TIMELOCK s..."

  # lưu ý: cast rpc không cần '[1801]', chỉ truyền số
  cast rpc evm_increaseTime $((TIMELOCK + 1)) --rpc-url "$RPC"
  cast rpc evm_mine --rpc-url "$RPC"

  echo "[*] Timestamp sau evm_increaseTime + evm_mine:"
  cast block latest --rpc-url "$RPC" | grep timestamp || true

  echo "[*] Sender refund sau khi timelock qua..."
  time cast send "$ADDR_HTLC_TRAD" "refund(bytes32)" \
    "$LOCK_ID_B" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] Balance sender sau refund:"
  cast call "$ADDR_TOKEN_TRAD" "balanceOf(address)(uint256)" "$ADDR_SENDER" --rpc-url "$RPC"

  echo
  echo "==> Run này dùng cho Scenario B (lock + refund) + Scenario C (griefing)."
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
  scenario_BC

  log "Hoàn tất PoC HTLC truyền thống – Scenario A + B/C"
  echo "Log deploy: $LOG_DIR/deploy_htlc_trad.log"
  echo "Bạn có thể dùng: cast receipt <TX_HASH> --rpc-url $RPC để đọc gas."
}

main "$@"
