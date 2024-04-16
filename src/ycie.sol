// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "interfaces/IERC20.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";


contract TokenPool {
    /**
     * Constants
     */
    DelegationManager public immutable dm;
    IERC20 public immutable token;

    /**
     * Errors
     */
    error TokenPool__DepositNotPositive();
    error TokenPool__StakerSlashed();

    /**
     * State Variables
     */
    mapping(address => uint256) public stakerBalance;

    /**
     * Special Functions
     */
    constructor(address tokenAddress) {
        dm = new DelegationManager(address(this));
        token = IERC20(tokenAddress);
    }
    
    /**
     * External & Public Functions
     */

    function stake(uint256 amount) external {
        if (amount == 0)
            revert TokenPool__DepositNotPositive();

        stakerBalance[msg.sender] += amount;

        // increase delegated operator's balance 
        dm.stake(msg.sender, amount);

        token.transferFrom(msg.sender, address(this), amount);
    }

    function withdraw() external {
        uint balance = stakerBalance[msg.sender];
        
        stakerBalance[msg.sender] = 0;
        dm.withdraw(msg.sender, balance);

        if (!dm.isStakerSlashed(msg.sender)) {
            token.transfer(msg.sender, balance);
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
    TokenPool public immutable tp;
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
    mapping(address => uint256) public operatorBalance;
    mapping(address => address) public delegation;
    mapping(address => address[]) public slasher;

    /**
     * Special Functions
     */
    constructor(address owner) Ownable(owner) {
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
