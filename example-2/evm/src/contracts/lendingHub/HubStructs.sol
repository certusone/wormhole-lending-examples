// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract HubStructs {
    struct VaultAmount {
        uint256 deposited;
        uint256 borrowed;
    }

    struct AccrualIndices {
        uint256 deposited;
        uint256 borrowed;
        uint256 lastBlock;
    }

    struct AssetInfo {
        uint256 collateralizationRatioDeposit;
        uint256 collateralizationRatioBorrow;
        bytes32 pythId;
        // pyth id info
        uint8 decimals;
        InterestRateModel interestRateModel;
        bool exists;
    }

    struct InterestRateModel {
        uint64 ratePrecision;
        uint64 rateIntercept;
        uint64 rateCoefficientA;
        uint256 reserveFactor;
        uint256 reservePrecision;
    }

    enum Action{Deposit, Borrow, Withdraw, Repay, DepositNative, RepayNative}

    struct ActionPayload {
        Action action;
        address sender;
        address assetAddress;
        uint256 assetAmount;
    }

    // struct for mock oracle price
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    // taken from wormhole/ethereum/contracts/bridge/BridgeStructs.sol
    struct TransferResult {
        // Chain ID of the token
        uint16  tokenChain;
        // Address of the token. Left-zero-padded if shorter than 32 bytes
        bytes32 tokenAddress;
        // Amount being transferred (big-endian uint256)
        uint256 normalizedAmount;
        // Amount of tokens (big-endian uint256) that the user is willing to pay as relayer fee. Must be <= Amount.
        uint256 normalizedArbiterFee;
        // Portion of msg.value to be paid as the core bridge fee
        uint wormholeFee;
    }
}
