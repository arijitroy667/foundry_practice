// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CCIPReceiver} from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";

contract MockCCIPRouter {
    // Events to simulate ccip router behavior
    event CCIPMessageSent(bytes32 messageId);

    // Mock ccipSend function
    function ccipSend(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage calldata message
    ) external returns (bytes32) {
        bytes32 messageId = keccak256(abi.encode(
            destinationChainSelector,
            message.receiver,
            message.data,
            block.timestamp
        ));
        
        emit CCIPMessageSent(messageId);
        
        return messageId;
    }
    
    // Helper function to simulate sending CCIP messages
    function simulateMessageReceived(
        address receiver,
        Client.Any2EVMMessage memory message
    ) external {
        // Transfer the tokens to the receiver first
        for (uint i = 0; i < message.destTokenAmounts.length; i++) {
            IERC20(message.destTokenAmounts[i].token).transfer(
                receiver,
                message.destTokenAmounts[i].amount
            );
        }
        
        // Call ccipReceive on the target
        CCIPReceiver(receiver).ccipReceive(message);
    }
}