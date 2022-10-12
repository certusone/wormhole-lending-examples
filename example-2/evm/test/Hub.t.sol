// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {Hub} from "../src/contracts/lendingHub/Hub.sol";
import {HubStructs} from "../src/contracts/lendingHub/HubStructs.sol";
import {HubMessages} from "../src/contracts/lendingHub/HubMessages.sol";
import {MyERC20} from "./helpers/MyERC20.sol";
// TODO: add wormhole interface and use fork-url w/ mainnet

contract HubTest is Test, HubStructs, HubMessages {
    MyERC20[] tokens;
    string[] tokenNames = ["BNB", "ETH", "USDC", "SOL", "AVAX"];
    Hub hub;
    function setUp() public {
        hub = new Hub(msg.sender, msg.sender, msg.sender, 1);
        
        for(uint8 i=0; i<tokenNames.length; i++) {
            tokens.push(new MyERC20(tokenNames[i], tokenNames[i], 18));
        }
    }

    function toString(address account) public pure returns(string memory) {
    return toString(abi.encodePacked(account));
}
function toString(bytes memory data) public pure returns(string memory) {
    bytes memory alphabet = "0123456789abcdef";

    bytes memory str = new bytes(2 + data.length * 2);
    str[0] = "0";
    str[1] = "x";
    for (uint i = 0; i < data.length; i++) {
        str[2+i*2] = alphabet[uint(uint8(data[i] >> 4))];
        str[3+i*2] = alphabet[uint(uint8(data[i] & 0x0f))];
    }
    return string(str);
}

    function testEncodeDepositMessage() public {
        MessageHeader memory header = MessageHeader({
            payloadID: 1,
            sender: address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF)
        });
        address[] memory assetAddresses = new address[](3);
        uint256[] memory assetAmounts = new uint256[](3);
        for(uint8 i=0; i<3; i++) {
            assetAddresses[i] = address(tokens[i]);
            assetAmounts[i] = 100;
        }
        DepositMessage memory myMsg = DepositMessage({
            header: header,
            assetAddresses: assetAddresses,
            assetAmounts: assetAmounts
        });
        bytes memory serialized = encodeDepositMessage(myMsg);
        DepositMessage memory encodedAndDecodedMsg = decodeDepositMessage(serialized);

        require(myMsg.header.payloadID == encodedAndDecodedMsg.header.payloadID, "payload ids do not match");
        require(myMsg.header.sender == encodedAndDecodedMsg.header.sender, "sender addresses do not match");
        require(myMsg.assetAddresses.length == encodedAndDecodedMsg.assetAddresses.length, "asset addresses array length does not match ");
        for(uint8 i=0; i<myMsg.assetAddresses.length; i++) {
            require(myMsg.assetAddresses[i] == encodedAndDecodedMsg.assetAddresses[i], "asset addresses array differ at an index");
        }
        require(myMsg.assetAmounts.length == encodedAndDecodedMsg.assetAmounts.length, "asset amounts array length does not match");
        for(uint8 i=0; i<myMsg.assetAmounts.length; i++) {
            require(myMsg.assetAmounts[i] == encodedAndDecodedMsg.assetAmounts[i], "asset amounts array differ at an index");
        }

    }
    
}
