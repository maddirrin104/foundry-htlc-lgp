#!/usr/bin/env bash
set -euo pipefail

############################################
# 0. PATH + CONFIG CHUNG
############################################

# Xác định root project và thư mục logs (script nằm ở utils/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
LOG_DIR="$ROOT_DIR/logs"

cd "$ROOT_DIR"
mkdir -p "$LOG_DIR"

# RPC Anvil
RPC="${RPC:-http://127.0.0.1:8545}"

# Account deploy (đồng thời dùng làm PK_RECEIVER cho simplicity)
PK_DEPLOY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
PK_RECEIVER="$PK_DEPLOY"

# Tham số protocol
AMOUNT="100000000000000000000"         # 100 * 1e18
TIMELOCK=1800                          # 30 phút
TIMEBASED=600                          # 10 phút cuối là penalty window
DEPOSIT_REQUIRED="1000000000000000000" # 1 ETH
DEPOSIT_WINDOW=600                     # 10 phút confirmParticipation

# Preimage (phải khớp với mk bên Go)
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

# Đọc ADDR_TSS, LOCK_ID, SIG từ logs/tss_lgp.log
read_tss_info() {
  local tss_log="$LOG_DIR/tss_lgp.log"
  if [[ ! -f "$tss_log" ]]; then
    echo "[!] Không tìm thấy $tss_log. Hãy chạy go run main.go riêng và copy log vào đó."
    exit 1
  fi

  ADDR_TSS=$(grep -E "TSS Ethereum Address" "$tss_log" | tail -1 | awk -F'= ' '{print $2}' | tr -d ' "\r')
  LOCK_ID=$(grep -E "lockId" "$tss_log" | tail -1 | awk -F': ' '{print $2}' | tr -d ' "\r')
  SIG=$(grep -E "ethSig\(65\)" "$tss_log" | tail -1 | awk -F'= ' '{print $2}' | tr -d ' "\r')

  if [[ -z "${ADDR_TSS:-}" || -z "${LOCK_ID:-}" || -z "${SIG:-}" ]]; then
    echo "[!] Không parse được ADDR_TSS / LOCK_ID / SIG từ $tss_log"
    echo "    Hãy kiểm tra lại format log (cần có các dòng:"
    echo "      'TSS Ethereum Address = 0x...', 'lockId: 0x...', 'ethSig(65) = 0x...')."
    exit 1
  fi

  echo "[*] TSS Ethereum Address = $ADDR_TSS"
  echo "[*] LOCK_ID             = $LOCK_ID"
  echo "[*] SIG (ethSig(65))    = $SIG"

  export ADDR_TSS LOCK_ID SIG
  export TSS_SIGNER="$ADDR_TSS"
}

# Deploy htlc_lgp + MockToken, config basic account, mint, impersonate, approve
deploy_and_setup_env() {
  local label="$1"

  log "[$label] Deploy MockToken + HTLC-LGP bằng forge script"

  DEPLOY_LOG=$(forge script script/htlc-lgp-script.s.sol:htlc_lgp_script \
    --rpc-url "$RPC" \
    --private-key "$PK_DEPLOY" \
    --broadcast -vv 2>&1)

  echo "$DEPLOY_LOG" > "$LOG_DIR/deploy_htlc_lgp_${label}.log"

  # Parse địa chỉ từ console.log trong script:
  #   MockToken: 0x...
  #   HTLC-LGP : 0x...
  ADDR_TOKEN=$(grep "MockToken" "$LOG_DIR/deploy_htlc_lgp_${label}.log" | awk '{print $2}' | tail -1 | tr -d '\r')
  ADDR_HTLC=$(grep "HTLC-LGP"  "$LOG_DIR/deploy_htlc_lgp_${label}.log" | awk '{print $3}' | tail -1 | tr -d '\r')

  if [[ -z "$ADDR_TOKEN" || -z "$ADDR_HTLC" ]]; then
    echo "[!] [$label] Không parse được địa chỉ từ deploy_htlc_lgp_${label}.log"
    echo "    Kiểm tra lại console.log trong script htlc_lgp_script."
    exit 1
  fi

  echo "[*] [$label] ADDR_TOKEN = $ADDR_TOKEN"
  echo "[*] [$label] ADDR_HTLC  = $ADDR_HTLC"

  export ADDR_TOKEN ADDR_HTLC

  # Config account receiver
  ADDR_RECEIVER=$(cast wallet address --private-key "$PK_RECEIVER")
  echo "[*] [$label] ADDR_RECEIVER = $ADDR_RECEIVER"
  echo "[*] [$label] ADDR_TSS      = $ADDR_TSS"

  export ADDR_RECEIVER

  # Cấp ETH cho TSS + receiver (nếu đang chạy anvil)
  cast rpc anvil_setBalance "$ADDR_TSS" 0x56bc75e2d63100000 --rpc-url "$RPC"      # 100 ETH
  cast rpc anvil_setBalance "$ADDR_RECEIVER" 0x56bc75e2d63100000 --rpc-url "$RPC" # 100 ETH

  # Mint token cho TSS (dùng PK_DEPLOY = owner của MockToken)
  cast send "$ADDR_TOKEN" "mint(address,uint256)" \
    "$ADDR_TSS" 1000000000000000000000 \
    --private-key "$PK_DEPLOY" \
    --rpc-url "$RPC"

  # Impersonate TSS + approve token cho HTLC
  cast rpc anvil_impersonateAccount "$ADDR_TSS" --rpc-url "$RPC"

  cast send "$ADDR_TOKEN" "approve(address,uint256)" \
    "$ADDR_HTLC" 1000000000000000000000 \
    --from "$ADDR_TSS" \
    --unlocked \
    --rpc-url "$RPC"

  # Chuẩn bị PREIMAGE_HEX (phải trùng với preimage mà TSS dùng)
  PREIMAGE_HEX="0x$(echo -n "$PREIMAGE" | xxd -p -c 200)"
  export PREIMAGE_HEX

  echo "[*] [$label] PREIMAGE      = $PREIMAGE"
  echo "[*] [$label] PREIMAGE_HEX  = $PREIMAGE_HEX"
  echo "[*] [$label] LOCK_ID       = $LOCK_ID"
  echo "[*] [$label] Ready cho các scenario."
}

