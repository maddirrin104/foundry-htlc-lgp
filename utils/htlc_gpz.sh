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

# Các tham số chung
AMOUNT="100000000000000000000"          # 100 * 1e18
TIMELOCK=1800                           # 30 phút
TIMEBASED=600                           # 10 phút cuối là penalty window
DEPOSIT_REQUIRED="1000000000000000000"  # 1 ETH
DEPOSIT_WINDOW=600                      # 10 phút cho confirmParticipation

# Preimage gốc (sẽ derive ra 5 cái cho 5 scenario)
PREIMAGE_BASE="${PREIMAGE:-super-secret-preimage}"

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

# đảm bảo thư mục logs tồn tại (chạy từ root project)
mkdir -p logs

############################################
# 2. DEPLOY MockToken + HTLC-GPZ
############################################

deploy_contracts() {
  log "Deploy MockToken + HTLC-GPZ bằng forge script"

  export PRIVATE_KEY="$PK_DEPLOY"

  DEPLOY_LOG=$(forge script script/htlc-gpz-script.s.sol:htlc_gpz_script \
    --rpc-url "$RPC" \
    --private-key "$PK_DEPLOY" \
    --broadcast -vv 2>&1)

  echo "$DEPLOY_LOG" > logs/deploy_htlc_gpz.log

  # Bóc địa chỉ 0x... từ log (chỉnh lại keyword nếu console.log khác)
  ADDR_TOKEN_GPZ=$(echo "$DEPLOY_LOG" | grep -i "MockToken"  | grep -o -E "0x[0-9a-fA-F]{40}" | tail -1 || true)
  ADDR_HTLC_GPZ=$(echo "$DEPLOY_LOG" | grep -Ei "HTLC[_-]GPZ|htlc_gpz" | grep -o -E "0x[0-9a-fA-F]{40}" | tail -1 || true)

  if [[ -z "$ADDR_TOKEN_GPZ" || -z "$ADDR_HTLC_GPZ" ]]; then
    echo "[!] Không parse được địa chỉ từ logs/deploy_htlc_gpz.log"
    echo "    Mở file log và chỉnh lại 2 dòng grep trong deploy_contracts()."
    exit 1
  fi

  echo "[*] ADDR_TOKEN_GPZ = $ADDR_TOKEN_GPZ"
  echo "[*] ADDR_HTLC_GPZ  = $ADDR_HTLC_GPZ"

  export ADDR_TOKEN_GPZ
  export ADDR_HTLC_GPZ
}

############################################
# 3. CONFIG ACCOUNT + PREIMAGE / LOCK_ID
############################################

config_accounts_and_funding() {
  log "Config account sender/receiver + cấp ETH + mint token"

  export ADDR_RECEIVER
  export ADDR_SENDER

  ADDR_RECEIVER=$(cast wallet address --private-key "$PK_RECEIVER")
  ADDR_SENDER=$(cast wallet address --private-key "$PK_SENDER")

  echo "[*] ADDR_RECEIVER = $ADDR_RECEIVER"
  echo "[*] ADDR_SENDER   = $ADDR_SENDER"

  # Cấp ETH (anvil)
  cast rpc anvil_setBalance "$ADDR_SENDER"   0x56bc75e2d63100000 --rpc-url "$RPC"
  cast rpc anvil_setBalance "$ADDR_RECEIVER" 0x56bc75e2d63100000 --rpc-url "$RPC"

  # Mint token cho sender (gọi bằng deployer/receiver)
  cast send "$ADDR_TOKEN_GPZ" "mint(address,uint256)" \
    "$ADDR_SENDER" 1000000000000000000000 \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  # Các preimage/lock id cho từng scenario
  export PREIMAGE_S1 PREIMAGE_HEX_S1 LOCK_ID_S1
  export PREIMAGE_S2 PREIMAGE_HEX_S2 LOCK_ID_S2
  export PREIMAGE_S3 PREIMAGE_HEX_S3 LOCK_ID_S3
  export PREIMAGE_S4 PREIMAGE_HEX_S4 LOCK_ID_S4
  export PREIMAGE_S5 PREIMAGE_HEX_S5 LOCK_ID_S5

  PREIMAGE_S1="${PREIMAGE_BASE}-s1"
  PREIMAGE_S2="${PREIMAGE_BASE}-s2"
  PREIMAGE_S3="${PREIMAGE_BASE}-s3"
  PREIMAGE_S4="${PREIMAGE_BASE}-s4"
  PREIMAGE_S5="${PREIMAGE_BASE}-s5"

  PREIMAGE_HEX_S1="0x$(echo -n "$PREIMAGE_S1" | xxd -p -c 200)"
  PREIMAGE_HEX_S2="0x$(echo -n "$PREIMAGE_S2" | xxd -p -c 200)"
  PREIMAGE_HEX_S3="0x$(echo -n "$PREIMAGE_S3" | xxd -p -c 200)"
  PREIMAGE_HEX_S4="0x$(echo -n "$PREIMAGE_S4" | xxd -p -c 200)"
  PREIMAGE_HEX_S5="0x$(echo -n "$PREIMAGE_S5" | xxd -p -c 200)"

  LOCK_ID_S1="0x$(echo -n "$PREIMAGE_S1" | openssl dgst -binary -sha256 | xxd -p -c 64)"
  LOCK_ID_S2="0x$(echo -n "$PREIMAGE_S2" | openssl dgst -binary -sha256 | xxd -p -c 64)"
  LOCK_ID_S3="0x$(echo -n "$PREIMAGE_S3" | openssl dgst -binary -sha256 | xxd -p -c 64)"
  LOCK_ID_S4="0x$(echo -n "$PREIMAGE_S4" | openssl dgst -binary -sha256 | xxd -p -c 64)"
  LOCK_ID_S5="0x$(echo -n "$PREIMAGE_S5" | openssl dgst -binary -sha256 | xxd -p -c 64)"

  echo "[*] PREIMAGE_S1 / LOCK_ID_S1 = $LOCK_ID_S1"
  echo "[*] PREIMAGE_S2 / LOCK_ID_S2 = $LOCK_ID_S2"
  echo "[*] PREIMAGE_S3 / LOCK_ID_S3 = $LOCK_ID_S3"
  echo "[*] PREIMAGE_S4 / LOCK_ID_S4 = $LOCK_ID_S4"
  echo "[*] PREIMAGE_S5 / LOCK_ID_S5 = $LOCK_ID_S5"
}

