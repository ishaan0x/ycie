// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "interfaces/IERC20.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";

contract TokenManager is Ownable {
    /**
     * Constants
     */
    DelegationManager private immutable dm;

    /**
     * Errors
     */
    error TokenManger__PoolDNE();
    error TokenManger__PoolAlreadyExists();
    error TokenManager__NoMoneyInPool();
    error TokenManager__WithdrawalAlreadyInProgress();
    error TokenManager__WithdrawalNotReady();

    /**
     * State Variables
     */
    // token address -> pool address
    mapping(address => address) public tokenPoolRegistry;

    // staker -> list of pool addresses that staker stakes to
    mapping(address => address[]) public stakerPools;

    // staker -> withdrawal complete time
    mapping(address => uint256) public withdrawalCompleteTime;

    // staker address -> pool address -> staker's sub-shares in that pool
    mapping(address => mapping(address => uint256)) public stakerPoolShares;
    // pool address -> total sub-shares in that pool
    mapping(address => uint256) totalSPShares;

    // pool address -> # of shares allocated to that pool
    mapping(address => uint256) public poolShares;
    // # of shares allocated
    uint256 public totalPoolShares;

    /**
     * Special Functions
     */
    constructor(address tokenAddress) Ownable(msg.sender) {
        dm = new DelegationManager();
    }

    /**
     * External & Public Functions
     */

    function stakeToPool(address pool, uint256 amount) external {
        if (pool == address(0)) revert TokenManger__PoolDNE();

        // Add to indexed pools for user, as needed
        if (stakerPoolShares[msg.sender][pool] == 0)
            stakerPools[msg.sender].push(pool);

        // accounting
        stakerPoolShares[msg.sender][pool] += amount;
        totalSPShares[pool] += amount;

        // move tokens from staker to pool
        TokenPool(pool).stake(msg.sender, amount);

        // increase delegated operator's balance
        dm.stakeToPool(msg.sender, pool, amount);
    }

    function withdrawFromPool(address pool) external {
        if (pool == address(0)) revert TokenManger__PoolDNE();

        uint256 amount = stakerPoolShares[msg.sender][pool];
        if (amount == 0) revert TokenManager__NoMoneyInPool();

        // Remove from indexed pools for user
        address[] memory pools = stakerPools[msg.sender];
        uint256 length = pools.length;
        for (uint i = 0; i < length; i++) {
            if (pools[i] == pool) {
                stakerPools[msg.sender][i] = pools[length - 1];
                stakerPools[msg.sender].pop();
            }
        }

        // accounting
        stakerPoolShares[msg.sender][pool] = 0;
        totalSPShares[pool] -= amount;

        // move tokens from pool to staker
        if (!isSlashed(msg.sender))
            TokenPool(pool).withdraw(msg.sender, amount);

        // decrease delegated operator's balance
        dm.withdrawFromPool(msg.sender, pool, amount);
    }

    function queueWithdrawal() external {
        if (withdrawalCompleteTime[msg.sender] != 0)
            revert TokenManager__WithdrawalAlreadyInProgress();

        withdrawalCompleteTime[msg.sender] =
            block.timestamp +
            dm.stakerUnbondingPeriod(msg.sender);
    }

    function completeWithdrawal() external {
        if (block.timestamp < withdrawalCompleteTime[msg.sender])
            revert TokenManager__WithdrawalNotReady();

        address[] memory pools = stakerPools[msg.sender];
        uint256 length = pools.length;
        bool isNotSlashed = !isSlashed(msg.sender);

        for (uint i = 0; i < length; i++) {
            address pool = pools[i];
            uint256 amount = stakerPoolShares[msg.sender][pool];

            // accounting
            stakerPoolShares[msg.sender][pool] = 0;
            totalSPShares[pool] -= amount;

            // move tokens from pool to staker
            if (isNotSlashed) TokenPool(pool).withdraw(msg.sender, amount);

            // decrease delegated operator's balance
            dm.withdrawFromPool(msg.sender, pool, amount);
        }
        // Remove from indexed pools for user
        delete stakerPools[msg.sender];
    }

    /**
     * onlyOwner Functions
     */

    /**
     * @notice no way to remove token pool - modify pool shares to 0 instead
     */
    function addTokenPool(address token) external onlyOwner {
        if (tokenPoolRegistry[token] != address(0))
            revert TokenManger__PoolAlreadyExists();

        TokenPool tp = new TokenPool(token);
        tokenPoolRegistry[token] = address(tp);
    }

    function modifyPoolShares(address pool, uint256 amount) external onlyOwner {
        totalPoolShares -= poolShares[pool];
        poolShares[pool] = amount;
        totalPoolShares += amount;
    }

    /**
     * View & Pure Functions
     */

    function isSlashed(address staker) public view returns (bool) {
        return dm.isStakerSlashed(staker);
    }

    function getStakerPools(
        address staker
    ) public view returns (address[] memory) {
        return stakerPools[staker];
    }
}

contract TokenPool is Ownable {
    /**
     * Constants
     */
    IERC20 private immutable token;

    /**
     * Errors
     */
    error TokenPool__DepositNotPositive();
    error TokenPool__StakerSlashed();

    /**
     * State Variables
     */
    uint256 public totalShares;

    /**
     * Special Functions
     */
    constructor(address tokenAddress) Ownable(msg.sender) {
        token = IERC20(tokenAddress);
    }

    /**
     * External & Public Functions
     */

    function stake(address staker, uint256 amount) external onlyOwner {
        if (amount == 0) revert TokenPool__DepositNotPositive();

        token.transferFrom(staker, address(this), amount);
    }

    function withdraw(address staker, uint256 amount) external onlyOwner {
        token.transfer(staker, amount);
    }
}

