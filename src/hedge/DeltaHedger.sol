// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICoreWriter} from "../interfaces/hypercore/ICoreWriter.sol";

/// @title DeltaHedger
/// @notice Delta hedging via HyperCore perpetuals
/// @dev Reads prices via precompiles, places perp orders via CoreWriter
contract DeltaHedger is Ownable {
    // HyperCore CoreWriter at fixed address
    ICoreWriter public constant CORE_WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);

    // Precompile addresses for price queries
    address public constant ORACLE_PX = address(0x0803);
    address public constant MARK_PX = address(0x0804);

    struct HedgePosition {
        uint32 asset;           // HyperCore asset ID
        int256 size;            // Positive = long, negative = short
        uint256 entryPrice;
        uint256 timestamp;
    }

    mapping(bytes32 => HedgePosition) public hedgePositions;
    bytes32[] public activePositionIds;

    int256 public targetDelta;      // Target portfolio delta (should be ~0)
    uint256 public hedgeThreshold;  // Min delta deviation before rehedge (bps)

    event HedgeOpened(bytes32 indexed id, uint32 asset, int256 size, uint256 price);
    event HedgeClosed(bytes32 indexed id, int256 pnl);
    event HedgeAdjusted(bytes32 indexed id, int256 oldSize, int256 newSize);

    constructor(address owner_) Ownable(owner_) {
        hedgeThreshold = 500; // 5% delta deviation triggers rehedge
    }

    /// @notice Get current net delta across all hedge positions
    function netDelta() external view returns (int256 delta) {
        for (uint256 i = 0; i < activePositionIds.length; i++) {
            delta += hedgePositions[activePositionIds[i]].size;
        }
    }

    /// @notice Open a hedge position on HyperCore
    /// @param asset HyperCore asset ID
    /// @param size Position size (negative for short)
    /// @param limitPrice Limit price for the order
    function openHedge(uint32 asset, int256 size, uint64 limitPrice) external onlyOwner returns (bytes32 id) {
        id = keccak256(abi.encodePacked(asset, size, block.timestamp, msg.sender));

        bool isBuy = size > 0;
        uint64 absSize = uint64(size > 0 ? uint256(int256(size)) : uint256(-int256(size)));

        // Place limit order via CoreWriter
        // Action code 1 = limit order
        bytes memory action = abi.encodePacked(
            uint8(1),           // action: limit order
            asset,              // asset ID
            isBuy,              // direction
            limitPrice,         // price
            absSize,            // size
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

    /// @notice Close a hedge position
    function closeHedge(bytes32 id) external onlyOwner {
        HedgePosition storage pos = hedgePositions[id];
        require(pos.timestamp > 0, "Position not found");

        // Place opposite order to close
        bool isBuy = pos.size < 0; // close short = buy, close long = sell
        uint64 absSize = uint64(pos.size > 0 ? uint256(int256(pos.size)) : uint256(-int256(pos.size)));

        bytes memory action = abi.encodePacked(
            uint8(1),
            pos.asset,
            isBuy,
            uint64(0),      // market price (TODO: get from precompile)
            absSize,
            true,           // reduceOnly = true
            uint8(2)        // IOC
        );
        CORE_WRITER.sendRawAction(action);

        // Remove from active positions
        _removePosition(id);
        emit HedgeClosed(id, 0); // TODO: calculate actual PnL
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

    function setHedgeThreshold(uint256 newThreshold) external onlyOwner {
        hedgeThreshold = newThreshold;
    }

    // --- Internal ---

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
