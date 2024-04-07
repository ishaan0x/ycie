// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;
import {IERC20} from "../lib/forge-std/src/interfaces/IERC20.sol";

contract TokenPool {
    mapping(address => uint256) public balance;
    IERC20 public token;

    // generic Proof object - replace 
    // True = fraudulent => user is slashed
    struct Proof {
        bool fraudulent;
    }

    constructor(address tokenAddress) {
        token = IERC20(tokenAddress);
    }
    
    function stake(uint256 amount) public {
        require(amount > 0, "Deposit amount must be greater than 0");

        token.transferFrom(msg.sender, address(this), amount);
        balance[msg.sender] += amount;
    }

    function withdraw() public {
        token.transfer(msg.sender, balance[msg.sender]);
        balance[msg.sender] = 0;
    }

    function slash(address staker, Proof memory proof) public {
        // no need to do anything if proof is not valid
        if (!isProofValid(proof))
            return;

        balance[staker] = 0;
    }

    function isProofValid(Proof memory proof) private pure returns(bool) {
        return proof.fraudulent;
    }
}
