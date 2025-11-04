// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract HashedTimelockERC20 {
    struct Lock {
        address sender;
        address receiver;
        address tokenContract;
        uint256 amount;
        uint256 unlockTime;
        bool claimed;
        bool refunded;
    }

    mapping(bytes32 => Lock) public locks;

    event LogLockCreated(
        bytes32 indexed lockId, address indexed sender, address indexed receiver, address tokenContract, uint256 amount
    );
    event LogLockClaimed(bytes32 indexed lockId);
    event LogLockRefunded(bytes32 indexed lockId);

    function lock(address _receiver, address _tokenContract, uint256 _amount, bytes32 _hashlock, uint256 _timelock)
        public
        returns (bytes32 lockId)
    {
        require(locks[_hashlock].sender == address(0), "Lock already exists");
        require(_amount > 0, "Amount must be greater than 0");

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

        //sender call approve()
        // require(IERC20(_tokenContract).transferFrom(msg.sender, address(this), _amount), "transfer failed");
        uint256 before = IERC20(_tokenContract).balanceOf(address(this));
        IERC20(_tokenContract).transferFrom(msg.sender, address(this), _amount);
        uint256 received = IERC20(_tokenContract).balanceOf(address(this)) - before;
        require(received > 0, "zero received");
        locks[_hashlock].amount = received;
        emit LogLockCreated(_hashlock, msg.sender, _receiver, _tokenContract, received);

        return _hashlock;
    }

    function claim(bytes32 _lockId, bytes calldata _preimage) public {
        require(sha256(_preimage) == _lockId, "Invalid preimage");
        Lock storage locked = locks[_lockId];
        require(msg.sender == locked.receiver, "Only receiver can claim");
        require(!locked.claimed);
        require(!locked.refunded);
        require(block.timestamp < locked.unlockTime);

        // update trước để tránh re-entrancy
        locked.claimed = true;
        require(IERC20(locked.tokenContract).transfer(locked.receiver, locked.amount), "Token transfer failed");

        emit LogLockClaimed(_lockId);
    }

    function refund(bytes32 _lockId) public {
        Lock storage locked = locks[_lockId];
        require(msg.sender == locked.sender, "Only sender can refund");
        require(!locked.claimed);
        require(!locked.refunded);
        require(block.timestamp >= locked.unlockTime);

        locked.refunded = true;
        require(IERC20(locked.tokenContract).transfer(locked.sender, locked.amount), "Token transfer failed");

        emit LogLockRefunded(_lockId);
    }

    receive() external payable {
        revert("Send ETH via confirmParticipation only");
    }

    fallback() external payable {
        revert("Fallback not supported");
    }
}
