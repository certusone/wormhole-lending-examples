// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IWormhole.sol";
import "./libraries/external/BytesLib.sol";

import "./CrossChainBorrowLendStructs.sol";
import "./CrossChainBorrowLendGetters.sol";
import "./CrossChainBorrowLendMessages.sol";

contract CrossChainBorrowLend is
    CrossChainBorrowLendGetters,
    CrossChainBorrowLendMessages,
    ReentrancyGuard
{
    constructor(
        address wormholeContractAddress_,
        uint8 consistencyLevel_,
        address mockPythAddress_,
        uint16 targetChainId_,
        bytes32 targetContractAddress_,
        address collateralAsset_,
        bytes32 collateralAssetPythId_,
        uint256 collateralizationRatio_,
        address borrowingAsset_,
        bytes32 borrowingAssetPythId_,
        uint256 repayGracePeriod_
    ) {
        // REVIEW: set owner for only owner methods if desired

        // wormhole
        state.wormholeContractAddress = wormholeContractAddress_;
        state.consistencyLevel = consistencyLevel_;

        // target chain info
        state.targetChainId = targetChainId_;
        state.targetContractAddress = targetContractAddress_;

        // collateral params
        state.collateralAssetAddress = collateralAsset_;
        state.collateralizationRatio = collateralizationRatio_;
        state.collateralizationRatioPrecision = 1e18; // fixed

        // borrowing asset address
        state.borrowingAssetAddress = borrowingAsset_;

        // interest rate parameters
        state.interestRateModel.ratePrecision = 1e18;
        state.interestRateModel.rateIntercept = 2e16; // 2%
        state.interestRateModel.rateCoefficientA = 0;

        // Price index of 1 with the current precision is 1e18
        // since this is the precision of our value.
        state.interestAccrualIndexPrecision = 1e18;
        state.interestAccrualIndex = state.interestAccrualIndexPrecision;

        // pyth oracle address and asset IDs
        state.mockPythAddress = mockPythAddress_;
        state.collateralAssetPythId = collateralAssetPythId_;
        state.borrowingAssetPythId = borrowingAssetPythId_;

        // repay grace period for this chain
        state.repayGracePeriod = repayGracePeriod_;
    }

    function addCollateral(uint256 amount) public nonReentrant {
        require(amount > 0, "nothing to deposit");

        // update current price index
        updateInterestAccrualIndex();

        // update state for supplier
        uint256 normalizedAmount = normalizeAmount(
            amount,
            collateralInterestAccrualIndex()
        );
        state.accountAssets[_msgSender()].sourceDeposited += normalizedAmount;
        state.totalAssets.deposited += normalizedAmount;

        SafeERC20.safeTransferFrom(
            collateralToken(),
            _msgSender(),
            address(this),
            amount
        );
    }

    function removeCollateral(uint256 amount) public nonReentrant {
        require(amount > 0, "nothing to withdraw");

        // update current price index
        updateInterestAccrualIndex();

        // Check if user has enough to withdraw from the contract
        require(
            amount < maxAllowedToWithdraw(_msgSender()),
            "amount >= maxAllowedToWithdraw(msg.sender)"
        );

        // update state for supplier
        uint256 normalizedAmount = normalizeAmount(
            amount,
            collateralInterestAccrualIndex()
        );
        state.accountAssets[_msgSender()].sourceDeposited -= normalizedAmount;
        state.totalAssets.deposited -= normalizedAmount;

        // transfer the tokens to the caller
        SafeERC20.safeTransfer(collateralToken(), _msgSender(), amount);
    }

    function removeCollateralInFull() public nonReentrant {
        // fetch the account information for the caller
        NormalizedAmounts memory normalizedAmounts = state.accountAssets[
            _msgSender()
        ];

        // make sure the account has closed all borrowed positions
        require(
            normalizedAmounts.targetBorrowed == 0,
            "account has outstanding loans"
        );

        // update current price index
        updateInterestAccrualIndex();

        // update state for supplier
        uint256 normalizedAmount = normalizedAmounts.sourceDeposited;
        state.accountAssets[_msgSender()].sourceDeposited = 0;
        state.totalAssets.deposited -= normalizedAmount;

        // transfer the tokens to the caller
        SafeERC20.safeTransfer(
            collateralToken(),
            _msgSender(),
            denormalizeAmount(
                normalizedAmount,
                collateralInterestAccrualIndex()
            )
        );
    }

    function computeInterestProportion(
        uint256 secondsElapsed,
        uint256 intercept,
        uint256 coefficient
    ) internal view returns (uint256) {
        uint256 deposited = state.totalAssets.deposited;
        if (deposited == 0) {
            return 0;
        }
        return
            (secondsElapsed *
                (intercept +
                    (coefficient * state.totalAssets.borrowed) /
                    deposited)) /
            365 /
            24 /
            60 /
            60;
    }

    function updateInterestAccrualIndex() internal {
        // TODO: change to block.number?
        uint256 secondsElapsed = block.timestamp -
            state.lastActivityBlockTimestamp;

        if (secondsElapsed == 0) {
            // nothing to do
            return;
        }

        // Should not hit, but just here in case someone
        // tries to update the interest when there is nothing
        // deposited.
        uint256 deposited = state.totalAssets.deposited;
        if (deposited == 0) {
            return;
        }

        state.lastActivityBlockTimestamp = block.timestamp;

        state.interestAccrualIndex += computeInterestProportion(
            secondsElapsed,
            state.interestRateModel.rateIntercept,
            state.interestRateModel.rateCoefficientA
        );
    }

    function initiateBorrow(uint256 amount) public returns (uint64 sequence) {
        require(amount > 0, "nothing to borrow");

        // update current price index
        updateInterestAccrualIndex();

        // Check if user has enough to borrow
        require(
            amount < maxAllowedToBorrow(_msgSender()),
            "amount >= maxAllowedToBorrow(msg.sender)"
        );

        // update state for borrower
        uint256 borrowedIndex = borrowedInterestAccrualIndex();
        uint256 normalizedAmount = normalizeAmount(amount, borrowedIndex);
        state.accountAssets[_msgSender()].targetBorrowed += normalizedAmount;
        state.totalAssets.borrowed += normalizedAmount;

        // construct wormhole message
        MessageHeader memory header = MessageHeader({
            payloadID: uint8(1),
            borrower: _msgSender(),
            collateralAddress: state.collateralAssetAddress,
            borrowAddress: state.borrowingAssetAddress
        });

        sequence = sendWormholeMessage(
            encodeBorrowMessage(
                BorrowMessage({
                    header: header,
                    borrowAmount: amount,
                    totalNormalizedBorrowAmount: state
                        .accountAssets[_msgSender()]
                        .targetBorrowed,
                    interestAccrualIndex: borrowedIndex
                })
            )
        );
    }

    function completeBorrow(bytes calldata encodedVm)
        public
        returns (uint64 sequence)
    {
        // parse and verify the wormhole BorrowMessage
        (
            IWormhole.VM memory parsed,
            bool valid,
            string memory reason
        ) = wormhole().parseAndVerifyVM(encodedVm);
        require(valid, reason);

        // verify emitter
        require(verifyEmitter(parsed), "invalid emitter");

        // completed (replay protection)
        // also serves as reentrancy protection
        require(!messageHashConsumed(parsed.hash), "message already consumed");
        consumeMessageHash(parsed.hash);

        // decode borrow message
        BorrowMessage memory params = decodeBorrowMessage(parsed.payload);

        // correct assets?
        require(verifyAssetMetaFromBorrow(params), "invalid asset metadata");

        // make sure this contract has enough assets to fund the borrow
        if (
            params.borrowAmount >
            denormalizeAmount(
                normalizedLiquidity(),
                borrowedInterestAccrualIndex()
            )
        ) {
            // construct RevertBorrow wormhole message
            // switch the borrow and collateral addresses for the target chain
            MessageHeader memory header = MessageHeader({
                payloadID: uint8(2),
                borrower: params.header.borrower,
                collateralAddress: state.borrowingAssetAddress,
                borrowAddress: state.collateralAssetAddress
            });

            sequence = sendWormholeMessage(
                encodeRevertBorrowMessage(
                    RevertBorrowMessage({
                        header: header,
                        borrowAmount: params.borrowAmount,
                        sourceInterestAccrualIndex: params.interestAccrualIndex
                    })
                )
            );
        } else {
            // save the total normalized borrow amount for repayments
            state.totalAssets.borrowed +=
                params.totalNormalizedBorrowAmount -
                state.accountAssets[params.header.borrower].sourceBorrowed;
            state.accountAssets[params.header.borrower].sourceBorrowed = params
                .totalNormalizedBorrowAmount;

            // params.borrowAmount == 0 means that there was a repayment
            // made outside of the grace period, so we will have received
            // another VAA representing the updated borrowed amount
            // on the source chain.
            if (params.borrowAmount > 0) {
                // finally transfer
                SafeERC20.safeTransferFrom(
                    collateralToken(),
                    address(this),
                    params.header.borrower,
                    params.borrowAmount
                );
            }

            // no wormhole message, return the default value: zero == success
        }
    }

    function completeRevertBorrow(bytes calldata encodedVm) public {
        // parse and verify the wormhole RevertBorrowMessage
        (
            IWormhole.VM memory parsed,
            bool valid,
            string memory reason
        ) = wormhole().parseAndVerifyVM(encodedVm);
        require(valid, reason);

        // verify emitter
        require(verifyEmitter(parsed), "invalid emitter");

        // completed (replay protection)
        // also serves as reentrancy protection
        require(!messageHashConsumed(parsed.hash), "message already consumed");
        consumeMessageHash(parsed.hash);

        // decode borrow message
        RevertBorrowMessage memory params = decodeRevertBorrowMessage(
            parsed.payload
        );

        // verify asset meta
        require(
            state.collateralAssetAddress == params.header.collateralAddress &&
                state.borrowingAssetAddress == params.header.borrowAddress,
            "invalid asset metadata"
        );

        // update state for borrower
        // Normalize the borrowAmount by the original interestAccrualIndex (encoded in the BorrowMessage)
        // to revert the inteded borrow amount.
        uint256 normalizedAmount = normalizeAmount(
            params.borrowAmount,
            params.sourceInterestAccrualIndex
        );
        state
            .accountAssets[params.header.borrower]
            .targetBorrowed -= normalizedAmount;
        state.totalAssets.borrowed -= normalizedAmount;
    }

    function initiateRepay(uint256 amount)
        public
        nonReentrant
        returns (uint64 sequence)
    {
        require(amount > 0, "nothing to repay");

        // For EVMs, same private key will be used for borrowing-lending activity.
        // When introducing other chains (e.g. Cosmos), need to do wallet registration
        // so we can access a map of a non-EVM address based on this EVM borrower
        NormalizedAmounts memory normalizedAmounts = state.accountAssets[
            _msgSender()
        ];

        // update the index
        updateInterestAccrualIndex();

        // cache the index to save gas
        uint256 index = borrowedInterestAccrualIndex();

        // save the normalized amount
        uint256 normalizedAmount = normalizeAmount(amount, index);

        // confirm that the caller has loans to pay back
        require(
            normalizedAmount <= normalizedAmounts.sourceBorrowed,
            "loan payment too large"
        );

        // update state on this contract
        state.accountAssets[_msgSender()].sourceBorrowed -= normalizedAmount;
        state.totalAssets.borrowed -= normalizedAmount;

        // transfer to this contract
        SafeERC20.safeTransferFrom(
            borrowToken(),
            _msgSender(),
            address(this),
            amount
        );

        // construct wormhole message
        MessageHeader memory header = MessageHeader({
            payloadID: uint8(3),
            borrower: _msgSender(),
            collateralAddress: state.borrowingAssetAddress,
            borrowAddress: state.collateralAssetAddress
        });

        // add index and block timestamp
        sequence = sendWormholeMessage(
            encodeRepayMessage(
                RepayMessage({
                    header: header,
                    repayAmount: amount,
                    targetInterestAccrualIndex: index,
                    repayTimestamp: block.timestamp,
                    paidInFull: 0
                })
            )
        );
    }

    function initiateRepayInFull()
        public
        nonReentrant
        returns (uint64 sequence)
    {
        // For EVMs, same private key will be used for borrowing-lending activity.
        // When introducing other chains (e.g. Cosmos), need to do wallet registration
        // so we can access a map of a non-EVM address based on this EVM borrower
        NormalizedAmounts memory normalizedAmounts = state.accountAssets[
            _msgSender()
        ];

        // update the index
        updateInterestAccrualIndex();

        // cache the index to save gas
        uint256 index = borrowedInterestAccrualIndex();

        // update state on the contract
        uint256 normalizedAmount = normalizedAmounts.sourceBorrowed;
        state.accountAssets[_msgSender()].sourceBorrowed = 0;
        state.totalAssets.borrowed -= normalizedAmount;

        // transfer to this contract
        SafeERC20.safeTransferFrom(
            borrowToken(),
            _msgSender(),
            address(this),
            denormalizeAmount(normalizedAmount, index)
        );

        // construct wormhole message
        MessageHeader memory header = MessageHeader({
            payloadID: uint8(3),
            borrower: _msgSender(),
            collateralAddress: state.borrowingAssetAddress,
            borrowAddress: state.collateralAssetAddress
        });

        // add index and block timestamp
        sequence = sendWormholeMessage(
            encodeRepayMessage(
                RepayMessage({
                    header: header,
                    repayAmount: denormalizeAmount(normalizedAmount, index),
                    targetInterestAccrualIndex: index,
                    repayTimestamp: block.timestamp,
                    paidInFull: 1
                })
            )
        );
    }

    function completeRepay(bytes calldata encodedVm)
        public
        returns (uint64 sequence)
    {
        // parse and verify the RepayMessage
        (
            IWormhole.VM memory parsed,
            bool valid,
            string memory reason
        ) = wormhole().parseAndVerifyVM(encodedVm);
        require(valid, reason);

        // verify emitter
        require(verifyEmitter(parsed), "invalid emitter");

        // completed (replay protection)
        require(!messageHashConsumed(parsed.hash), "message already consumed");
        consumeMessageHash(parsed.hash);

        // update the index
        updateInterestAccrualIndex();

        // cache the index to save gas
        uint256 index = borrowedInterestAccrualIndex();

        // decode the RepayMessage
        RepayMessage memory params = decodeRepayMessage(parsed.payload);

        // correct assets?
        require(verifyAssetMetaFromRepay(params), "invalid asset metadata");

        // see if the loan is repaid in full
        if (params.paidInFull == 1) {
            // REVIEW: do we care about getting the VAA in time?
            if (
                params.repayTimestamp + state.repayGracePeriod <=
                block.timestamp
            ) {
                // update state in this contract
                uint256 normalizedAmount = normalizeAmount(
                    params.repayAmount,
                    params.targetInterestAccrualIndex
                );
                state.accountAssets[params.header.borrower].targetBorrowed = 0;
                state.totalAssets.borrowed -= normalizedAmount;
            } else {
                uint256 normalizedAmount = normalizeAmount(
                    params.repayAmount,
                    index
                );
                state
                    .accountAssets[params.header.borrower]
                    .targetBorrowed -= normalizedAmount;
                state.totalAssets.borrowed -= normalizedAmount;

                // Send a wormhole message again since he did not repay in full
                // (due to repaying outside of the grace period)
                sequence = sendWormholeMessage(
                    encodeBorrowMessage(
                        BorrowMessage({
                            header: MessageHeader({
                                payloadID: uint8(1),
                                borrower: params.header.borrower,
                                collateralAddress: state.collateralAssetAddress,
                                borrowAddress: state.borrowingAssetAddress
                            }),
                            borrowAmount: 0, // special value to indicate failed repay in full
                            totalNormalizedBorrowAmount: state
                                .accountAssets[params.header.borrower]
                                .targetBorrowed,
                            interestAccrualIndex: index
                        })
                    )
                );
            }
        } else {
            // update state in this contract
            uint256 normalizedAmount = normalizeAmount(
                params.repayAmount,
                params.targetInterestAccrualIndex
            );
            state
                .accountAssets[params.header.borrower]
                .targetBorrowed -= normalizedAmount;
            state.totalAssets.borrowed -= normalizedAmount;
        }
    }

    /**
     @notice `initiateLiquidationOnTargetChain` has not been implemented yet.

     This function should determine if a particular position is undercollateralized
     by querying the `accountAssets` state variable for the passed account. Calculate
     the health of the account.

     If an account is undercollateralized, this method should generate a Wormhole
     message sent to the target chain by the caller. The caller will invoke the
     `completeRepayOnBehalf` method on the target chain and pass the signed Wormhole
     message as an argument.

     If the account has not yet paid the loan back by the time the Wormhole message
     arrives on the target chain, `completeRepayOnBehalf` will accept funds from the
     caller, and generate another Wormhole messsage to be delivered to the source chain.

     The caller will then invoke `completeLiquidation` on the source chain and pass
     the signed Wormhole message in as an argument. This function should handle
     releasing the account's collateral to the liquidator, less fees (which should be
     defined in the contract and updated by the contract owner).

     In order for off-chain processes to calculate an account's health, the integrator
     needs to expose a getter that will return the list of accounts with open positions.
     The integrator needs to expose a getter that allows the liquidator to query the
     `accountAssets` state variable for a particular account.
    */
    function initiateLiquidationOnTargetChain(address accountToLiquidate)
        public
    {}

    function completeRepayOnBehalf(bytes calldata encodedVm) public {}

    function completeLiquidation(bytes calldata encodedVm) public {}

    function sendWormholeMessage(bytes memory payload)
        internal
        returns (uint64 sequence)
    {
        sequence = IWormhole(state.wormholeContractAddress).publishMessage(
            0, // nonce
            payload,
            state.consistencyLevel
        );
    }

    function verifyEmitter(IWormhole.VM memory parsed)
        internal
        view
        returns (bool)
    {
        return
            parsed.emitterAddress == state.targetContractAddress &&
            parsed.emitterChainId == state.targetChainId;
    }

    function verifyAssetMetaFromBorrow(BorrowMessage memory params)
        internal
        view
        returns (bool)
    {
        return
            params.header.collateralAddress == state.borrowingAssetAddress &&
            params.header.borrowAddress == state.collateralAssetAddress;
    }

    function verifyAssetMetaFromRepay(RepayMessage memory params)
        internal
        view
        returns (bool)
    {
        return
            params.header.collateralAddress == state.collateralAssetAddress &&
            params.header.borrowAddress == state.borrowingAssetAddress;
    }

    function consumeMessageHash(bytes32 vmHash) internal {
        state.consumedMessages[vmHash] = true;
    }
}
