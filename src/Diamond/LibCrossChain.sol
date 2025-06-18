//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IAutomationLoanInternal, PaymentType} from "../../interfaces/ICrossChain.sol";

library LibCrossChain {
    // Custom error for clarity
    error CrossChainHandlerFailed();

    /**
     * @notice Processes a received CCIP message, decodes it, and routes it to the correct handler.
     * @dev This is the central logic hub for all incoming cross-chain payments.
     * @param message The raw CCIP message received by the CrossChainFacet.
     */
    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }

    function processIncomingPayment(
        bytes memory message,
        EVMTokenAmount[] memory tokens
    ) internal {
        require(tokens.length == 1, "CCIP: Must send exactly one token type");

        // Decode the message
        (uint256 loanId, PaymentType pType) = abi.decode(
            message,
            (uint256, PaymentType)
        );

        EVMTokenAmount memory tokenAmount = tokens[0];

        // Use the main handler function instead of direct calls
        (bool success, ) = address(this).delegatecall(
            abi.encodeWithSelector(
                IAutomationLoanInternal._handleCrossChainPayment.selector,
                loanId,
                tokenAmount.amount,
                tokenAmount.token,
                pType
            )
        );

        if (!success) revert CrossChainHandlerFailed();
    }
}
