// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../interfaces/IWormhole.sol";

import "forge-std/console.sol";

import "./HubSetters.sol";
import "./HubStructs.sol";
import "./HubMessages.sol";
import "./HubGetters.sol";
import "./HubUtilities.sol"; 

contract Hub is HubStructs, HubMessages, HubGetters, HubSetters, HubUtilities {
    constructor(address wormhole_, address tokenBridge_, address mockPythAddress_, uint8 consistencyLevel_, uint256 interestAccrualIndexPrecision_, uint256 collateralizationRatioPrecision_, uint8 initialMaxDecimals) {
        setOwner(_msgSender());
        setWormhole(wormhole_);
        setTokenBridge(tokenBridge_);
        setPyth(mockPythAddress_);
        setMaxDecimals(initialMaxDecimals);
        setConsistencyLevel(consistencyLevel_);
        setInterestAccrualIndexPrecision(interestAccrualIndexPrecision_);
        setCollateralizationRatioPrecision(collateralizationRatioPrecision_);
    }

    /**
    * Registers asset on the hub. Only registered assets are allowed to be stored in the protocol.
    *
    * @param assetAddress - The address to be checked
    * @param collateralizationRatio - The constant c multiplied by collateralizationRatioPrecision, 
    * where c is such that we allow users to borrow $1 worth of any assets against $c worth of this asset 
    * (according to Pyth prices) 
    * @param reserveFactor - TODO: Explain what this is
    * @param pythId - Id of the relevant Pyth price feed (USD <-> asset) TODO: Make this explanation more precise
    * @param decimals - Precision that the asset amount is stored in TODO: Make this explanation more precise
    * @return sequence The sequence number of the wormhole message documenting the registration of the asset
    */ 
    function registerAsset(
        address assetAddress,
        uint256 collateralizationRatio,
        uint256 reserveFactor,
        bytes32 pythId,
        uint8 decimals
    ) public returns (uint64 sequence) {
        require(msg.sender == owner(), "invalid owner");

        AssetInfo memory registered_info = getAssetInfo(assetAddress);
        require(!registered_info.exists, "Asset already registered");

        allowAsset(assetAddress);

        AssetInfo memory info = AssetInfo({
            collateralizationRatio: collateralizationRatio,
            reserveFactor: reserveFactor,
            pythId: pythId,
            decimals: decimals,
            exists: true
        });

        registerAssetInfo(assetAddress, info);

        PayloadHeader memory payloadHeader = PayloadHeader({
            payloadID: 5,
            sender: address(this)
        });

        RegisterAssetMessage memory registerAssetMessage = RegisterAssetMessage({
            header: payloadHeader,
            assetAddress: assetAddress,
            collateralizationRatio: collateralizationRatio,
            reserveFactor: reserveFactor,
            pythId: pythId,
            decimals: decimals
        });

        // create WH message
        bytes memory serialized = encodeRegisterAssetMessage(registerAssetMessage);

        sequence = sendWormholeMessage(serialized);
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

    /**
    * Completes a deposit that was initiated on a spoke
    *
    * @param encodedMessage - Encoded token bridge VAA (payload3) with the tokens deposited and deposit information
    */ 
    function completeDeposit(bytes memory encodedMessage) public { // calldata encodedMessage

        // encodedMessage is WH full msg, returns token bridge transfer msg
        bytes memory vmPayload = getTransferPayload(encodedMessage);

        bytes memory serialized = extractSerializedFromTransferWithPayload(vmPayload);

        DepositPayload memory params = decodeDepositPayload(serialized);

        deposit(params.header.sender, params.assetAddress, params.assetAmount);
    }

    /**
    * Completes a withdraw that was initiated on a spoke
    *
    * @param encodedMessage - Encoded VAA with the withdraw information
    */
    function completeWithdraw(bytes calldata encodedMessage) public {

        WithdrawPayload memory params = decodeWithdrawPayload(getWormholePayload(encodedMessage));

        withdraw(params.header.sender, params.assetAddress, params.assetAmount);
    }

    /**
    * Completes a borrow that was initiated on a spoke
    *
    * @param encodedMessage - Encoded VAA with the borrow information
    */
    function completeBorrow(bytes calldata encodedMessage) public {

        // encodedMessage is WH full msg, returns arbitrary bytes
        BorrowPayload memory params = decodeBorrowPayload(getWormholePayload(encodedMessage));

        borrow(params.header.sender, params.assetAddress, params.assetAmount);
    }

    /**
    * Completes a repay that was initiated on a spoke
    *
    * @param encodedMessage - Encoded token bridge VAA (payload3) with the repayed tokens and repay information
    */
    function completeRepay(bytes calldata encodedMessage) public {

        // encodedMessage is Token Bridge payload 3 full msg
        bytes memory vmPayload = getTransferPayload(encodedMessage);

        bytes memory serialized = extractSerializedFromTransferWithPayload(vmPayload);

        RepayPayload memory params = decodeRepayPayload(serialized);
        
        repay(params.header.sender, params.assetAddress, params.assetAmount);
    }

    /**
    * Updates vault amounts for a deposit from depositor of the asset at 'assetAddress' and amount 'amount'
    *
    * @param depositor - the address of the depositor
    * @param assetAddress - the address of the asset 
    * @param amount - the amount of the asset
    */
    function deposit(address depositor, address assetAddress, uint256 amount) internal {
        // TODO: What to do if this fails?
        
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
    function withdraw(address withdrawer, address assetAddress, uint256 amount) internal {
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

        transferTokens(withdrawer, assetAddress, amount);
    }

    /**
    * Updates vault amounts for a borrow from borrower of the asset at 'assetAddress' and amount 'amount'
    *
    * @param borrower - the address of the borrower
    * @param assetAddress - the address of the asset 
    * @param amount - the amount of the asset
    */
    function borrow(address borrower, address assetAddress, uint256 amount) internal {
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

        // TODO: token transfers
        transferTokens(borrower, assetAddress, amount);
    }

    /**
    * Updates vault amounts for a repay from repayer of the asset at 'assetAddress' and amount 'amount'
    *
    * @param repayer - the address of the repayer
    * @param assetAddress - the address of the asset 
    * @param amount - the amount of the asset
    */
    function repay(address repayer, address assetAddress, uint256 amount) internal {
        checkValidAddress(assetAddress);

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
    function liquidation(address vault, address[] memory assetRepayAddresses, uint256[] memory assetRepayAmounts, address[] memory assetReceiptAddresses, uint256[] memory assetReceiptAmounts) public {
        // check if asset addresses all valid
        // TODO: eventually check all addresses in one function checkValidAddresses that checks for no duplicates also
        for(uint i=0; i<assetRepayAddresses.length; i++){
            checkValidAddress(assetRepayAddresses[i]);
        }
        for(uint i=0; i<assetReceiptAddresses.length; i++){
            checkValidAddress(assetReceiptAddresses[i]);
        }

        // update the interest accrual indices
        // TODO: Make more efficient
        address[] memory allowList = getAllowList();
        for(uint i=0; i<allowList.length; i++){
            updateAccrualIndices(allowList[i]);
        }

        // check if intended liquidation is valid
        require(allowedToLiquidate(vault, assetRepayAddresses, assetRepayAmounts, assetReceiptAddresses, assetReceiptAmounts), "Liquidation attempt not allowed");

        // for repay assets update amounts for vault and global
        for(uint i=0; i<assetRepayAddresses.length; i++){
            address assetAddress = assetRepayAddresses[i];
            uint256 assetAmount = assetRepayAmounts[i];

            AccrualIndices memory indices = getInterestAccrualIndices(assetAddress);

            uint256 normalizedAmount = normalizeAmount(assetAmount, indices.borrowed);
            // update state for vault
            VaultAmount memory vaultAmounts = getVaultAmounts(vault, assetAddress);
            // require that amount paid back <= amount borrowed
            uint256 denormalizedBorrowedAmount = denormalizeAmount(vaultAmounts.borrowed, indices.borrowed);
            require(denormalizedBorrowedAmount >= assetAmount, "cannot repay more than has been borrowed");
            vaultAmounts.borrowed -= normalizedAmount;
            // update global state
            VaultAmount memory globalAmounts = getGlobalAmounts(assetAddress);
            globalAmounts.borrowed -= normalizedAmount;

            setVaultAmounts(vault, assetAddress, vaultAmounts);
            setGlobalAmounts(assetAddress, globalAmounts);
        }

        // for received assets update amounts for vault and global
        for (uint256 i=0; i<assetReceiptAddresses.length; i++) {
            address assetAddress = assetReceiptAddresses[i];
            uint256 assetAmount = assetReceiptAmounts[i];

            AccrualIndices memory indices = getInterestAccrualIndices(assetAddress);

            uint256 normalizedAmount = normalizeAmount(assetAmount, indices.deposited);
            // update state for vault
            VaultAmount memory vaultAmounts = getVaultAmounts(vault, assetAddress);
            // require that amount received <= amount deposited
            uint256 denormalizedDepositedAmount = denormalizeAmount(vaultAmounts.deposited, indices.deposited);
            require(denormalizedDepositedAmount >= assetAmount, "cannot take out more collateral than vault has deposited");
            vaultAmounts.deposited -= normalizedAmount;
            // update global state
            VaultAmount memory globalAmounts = getGlobalAmounts(assetAddress);
            globalAmounts.deposited -= normalizedAmount;

            setVaultAmounts(vault, assetAddress, vaultAmounts);
            setGlobalAmounts(assetAddress, globalAmounts);
        }

        // send repay tokens from liquidator to contract
        for(uint i=0; i<assetRepayAddresses.length; i++){
            address assetAddress = assetRepayAddresses[i];
            uint256 assetAmount = assetRepayAmounts[i];

            SafeERC20.safeTransferFrom(
                IERC20(assetAddress),
                msg.sender,
                address(this),
                assetAmount
            );
        }

        // send receive tokens from contract to liquidator
        for(uint i=0; i<assetReceiptAddresses.length; i++){
            address assetAddress = assetReceiptAddresses[i];
            uint256 assetAmount = assetReceiptAmounts[i];

            SafeERC20.safeTransferFrom(
                IERC20(assetAddress),
                address(this),
                msg.sender,
                assetAmount
            );
        }
    }
}
