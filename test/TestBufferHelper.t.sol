// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/Diamond/DiamondStorage.sol";
import "../src/Diamond/AutomationLoan.sol";
import {viewFacet as ViewFacetContract} from "../src/Diamond/viewFacet.sol";
import "forge-std/console.sol";

contract TestBufferHelper {
    // Define events locally that match the events in the main contract
    event EMIPaid(uint256 indexed loanId, uint256 amount);
    event BufferUsed(uint256 indexed loanId, uint256 amount);

    function makeBufferPayment(
        address diamond,
        uint256 loanId,
        uint256 monthIndex
    ) external returns (bool paymentFullyCovered) {
        console.log("Attempting buffer payment for loan ID:", loanId);
        console.log("Month index:", monthIndex);

        // Get loan data through the view facet
        DiamondStorage.LoanData memory loanData = ViewFacetContract(diamond)
            .getLoanById(loanId);

        // Debug output
        console.log("Retrieved loan data - Active:", loanData.isActive);
        console.log("Collateral Token ID:", loanData.userAccountTokenId);

        // Validate the loan
        require(loanData.isActive, "Loan not active");
        require(
            monthIndex < loanData.monthlyPayments.length,
            "Invalid month index"
        );
        require(!loanData.monthlyPayments[monthIndex], "Payment already made");

        // Calculate payment amount
        uint256 monthlyAmount = loanData.totalDebt /
            loanData.monthlyPayments.length;

        // Determine how much we can deduct from buffer
        uint256 actualPayment;
        if (loanData.remainingBuffer >= monthlyAmount) {
            actualPayment = monthlyAmount;
            paymentFullyCovered = true;
        } else {
            // If buffer is less than monthly amount, use whatever is left
            actualPayment = loanData.remainingBuffer;
            paymentFullyCovered = false;
            console.log("WARNING: Buffer is less than monthly payment");
            console.log("Using remaining buffer:", actualPayment);
        }

        // Don't attempt to make payment if buffer is zero
        if (actualPayment == 0) {
            console.log("ERROR: Buffer is depleted, cannot make payment");
            return false;
        }

        // Call diamond contract to make the buffer payment
        bytes memory callData = abi.encodeWithSignature(
            "testBufferPayment(uint256,uint256,uint256)",
            loanId,
            monthIndex,
            actualPayment
        );

        (bool success, ) = diamond.call(callData);

        // If the function doesn't exist, handle the fallback
        if (!success) {
            console.log("Failed to call testBufferPayment function");
        }

        // Get updated loan data
        loanData = ViewFacetContract(diamond).getLoanById(loanId);
        if (!loanData.isActive) {
            console.log("ALERT: Loan liquidated due to insufficient buffer");
            paymentFullyCovered = false;
        } else {
            console.log(
                "Payment processed. New buffer:",
                loanData.remainingBuffer
            );
        }

        return paymentFullyCovered;
    }
}
