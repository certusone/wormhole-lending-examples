// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

import "../../interfaces/IWormhole.sol";

import "forge-std/console.sol";

import "./HubSetters.sol";
import "./HubStructs.sol";
import "./HubMessages.sol";
import "./HubGetters.sol";
import "./HubUtilities.sol";

contract Hub is HubStructs, HubMessages, HubGetters, HubSetters, HubUtilities {
    constructor(
        address wormhole_,
        address tokenBridge_,
        address pythAddress_,
        uint8 oracleMode_,
        uint8 consistencyLevel_,
        uint256 interestAccrualIndexPrecision_,
        uint256 collateralizationRatioPrecision_,
        uint8 initialMaxDecimals_,
        uint256 maxLiquidationBonus_,
        uint256 maxLiquidationPortion_,
        uint256 maxLiquidationPortionPrecision_,
        uint64 nConf_,
        uint64 nConfPrecision_
    ) {
        setOwner(_msgSender());
        setWormhole(wormhole_);
        setTokenBridge(tokenBridge_);
        setPyth(pythAddress_);
        setOracleMode(oracleMode_);
        setMaxDecimals(initialMaxDecimals_);
        setConsistencyLevel(consistencyLevel_);
        setInterestAccrualIndexPrecision(interestAccrualIndexPrecision_);
        setCollateralizationRatioPrecision(collateralizationRatioPrecision_);
        setMaxLiquidationBonus(maxLiquidationBonus_); // use the precision of the collateralization ratio
        setMaxLiquidationPortion(maxLiquidationPortion_);
        setMaxLiquidationPortionPrecision(maxLiquidationPortionPrecision_);

        uint256 validTimePeriod = 60 * (10 ** 18);
        uint256 singleUpdateFeeInWei = 0;
        setMockPyth(validTimePeriod, singleUpdateFeeInWei);

        setNConf(nConf_, nConfPrecision_);
    }

    /**
     * Registers asset on the hub. Only registered assets are allowed to be stored in the protocol.
     *
     * @param assetAddress - The address to be checked
     * @param collateralizationRatioDeposit - The constant c divided by collateralizationRatioPrecision,
     * where c is such that we account $1 worth of effective deposits per actual $c worth of this asset deposited
     * @param collateralizationRatioBorrow - The constant c divided by collateralizationRatioPrecision,
     * where c is such that for every $1 worth of effective deposits we allow $c worth of this asset borrowed
     * (according to Pyth prices)
     * @param reserveFactor - The portion of the paid interest by borrowers that is diverted to the protocol for rainy day,
     * the remainder is distributed among lenders of the asset
     * @param pythId - Id of the relevant oracle price feed (USD <-> asset) TODO: Make this explanation more precise
     * @param decimals - Precision that the asset amount is stored in TODO: Make this explanation more precise
     */
    function registerAsset(
        address assetAddress,
        uint256 collateralizationRatioDeposit,
        uint256 collateralizationRatioBorrow,
        uint64 ratePrecision,
        uint64 rateIntercept,
        uint64 rateCoefficientA,
        uint256 reserveFactor,
        uint256 reservePrecision,
        bytes32 pythId,
        uint8 decimals
    ) public {
        require(msg.sender == owner(), "invalid owner");

        AssetInfo memory registeredInfo = getAssetInfo(assetAddress);
        require(!registeredInfo.exists, "Asset already registered");

        allowAsset(assetAddress);

        InterestRateModel memory interestRateModel = InterestRateModel({
            ratePrecision: ratePrecision,
            rateIntercept: rateIntercept,
            rateCoefficientA: rateCoefficientA,
            reserveFactor: reserveFactor,
            reservePrecision: reservePrecision
        });

        AssetInfo memory info = AssetInfo({
            collateralizationRatioDeposit: collateralizationRatioDeposit,
            collateralizationRatioBorrow: collateralizationRatioBorrow,
            pythId: pythId,
            decimals: decimals,
            interestRateModel: interestRateModel,
            exists: true
        });

        registerAssetInfo(assetAddress, info);
    }

    /**
     * Registers a spoke contract. Only wormhole messages from registered spoke contracts are allowed.
     *
     * @param chainId - The chain id which the spoke is deployed on
     * @param spokeContractAddress - The address of the spoke contract on its chain
     */
    function registerSpoke(uint16 chainId, address spokeContractAddress) public {
        require(msg.sender == owner(), "invalid owner");
        registerSpokeContract(chainId, spokeContractAddress);
    }

    function completeDeposit(bytes memory encodedMessage) public {
        completeAction(encodedMessage, true);
    }

    function completeWithdraw(bytes memory encodedMessage) public {
        completeAction(encodedMessage, false);
    }

    function completeBorrow(bytes memory encodedMessage) public {
        completeAction(encodedMessage, false);
    }

    function completeRepay(bytes memory encodedMessage) public {
        completeAction(encodedMessage, true);
    }

     /**
     * Completes an action (deposit, borrow, withdraw, or repay) that was initiated on a spoke
     *
     * @param encodedMessage - Encoded wormhole VAA with a token bridge message as payload, which allows retrieval of the tokens from token bridge and has deposit information
     */
    function completeAction(bytes memory encodedMessage, bool isTokenBridgePayload) internal {
        
        bytes memory serialized;
        IWormhole.VM memory parsed = getWormholeParsed(encodedMessage);
        
        if(isTokenBridgePayload) {
            serialized = extractSerializedFromTransferWithPayload(getTransferPayload(encodedMessage));
        } else {
            verifySenderIsSpoke(parsed.emitterChainId, address(uint160(uint256(parsed.emitterAddress)))); 
            serialized = parsed.payload;
        }

        ActionPayload memory params = decodeActionPayload(serialized);
        Action action = Action(params.action);

        if(action == Action.Deposit) {
            deposit(params.sender, params.assetAddress, params.assetAmount);
        } else if(action == Action.Withdraw) {
            withdraw(params.sender, params.assetAddress, params.assetAmount, parsed.emitterChainId);
        } else if(action == Action.Borrow) {
            borrow(params.sender, params.assetAddress, params.assetAmount, parsed.emitterChainId);
        } else if(action == Action.Repay) {
            repay(params.sender, params.assetAddress, params.assetAmount, parsed.emitterChainId);
        } 
    }

    /**
    * Updates vault amounts for a deposit from depositor of the asset at 'assetAddress' and amount 'amount'
    *
    * @param depositor - the address of the depositor
    * @param assetAddress - the address of the asset 
    * @param amount - the amount of the asset
    */
    function deposit(address depositor, address assetAddress, uint256 amount) internal {        

        checkValidAddress(assetAddress);

        // update the interest accrual indices
        updateAccrualIndices(assetAddress);

        // calculate the normalized amount and store in the vault
        // update the global contract state with normalized amount
        VaultAmount memory vaultAmounts = getVaultAmounts(depositor, assetAddress);
        VaultAmount memory globalAmounts = getGlobalAmounts(assetAddress);

        AccrualIndices memory indices = getInterestAccrualIndices(assetAddress);

        uint256 normalizedDeposit = normalizeAmount(amount, indices.deposited);

        vaultAmounts.deposited += normalizedDeposit;
        globalAmounts.deposited += normalizedDeposit;

        setVaultAmounts(depositor, assetAddress, vaultAmounts);
        setGlobalAmounts(assetAddress, globalAmounts);
    }

    /**
     * Updates vault amounts for a withdraw from withdrawer of the asset at 'assetAddress' and amount 'amount'
     *
     * @param withdrawer - the address of the withdrawer
     * @param assetAddress - the address of the asset
     * @param amount - the amount of the asset
     */
    function withdraw(address withdrawer, address assetAddress, uint256 amount, uint16 recipientChain) internal {
        checkValidAddress(assetAddress);

        // recheck if withdraw is valid given up to date prices? bc the prices can move in the time for VAA to come
        (bool check1, bool check2, bool check3) = allowedToWithdraw(withdrawer, assetAddress, amount);
        require(check1, "Not enough in vault");
        require(check2, "Not enough in global supply");
        require(check3, "Vault is undercollateralized if this withdraw goes through");

        // update the interest accrual indices
        updateAccrualIndices(assetAddress);

        AccrualIndices memory indices = getInterestAccrualIndices(assetAddress);

        uint256 normalizedAmount = normalizeAmount(amount, indices.deposited);

        // update state for vault
        VaultAmount memory vaultAmounts = getVaultAmounts(withdrawer, assetAddress);
        vaultAmounts.deposited -= normalizedAmount;
        // update state for global
        VaultAmount memory globalAmounts = getGlobalAmounts(assetAddress);
        globalAmounts.deposited -= normalizedAmount;

        setVaultAmounts(withdrawer, assetAddress, vaultAmounts);
        setGlobalAmounts(assetAddress, globalAmounts);

        transferTokens(withdrawer, assetAddress, amount, recipientChain);
    }

    /**
     * Updates vault amounts for a borrow from borrower of the asset at 'assetAddress' and amount 'amount'
     *
     * @param borrower - the address of the borrower
     * @param assetAddress - the address of the asset
     * @param amount - the amount of the asset
     */
    function borrow(address borrower, address assetAddress, uint256 amount, uint16 recipientChain) internal {
        checkValidAddress(assetAddress);

        // recheck if borrow is valid given up to date prices? bc the prices can move in the time for VAA to come
        (bool check1, bool check2) = allowedToBorrow(borrower, assetAddress, amount);

        require(check1, "Not enough in global supply");
        require(check2, "Vault is undercollateralized if this borrow goes through");

        // update the interest accrual indices
        updateAccrualIndices(assetAddress);

        AccrualIndices memory indices = getInterestAccrualIndices(assetAddress);

        uint256 normalizedAmount = normalizeAmount(amount, indices.deposited);

        // update state for vault
        VaultAmount memory vaultAmounts = getVaultAmounts(borrower, assetAddress);
        vaultAmounts.borrowed += normalizedAmount;

        // update state for global
        VaultAmount memory globalAmounts = getGlobalAmounts(assetAddress);
        globalAmounts.borrowed += normalizedAmount;
        setVaultAmounts(borrower, assetAddress, vaultAmounts);
        setGlobalAmounts(assetAddress, globalAmounts);

        transferTokens(borrower, assetAddress, amount, recipientChain);
    }

    /**
    * Updates vault amounts for a repay from repayer of the asset at 'assetAddress' and amount 'amount'
    *
    * @param repayer - the address of the repayer
    * @param assetAddress - the address of the asset 
    * @param amount - the amount of the asset
    */
    function repay(address repayer, address assetAddress, uint256 amount, uint16 recipientChain) internal {
    
        checkValidAddress(assetAddress);

        bool check = allowedToRepay(repayer, assetAddress, amount);

        // handle revert--transfer tokens back to the repayer on their original chain
        if(!check){
            transferTokens(repayer, assetAddress, amount, recipientChain);
            return;
        }

        // update the interest accrual indices
        updateAccrualIndices(assetAddress);

        // calculate the normalized amount and store in the vault and global
        AccrualIndices memory indices = getInterestAccrualIndices(assetAddress);

        uint256 normalizedAmount = normalizeAmount(amount, indices.borrowed);
        // update state for vault
        VaultAmount memory vaultAmounts = getVaultAmounts(repayer, assetAddress);
        vaultAmounts.borrowed -= normalizedAmount;
        // update global state
        VaultAmount memory globalAmounts = getGlobalAmounts(assetAddress);
        globalAmounts.borrowed -= normalizedAmount;

        setVaultAmounts(repayer, assetAddress, vaultAmounts);
        setGlobalAmounts(assetAddress, globalAmounts);
    }

    /**
     * Liquidates a vault. The sender of this transaction pays, for each i, assetRepayAmount[i] of the asset assetRepayAddresses[i]
     * and receives, for each i, assetReceiptAmount[i] of the asset at assetReceiptAddresses[i].
     * A check is made to see if this liquidation attempt should be allowed
     *
     * @param vault - the address of the vault
     * @param assetRepayAddresses - An array of the addresses of the assets being paid by the liquidator
     * @param assetRepayAmounts - An array of the amounts of the assets being paid by the liquidator
     * @param assetReceiptAddresses - An array of the addresses of the assets being received by the liquidator
     * @param assetReceiptAmounts - An array of the amounts of the assets being received by the liquidator
     */
    function liquidation(
        address vault,
        address[] memory assetRepayAddresses,
        uint256[] memory assetRepayAmounts,
        address[] memory assetReceiptAddresses,
        uint256[] memory assetReceiptAmounts
    ) public {
        // check if inputs are valid
        checkLiquidationInputsValid(assetRepayAddresses, assetRepayAmounts, assetReceiptAddresses, assetReceiptAmounts);

        // check if intended liquidation is valid
        checkAllowedToLiquidate(vault, assetRepayAddresses, assetRepayAmounts, assetReceiptAddresses, assetReceiptAmounts);

        // update the interest accrual indices
        address[] memory allowList = getAllowList();
        for (uint256 i = 0; i < allowList.length; i++) {
            updateAccrualIndices(allowList[i]);
        }

        // for repay assets update amounts for vault and global
        for (uint256 i = 0; i < assetRepayAddresses.length; i++) {
            address assetAddress = assetRepayAddresses[i];
            uint256 assetAmount = assetRepayAmounts[i];

            AccrualIndices memory indices = getInterestAccrualIndices(assetAddress);

            uint256 normalizedAmount = normalizeAmount(assetAmount, indices.borrowed);
            // update state for vault
            VaultAmount memory vaultAmounts = getVaultAmounts(vault, assetAddress);
            vaultAmounts.borrowed -= normalizedAmount;

            // update global state
            VaultAmount memory globalAmounts = getGlobalAmounts(assetAddress);
            globalAmounts.borrowed -= normalizedAmount;

            setVaultAmounts(vault, assetAddress, vaultAmounts);
            setGlobalAmounts(assetAddress, globalAmounts);
        }

        // for received assets update amounts for vault and global
        for (uint256 i = 0; i < assetReceiptAddresses.length; i++) {
            address assetAddress = assetReceiptAddresses[i];
            uint256 assetAmount = assetReceiptAmounts[i];

            AccrualIndices memory indices = getInterestAccrualIndices(assetAddress);

            uint256 normalizedAmount = normalizeAmount(assetAmount, indices.deposited);
            // update state for vault
            VaultAmount memory vaultAmounts = getVaultAmounts(vault, assetAddress);

            vaultAmounts.deposited -= normalizedAmount;
            // update global state
            VaultAmount memory globalAmounts = getGlobalAmounts(assetAddress);
            globalAmounts.deposited -= normalizedAmount;

            setVaultAmounts(vault, assetAddress, vaultAmounts);
            setGlobalAmounts(assetAddress, globalAmounts);
        }

        // send repay tokens from liquidator to contract
        for (uint256 i = 0; i < assetRepayAddresses.length; i++) {
            SafeERC20.safeTransferFrom(IERC20(assetRepayAddresses[i]), msg.sender, address(this), assetRepayAmounts[i]);
        }
        // send receive tokens from contract to liquidator
        for (uint256 i = 0; i < assetReceiptAddresses.length; i++) {
            SafeERC20.safeTransfer(IERC20(assetReceiptAddresses[i]), msg.sender, assetReceiptAmounts[i]);
        }
    }
}