approve_tokens() {
  log "Approve token cho HTLC-GPZ"

  cast send "$ADDR_TOKEN_GPZ" "approve(address,uint256)" \
    "$ADDR_HTLC_GPZ" 1000000000000000000000 \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"
}

############################################
# 4. SCENARIO 1 – Claim sớm, penalty = 0
############################################

scenario_1() {
  log "Scenario 1 – claim sớm, penalty = 0"

  echo "[*] createLock S1..."
  time cast send "$ADDR_HTLC_GPZ" \
    "createLock(address,address,uint256,bytes32,uint256,uint256,uint256,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN_GPZ" \
    "$AMOUNT" \
    "$LOCK_ID_S1" \
    "$TIMELOCK" \
    "$TIMEBASED" \
    "$DEPOSIT_REQUIRED" \
    "$DEPOSIT_WINDOW" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] confirmParticipation S1..."
  time cast send "$ADDR_HTLC_GPZ" "confirmParticipation(bytes32)" \
    "$LOCK_ID_S1" \
    --value "$DEPOSIT_REQUIRED" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[*] claim S1 (trước penalty window)..."
  time cast send "$ADDR_HTLC_GPZ" "claim(bytes32,bytes)" \
    "$LOCK_ID_S1" \
    "$PREIMAGE_HEX_S1" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[*] Balance receiver (token) sau S1:"
  cast call "$ADDR_TOKEN_GPZ" "balanceOf(address)(uint256)" "$ADDR_RECEIVER" --rpc-url "$RPC"
}

############################################
# 5. SCENARIO 2 – Claim trong penalty window
############################################

scenario_2() {
  log "Scenario 2 – claim trong penalty window (0 < penalty < deposit)"

  echo "[*] createLock S2..."
  time cast send "$ADDR_HTLC_GPZ" \
    "createLock(address,address,uint256,bytes32,uint256,uint256,uint256,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN_GPZ" \
    "$AMOUNT" \
    "$LOCK_ID_S2" \
    "$TIMELOCK" \
    "$TIMEBASED" \
    "$DEPOSIT_REQUIRED" \
    "$DEPOSIT_WINDOW" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] confirmParticipation S2..."
  time cast send "$ADDR_HTLC_GPZ" "confirmParticipation(bytes32)" \
    "$LOCK_ID_S2" \
    --value "$DEPOSIT_REQUIRED" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[*] Nhảy thời gian ~ 1300s để vào giữa penalty window..."
  cast rpc evm_increaseTime 1300 --rpc-url "$RPC"
  cast rpc evm_mine --rpc-url "$RPC"

  echo "[*] claim S2 (bị phạt tuyến tính)..."
  time cast send "$ADDR_HTLC_GPZ" "claim(bytes32,bytes)" \
    "$LOCK_ID_S2" \
    "$PREIMAGE_HEX_S2" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[*] Balance sender/receiver (ETH) sau S2:"
  cast balance "$ADDR_SENDER"   --rpc-url "$RPC" || true
  cast balance "$ADDR_RECEIVER" --rpc-url "$RPC" || true
}

############################################
# 6. SCENARIO 3 – Claim rất trễ, sát unlockTime
############################################

