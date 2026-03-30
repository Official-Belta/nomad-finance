// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICoreWriter} from "../interfaces/hypercore/ICoreWriter.sol";

/// @title DeltaHedger
/// @notice Delta hedging via HyperCore perpetuals
/// @dev Reads prices via precompiles, places perp orders via CoreWriter
contract DeltaHedger is Ownable {
    ICoreWriter public constant CORE_WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);

    address public constant ORACLE_PX = address(0x0803);
    address public constant MARK_PX = address(0x0804);

    struct HedgePosition {
        uint32 asset;
        int256 size;            // Positive = long, negative = short
        uint256 entryPrice;
        uint256 timestamp;
    }

    mapping(bytes32 => HedgePosition) public hedgePositions;
    bytes32[] public activePositionIds;

    int256 public targetDelta;
    uint256 public hedgeThreshold;  // Min delta deviation before rehedge (bps)

    event HedgeOpened(bytes32 indexed id, uint32 asset, int256 size, uint256 price);
    event HedgeClosed(bytes32 indexed id, int256 pnl);
    event HedgeAdjusted(bytes32 indexed id, int256 oldSize, int256 newSize);

    constructor(address owner_) Ownable(owner_) {
        hedgeThreshold = 500; // 5%
    }

    function netDelta() external view returns (int256 delta) {
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            delta += hedgePositions[activePositionIds[i]].size;
        }
    }

    /// @notice Open a hedge position on HyperCore
    function openHedge(uint32 asset, int256 size, uint64 limitPrice) external onlyOwner returns (bytes32 id) {
        id = keccak256(abi.encodePacked(asset, size, block.timestamp, msg.sender));

        bool isBuy = size > 0;
        uint64 absSize = uint64(size > 0 ? uint256(int256(size)) : uint256(-int256(size)));

        bytes memory action = abi.encodePacked(
            uint8(1),           // action: limit order
            asset,
            isBuy,
            limitPrice,
            absSize,
            false,              // reduceOnly
            uint8(2)            // TIF: IOC
        );
        CORE_WRITER.sendRawAction(action);

        hedgePositions[id] = HedgePosition({
            asset: asset,
            size: size,
            entryPrice: uint256(limitPrice),
            timestamp: block.timestamp
        });
        activePositionIds.push(id);

        emit HedgeOpened(id, asset, size, uint256(limitPrice));
    }

    /// @notice Close a hedge position with PnL tracking
    function closeHedge(bytes32 id) external onlyOwner {
        HedgePosition storage pos = hedgePositions[id];
        require(pos.timestamp > 0, "Position not found");

        bool isBuy = pos.size < 0;
        uint64 absSize = uint64(pos.size > 0 ? uint256(int256(pos.size)) : uint256(-int256(pos.size)));

        // Get current mark price from precompile
        uint256 markPrice = _getMarkPrice(pos.asset);
        uint64 closePrice = markPrice > 0 ? uint64(markPrice) : uint64(0);

        bytes memory action = abi.encodePacked(
            uint8(1),
            pos.asset,
            isBuy,
            closePrice,
            absSize,
            true,               // reduceOnly
            uint8(2)            // IOC
        );
        CORE_WRITER.sendRawAction(action);

        // Calculate PnL
        int256 pnl = _calcPnl(pos.size, pos.entryPrice, markPrice > 0 ? markPrice : pos.entryPrice);

        _removePosition(id);
        emit HedgeClosed(id, pnl);
    }

    /// @notice Adjust an existing hedge (partial close/extend)
    function adjustHedge(bytes32 id, int256 newSize, uint64 limitPrice) external onlyOwner {
        HedgePosition storage pos = hedgePositions[id];
        require(pos.timestamp > 0, "Position not found");

        int256 sizeDiff = newSize - pos.size;
        if (sizeDiff == 0) return;

        bool isBuy = sizeDiff > 0;
        uint64 absSize = uint64(sizeDiff > 0 ? uint256(sizeDiff) : uint256(-sizeDiff));

        bytes memory action = abi.encodePacked(
            uint8(1),
            pos.asset,
            isBuy,
            limitPrice,
            absSize,
            false,
            uint8(2)
        );
        CORE_WRITER.sendRawAction(action);

        emit HedgeAdjusted(id, pos.size, newSize);
        pos.size = newSize;
    }

    /// @notice Emergency close all hedges
    function emergencyCloseAll() external onlyOwner {
        for (uint256 i = activePositionIds.length; i > 0; i--) {
            bytes32 id = activePositionIds[i - 1];
            HedgePosition storage pos = hedgePositions[id];

            bool isBuy = pos.size < 0;
            uint64 absSize = uint64(pos.size > 0 ? uint256(int256(pos.size)) : uint256(-int256(pos.size)));

            bytes memory action = abi.encodePacked(uint8(1), pos.asset, isBuy, uint64(0), absSize, true, uint8(2));
            CORE_WRITER.sendRawAction(action);

            delete hedgePositions[id];
        }
        delete activePositionIds;
    }

    /// @notice Get the number of active positions
    function activePositionCount() external view returns (uint256) {
        return activePositionIds.length;
    }

    function setHedgeThreshold(uint256 newThreshold) external onlyOwner {
        hedgeThreshold = newThreshold;
    }

    // --- Internal ---

    /// @dev Get mark price from HyperCore precompile (0x0804)
    function _getMarkPrice(uint32 asset) internal view returns (uint256) {
        (bool ok, bytes memory data) = MARK_PX.staticcall(abi.encodePacked(asset));
        if (ok && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return 0; // fallback: 0 means unavailable
    }

    /// @dev Calculate PnL for a hedge position
    /// @param size Position size (positive=long, negative=short)
    /// @param entryPrice Entry price
    /// @param exitPrice Exit price
    function _calcPnl(int256 size, uint256 entryPrice, uint256 exitPrice) internal pure returns (int256) {
        // PnL = size * (exitPrice - entryPrice) / entryPrice
        if (entryPrice == 0) return 0;
        int256 priceDiff = int256(exitPrice) - int256(entryPrice);
        return (size * priceDiff) / int256(entryPrice);
    }

    function _removePosition(bytes32 id) internal {
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            if (activePositionIds[i] == id) {
                activePositionIds[i] = activePositionIds[activePositionIds.length - 1];
                activePositionIds.pop();
                delete hedgePositions[id];
                break;
            }
        }
    }
}