############################################
# 2. CÁC SCENARIO
############################################

# Scenario 1 – Claim sớm (trước penalty window, penalty = 0)
scenario_1() {
  log "[S1] Claim sớm – không penalty"

  # lock: amount=100e18, timelock=1800, timeBased=600, deposit=1 ETH, depositWindow=600
  echo "[S1] lock() từ TSS..."
  cast send "$ADDR_HTLC" \
    "lock(address,address,bytes32,uint256,uint256,uint256,uint256,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN" \
    "$LOCK_ID" \
    "$AMOUNT" \
    "$TIMELOCK" \
    "$TIMEBASED" \
    "$DEPOSIT_REQUIRED" \
    "$DEPOSIT_WINDOW" \
    --from "$ADDR_TSS" \
    --unlocked \
    --rpc-url "$RPC"

  echo "[S1] Receiver confirmParticipation() – đặt cọc..."
  cast send "$ADDR_HTLC" "confirmParticipation(bytes32)" \
    "$LOCK_ID" \
    --value "$DEPOSIT_REQUIRED" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[S1] ClaimWithSig ngay (không tăng thời gian, không bị penalty)..."
  cast send "$ADDR_HTLC" "claimWithSig(bytes32,bytes,bytes)" \
    "$LOCK_ID" \
    "$PREIMAGE_HEX" \
    "$SIG" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[S1] Balance receiver sau claim:"
  cast call "$ADDR_TOKEN" "balanceOf(address)(uint256)" "$ADDR_RECEIVER" --rpc-url "$RPC"
  echo "[S1] Balance TSS (ETH) sau scenario 1:"
  cast balance "$ADDR_TSS" --rpc-url "$RPC"
}

# Scenario 2 – Claim trong penalty window (0 < penalty < deposit)
scenario_2() {
  log "[S2] Claim trong penalty window – penalty tuyến tính"

  echo "[S2] lock() từ TSS..."
  cast send "$ADDR_HTLC" \
    "lock(address,address,bytes32,uint256,uint256,uint256,uint256,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN" \
    "$LOCK_ID" \
    "$AMOUNT" \
    "$TIMELOCK" \
    "$TIMEBASED" \
    "$DEPOSIT_REQUIRED" \
    "$DEPOSIT_WINDOW" \
    --from "$ADDR_TSS" \
    --unlocked \
    --rpc-url "$RPC"

  echo "[S2] Receiver confirmParticipation() – đặt cọc..."
  cast send "$ADDR_HTLC" "confirmParticipation(bytes32)" \
    "$LOCK_ID" \
    --value "$DEPOSIT_REQUIRED" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  # Nhảy thời gian vào giữa penalty window:
  # penaltyWindowStart = unlockTime - timeBased = now + (1800 - 600) = now + 1200
  local jump=$((TIMELOCK - TIMEBASED + 100)) # 1200 + 100 = 1300
  echo "[S2] evm_increaseTime $jump (vào giữa penalty window)..."
  cast rpc evm_increaseTime "$jump" --rpc-url "$RPC"
  cast rpc evm_mine --rpc-url "$RPC"

  echo "[S2] ClaimWithSig trong penalty window..."
  cast send "$ADDR_HTLC" "claimWithSig(bytes32,bytes,bytes)" \
    "$LOCK_ID" \
    "$PREIMAGE_HEX" \
    "$SIG" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[S2] Balance receiver (token):"
  cast call "$ADDR_TOKEN" "balanceOf(address)(uint256)" "$ADDR_RECEIVER" --rpc-url "$RPC"

  echo "[S2] Balance TSS vs receiver (ETH) để xem penalty chia như thế nào:"
  cast balance "$ADDR_TSS"      --rpc-url "$RPC"
  cast balance "$ADDR_RECEIVER" --rpc-url "$RPC"
}

