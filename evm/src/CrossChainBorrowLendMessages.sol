// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "./libraries/external/BytesLib.sol";

import "./CrossChainBorrowLendStructs.sol";

contract CrossChainBorrowLendMessages {
    using BytesLib for bytes;

    function encodeMessageHeader(MessageHeader memory header)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                header.borrower,
                header.collateralAddress,
                header.borrowAddress
            );
    }

    function encodeBorrowMessage(BorrowMessage memory message)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                uint8(1), // payloadID
                encodeMessageHeader(message.header),
                message.borrowAmount,
                message.totalNormalizedBorrowAmount,
                message.interestAccrualIndex
            );
    }

    function encodeRevertBorrowMessage(RevertBorrowMessage memory message)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                uint8(2), // payloadID
                encodeMessageHeader(message.header),
                message.borrowAmount,
                message.sourceInterestAccrualIndex
            );
    }

    function encodeRepayMessage(RepayMessage memory message)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                uint8(3), // payloadID
                encodeMessageHeader(message.header),
                message.repayAmount,
                message.targetInterestAccrualIndex,
                message.repayTimestamp,
                message.paidInFull
            );
    }

    function encodeLiquidationIntentMessage(
        LiquidationIntentMessage memory message
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                uint8(4), // payloadID
                encodeMessageHeader(message.header)
            );
    }

    function decodeMessageHeader(bytes memory serialized)
        internal
        pure
        returns (MessageHeader memory header)
    {
        uint256 index = 0;

        // parse the header
        header.payloadID = serialized.toUint8(index += 1);
        header.borrower = serialized.toAddress(index += 20);
        header.collateralAddress = serialized.toAddress(index += 20);
        header.borrowAddress = serialized.toAddress(index += 20);
    }

    function decodeBorrowMessage(bytes memory serialized)
        internal
        pure
        returns (BorrowMessage memory params)
    {
        uint256 index = 0;

        // parse the message header
        params.header = decodeMessageHeader(
            serialized.slice(index, index += 61)
        );
        params.borrowAmount = serialized.toUint256(index += 32);
        params.totalNormalizedBorrowAmount = serialized.toUint256(index += 32);
        params.interestAccrualIndex = serialized.toUint256(index += 32);

        require(params.header.payloadID == 1, "invalid message");
        require(index == serialized.length, "index != serialized.length");
    }

    function decodeRevertBorrowMessage(bytes memory serialized)
        internal
        pure
        returns (RevertBorrowMessage memory params)
    {
        uint256 index = 0;

        // parse the message header
        params.header = decodeMessageHeader(
            serialized.slice(index, index += 61)
        );
        params.borrowAmount = serialized.toUint256(index += 32);
        params.sourceInterestAccrualIndex = serialized.toUint256(index += 32);

        require(params.header.payloadID == 2, "invalid message");
        require(index == serialized.length, "index != serialized.length");
    }

    function decodeRepayMessage(bytes memory serialized)
        internal
        pure
        returns (RepayMessage memory params)
    {
        uint256 index = 0;

        // parse the message header
        params.header = decodeMessageHeader(
            serialized.slice(index, index += 61)
        );
        params.repayAmount = serialized.toUint256(index += 32);
        params.targetInterestAccrualIndex = serialized.toUint256(index += 32);
        params.repayTimestamp = serialized.toUint256(index += 32);
        params.paidInFull = serialized.toUint8(index += 1);

        require(params.header.payloadID == 3, "invalid message");
        require(index == serialized.length, "index != serialized.length");
    }

    function decodeLiquidationIntentMessage(bytes memory serialized)
        internal
        pure
        returns (LiquidationIntentMessage memory params)
    {
        uint256 index = 0;

        // parse the message header
        params.header = decodeMessageHeader(
            serialized.slice(index, index += 61)
        );

        // TODO: deserialize the LiquidationIntentMessage when implemented

        require(params.header.payloadID == 4, "invalid message");
        require(index == serialized.length, "index != serialized.length");
    }
}
