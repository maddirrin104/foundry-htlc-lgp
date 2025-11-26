// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract mp_htlc is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev địa chỉ signer MPC/TSS (tổng hợp từ N bên)
    address public immutable tssSigner;

    constructor(address _tssSigner) {
        require(_tssSigner != address(0), "invalid TSS signer");
        tssSigner = _tssSigner;
    }

    struct Lock {
        address sender; // TSS address (đa bên)
        address receiver; // EOA của người nhận trên chain này
        address tokenContract; // ERC20
        uint256 amount;
        uint256 unlockTime; // block.timestamp + timelock
        bool claimed;
        bool refunded;
    }

    mapping(bytes32 => Lock) public locks;

    event LockCreated(
        bytes32 indexed lockId,
        address indexed sender,
        address indexed receiver,
        address tokenContract,
        uint256 amount,
        uint256 unlockTime
    );

    event LockClaimed(bytes32 indexed lockId, address indexed receiver);
    event LockRefunded(bytes32 indexed lockId, address indexed sender);

    /// @notice tạo lock HTLC truyền thống
    /// @param _receiver người nhận
    /// @param _tokenContract token ERC20
    /// @param _hashlock sha256(preimage)
    /// @param _amount số lượng token
    /// @param _timelock số giây từ block.timestamp tới khi hết hạn
    function lock(address _receiver, address _tokenContract, bytes32 _hashlock, uint256 _amount, uint256 _timelock)
        external
        nonReentrant
        returns (bytes32 lockId)
    {
        require(_receiver != address(0), "invalid receiver");
        require(_tokenContract != address(0), "invalid token");
        require(_amount > 0, "amount must be > 0");
        require(_timelock > 0, "timelock must be > 0");
        require(locks[_hashlock].sender == address(0), "lock already exists");

        uint256 _unlockTime = block.timestamp + _timelock;

        locks[_hashlock] = Lock({
            sender: msg.sender,
            receiver: _receiver,
            tokenContract: _tokenContract,
            amount: _amount,
            unlockTime: _unlockTime,
            claimed: false,
            refunded: false
        });

        IERC20(_tokenContract).safeTransferFrom(msg.sender, address(this), _amount);

        emit LockCreated(_hashlock, msg.sender, _receiver, _tokenContract, _amount, _unlockTime);

        return _hashlock;
    }

    // ============ INTERNAL ============

    function _claim(bytes32 _lockId, bytes calldata _preimage, address _receiver) internal {
        require(sha256(_preimage) == _lockId, "invalid preimage");

        Lock storage lk = locks[_lockId];
        require(lk.sender != address(0), "lock not found");
        require(!lk.claimed && !lk.refunded, "already finished");
        require(_receiver == lk.receiver, "only receiver");
        require(block.timestamp < lk.unlockTime, "lock expired");

        lk.claimed = true;
        IERC20(lk.tokenContract).safeTransfer(lk.receiver, lk.amount);

        emit LockClaimed(_lockId, lk.receiver);
    }

    // ============ CLAIM ============

    /// @notice claim kiểu HTLC truyền thống: chỉ cần preimage
    function claim(bytes32 _lockId, bytes calldata _preimage) external nonReentrant {
        _claim(_lockId, _preimage, msg.sender);
    }

    /// @notice claim kèm chữ ký MPC/TSS trên lockId
    /// @dev digest = lockId (PoC), sig = ethSig(65) từ Go MPC/TSS
    function claimWithSig(bytes32 _lockId, bytes calldata _preimage, bytes calldata _sig) external nonReentrant {
        Lock storage lk = locks[_lockId];
        require(lk.sender != address(0), "lock not found");
        require(msg.sender == lk.receiver, "only receiver");

        (bytes32 r, bytes32 s, uint8 v) = _splitSig(_sig);

        if (v < 27) {
            v += 27;
        }

        bytes32 digest = _lockId;
        address signer = ecrecover(digest, v, r, s);
        require(signer == tssSigner, "invalid TSS signature");

        _claim(_lockId, _preimage, msg.sender);
    }

    function _splitSig(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(sig.length == 65, "invalid sig length");
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }

    // ============ REFUND ============

    /// @notice refund sau khi hết timelock nếu chưa claim
    function refund(bytes32 _lockId) external nonReentrant {
        Lock storage lk = locks[_lockId];
        require(lk.sender != address(0), "lock not found");
        require(msg.sender == lk.sender, "only sender");
        require(!lk.claimed && !lk.refunded, "already finished");
        require(block.timestamp >= lk.unlockTime, "lock not yet expired");

        lk.refunded = true;
        IERC20(lk.tokenContract).safeTransfer(lk.sender, lk.amount);

        emit LockRefunded(_lockId, lk.sender);
    }

    receive() external payable {
        revert("no direct ETH");
    }

    fallback() external payable {
        revert("fallback not supported");
    }
}
