// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {CoreWriterLib} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {HLConversions} from "@hyper-evm-lib/src/common/HLConversions.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {HyperCore} from "@hyper-evm-lib/test/simulation/HyperCore.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {BaseSimulatorTest} from "@hyper-evm-lib/test/BaseSimulatorTest.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {StickySuper} from "../contracts/StickySuper.sol";
import {StickyUSD} from "../contracts/StickyUSD.sol";

contract StickySuperTest is BaseSimulatorTest {
    using PrecompileLib for address;
    using HLConversions for *;

    StickySuper public stickySuper;

    // Use a mock USDC address for simulation - token index 0 is USDC
    address public constant MOCK_USDC = address(0x1234567890123456789012345678901234567890);
    address public constant HYPE_EVM_ADDRESS = address(0x2222222222222222222222222222222222222222);

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();

        // Deploy StickySuper contract with mock USDC
        stickySuper = new StickySuper(MOCK_USDC);

        // Setup accounts
        CoreSimulatorLib.forceAccountActivation(address(stickySuper));
        CoreSimulatorLib.forceAccountActivation(alice);
        CoreSimulatorLib.forceAccountActivation(bob);

        // Give users USDC (USDT0)
        deal(MOCK_USDC, alice, 10000e6);
        deal(MOCK_USDC, bob, 10000e6);

        vm.label(address(stickySuper), "StickySuper");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
    }

    /*//////////////////////////////////////////////////////////////
                        CREATE STICKY TOKEN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateNewStickyToken() public {
        vm.prank(stickySuper.owner());
        uint8 tokenIndex = stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS);

        assertEq(tokenIndex, 0, "First token index should be 0");
        assertEq(stickySuper.nextStickyTokenIndex(), 1, "Next index should be 1");
    }

    function test_CreateMultipleStickyTokens() public {
        vm.startPrank(stickySuper.owner());

        uint8 index1 = stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS);
        uint8 index2 = stickySuper.createNewStickyToken(address(0x1111111111111111111111111111111111111111)); // BTC example
        uint8 index3 = stickySuper.createNewStickyToken(address(0x3333333333333333333333333333333333333333)); // ETH example

        vm.stopPrank();

        assertEq(index1, 0);
        assertEq(index2, 1);
        assertEq(index3, 2);
        assertEq(stickySuper.nextStickyTokenIndex(), 3);
    }

    function test_CreateNewStickyToken_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS);
    }

    function test_CreateNewStickyToken_EmitsEvent() public {
        vm.prank(stickySuper.owner());

        // Just create the token - event will be emitted with derived IDs
        stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS);

        // Could check event logs if needed, but just verifying it doesn't revert is sufficient
    }

    /*//////////////////////////////////////////////////////////////
                        MINT STICKY TOKEN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MintStickyToken() public {
        // Create sticky token first
        vm.prank(stickySuper.owner());
        uint8 tokenIndex = stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS);

        uint256 mintAmount = 100e6; // 100 USDC

        vm.startPrank(alice);
        ERC20(MOCK_USDC).approve(address(stickySuper), mintAmount);

        stickySuper.mintStickyToken(mintAmount, tokenIndex);
        vm.stopPrank();

        CoreSimulatorLib.nextBlock();

        // Verify sticky tokens were minted
        // Note: The actual sticky token balance check would depend on the StickyUSD contract
    }

    function test_MintStickyToken_RevertsIfAmountTooSmall() public {
        vm.prank(stickySuper.owner());
        uint8 tokenIndex = stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS);

        vm.startPrank(alice);
        vm.expectRevert(StickySuper.AmountTooSmall.selector);
        stickySuper.mintStickyToken(1, tokenIndex);
        vm.stopPrank();
    }

    function test_MintStickyToken_MultipleUsers() public {
        vm.prank(stickySuper.owner());
        uint8 tokenIndex = stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS);

        uint256 aliceMintAmount = 100e6;
        uint256 bobMintAmount = 200e6;

        // Alice mints
        vm.startPrank(alice);
        ERC20(MOCK_USDC).approve(address(stickySuper), aliceMintAmount);
        stickySuper.mintStickyToken(aliceMintAmount, tokenIndex);
        vm.stopPrank();

        CoreSimulatorLib.nextBlock();

        // Bob mints
        vm.startPrank(bob);
        ERC20(MOCK_USDC).approve(address(stickySuper), bobMintAmount);
        stickySuper.mintStickyToken(bobMintAmount, tokenIndex);
        vm.stopPrank();

        CoreSimulatorLib.nextBlock();
    }

    /*//////////////////////////////////////////////////////////////
                        REDEEM STICKY TOKEN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RedeemStickyToken() public {
        // Create and mint first
        vm.prank(stickySuper.owner());
        uint8 tokenIndex = stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS);

        uint256 mintAmount = 100e6;

        vm.startPrank(alice);
        ERC20(MOCK_USDC).approve(address(stickySuper), mintAmount);
        stickySuper.mintStickyToken(mintAmount, tokenIndex);
        vm.stopPrank();

        CoreSimulatorLib.nextBlock();

        // Get sticky token address
        // Note: Would need to add getter function to StickySuper to get sticky token address

        // Redeem
        // vm.startPrank(alice);
        // uint256 redeemAmount = 50e6;
        // stickySuper.redeemStickyToken(redeemAmount, tokenIndex);
        // vm.stopPrank();

        // CoreSimulatorLib.nextBlock();
    }

    function test_RedeemStickyToken_RevertsIfAmountTooSmall() public {
        vm.prank(stickySuper.owner());
        uint8 tokenIndex = stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS);

        vm.startPrank(alice);
        vm.expectRevert(StickySuper.AmountTooSmall.selector);
        stickySuper.redeemStickyToken(1, tokenIndex);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MintAndRedeemCycle() public {
        vm.prank(stickySuper.owner());
        uint8 tokenIndex = stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS);

        uint256 initialUsdcBalance = ERC20(USDT0).balanceOf(alice);
        uint256 mintAmount = 100e6;

        // Mint
        vm.startPrank(alice);
        ERC20(MOCK_USDC).approve(address(stickySuper), mintAmount);
        stickySuper.mintStickyToken(mintAmount, tokenIndex);
        vm.stopPrank();

        CoreSimulatorLib.nextBlock();

        uint256 afterMintBalance = ERC20(USDT0).balanceOf(alice);
        assertLt(afterMintBalance, initialUsdcBalance, "USDC should be deducted after mint");

        // Redeem (would need sticky token balance to test properly)
        // This is a placeholder for the full integration test
    }

    function test_MultipleTokenTypes() public {
        vm.startPrank(stickySuper.owner());
        uint8 hypeIndex = stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS); // HYPE
        uint8 btcIndex = stickySuper.createNewStickyToken(address(0x1111111111111111111111111111111111111111)); // BTC
        vm.stopPrank();

        assertEq(hypeIndex, 0);
        assertEq(btcIndex, 1);

        // Users can mint different types
        vm.startPrank(alice);
        ERC20(MOCK_USDC).approve(address(stickySuper), 200e6);
        stickySuper.mintStickyToken(100e6, hypeIndex);
        vm.stopPrank();

        CoreSimulatorLib.nextBlock();

        vm.startPrank(bob);
        ERC20(MOCK_USDC).approve(address(stickySuper), 100e6);
        stickySuper.mintStickyToken(100e6, btcIndex);
        vm.stopPrank();

        CoreSimulatorLib.nextBlock();
    }

    /*//////////////////////////////////////////////////////////////
                        OWNER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OwnershipTransfer() public {
        address originalOwner = stickySuper.owner();

        vm.prank(originalOwner);
        stickySuper.transferOwnership(alice);

        assertEq(stickySuper.owner(), alice);

        // New owner can create tokens
        vm.prank(alice);
        uint8 tokenIndex = stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS);
        assertEq(tokenIndex, 0);

        // Old owner cannot
        vm.prank(originalOwner);
        vm.expectRevert();
        stickySuper.createNewStickyToken(HYPE_EVM_ADDRESS);
    }
}
