// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract htlc_gpz is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Lock {
        address sender; // Alice
        address receiver; // Bob
        address tokenContract;
        uint256 amount;
        uint256 unlockTime;
        uint256 timeBased;
        uint256 depositRequired;
        uint256 depositPaid;
        uint256 depositWindowEnd;
        bool depositConfirmed;
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
        uint256 unlockTime,
        uint256 timeBased,
        uint256 depositRequired,
        uint256 depositWindowEnd
    );

    event DepositConfirmed(bytes32 indexed lockId, address indexed receiver, uint256 amount);
    event LockClaimed(bytes32 indexed lockId, address indexed receiver, uint256 penalty);
    event LockRefunded(bytes32 indexed lockId, address indexed sender, uint256 penalty);

    function createLock(
        address _receiver,
        address _tokenContract,
        uint256 _amount,
        bytes32 _hashlock,
        uint256 _timelock,
        uint256 _timeBased,
        uint256 _depositRequired,
        uint256 _depositWindow
    ) external nonReentrant returns (bytes32 lockId) {
        require(_timeBased > 0 && _timeBased <= _timelock, "Invalid timeBased");
        require(_receiver != address(0), "Invalid receiver");
        require(_tokenContract != address(0), "Invalid token");
        require(_amount > 0, "Amount must be > 0");
        require(locks[_hashlock].sender == address(0), "Lock already exists for this hash");

        uint256 _unlockTime = block.timestamp + _timelock;
        uint256 _depositWindowEnd = block.timestamp + _depositWindow;

        locks[_hashlock] = Lock({
            sender: msg.sender,
            receiver: _receiver,
            tokenContract: _tokenContract,
            amount: _amount,
            unlockTime: _unlockTime,
            timeBased: _timeBased,
            depositRequired: _depositRequired,
            depositPaid: 0,
            depositWindowEnd: _depositWindowEnd,
            depositConfirmed: false,
            claimed: false,
            refunded: false
        });

        // transfer tokens from Alice into contract (Alice must approve first)
        IERC20(_tokenContract).safeTransferFrom(msg.sender, address(this), _amount);

        emit LockCreated(
            _hashlock,
            msg.sender,
            _receiver,
            _tokenContract,
            _amount,
            _unlockTime,
            _timeBased,
            _depositRequired,
            _depositWindowEnd
        );
        return _hashlock;
    }

    function confirmParticipation(bytes32 _lockId) external payable nonReentrant {
        Lock storage lk = locks[_lockId];
        require(lk.sender != address(0), "Lock not found");
        require(msg.sender == lk.receiver, "Only designated receiver can confirm");
        require(!lk.depositConfirmed, "Deposit already confirmed");
        require(!lk.claimed && !lk.refunded, "Lock already finished");
        require(block.timestamp <= lk.depositWindowEnd, "Deposit window expired");
        require(msg.value == lk.depositRequired, "Incorrect deposit amount");

        lk.depositPaid = msg.value;
        lk.depositConfirmed = true;

        emit DepositConfirmed(_lockId, msg.sender, msg.value);
    }

    function claim(bytes32 _lockId, bytes calldata _preimage) external nonReentrant {
        require(sha256(_preimage) == _lockId, "Invalid preimage");
        Lock storage lk = locks[_lockId];
        require(lk.sender != address(0), "Lock not found");
        require(msg.sender == lk.receiver, "Only receiver can claim");
        require(!lk.claimed && !lk.refunded, "Already finished");
        require(lk.depositConfirmed, "Receiver did not confirm deposit");
        require(block.timestamp < lk.unlockTime, "Lock expired");

        uint256 penalty = 0;
        uint256 penaltyWindowStart = lk.unlockTime - lk.timeBased;
        if (block.timestamp > penaltyWindowStart) {
            uint256 elapsed = block.timestamp - penaltyWindowStart;
            if (elapsed > lk.timeBased) elapsed = lk.timeBased;
            // linear penalty proportional to elapsed/timeBased
            // penalty = depositRequired * elapsed / timeBased
            penalty = (lk.depositRequired * elapsed) / lk.timeBased;
            if (penalty > lk.depositPaid) penalty = lk.depositPaid;
        } else {
            penalty = 0;
        }

        uint256 depositBack = 0;
        if (lk.depositPaid > penalty) depositBack = lk.depositPaid - penalty;
        else depositBack = 0;

        lk.claimed = true;

        // transfer token to receiver
        IERC20(lk.tokenContract).safeTransfer(lk.receiver, lk.amount);

        // zero stored deposit before external calls
        lk.depositPaid = 0;

        // pay penalty to sender immediately if >0
        if (penalty > 0) {
            (bool sentP,) = payable(lk.sender).call{value: penalty}("");
            require(sentP, "Pay penalty failed");
        }

        // refund the remaining deposit (if any) to receiver
        if (depositBack > 0) {
            (bool sentR,) = payable(lk.receiver).call{value: depositBack}("");
            require(sentR, "Refund deposit failed");
        }

        emit LockClaimed(_lockId, lk.receiver, penalty);
    }

    function refund(bytes32 _lockId) external nonReentrant {
        Lock storage lk = locks[_lockId];
        require(lk.sender != address(0), "Lock not found");
        require(msg.sender == lk.sender, "Only sender can refund");
        require(!lk.claimed && !lk.refunded, "Already finished");

        // Case A: deposit not confirmed, and depositWindow expired -> sender can reclaim immediately
        if (!lk.depositConfirmed) {
            require(block.timestamp > lk.depositWindowEnd, "Deposit window still open; receiver may still confirm");
            // refund token to sender
            lk.refunded = true;
            IERC20(lk.tokenContract).safeTransfer(lk.sender, lk.amount);
            emit LockRefunded(_lockId, lk.sender, 0);
            return;
        }

        // Case B: deposit confirmed; allow refund only after timelock expiry (receiver had chance to claim)
        require(block.timestamp >= lk.unlockTime, "Lock not yet expired");

        lk.refunded = true;

        // transfer token back to sender
        IERC20(lk.tokenContract).safeTransfer(lk.sender, lk.amount);

        // transfer deposit (penalty) to sender
        uint256 penalty = lk.depositPaid;
        if (penalty > 0) {
            // zero stored deposit first
            lk.depositPaid = 0;
            (bool sent,) = payable(lk.sender).call{value: penalty}("");
            require(sent, "Penalty transfer failed");
        }

        emit LockRefunded(_lockId, lk.sender, penalty);
    }

    function isDepositWindowOpen(bytes32 _lockId) external view returns (bool) {
        Lock storage lk = locks[_lockId];
        if (lk.sender == address(0)) return false;
        return block.timestamp <= lk.depositWindowEnd && !lk.depositConfirmed && !lk.refunded && !lk.claimed;
    }

    receive() external payable {
        revert("Send ETH via confirmParticipation only");
    }

    fallback() external payable {
        revert("Fallback not supported");
    }
}
