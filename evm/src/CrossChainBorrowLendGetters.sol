// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import "./interfaces/IMockPyth.sol";
import "./interfaces/IWormhole.sol";
import "./CrossChainBorrowLendState.sol";

contract CrossChainBorrowLendGetters is Context, CrossChainBorrowLendState {
    function wormhole() internal view returns (IWormhole) {
        return IWormhole(state.wormholeContractAddress);
    }

    function collateralToken() internal view returns (IERC20) {
        return IERC20(state.collateralAssetAddress);
    }

    function collateralTokenDecimals() internal view returns (uint8) {
        return IERC20Metadata(state.collateralAssetAddress).decimals();
    }

    function borrowToken() internal view returns (IERC20) {
        return IERC20(state.borrowingAssetAddress);
    }

    function borrowTokenDecimals() internal view returns (uint8) {
        return IERC20Metadata(state.borrowingAssetAddress).decimals();
    }

    function getOraclePrices() internal view returns (uint64, uint64) {
        IMockPyth.PriceFeed memory collateralFeed = mockPyth().queryPriceFeed(
            state.collateralAssetPythId
        );
        IMockPyth.PriceFeed memory borrowFeed = mockPyth().queryPriceFeed(
            state.borrowingAssetPythId
        );

        // sanity check the price feeds
        require(
            collateralFeed.price.price > 0 && borrowFeed.price.price > 0,
            "negative prices detected"
        );

        // Users of Pyth prices should read: https://docs.pyth.network/consumers/best-practices
        // before using the price feed. Blindly using the price alone is not recommended.
        return (
            uint64(collateralFeed.price.price),
            uint64(borrowFeed.price.price)
        );
    }

    function collateralInterestAccrualIndex() public view returns (uint256) {
        uint256 deposited = state.totalAssets.deposited;
        uint256 precision = state.interestAccrualIndexPrecision;
        if (deposited == 0) {
            return precision;
        }
        return
            precision +
            (state.totalAssets.borrowed *
                (state.interestAccrualIndex - precision)) /
            deposited;
    }

    function borrowedInterestAccrualIndex() public view returns (uint256) {
        return state.interestAccrualIndex;
    }

    function mockPyth() internal view returns (IMockPyth) {
        return IMockPyth(state.mockPythAddress);
    }

    function normalizedLiquidity() internal view returns (uint256) {
        return state.totalAssets.deposited - state.totalAssets.borrowed;
    }

    function denormalizeAmount(
        uint256 normalizedAmount,
        uint256 interestAccrualIndex_
    ) public view returns (uint256) {
        return
            (normalizedAmount * interestAccrualIndex_) /
            state.interestAccrualIndexPrecision;
    }

    function normalizeAmount(
        uint256 denormalizedAmount,
        uint256 interestAccrualIndex_
    ) public view returns (uint256) {
        return
            (denormalizedAmount * state.interestAccrualIndexPrecision) /
            interestAccrualIndex_;
    }

    function messageHashConsumed(bytes32 hash) public view returns (bool) {
        return state.consumedMessages[hash];
    }

    function normalizedAmounts()
        public
        view
        returns (NormalizedTotalAmounts memory)
    {
        return state.totalAssets;
    }

    function maxAllowedToBorrowWithPrices(
        address account,
        uint64 collateralPrice,
        uint64 borrowAssetPrice
    ) internal view returns (uint256) {
        // For EVMs, same private key will be used for borrowing-lending activity.
        // When introducing other chains (e.g. Cosmos), need to do wallet registration
        // so we can access a map of a non-EVM address based on this EVM borrower
        NormalizedAmounts memory normalized = state.accountAssets[account];

        // denormalize
        uint256 denormalizedDeposited = denormalizeAmount(
            normalized.sourceDeposited,
            collateralInterestAccrualIndex()
        );
        uint256 denormalizedBorrowed = denormalizeAmount(
            normalized.targetBorrowed,
            borrowedInterestAccrualIndex()
        );

        return
            (denormalizedDeposited *
                state.collateralizationRatio *
                collateralPrice *
                10**borrowTokenDecimals()) /
            (state.collateralizationRatioPrecision *
                borrowAssetPrice *
                10**collateralTokenDecimals()) -
            denormalizedBorrowed;
    }

    function maxAllowedToBorrow(address account) public view returns (uint256) {
        // fetch asset prices
        (uint64 collateralPrice, uint64 borrowAssetPrice) = getOraclePrices();
        return
            maxAllowedToBorrowWithPrices(
                account,
                collateralPrice,
                borrowAssetPrice
            );
    }

    function maxAllowedToWithdrawWithPrices(
        address account,
        uint64 collateralPrice,
        uint64 borrowAssetPrice
    ) internal view returns (uint256) {
        // For EVMs, same private key will be used for borrowing-lending activity.
        // When introducing other chains (e.g. Cosmos), need to do wallet registration
        // so we can access a map of a non-EVM address based on this EVM borrower
        NormalizedAmounts memory normalized = state.accountAssets[account];

        // denormalize
        uint256 denormalizedDeposited = denormalizeAmount(
            normalized.sourceDeposited,
            collateralInterestAccrualIndex()
        );
        uint256 denormalizedBorrowed = denormalizeAmount(
            normalized.targetBorrowed,
            borrowedInterestAccrualIndex()
        );

        return
            denormalizedDeposited -
            (denormalizedBorrowed *
                state.collateralizationRatioPrecision *
                borrowAssetPrice *
                10**collateralTokenDecimals()) /
            (state.collateralizationRatio *
                collateralPrice *
                10**borrowTokenDecimals());
    }

    function maxAllowedToWithdraw(address account)
        public
        view
        returns (uint256)
    {
        (uint64 collateralPrice, uint64 borrowAssetPrice) = getOraclePrices();
        return
            maxAllowedToWithdrawWithPrices(
                account,
                collateralPrice,
                borrowAssetPrice
            );
    }
}
