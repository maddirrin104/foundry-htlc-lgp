pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract htlc_lgp is ReentrancyGuard {
    // using token ERC20 safe transfer from
    using SafeERC20 for IERC20;

    // TSS signer   
    address public immutable tssSigner;
    constructor(address _tssSigner) {
        require(_tssSigner != address(0), "invalid TSS signer");
        tssSigner = _tssSigner;
    }

    // lock struct
    struct Lock {
        address sender;
        address receiver;
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

    // lock mapping
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

    //create lock
    function lock(
        address _receiver,
        address _tokenContract,
        bytes32 _hashlock,
        uint256 _amount,
        uint256 _timelock,
        uint256 _timeBased,
        uint256 _depositRequired,
        uint256 _depositWindow
    ) external nonReentrant returns (bytes32 lockId) {
        require(_timeBased > 0 && _timeBased < _timelock, "Invalid timeBased");
        require(_timeBased + _depositWindow < _timelock, "timeBased + depositWindow must be < timelock");
        require(_receiver != address(0), "Invalid receiver");
        require(_tokenContract != address(0), "Invalid token");
        require(_amount > 0, "Amount must be > 0");
        require(locks[_hashlock].sender == address(0), "Lock already exists");

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

        IERC20(_tokenContract).safeTransferFrom(
            msg.sender, 
            address(this), 
            _amount
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

    function _claim(bytes32 _lockId, bytes calldata _preimage, address _receiver) internal {
        require(sha256(_preimage) == _lockId, "Invalid preimage");
        Lock storage lk = locks[_lockId];
        require(lk.sender != address(0), "Lock not found");
        require(_receiver == lk.receiver, "Only receiver can claim");
        require(!lk.claimed && !lk.refunded, "Already finished");
        require(lk.depositConfirmed, "Receiver did not confirm deposit");
        require(block.timestamp < lk.unlockTime, "Lock expired");

        uint256 penalty = 0;
        uint256 penaltyWindowStart = lk.unlockTime - lk.timeBased;
        if (block.timestamp > penaltyWindowStart) {
            uint256 elapsed = block.timestamp - penaltyWindowStart;
            if (elapsed > lk.timeBased) elapsed = lk.timeBased;
            penalty = (lk.depositRequired * elapsed) / lk.timeBased;
            if (penalty > lk.depositPaid) penalty = lk.depositPaid;
        }

        uint256 depositBack = 0;
        if (lk.depositPaid > penalty) depositBack = lk.depositPaid - penalty;

        lk.claimed = true;
        IERC20(lk.tokenContract).safeTransfer(lk.receiver, lk.amount);

        lk.depositPaid = 0;

        if (penalty > 0) {
            (bool sentP,) = payable(lk.sender).call{value: penalty}("");
            require(sentP, "Pay penalty failed");
        }

        if (depositBack > 0) {
            (bool sentR,) = payable(lk.receiver).call{value: depositBack}("");
            require(sentR, "Refund deposit failed");
        }

        emit LockClaimed(_lockId, lk.receiver, penalty);
    }

    // claim without signature
    function claim(bytes32 _lockId, bytes calldata _preimage) external nonReentrant {
        _claim(_lockId, _preimage, msg.sender);
    }

    // claim with signature
    function claimWithSig(
        bytes32 _lockId,
        bytes calldata _preimage,
        bytes calldata _sig
    ) external nonReentrant {
        Lock storage lk = locks[_lockId];
        require(lk.sender != address(0), "Lock not found");
        require(msg.sender == lk.receiver, "Only receiver can claim");

        (bytes32 r, bytes32 s, uint8 v) = _splitSig(_sig);

        // convert 0/1 -> 27/28 nếu cần
        if (v < 27) {
            v += 27;
        }

        // digest = lockId (PoC đơn giản)
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