contract DelegationManager is Ownable {
    /**
     * Constants
     */
    TokenManager public immutable tm;
    SlasherManager public immutable sm;
    IERC20 public immutable token;

    /**
     * Errors
     */
    error DelegationManager__OperatorSlashed();
    error DelegationManager__StakerSlashed();

    /**
     * State Variables
     */
    mapping(address => mapping(address => uint256)) public operatorPoolShares;
    mapping(address => address) public delegation;
    // mapping(address => address[]) public slasher;
    mapping(address => uint256) public unbondingPeriod;

    /**
     * Special Functions
     */
    constructor() Ownable(msg.sender) {
        tm = TokenManager(msg.sender);
        sm = new SlasherManager();
    }

    /**
     * External & Public Functions
     */

    /**
     * @notice Staker delegates to Operator
     */
    function delegateTo(address operator) external {
        if (isStakerSlashed(msg.sender))
            revert DelegationManager__StakerSlashed();
        if (isOperatorSlashed(operator))
            revert DelegationManager__OperatorSlashed();

        address[] memory pools = tm.getStakerPools(msg.sender);
        uint256 length = pools.length;
        address currentDelegate = delegation[msg.sender];

        for (uint i = 0; i < length; i++) {
            address pool = pools[i];
            uint256 amount = tm.stakerPoolShares(msg.sender, pool);

            operatorPoolShares[currentDelegate][pool] -= amount;
            operatorPoolShares[operator][pool] += amount;
        }
    }

    function stakeToPool(
        address staker,
        address pool,
        uint256 amount
    ) external onlyOwner {
        operatorPoolShares[delegation[staker]][pool] += amount;
    }

    function withdrawFromPool(
        address staker,
        address pool,
        uint256 amount
    ) external {
        address operator = delegation[staker];
        operatorPoolShares[operator][pool] -= amount;
        sm.removeAllSlashers(operator);
    }

    /**
     * Internal and Private Functions
     */

    /**
     * View & Pure Functions
     */

    function isStakerSlashed(address staker) public view returns (bool) {
        return isOperatorSlashed(delegation[staker]);
    }

    function isOperatorSlashed(address operator) public view returns (bool) {
        return sm.isSlashed(operator);
    }

    // function getSlashers(
    //     address operator
    // ) public view returns (address[] memory) {
    //     return slasher[operator];
    // }

    function stakerUnbondingPeriod(
        address staker
    ) public view returns (uint256) {
        return unbondingPeriod[delegation[staker]];
    }

    function existsIn(
        address element,
        address[] memory array
    ) public pure returns (bool) {
        uint length = array.length;
        for (uint i = 0; i < length; i++) {
            if (array[i] == element) return true;
        }
        return false;
    }
}

contract SlasherManager is Ownable {
    DelegationManager private immutable dm;

    /**
     * Type Declarations
     */
    // generic Proof object - replace
    // True = fraudulent => user is slashed
    struct Proof {
        bool fraudulent;
    }

    /**
     * Errors
     */
    error SlasherManager__OperatorSlashed();
    error SlasherManager__NotAllowedToSlash();

    /**
     * State Variables
     */
    mapping(address => bool) public isSlashed;
    mapping(address => mapping(address => bool)) public canSlash;
    mapping(address => address[]) slashers;

    constructor() Ownable(msg.sender) {
        dm = DelegationManager(msg.sender);
    }

    /**
     * @notice Operator enrolls in Slasher
     */
    // TODO - include unbonding period logic
    function enrollAVS(address slasher) external {
        if (isSlashed[msg.sender]) revert SlasherManager__OperatorSlashed();

        if (!canSlash[msg.sender][slasher])
            slashers[msg.sender].push(slasher);
        canSlash[msg.sender][slasher] = true;
    }

    /**
     * @notice Operator exits from Slasher
     */
    // TODO - include unbonding period logic
    function exitAVS(address slasher) external {
        if (isSlashed[msg.sender]) revert SlasherManager__OperatorSlashed();

        if (canSlash[msg.sender][slasher]) {
            address[] memory _slashers = slashers[msg.sender];
            uint256 length = _slashers.length;
            
            for (uint i=0; i<length; i++) {
                if (_slashers[i] == slasher) {
                    slashers[msg.sender][i] = _slashers[length-1];
                    slashers[msg.sender].pop();
                }
            }
        }
        canSlash[msg.sender][slasher] = false;
    }

    function slash(address operator) external {
        if (!canSlash[operator][msg.sender])
            revert SlasherManager__NotAllowedToSlash();

        isSlashed[operator] = true;
    }

    function removeAllSlashers(address operator) external onlyOwner {
        address[] memory _slashers = slashers[msg.sender];
        uint256 length = _slashers.length;

        for (uint i=0; i<length; i++) 
            canSlash[operator][msg.sender] = false;

        delete slashers[operator];
    }
}

contract Slasher is Ownable {
    SlasherManager private immutable sm;

    /**
     * Type Declarations
     */
    // generic Proof object - replace
    // True = fraudulent => user is slashed
    struct Proof {
        bool fraudulent;
    }

    uint256 public unbondingPeriod;

    constructor(address _sm, uint256 ubp) Ownable(msg.sender) {
        sm = SlasherManager(_sm);
        unbondingPeriod = ubp;
    }

    /**
     * External & Public Functions
     */
    function slash(address operator, Proof memory proof) public {
        // no need to do anything if proof is not valid
        if (isProofValid(proof))
            if (sm.canSlash(operator, address(this))) sm.slash(operator);
    }

    function changeUnbondingPeriod(uint256 ubp) external onlyOwner {
        unbondingPeriod = ubp;
    }

    /**
     * View & Pure Functions
     */
    function isProofValid(Proof memory proof) private pure returns (bool) {
        return proof.fraudulent;
    }
}
