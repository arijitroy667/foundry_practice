// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {LibCrossChain} from "./LibCrossChain.sol";

contract CrossChainFacet is CCIPReceiver {
    // Store router address as immutable
    address private immutable i_router;

    // You still deploy this with the CCIP Router address for your chain.
    constructor(address router) CCIPReceiver(router) {
        i_router = router;
    }

    /**
     * @notice The public entry point for all incoming CCIP messages
     * @dev Called by the CCIP router directly
     */
    function ccipReceive(
        Client.Any2EVMMessage calldata message
    ) external override onlyRouter {
        // Process the CCIP message by passing to the internal function
        _processMessage(message);
    }

    /**
     * @notice Internal implementation of CCIP message processing
     * @dev This matches the visibility (internal) of the parent contract
     */
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        _processMessage(message);
    }

    /**
     * @notice Common processing logic for both public and internal functions
     * @dev Extracts token data and sends to LibCrossChain for processing
     */
    function _processMessage(Client.Any2EVMMessage memory message) private {
        LibCrossChain.EVMTokenAmount[]
            memory tokens = new LibCrossChain.EVMTokenAmount[](
                message.destTokenAmounts.length
            );

        for (uint i = 0; i < message.destTokenAmounts.length; i++) {
            tokens[i] = LibCrossChain.EVMTokenAmount({
                token: message.destTokenAmounts[i].token,
                amount: message.destTokenAmounts[i].amount
            });
        }

        LibCrossChain.processIncomingPayment(message.data, tokens);
    }

    /**
     * @notice Get the router address
     */
    function getRouter() public view override returns (address) {
        return i_router; // Return the stored router address
    }
}
