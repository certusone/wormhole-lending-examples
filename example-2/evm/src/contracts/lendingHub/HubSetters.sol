// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./HubState.sol";
import "../HubSpokeStructs.sol";
import "./HubGetters.sol";

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

contract HubSetters is HubSpokeStructs, HubState, HubGetters {
    function setChainId(uint16 chainId) internal {
        _state.provider.chainId = chainId;
    }

    function setWormhole(address wormholeAddress) internal {
        _state.provider.wormhole = payable(wormholeAddress);
    }

    function setTokenBridge(address tokenBridgeAddress) internal {
        _state.provider.tokenBridge = tokenBridgeAddress;
    }

    function setPyth(address pythAddress) internal {
        _state.provider.pyth = IPyth(pythAddress);
    }

    function setOracleMode(uint8 oracleMode) internal {
        _state.oracleMode = oracleMode;
    }

    function setConsistencyLevel(uint8 consistencyLevel) internal {
        _state.consistencyLevel = consistencyLevel;
    }

    function registerSpokeContract(uint16 chainId, address spokeContractAddress) internal {
        _state.spokeContracts[chainId] = spokeContractAddress;
    }

    function registerAssetInfo(address assetAddress, AssetInfo memory info) internal {
        _state.assetInfos[assetAddress] = info;

        AccrualIndices memory accrualIndices;
        accrualIndices.deposited = 1 * getInterestAccrualIndexPrecision();
        accrualIndices.borrowed = 1 * getInterestAccrualIndexPrecision();
        accrualIndices.lastBlock = block.timestamp;

        setInterestAccrualIndices(assetAddress, accrualIndices);

        // set the max decimals to max of current max and new asset decimals
        uint8 currentMaxDecimals = getMaxDecimals();
        if (info.decimals > currentMaxDecimals) {
            setMaxDecimals(info.decimals);
        }
    }

    function consumeMessageHash(bytes32 vmHash) internal {
        _state.consumedMessages[vmHash] = true;
    }

    function allowAsset(address assetAddress) internal {
        _state.allowList.push(assetAddress);
    }

    function setLastActivityBlockTimestamp(address assetAddress, uint256 blockTimestamp) internal {
        _state.lastActivityBlockTimestamps[assetAddress] = blockTimestamp;
    }

    function setInterestAccrualIndices(address assetAddress, AccrualIndices memory indices) internal {
        _state.indices[assetAddress] = indices;
    }

    function setInterestAccrualIndexPrecision(uint256 interestAccrualIndexPrecision) internal {
        _state.interestAccrualIndexPrecision = interestAccrualIndexPrecision;
    }

    function setCollateralizationRatioPrecision(uint256 collateralizationRatioPrecision) internal {
        _state.collateralizationRatioPrecision = collateralizationRatioPrecision;
    }

    function setMaxDecimals(uint8 maxDecimals) internal {
        _state.MAX_DECIMALS = maxDecimals;
    }

    function setMaxLiquidationBonus(uint256 maxLiquidationBonus) internal {
        _state.maxLiquidationBonus = maxLiquidationBonus;
    }

    function setVaultAmounts(address vaultOwner, address assetAddress, VaultAmount memory vaultAmount) internal {
        _state.vault[vaultOwner][assetAddress] = vaultAmount;
    }

    function setGlobalAmounts(address assetAddress, VaultAmount memory vaultAmount) internal {
        _state.totalAssets[assetAddress] = vaultAmount;
    }

    function setMaxLiquidationPortion(uint256 maxLiquidationPortion) internal {
        _state.maxLiquidationPortion = maxLiquidationPortion;
    }

    function setMaxLiquidationPortionPrecision(uint256 maxLiquidationPortionPrecision) internal {
        _state.maxLiquidationPortionPrecision = maxLiquidationPortionPrecision;
    }

    function setMockPyth(uint256 validTimePeriod, uint256 singleUpdateFeeInWei) internal {
        _state.provider.mockPyth = new MockPyth(validTimePeriod, singleUpdateFeeInWei);
    }

    function setPriceStandardDeviations(uint64 priceStandardDeviations) internal {
        _state.priceStandardDeviations = priceStandardDeviations;
    }

    function setPricePrecision(uint64 pricePrecision) internal {
        _state.pricePrecision = pricePrecision;
    }

    function setOraclePrice(bytes32 oracleId, Price memory price) public onlyOwner {
        _state.oracle[oracleId] = price;
    }

    function setMockPythFeed(
        bytes32 id,
        int64 price,
        uint64 conf,
        int32 expo,
        int64 emaPrice,
        uint64 emaConf,
        uint64 publishTime
    ) public onlyOwner {
        bytes memory priceFeedData =
            _state.provider.mockPyth.createPriceFeedUpdateData(id, price, conf, expo, emaPrice, emaConf, publishTime);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = priceFeedData;
        _state.provider.mockPyth.updatePriceFeeds(updateData);
    }
}
