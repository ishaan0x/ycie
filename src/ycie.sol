// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;
import {IERC20} from "../lib/forge-std/src/interfaces/IERC20.sol";

contract TokenPool {
    error TokenPool__DepositNotPositive();
    error TokenPool__StakerSlashed();

    mapping(address => uint256) public balance;
    mapping(address => address[]) public slasher;
    IERC20 public token;

    constructor(address tokenAddress) {
        token = IERC20(tokenAddress);
    }
    
    function stake(uint256 amount) public {
        if (amount == 0)
            revert TokenPool__DepositNotPositive();

        token.transferFrom(msg.sender, address(this), amount);
        balance[msg.sender] += amount;
    }

    function withdraw() public {
        if (!isSlashed(msg.sender))
            token.transfer(msg.sender, balance[msg.sender]);
        balance[msg.sender] = 0;
        delete slasher[msg.sender];
    }

    function enroll(address _slasher) public {
        if (isSlashed(msg.sender))
            revert TokenPool__StakerSlashed();

        address[] memory slashers = slasher[msg.sender];
        if (exists(_slasher, slashers))
            return;

        slasher[msg.sender].push(_slasher);
    }

    function isSlashed(address staker) public returns(bool) {
        address[] memory slashers = slasher[staker];

        for (uint i=0; i < slashers.length; i++) {
            if (Slasher(slashers[i]).isSlashed(staker) == true)
                return true;
        }
        
        return false;
    }

    function exists(address element, address[] memory array) private pure returns(bool) {
        for (uint i=0; i < array.length; i++) {
            if (array[i] == element)
                return true;
        }
        return false;
    }
}

contract Slasher {
    mapping (address => bool) public isSlashed;
    
    // generic Proof object - replace 
    // True = fraudulent => user is slashed
    struct Proof {
        bool fraudulent;
    }
    
    function slash(address staker, Proof memory proof) public {
        // no need to do anything if proof is not valid
        if (isProofValid(proof))
            isSlashed[staker] = true;
    }

    function isProofValid(Proof memory proof) private pure returns(bool) {
        return proof.fraudulent;
    }
}