# Scenario 3 – Deposit đã confirm nhưng không claim, refund sau timelock
scenario_3() {
  log "[S3] Deposit đã confirm, không claim – refund sau timelock"

  echo "[S3] lock() từ TSS..."
  cast send "$ADDR_HTLC" \
    "lock(address,address,bytes32,uint256,uint256,uint256,uint256,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN" \
    "$LOCK_ID" \
    "$AMOUNT" \
    "$TIMELOCK" \
    "$TIMEBASED" \
    "$DEPOSIT_REQUIRED" \
    "$DEPOSIT_WINDOW" \
    --from "$ADDR_TSS" \
    --unlocked \
    --rpc-url "$RPC"

  echo "[S3] Receiver confirmParticipation() – đặt cọc..."
  cast send "$ADDR_HTLC" "confirmParticipation(bytes32)" \
    "$LOCK_ID" \
    --value "$DEPOSIT_REQUIRED" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[S3] Receiver im lặng, không claim → mô phỏng griefing chậm."
  echo "[S3] Nhảy thời gian qua timelock ($TIMELOCK + 1)..."
  local jump=$((TIMELOCK + 1))
  cast rpc evm_increaseTime "$jump" --rpc-url "$RPC"
  cast rpc evm_mine --rpc-url "$RPC"

  echo "[S3] refund() từ phía TSS (sender)..."
  cast send "$ADDR_HTLC" "refund(bytes32)" \
    "$LOCK_ID" \
    --from "$ADDR_TSS" \
    --unlocked \
    --rpc-url "$RPC"

  echo "[S3] Balance TSS (token + ETH) sau refund:"
  cast call "$ADDR_TOKEN" "balanceOf(address)(uint256)" "$ADDR_TSS" --rpc-url "$RPC"
  cast balance "$ADDR_TSS" --rpc-url "$RPC"
}

# Scenario 4 – Không confirm deposit, refund sau depositWindow (penalty = 0)
scenario_4() {
  log "[S4] Không confirm deposit – refund sau depositWindow (penalty = 0)"

  echo "[S4] lock() từ TSS (KHÔNG confirmParticipation)..."
  cast send "$ADDR_HTLC" \
    "lock(address,address,bytes32,uint256,uint256,uint256,uint256,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN" \
    "$LOCK_ID" \
    "$AMOUNT" \
    "$TIMELOCK" \
    "$TIMEBASED" \
    "$DEPOSIT_REQUIRED" \
    "$DEPOSIT_WINDOW" \
    --from "$ADDR_TSS" \
    --unlocked \
    --rpc-url "$RPC"

  echo "[S4] Nhảy thời gian qua depositWindow ($DEPOSIT_WINDOW + 1)..."
  local jump=$((DEPOSIT_WINDOW + 1))
  cast rpc evm_increaseTime "$jump" --rpc-url "$RPC"
  cast rpc evm_mine --rpc-url "$RPC"

  echo "[S4] refund() từ TSS – không có penalty vì depositPaid = 0..."
  cast send "$ADDR_HTLC" "refund(bytes32)" \
    "$LOCK_ID" \
    --from "$ADDR_TSS" \
    --unlocked \
    --rpc-url "$RPC"

  echo "[S4] Balance TSS (token) sau refund:"
  cast call "$ADDR_TOKEN" "balanceOf(address)(uint256)" "$ADDR_TSS" --rpc-url "$RPC"
  echo "[S4] Balance TSS (ETH) – chỉ trừ gas, không cộng thêm penalty:"
  cast balance "$ADDR_TSS" --rpc-url "$RPC"
}

############################################
# 3. MAIN
############################################

main() {
  start_anvil
  read_tss_info

  # Scenario 1
  deploy_and_setup_env "s1"
  scenario_1

  # Scenario 2
  deploy_and_setup_env "s2"
  scenario_2

  # Scenario 3
  deploy_and_setup_env "s3"
  scenario_3

  # Scenario 4
  deploy_and_setup_env "s4"
  scenario_4

  log "Hoàn tất PoC MP-HTLC-LGP – S1..S4 (mỗi scenario dùng 1 deploy riêng, cùng LOCK_ID & SIG)"
  echo "Bạn có thể xem lại các log deploy trong:"
  echo "  $LOG_DIR/deploy_htlc_lgp_s1.log .. deploy_htlc_lgp_s4.log"
  echo "Và log TSS gốc ở:"
  echo "  $LOG_DIR/tss_lgp.log"
}

main "$@"
