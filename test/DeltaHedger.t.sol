// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeltaHedger} from "../src/hedge/DeltaHedger.sol";

/// @dev Mock CoreWriter that just accepts calls
contract MockCoreWriter {
    bytes public lastAction;

    function sendRawAction(bytes calldata data) external {
        lastAction = data;
    }
}

contract DeltaHedgerTest is Test {
    DeltaHedger public hedger;

    function setUp() public {
        hedger = new DeltaHedger(address(this));

        // Deploy a mock CoreWriter at the expected address
        MockCoreWriter mock = new MockCoreWriter();
        vm.etch(
            0x3333333333333333333333333333333333333333,
            address(mock).code
        );
    }

    function test_openHedge() public {
        bytes32 id = hedger.openHedge(1, 100, 3000);
        assertNotEq(id, bytes32(0));
        assertEq(hedger.activePositionCount(), 1);
    }

    function test_netDelta() public {
        hedger.openHedge(1, 100, 3000);  // long 100
        hedger.openHedge(1, -50, 3000);  // short 50

        assertEq(hedger.netDelta(), 50);
    }

    function test_closeHedge() public {
        // Mock mark price precompile at 0x0804
        bytes memory priceReturn = abi.encode(uint256(3100));
        vm.mockCall(address(0x0804), "", priceReturn);

        bytes32 id = hedger.openHedge(1, 100, 3000);
        hedger.closeHedge(id);

        assertEq(hedger.activePositionCount(), 0);
        assertEq(hedger.netDelta(), 0);
    }

    function test_adjustHedge() public {
        bytes32 id = hedger.openHedge(1, 100, 3000);
        hedger.adjustHedge(id, 200, 3100);

        (,int256 size,,) = hedger.hedgePositions(id);
        assertEq(size, 200);
    }

    function test_emergencyCloseAll() public {
        hedger.openHedge(1, 100, 3000);
        hedger.openHedge(2, -200, 2000);

        hedger.emergencyCloseAll();
        assertEq(hedger.activePositionCount(), 0);
    }

    function test_closeHedge_nonexistent() public {
        vm.expectRevert("Position not found");
        hedger.closeHedge(bytes32(uint256(999)));
    }

    function test_hedgeThreshold() public {
        assertEq(hedger.hedgeThreshold(), 500);
        hedger.setHedgeThreshold(1000);
        assertEq(hedger.hedgeThreshold(), 1000);
    }

    function test_onlyOwner() public {
        address alice = makeAddr("alice");
        vm.prank(alice);
        vm.expectRevert();
        hedger.openHedge(1, 100, 3000);
    }
}
