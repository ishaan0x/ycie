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

    /**
     * State Variables
     */
    // token address -> pool address
    mapping(address => address) public tokenPoolRegistry;

    // staker address -> pool address -> staker's sub-shares in that pool
    mapping(address => mapping(address => uint256)) public stakerPoolShares;
    // pool address -> total sub-shares in that pool
    mapping (address => uint256) totalSPShares;

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
        if (pool == address(0))
            revert TokenManger__PoolDNE();

        stakerPoolShares[msg.sender][pool] += amount;

        TokenPool(pool).stake(msg.sender, amount);
    }

    function withdrawFromPool(address pool) external {
        if (pool == address(0))
            revert TokenManger__PoolDNE();

        TokenPool(pool).withdraw(msg.sender);
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
        if (amount == 0)
            revert TokenPool__DepositNotPositive();

        // increase delegated operator's balance 
        dm.stake(staker, amount);

        token.transferFrom(staker, address(this), amount);
    }

    function withdraw(address staker) external onlyOwner {
        uint balance = stakerBalance[staker];
        
        stakerBalance[staker] = 0;
        dm.withdraw(staker, balance);

        if (!dm.isStakerSlashed(staker)) {
            token.transfer(staker, balance);
        }
    }

    /**
     * View & Pure Functions
     */

    function isSlashed(address staker) public view returns(bool) {
        return dm.isOperatorSlashed(staker);
    }

    function existsIn(address element, address[] memory array) private pure returns(bool) {
        for (uint i=0; i < array.length; i++) {
            if (array[i] == element)
                return true;
        }
        return false;
    }
}

contract DelegationManager is Ownable {
    /**
     * Constants
     */
    TokenManager public immutable tm;
    Slasher public immutable slash;
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
    mapping(address => address[]) public slasher;

    /**
     * Special Functions
     */
    constructor() Ownable(msg.sender) {
        tp = TokenPool(owner);
        slash = new Slasher(address(this));
        token = tp.token();
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

        uint256 stakerBalance = tp.stakerBalance(msg.sender);
        address currentDelegate = delegation[msg.sender];

        operatorBalance[currentDelegate] -= stakerBalance;
        operatorBalance[operator] += stakerBalance;
    }

    /**
     * @notice Operator enrolls in Slasher
     */
    function enroll(address _slasher) external {
        if (isOperatorSlashed(msg.sender))
            revert DelegationManager__OperatorSlashed();

        address[] memory slashers = slasher[msg.sender];
        if (existsIn(_slasher, slashers))
            return;

        slasher[msg.sender].push(_slasher);
    }

    /**
     * @notice Operator exits from Slasher
     */
    function exit(address _slasher) external {
        address[] memory slashers = slasher[msg.sender];
        uint length = slashers.length;

        for (uint i=0; i < length; i++) {
            if (slashers[i] == _slasher) {
                slasher[msg.sender][i] = slasher[msg.sender][length-1];
                slasher[msg.sender].pop();
                return;
            }
        }
    }

    function stake(address staker, uint256 amount) external onlyOwner {
        operatorBalance[delegation[staker]] += amount;
    }

    function withdraw(address staker, uint256 amount) external {
        operatorBalance[delegation[staker]] -= amount;
        //delete slasher[msg.sender]; // TODO - see if this is valid, might need to create a function
    }

    /**
     * Internal and Private Functions
     */

    /**
     * View & Pure Functions
     */

    function isStakerSlashed(address staker) public view returns(bool) {
        return isOperatorSlashed(delegation[staker]);
    }

    function isOperatorSlashed(address operator) public view returns(bool) {
        return slash.isSlashed(operator);
    }

    function getSlashers(address operator) public view returns(address[] memory) {
        return slasher[operator];
    }

    function existsIn(address element, address[] memory array) public pure returns(bool) {
        uint length = array.length;
        for (uint i=0; i < length; i++) {
            if (array[i] == element)
                return true;
        }
        return false;
    }
}

contract Slasher is Ownable {
    DelegationManager dm;

    /**
     * Type Declarations
     */
    // generic Proof object - replace 
    // True = fraudulent => user is slashed
    struct Proof {
        bool fraudulent;
    }
    
    /**
     * State Variables
     */
    mapping (address => bool) public isSlashed;
    
    constructor(address owner) Ownable(owner) {
        dm = DelegationManager(owner);
    }

    /**
     * External & Public Functions
     */
    function slash(address operator, Proof memory proof) public {
        // no need to do anything if proof is not valid
        if (isProofValid(proof)) 
            if (dm.existsIn(operator, dm.getSlashers(operator)))
                isSlashed[operator] = true;
    }

    /**
     * View & Pure Functions
     */
    function isProofValid(Proof memory proof) private pure returns(bool) {
        return proof.fraudulent;
    }
}
