//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

enum PaymentType {
    Buffer,
    EMI,
    FullRepayment
}

interface IAutomationLoanInternal {
    function _handleCrossChainPayment(
        uint256 loanId,
        uint256 amountReceived,
        address tokenReceived,
        PaymentType pType
    ) external;

    // Keep external in interface
    function _activateLoanWithBuffer(
        uint256 loanId,
        uint256 amountReceived,
        address tokenReceived
    ) external;

    // Keep external in interface
    function _creditCrossChainEMI(
        uint256 loanId,
        uint256 amountReceived,
        address tokenReceived
    ) external;
}
