// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../interfaces/IWormhole.sol";
import "forge-std/console.sol";

import "./SpokeSetters.sol";
import "../lendingHub/HubStructs.sol";
import "../lendingHub/HubMessages.sol";
import "./SpokeGetters.sol";
import "./SpokeUtilities.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Spoke is HubStructs, HubMessages, SpokeGetters, SpokeSetters, SpokeUtilities {
    constructor(uint16 chainId_, address wormhole_, address tokenBridge_, uint16 hubChainId_, address hubContractAddress) {
        setOwner(_msgSender());
        setChainId(chainId_);
        setWormhole(wormhole_);
        setTokenBridge(tokenBridge_);
        setHubChainId(hubChainId_);
        setHubContractAddress(hubContractAddress);
    }

    function depositCollateral(address assetAddress, uint256 assetAmount) public returns (uint64 sequence) {
        sequence = doAction(Action.Deposit, assetAddress, assetAmount);
    }

    function withdrawCollateral(address assetAddress, uint256 assetAmount) public returns (uint64 sequence) {
        sequence = doAction(Action.Withdraw, assetAddress, assetAmount);
    }

    function borrow(address assetAddress, uint256 assetAmount) public returns (uint64 sequence) {
        sequence = doAction(Action.Borrow, assetAddress, assetAmount);
    }

    function repay(address assetAddress, uint256 assetAmount) public returns (uint64 sequence) {
        sequence = doAction(Action.Repay, assetAddress, assetAmount);
    }

    function depositCollateralNative() public payable returns (uint64 sequence) {
        sequence = doAction(Action.DepositNative, address(tokenBridge().WETH()), msg.value - wormhole().messageFee());
    }

    function repayNative() public payable returns (uint64 sequence) {
        sequence = doAction(Action.RepayNative, address(tokenBridge().WETH()), msg.value - wormhole().messageFee());
    }

    function doAction(Action action, address assetAddress, uint256 assetAmount) internal returns (uint64 sequence) {
        requireAssetAmountValidForTokenBridge(assetAddress, assetAmount);
        Action hubAction = action;
        if (action == Action.DepositNative) {
            hubAction = Action.Deposit;
        }
        if (action == Action.RepayNative) {
            hubAction = Action.Repay;
        }

        ActionPayload memory payload = ActionPayload({
            action: hubAction,
            sender: msg.sender,
            assetAddress: assetAddress,
            assetAmount: assetAmount
        });

        bytes memory serialized = encodeActionPayload(payload);

        if(action == Action.Deposit || action == Action.Repay) {
            sequence = sendTokenBridgeMessage(assetAddress, assetAmount, serialized);
        } else if(action == Action.Withdraw || action == Action.Borrow) {
            sequence = sendWormholeMessage(serialized);
        } else if(action == Action.DepositNative || action == Action.RepayNative)  {
            sequence = sendTokenBridgeMessageNative(assetAmount + wormhole().messageFee(), serialized); 
        }
    }
}