scenario_3() {
  log "Scenario 3 – claim rất trễ, penalty ≈ full deposit"

  echo "[*] createLock S3..."
  time cast send "$ADDR_HTLC_GPZ" \
    "createLock(address,address,uint256,bytes32,uint256,uint256,uint256,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN_GPZ" \
    "$AMOUNT" \
    "$LOCK_ID_S3" \
    "$TIMELOCK" \
    "$TIMEBASED" \
    "$DEPOSIT_REQUIRED" \
    "$DEPOSIT_WINDOW" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] confirmParticipation S3..."
  time cast send "$ADDR_HTLC_GPZ" "confirmParticipation(bytes32)" \
    "$LOCK_ID_S3" \
    --value "$DEPOSIT_REQUIRED" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[*] Nhảy thời gian ~ TIMELOCK-1 (=1799)..."
  cast rpc evm_increaseTime 1798 --rpc-url "$RPC"
  cast rpc evm_mine --rpc-url "$RPC"

  echo "[*] claim S3 (sát unlockTime)..."
  time cast send "$ADDR_HTLC_GPZ" "claim(bytes32,bytes)" \
    "$LOCK_ID_S3" \
    "$PREIMAGE_HEX_S3" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[*] Balance sender/receiver (ETH) sau S3:"
  cast balance "$ADDR_SENDER"   --rpc-url "$RPC" || true
  cast balance "$ADDR_RECEIVER" --rpc-url "$RPC" || true
}

############################################
# 7. SCENARIO 4 – Không confirm deposit, refund sau depositWindow
############################################

scenario_4() {
  log "Scenario 4 – deposit không confirm, refund sau depositWindow (penalty = 0)"

  echo "[*] createLock S4 (không confirmParticipation)..."
  time cast send "$ADDR_HTLC_GPZ" \
    "createLock(address,address,uint256,bytes32,uint256,uint256,uint256,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN_GPZ" \
    "$AMOUNT" \
    "$LOCK_ID_S4" \
    "$TIMELOCK" \
    "$TIMEBASED" \
    "$DEPOSIT_REQUIRED" \
    "$DEPOSIT_WINDOW" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] Nhảy thời gian > depositWindow (601s)..."
  cast rpc evm_increaseTime 601 --rpc-url "$RPC"
  cast rpc evm_mine --rpc-url "$RPC"

  echo "[*] refund S4 (deposit chưa confirm, penalty = 0)..."
  time cast send "$ADDR_HTLC_GPZ" "refund(bytes32)" \
    "$LOCK_ID_S4" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] Balance sender (token/ETH) sau S4:"
  cast call "$ADDR_TOKEN_GPZ" "balanceOf(address)(uint256)" "$ADDR_SENDER" --rpc-url "$RPC"
  cast balance "$ADDR_SENDER" --rpc-url "$RPC" || true
}

############################################
# 8. SCENARIO 5 – Deposit confirm nhưng không claim, refund sau timelock
############################################

scenario_5() {
  log "Scenario 5 – deposit đã confirm nhưng receiver không claim, refund sau timelock"

  echo "[*] createLock S5..."
  time cast send "$ADDR_HTLC_GPZ" \
    "createLock(address,address,uint256,bytes32,uint256,uint256,uint256,uint256)(bytes32)" \
    "$ADDR_RECEIVER" \
    "$ADDR_TOKEN_GPZ" \
    "$AMOUNT" \
    "$LOCK_ID_S5" \
    "$TIMELOCK" \
    "$TIMEBASED" \
    "$DEPOSIT_REQUIRED" \
    "$DEPOSIT_WINDOW" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] confirmParticipation S5..."
  time cast send "$ADDR_HTLC_GPZ" "confirmParticipation(bytes32)" \
    "$LOCK_ID_S5" \
    --value "$DEPOSIT_REQUIRED" \
    --private-key "$PK_RECEIVER" \
    --rpc-url "$RPC"

  echo "[*] Receiver KHÔNG claim → mô phỏng griefing chậm."
  echo "[*] Nhảy thời gian > timelock (1801)..."
  cast rpc evm_increaseTime 1801 --rpc-url "$RPC"
  cast rpc evm_mine --rpc-url "$RPC"

  echo "[*] refund S5 (sender nhận lại token + full deposit)..."
  time cast send "$ADDR_HTLC_GPZ" "refund(bytes32)" \
    "$LOCK_ID_S5" \
    --private-key "$PK_SENDER" \
    --rpc-url "$RPC"

  echo "[*] Balance sender (token/ETH) sau S5:"
  cast call "$ADDR_TOKEN_GPZ" "balanceOf(address)(uint256)" "$ADDR_SENDER" --rpc-url "$RPC"
  cast balance "$ADDR_SENDER" --rpc-url "$RPC" || true
}

############################################
# MAIN
############################################

main() {
  start_anvil
  deploy_contracts
  config_accounts_and_funding
  approve_tokens

  scenario_1
  scenario_2
  scenario_3
  scenario_4
  scenario_5

  log "Hoàn tất PoC HTLC-GPZ – Scenario 1 → 5"
  echo "Xem log deploy: logs/deploy_htlc_gpz.log"
  echo "Muốn đo gas chi tiết từng tx: cast receipt <TX_HASH> --rpc-url $RPC"
}

main "$@"
