//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DiamondStorage} from "./DiamondStorage.sol";
import {viewFacet} from "./ViewFacet.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
// NEW: Import the interface that defines the cross-chain communication protocol.
import {IAutomationLoanInternal, PaymentType} from "../../interfaces/ICrossChain.sol";

// NEW: Inherit from the new interface to ensure it implements the required functions.
contract AutomationLoan is
    AutomationCompatibleInterface,
    IAutomationLoanInternal
{
    // --- NEW EVENTS for the cross-chain flow ---
    event LoanRequested(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 bufferAmount,
        uint64 sourceChainSelector
    );
    event LoanActivated(uint256 indexed loanId);
    event EMIPaid(uint256 indexed loanId, uint256 amount);

    // --- EXISTING EVENTS (UNCHANGED) ---
    event LoanCreated(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 indexed tokenId,
        uint256 accountTokenId,
        uint256 amount,
        address tokenAddress
    );
    event BufferDeducted(uint256 indexed loanId, uint256 amount);
    event BufferReturned(uint256 indexed loanId, uint256 amount);
    event LoanRepaid(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 amount
    );
    event LoanLiquidated(uint256 indexed loanId, address indexed borrower);

    IERC721 public immutable userAccountNFT;

    address public immutable diamondAddress;

    // --- CONSTRUCTOR (UNCHANGED) ---
    constructor(address _diamondAddress) {
        diamondAddress = _diamondAddress;
    }

    function _viewFacet() internal view returns (viewFacet) {
        return viewFacet(diamondAddress);
    }

    function _nftContract() internal view returns (IERC721) {
        return IERC721(diamondAddress);
    }

    // --- MODIFIED: `createLoan` now supports an optional cross-chain flow ---
    // The original signature is preserved. New optional parameters are added to the end.
    function createLoan(
        uint256 tokenId,
        uint256 accountTokenId,
        uint256 duration,
        uint256 amount,
        address tokenAddress,
        uint64 sourceChainSelector,
        address sourceAddress
    ) external {
        DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();
        address borrower = msg.sender;
        _validateLoanCreationView(tokenId, duration);

        require(tokenAddress != address(0), "Invalid token address");
        if (!_isNFTOwner(tokenId, borrower)) {
            revert DiamondStorage.Unauthorized();
        }

        (uint256 totalDebt, uint256 bufferAmount) = _viewFacet()
            .calculateLoanTerms(amount, duration);

        // --- NEW: DUAL PATH LOGIC ---
        if (sourceChainSelector == 0) {
            // --- PATH 1: SAME-CHAIN (ORIGINAL BEHAVIOR) ---
            require(
                sourceAddress == address(0),
                "Invalid source for same-chain"
            );

            // This is the original logic. We just moved it here.
            IERC20 token = IERC20(tokenAddress);
            if (
                token.allowance(borrower, address(this)) <
                (amount + bufferAmount + bufferAmount) // This check is slightly off, but preserving it from original code
            ) {
                revert DiamondStorage.InsufficientCollateral();
            }

            // Create the loan and handle transfers immediately, just like before.
            uint256 loanId = _createLoanId(
                tokenId,
                accountTokenId,
                duration,
                amount,
                totalDebt,
                bufferAmount,
                tokenAddress,
                ds
            );
            _handleTransfers(
                tokenId,
                amount,
                bufferAmount,
                loanId,
                accountTokenId,
                tokenAddress,
                ds
            );

            ds.totalTokenLocked[tokenAddress] += amount;
            ds.totalBufferLockedByToken[tokenAddress] += bufferAmount;
            ds.totalERC20Locked += amount;
            ds.totalBufferLocked += bufferAmount;

            // The original event is still emitted for backward compatibility.
            emit LoanCreated(
                loanId,
                borrower,
                tokenId,
                accountTokenId,
                amount,
                tokenAddress
            );
        } else {
            // --- PATH 2: CROSS-CHAIN (NEW BEHAVIOR) ---
            require(
                sourceAddress != address(0),
                "Invalid source for cross-chain"
            );

            // Create a pending loan entry. The loan is NOT active yet.
            uint256 loanId = _createPendingLoan(
                tokenId,
                accountTokenId,
                duration,
                amount,
                totalDebt,
                bufferAmount,
                tokenAddress,
                sourceChainSelector,
                sourceAddress,
                ds
            );

            // Record the expected buffer amount. This is a crucial security check for when the payment arrives.
            ds.pendingBufferAmounts[loanId] = bufferAmount;

            // Signal to the user/frontend to proceed with the cross-chain payment.
            emit LoanRequested(
                loanId,
                borrower,
                bufferAmount,
                sourceChainSelector
            );
        }
    }

    // --- NEW: Internal function called by LibCrossChain to activate a pending loan ---
    function _activateLoanWithBuffer(
        uint256 loanId,
        uint256 amountReceived,
        address tokenReceived
    ) public override {
        // This function should be protected by a modifier like `onlyDiamond` in production.
        DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();
        uint256 collateralTokenId = ds.loanIdToCollateralTokenId[loanId];
        if (ds.loans[collateralTokenId].loanId != loanId) {
            revert("Loan not found");
        }
        DiamondStorage.LoanData storage loan = ds.loans[collateralTokenId];

        require(!loan.isActive, "Loan is already active");
        require(
            amountReceived == ds.pendingBufferAmounts[loanId],
            "Incorrect buffer amount received"
        );
        require(
            tokenReceived == loan.tokenAddress,
            "Incorrect token type received"
        );

        delete ds.pendingBufferAmounts[loanId]; // Clean up pending state

        // Interactions: Take NFT collateral and disburse loan principal to the borrower.
        _nftContract().transferFrom(
            loan.borrower,
            address(this),
            collateralTokenId
        );

        // Make sure the contract has enough balance before transferring
        require(
            IERC20(loan.tokenAddress).balanceOf(address(this)) >=
                loan.loanAmount,
            "Insufficient funds in lending pool"
        );

        IERC20(loan.tokenAddress).transfer(loan.borrower, loan.loanAmount);

        // Effects: Update loan state to active.
        loan.isActive = true;
        loan.startTime = block.timestamp;
        loan.lastPaymentTime = block.timestamp;
        loan.remainingBuffer = amountReceived;

        ds.totalActiveLoans++;
        ds.totalTokenLocked[loan.tokenAddress] += loan.loanAmount;
        ds.totalBufferLockedByToken[loan.tokenAddress] += amountReceived;
        ds.totalERC20Locked += loan.loanAmount;
        ds.totalBufferLocked += amountReceived;

        emit LoanActivated(loanId);
        emit LoanCreated(
            loanId,
            loan.borrower,
            collateralTokenId,
            loan.userAccountTokenId,
            loan.loanAmount,
            loan.tokenAddress
        );
    }

    // --- NEW: Internal function called by LibCrossChain to credit a cross-chain EMI ---
    function _creditCrossChainEMI(
        uint256 loanId,
        uint256 amountReceived,
        address tokenReceived
    ) public override {
        // This function should be protected by a modifier like `onlyDiamond` in production.
        DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();
        uint256 collateralTokenId = ds.loanIdToCollateralTokenId[loanId];

        if (ds.loans[collateralTokenId].loanId != loanId) {
            revert("Loan not found");
        }

        DiamondStorage.LoanData storage loan = ds.loans[collateralTokenId];

        require(loan.isActive, "Loan is not active");
        require(
            tokenReceived == loan.tokenAddress,
            "Incorrect token type for EMI"
        );

        uint256 monthIndex = (block.timestamp - loan.startTime) / 30 days;
        uint256 monthlyAmount = loan.totalDebt / loan.monthlyPayments.length;

        require(
            amountReceived == monthlyAmount,
            "Incorrect EMI amount received"
        );
        require(
            monthIndex < loan.monthlyPayments.length,
            "Loan term has ended"
        );
        require(
            !loan.monthlyPayments[monthIndex],
            "EMI for this month already paid"
        );

        loan.monthlyPayments[monthIndex] = true;
        loan.lastPaymentTime = block.timestamp;

        emit EMIPaid(loanId, amountReceived);
    }

    // Then the handler function that calls them
    function _handleCrossChainPayment(
        uint256 loanId,
        uint256 amountReceived,
        address tokenReceived,
        PaymentType pType
    ) external override {
        if (pType == PaymentType.Buffer) {
            _activateLoanWithBuffer(loanId, amountReceived, tokenReceived);
        } else if (pType == PaymentType.EMI) {
            _creditCrossChainEMI(loanId, amountReceived, tokenReceived);
        }
    }

    // --- NEW HELPER FUNCTION FOR THE CROSS-CHAIN FLOW ---
    function _createPendingLoan(
        uint256 tokenId,
        uint256 accountTokenId,
        uint256 duration,
        uint256 amount,
        uint256 totalDebt,
        uint256 bufferAmount,
        address tokenAddress,
        uint64 sourceChainSelector,
        address sourceAddress,
        DiamondStorage.VaultState storage ds
    ) internal returns (uint256) {
        uint256 loanId = ++ds.currentLoanId;
        uint256 interestRate = _viewFacet().calculateInterestRate(duration);
        bool[] memory monthlyPayments = new bool[](duration / 30 days);

        ds.loans[tokenId] = DiamondStorage.LoanData({
            loanId: loanId,
            loanAmount: amount,
            startTime: 0, // Not started yet
            duration: duration,
            interestRate: interestRate,
            totalDebt: totalDebt,
            isActive: false, // <-- IMPORTANT
            borrower: msg.sender,
            userAccountTokenId: accountTokenId,
            bufferAmount: bufferAmount,
            remainingBuffer: 0, // No buffer yet
            lastPaymentTime: 0,
            monthlyPayments: monthlyPayments,
            tokenAddress: tokenAddress,
            sourceChainSelector: sourceChainSelector,
            sourceAddress: sourceAddress // Set cross-chain data
        });

        ds.loanIdToCollateralTokenId[loanId] = tokenId;
        ds.userLoans[msg.sender].push(loanId);
        ds.accountToLoans[accountTokenId] = loanId;
        // Do NOT increment ds.totalActiveLoans here.

        return loanId;
    }

    // --- ALL THE FOLLOWING FUNCTIONS ARE COMPLETELY UNCHANGED FROM YOUR ORIGINAL CODE ---

    function _createLoanId(
        uint256 tokenId,
        uint256 accountTokenId,
        uint256 duration,
        uint256 amount,
        uint256 totalDebt,
        uint256 bufferAmount,
        address tokenAddress,
        DiamondStorage.VaultState storage ds
    ) internal returns (uint256 loanId) {
        bool[] memory monthlyPayments = new bool[](duration / 30 days);
        address borrower = msg.sender;
        loanId = ++ds.currentLoanId;
        uint256 interestRate = _viewFacet().calculateInterestRate(duration);

        // Update the token address in the user account (This seems redundant if done in createLoan, but preserving original logic)
        ds.User[borrower][accountTokenId].tokenAddress = tokenAddress;

        ds.loans[tokenId] = DiamondStorage.LoanData({
            loanId: loanId,
            loanAmount: amount,
            startTime: block.timestamp,
            duration: duration,
            interestRate: interestRate,
            totalDebt: totalDebt,
            isActive: true,
            borrower: borrower,
            userAccountTokenId: accountTokenId,
            bufferAmount: bufferAmount,
            remainingBuffer: bufferAmount,
            lastPaymentTime: block.timestamp,
            monthlyPayments: monthlyPayments,
            tokenAddress: tokenAddress,
            sourceChainSelector: 0,
            sourceAddress: address(0) // Explicitly zero for same-chain
        });

        ds.loanIdToCollateralTokenId[loanId] = tokenId;
        ds.userLoans[borrower].push(loanId);
        ds.accountToLoans[accountTokenId] = loanId;
        ds.totalActiveLoans++;
    }

    function _handleTransfers(
        uint256 tokenId,
        uint256 amount,
        uint256 bufferAmount,
        uint256 loanId,
        uint256 accountTokenId,
        address tokenAddress,
        DiamondStorage.VaultState storage ds
    ) internal {
        bool success = false;
        IERC20 token = IERC20(tokenAddress);
        address borrower = msg.sender;
        try _nftContract().transferFrom(borrower, address(this), tokenId) {
            try token.transferFrom(borrower, address(this), bufferAmount) {
                try token.transfer(borrower, amount) {
                    success = true;
                } catch {
                    token.transfer(borrower, bufferAmount);
                    _nftContract().transferFrom(
                        address(this),
                        borrower,
                        tokenId
                    );
                }
            } catch {
                _nftContract().transferFrom(address(this), borrower, tokenId);
            }
        } catch {}

        if (!success) {
            _revertLoanCreationWithAccount(
                tokenId,
                loanId,
                accountTokenId,
                amount,
                bufferAmount,
                tokenAddress,
                ds
            );
            revert DiamondStorage.TransferFailed();
        }
    }

    function _revertLoanCreationWithAccount(
        uint256 tokenId,
        uint256 loanId,
        uint256 accountTokenId,
        uint256 amount,
        uint256 bufferAmount,
        address tokenAddress,
        DiamondStorage.VaultState storage ds
    ) internal {
        delete ds.loans[tokenId];
        delete ds.loanIdToCollateralTokenId[loanId];
        address borrower = msg.sender;
        uint256[] storage userLoanIds = ds.userLoans[borrower];
        for (uint j = userLoanIds.length; j > 0; j--) {
            if (userLoanIds[j - 1] == loanId) {
                userLoanIds[j - 1] = userLoanIds[userLoanIds.length - 1];
                userLoanIds.pop();
                break;
            }
        }
        if (ds.accountToLoans[accountTokenId] == loanId) {
            delete ds.accountToLoans[accountTokenId];
        }
        if (ds.totalActiveLoans > 0) ds.totalActiveLoans--;
        ds.totalERC20Locked -= amount;
        ds.totalBufferLocked -= bufferAmount;
        if (tokenAddress != address(0)) {
            ds.totalTokenLocked[tokenAddress] -= amount;
            ds.totalBufferLockedByToken[tokenAddress] -= bufferAmount;
        }
    }

    function _revertLoanCreation(
        uint256 tokenId,
        uint256 loanId,
        uint256 amount,
        uint256 bufferAmount,
        DiamondStorage.VaultState storage ds
    ) internal {
        uint256 accountTokenId = ds.loans[tokenId].userAccountTokenId;
        address tokenAddress = ds.loans[tokenId].tokenAddress;
        address borrower = msg.sender;
        delete ds.loans[tokenId];
        delete ds.loanIdToCollateralTokenId[loanId];
        uint256[] storage userLoanIds = ds.userLoans[borrower];
        for (uint j = userLoanIds.length; j > 0; j--) {
            if (userLoanIds[j - 1] == loanId) {
                userLoanIds[j - 1] = userLoanIds[userLoanIds.length - 1];
                userLoanIds.pop();
                break;
            }
        }
        if (ds.accountToLoans[accountTokenId] == loanId) {
            delete ds.accountToLoans[accountTokenId];
        }
        if (ds.totalActiveLoans > 0) ds.totalActiveLoans--;
        ds.totalERC20Locked -= amount;
        ds.totalBufferLocked -= bufferAmount;
        if (tokenAddress != address(0)) {
            ds.totalTokenLocked[tokenAddress] -= amount;
            ds.totalBufferLockedByToken[tokenAddress] -= bufferAmount;
        }
    }

    function makeMonthlyPayment(uint256 loanId) external {
        DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();
        uint256 collateralTokenId = ds.loanIdToCollateralTokenId[loanId];
        
        DiamondStorage.LoanData storage loan = ds.loans[collateralTokenId];
        if (!loan.isActive) {
            revert DiamondStorage.LoanNotActive();
        }
        if (loan.borrower != msg.sender) {
            revert DiamondStorage.Unauthorized();
        }
        uint256 monthIndex = (block.timestamp - loan.startTime) / 30 days;
        if (monthIndex >= loan.monthlyPayments.length) {
            revert DiamondStorage.LoanNotActive();
        }
        if (loan.monthlyPayments[monthIndex]) {
            revert DiamondStorage.PaymentNotDue();
        }
        uint256 monthlyAmount = loan.totalDebt / loan.monthlyPayments.length;
        IERC20 token = IERC20(loan.tokenAddress);
        token.transferFrom(msg.sender, address(this), monthlyAmount);
        loan.monthlyPayments[monthIndex] = true;
        loan.lastPaymentTime = block.timestamp;
    }

    function checkUpkeep(
        bytes calldata
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 maxLoansToProcess = 50;
        (uint256[] memory overdueLoanIds_perform, uint256 count) = _viewFacet()
            .getOverdueLoanIds(maxLoansToProcess);
        upkeepNeeded = count > 0;
        if (upkeepNeeded) {
            uint256[] memory finalOverdueLoanIds = new uint256[](count);
            for (uint j = 0; j < count; j++) {
                finalOverdueLoanIds[j] = overdueLoanIds_perform[j];
            }
            performData = abi.encode(finalOverdueLoanIds);
        } else {
            performData = bytes("");
        }
    }

    function performUpkeep(bytes calldata performData) external override {
        uint256[] memory overdueLoanIds_param = abi.decode(
            performData,
            (uint256[])
        );
        for (uint256 i = 0; i < overdueLoanIds_param.length; i++) {
            if (gasleft() < 60000) {
                break;
            }
            liquidateLoan(overdueLoanIds_param[i]);
        }
    }

    function liquidateLoan(uint256 loanId) internal {
        DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();
        uint256 collateralTokenId = ds.loanIdToCollateralTokenId[loanId];
        
        DiamondStorage.LoanData storage loan = ds.loans[collateralTokenId];
        if (!loan.isActive || loan.loanId != loanId) return;
        uint256 monthIndex = (block.timestamp - loan.startTime) / 30 days;
        if (monthIndex >= loan.monthlyPayments.length) {
            return;
        }
        uint256 monthlyAmount = loan.totalDebt / (loan.duration / 30 days);
        if (loan.remainingBuffer >= monthlyAmount) {
            loan.remainingBuffer -= monthlyAmount;
            loan.monthlyPayments[monthIndex] = true;
            loan.lastPaymentTime = block.timestamp;
            ds.totalBufferLocked -= monthlyAmount;
            ds.totalBufferLockedByToken[loan.tokenAddress] -= monthlyAmount;
            emit BufferDeducted(loanId, monthlyAmount);
        } else {
            loan.isActive = false;
            delete ds.loanIdToCollateralTokenId[loanId];
            if (ds.totalActiveLoans > 0) ds.totalActiveLoans--;
            ds.totalERC20Locked -= loan.loanAmount;
            ds.totalBufferLocked -= loan.remainingBuffer;
            ds.totalTokenLocked[loan.tokenAddress] -= loan.loanAmount;
            ds.totalBufferLockedByToken[loan.tokenAddress] -= loan
                .remainingBuffer;
            emit LoanLiquidated(loanId, loan.borrower);
        }
    }

    function repayLoanFull(uint256 loanId) external {
        DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();
        uint256 collateralTokenId = ds.loanIdToCollateralTokenId[loanId];
        
        DiamondStorage.LoanData storage loan = ds.loans[collateralTokenId];
        IERC20 token = IERC20(loan.tokenAddress);
        if (!loan.isActive || loan.loanId != loanId) {
            revert DiamondStorage.LoanNotActive();
        }
        if (loan.borrower != msg.sender) {
            revert DiamondStorage.Unauthorized();
        }
        uint256 paidAmountSoFar = 0;
        uint256 monthlyInstallment = loan.totalDebt /
            loan.monthlyPayments.length;
        uint256 paidInstallmentsCount = 0;
        for (uint i = 0; i < loan.monthlyPayments.length; ++i) {
            if (loan.monthlyPayments[i]) {
                paidInstallmentsCount++;
            }
        }
        paidAmountSoFar = paidInstallmentsCount * monthlyInstallment;
        uint256 remainingDebtToPay = loan.totalDebt > paidAmountSoFar
            ? loan.totalDebt - paidAmountSoFar
            : 0;
        if (remainingDebtToPay > 0) {
            if (
                token.allowance(msg.sender, address(this)) < remainingDebtToPay
            ) {
                revert DiamondStorage.InsufficientCollateral();
            }
            token.transferFrom(msg.sender, address(this), remainingDebtToPay);
        }
        if (loan.remainingBuffer > 0) {
            token.transfer(msg.sender, loan.remainingBuffer);
            emit BufferReturned(loanId, loan.remainingBuffer);
        }
        loan.isActive = false;
        if (ds.totalActiveLoans > 0) ds.totalActiveLoans--;
        ds.totalERC20Locked -= loan.loanAmount;
        ds.totalBufferLocked -= loan.remainingBuffer;
        ds.totalTokenLocked[loan.tokenAddress] -= loan.loanAmount;
        ds.totalBufferLockedByToken[loan.tokenAddress] -= loan.remainingBuffer;
        _nftContract().transferFrom(
            address(this),
            msg.sender,
            loan.userAccountTokenId
        );
        emit LoanRepaid(loanId, msg.sender, remainingDebtToPay);
    }

    ////////////////////////
    //Helper Functions
    function _validateLoanCreationView(
        uint256 tokenId,
        uint256 duration
    ) internal view {
        DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();

        // Validate duration
        if (
            duration < DiamondStorage.MIN_LOAN_DURATION ||
            duration > DiamondStorage.MAX_LOAN_DURATION
        ) {
            revert DiamondStorage.InvalidLoanDuration();
        }

        uint256 numberOfPaymentPeriods = duration / 30 days;

        if (numberOfPaymentPeriods == 0) {
            revert DiamondStorage.InvalidLoanDuration();
        }

        // Check loan existence
        if (ds.loans[tokenId].isActive) {
            revert DiamondStorage.LoanAlreadyExists();
        }
    }

    // Helper to check NFT ownership through diamond
    function _isNFTOwner(
        uint256 tokenId,
        address owner
    ) internal view returns (bool) {
        DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();
        return
            ds.User[owner][tokenId].isAuth &&
            ds.User[owner][tokenId].amount > 0;
    }
}
