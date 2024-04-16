// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "interfaces/IERC20.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";


contract TokenPool {
    DelegationManager dm;

    /**
     * Errors
     */
    error TokenPool__DepositNotPositive();
    error TokenPool__StakerSlashed();

    /**
     * State Variables
     */
    mapping(address => uint256) public stakerBalance;
    IERC20 public token;

    /**
     * Special Functions
     */
    constructor(address tokenAddress) {
        dm = new DelegationManager();
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
        uint balance;
        
        // check if slashed
        // decrease delegated operator's balance
        // delete delegation mapping 
            // delete slasher[msg.sender]; // TODO - see if this is valid, might need to create a function
        if (!dm.withdraw(msg.sender))
            balance = stakerBalance[msg.sender];

        stakerBalance[msg.sender] = 0;

        token.transfer(msg.sender, balance);
    }

    // function enroll(address _slasher) external {
    //     if (isSlashed(msg.sender))
    //         revert TokenPool__StakerSlashed();

    //     address[] memory slashers = slasher[msg.sender];
    //     if (existsIn(_slasher, slashers))
    //         return;

    //     slasher[msg.sender].push(_slasher);
    // }

    /**
     * View & Pure Functions
     */

    function isSlashed(address staker) public view returns(bool) {
        address[] memory slashers = slasher[staker];

        for (uint i=0; i < slashers.length; i++) {
            if (Slasher(slashers[i]).isSlashed(staker) == true)
                return true;
        }
        
        return false;
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
     * State Variables
     */
    mapping(address => uint256) public operatorBalance;
    mapping(address => address) public delegation;
    mapping(address => address[]) public slasher;
    IERC20 public token;

    /**
     * Special Functions
     */
    constructor(address tokenAddress) {
        token = IERC20(tokenAddress);
    }
    
    /**
     * External & Public Functions
     */

    function stake(uint256 amount) external {
        if (amount == 0)
            revert TokenPool__DepositNotPositive();

        stakerBalance[msg.sender] += amount;
        token.transferFrom(msg.sender, address(this), amount);
    }

    function withdraw() external {
        uint _balance;
        if (!isSlashed(msg.sender))
            _balance = stakerBalance[msg.sender];
        
        stakerBalance[msg.sender] = 0;
        delete slasher[msg.sender]; // TODO - see if this is valid, might need to create a function

        token.transfer(msg.sender, _balance);
    }

    function enroll(address _slasher) external {
        if (isSlashed(msg.sender))
            revert TokenPool__StakerSlashed();

        address[] memory slashers = slasher[msg.sender];
        if (existsIn(_slasher, slashers))
            return;

        slasher[msg.sender].push(_slasher);
    }

    /**
     * View & Pure Functions
     */

    function isSlashed(address staker) public view returns(bool) {
        address[] memory slashers = slasher[staker];

        for (uint i=0; i < slashers.length; i++) {
            if (Slasher(slashers[i]).isSlashed(staker) == true)
                return true;
        }
        
        return false;
    }

    function existsIn(address element, address[] memory array) private pure returns(bool) {
        for (uint i=0; i < array.length; i++) {
            if (array[i] == element)
                return true;
        }
        return false;
    }
}

contract Slasher {
    /**
     * Type Declarations
     */
    mapping (address => bool) public isSlashed;
    
    /**
     * State Variables
     */

    // generic Proof object - replace 
    // True = fraudulent => user is slashed
    struct Proof {
        bool fraudulent;
    }
    
    /**
     * External & Public Functions
     */
    function slash(address operator, Proof memory proof) public {
        // no need to do anything if proof is not valid
        if (isProofValid(proof))
            isSlashed[operator] = true;
    }

    /**
     * View & Pure Functions
     */
    function isProofValid(Proof memory proof) private pure returns(bool) {
        return proof.fraudulent;
    }
}
