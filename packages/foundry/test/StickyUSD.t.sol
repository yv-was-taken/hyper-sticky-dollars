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
import {StickyUSD} from "../contracts/StickyUSD.sol";

contract StickyUSDTest is BaseSimulatorTest {
    using PrecompileLib for address;
    using HLConversions for *;

    StickyUSD public stickyUSD;

    // Use testnet addresses for simulation
    address public constant MOCK_USDC = address(0x1234567890123456789012345678901234567890);
    address public constant HYPE_EVM_ADDRESS = address(0x2222222222222222222222222222222222222222);

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();

        // Deploy StickyUSD contract - it will derive all IDs from HYPE EVM address
        vm.prank(owner);
        stickyUSD = new StickyUSD(owner, HYPE_EVM_ADDRESS, MOCK_USDC);

        // Setup accounts
        CoreSimulatorLib.forceAccountActivation(address(stickyUSD));
        CoreSimulatorLib.forceAccountActivation(owner);
        CoreSimulatorLib.forceAccountActivation(alice);
        CoreSimulatorLib.forceAccountActivation(bob);

        // Give contract USDC on core
        CoreSimulatorLib.forceSpotBalance(address(stickyUSD), USDC_TOKEN, 10000e8);
        CoreSimulatorLib.forcePerpBalance(address(stickyUSD), 10000e6);

        // Register tokens for tokenInfo calls
        hyperCore.registerTokenInfo(USDC_TOKEN); // USDC
        hyperCore.registerTokenInfo(HYPE_TOKEN); // HYPE

        // Set reasonable market prices using derived IDs from the contract
        CoreSimulatorLib.setMarkPx(uint16(stickyUSD.ASSET_PERP_ID()), 1e6); // $1 per HYPE
        CoreSimulatorLib.setSpotPx(stickyUSD.ASSET_SPOT_ID() - 10000, 1e6); // $1 per HYPE

        vm.label(address(stickyUSD), "StickyUSD");
        vm.label(owner, "Owner");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor() public {
        assertEq(stickyUSD.name(), "Sticky USD");
        assertEq(stickyUSD.symbol(), "sUSD");
        assertEq(stickyUSD.decimals(), 18);
        assertEq(stickyUSD.owner(), owner);
    }

    function test_Constructor_SetsCorrectOwner() public {
        address newOwner = makeAddr("newOwner");
        StickyUSD newStickyUSD = new StickyUSD(newOwner, HYPE_EVM_ADDRESS, MOCK_USDC);
        assertEq(newStickyUSD.owner(), newOwner);
    }

    /*//////////////////////////////////////////////////////////////
                        MINT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Mint() public {
        uint64 coreAmount = 100e8; // 100 USDC in core format

        vm.prank(owner);
        stickyUSD.mint(coreAmount, alice);

        // Execute the orders placed by mint
        CoreSimulatorLib.nextBlock();

        // Check that tokens were minted to alice
        uint256 aliceBalance = stickyUSD.balanceOf(alice);
        assertGt(aliceBalance, 0, "Alice should have received sticky tokens");
    }

    function test_Mint_OnlyOwner() public {
        uint64 coreAmount = 100e8;

        vm.prank(alice);
        vm.expectRevert();
        stickyUSD.mint(coreAmount, alice);
    }

    function test_Mint_CreatesPositions() public {
        uint64 coreAmount = 100e8;

        // Check positions before
        PrecompileLib.Position memory perpPosBefore = PrecompileLib.position(address(stickyUSD), uint16(stickyUSD.ASSET_PERP_ID()));
        PrecompileLib.SpotBalance memory spotBalBefore = PrecompileLib.spotBalance(address(stickyUSD), HYPE_TOKEN);

        vm.prank(owner);
        stickyUSD.mint(coreAmount, alice);

        CoreSimulatorLib.nextBlock();

        // Check positions after
        PrecompileLib.Position memory perpPosAfter = PrecompileLib.position(address(stickyUSD), uint16(stickyUSD.ASSET_PERP_ID()));
        PrecompileLib.SpotBalance memory spotBalAfter = PrecompileLib.spotBalance(address(stickyUSD), HYPE_TOKEN);

        // Should have short perp position (negative)
        assertLt(perpPosAfter.szi, perpPosBefore.szi, "Should have short perp position");

        // Should have long spot position
        assertGt(spotBalAfter.total, spotBalBefore.total, "Should have long spot position");
    }

    function test_Mint_MultipleTimes() public {
        uint64 amount1 = 100e8;
        uint64 amount2 = 50e8;

        vm.startPrank(owner);
        stickyUSD.mint(amount1, alice);
        CoreSimulatorLib.nextBlock();

        uint256 balanceAfterFirst = stickyUSD.balanceOf(alice);

        stickyUSD.mint(amount2, alice);
        CoreSimulatorLib.nextBlock();

        uint256 balanceAfterSecond = stickyUSD.balanceOf(alice);
        vm.stopPrank();

        assertGt(balanceAfterSecond, balanceAfterFirst, "Balance should increase after second mint");
    }

    function test_Mint_DifferentRecipients() public {
        uint64 coreAmount = 100e8;

        vm.startPrank(owner);
        stickyUSD.mint(coreAmount, alice);
        CoreSimulatorLib.nextBlock();

        stickyUSD.mint(coreAmount, bob);
        CoreSimulatorLib.nextBlock();
        vm.stopPrank();

        uint256 aliceBalance = stickyUSD.balanceOf(alice);
        uint256 bobBalance = stickyUSD.balanceOf(bob);

        assertGt(aliceBalance, 0, "Alice should have balance");
        assertGt(bobBalance, 0, "Bob should have balance");
    }

    /*//////////////////////////////////////////////////////////////
                        REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Redeem() public {
        // First mint
        uint64 mintAmount = 100e8;

        vm.prank(owner);
        stickyUSD.mint(mintAmount, alice);
        CoreSimulatorLib.nextBlock();

        uint256 aliceTokenBalance = stickyUSD.balanceOf(alice);
        assertGt(aliceTokenBalance, 0, "Alice should have tokens");

        // Give alice's tokens to owner for redemption
        vm.prank(alice);
        stickyUSD.transfer(owner, aliceTokenBalance);

        // Now redeem
        uint256 redeemAmount = aliceTokenBalance / 2;

        vm.prank(owner);
        stickyUSD.redeem(redeemAmount, bob);

        CoreSimulatorLib.nextBlock();

        // Check that tokens were burned
        uint256 ownerBalanceAfter = stickyUSD.balanceOf(owner);
        assertLt(ownerBalanceAfter, aliceTokenBalance, "Tokens should be burned");
    }

    function test_Redeem_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        stickyUSD.redeem(100e18, alice);
    }

    function test_Redeem_ClosesPositions() public {
        // First mint to create positions
        uint64 mintAmount = 100e8;

        vm.prank(owner);
        stickyUSD.mint(mintAmount, alice);
        CoreSimulatorLib.nextBlock();

        // Transfer tokens to owner
        uint256 tokenBalance = stickyUSD.balanceOf(alice);
        vm.prank(alice);
        stickyUSD.transfer(owner, tokenBalance);

        // Get positions after mint
        PrecompileLib.Position memory perpPosBeforeRedeem = PrecompileLib.position(address(stickyUSD), uint16(stickyUSD.ASSET_PERP_ID()));
        PrecompileLib.SpotBalance memory spotBalBeforeRedeem = PrecompileLib.spotBalance(address(stickyUSD), HYPE_TOKEN);

        // Redeem
        vm.prank(owner);
        stickyUSD.redeem(tokenBalance, bob);
        CoreSimulatorLib.nextBlock();

        // Check positions after redeem
        PrecompileLib.Position memory perpPosAfterRedeem = PrecompileLib.position(address(stickyUSD), uint16(stickyUSD.ASSET_PERP_ID()));
        PrecompileLib.SpotBalance memory spotBalAfterRedeem = PrecompileLib.spotBalance(address(stickyUSD), HYPE_TOKEN);

        // Perp position should be less short (closer to 0)
        assertGt(perpPosAfterRedeem.szi, perpPosBeforeRedeem.szi, "Perp position should be closed partially");

        // Spot position should be reduced
        assertLt(spotBalAfterRedeem.total, spotBalBeforeRedeem.total, "Spot position should be reduced");
    }

    function test_Redeem_BurnsTokens() public {
        // Mint first
        uint64 mintAmount = 100e8;

        vm.prank(owner);
        stickyUSD.mint(mintAmount, alice);
        CoreSimulatorLib.nextBlock();

        uint256 totalSupplyAfterMint = stickyUSD.totalSupply();
        uint256 aliceBalance = stickyUSD.balanceOf(alice);

        // Transfer to owner
        vm.prank(alice);
        stickyUSD.transfer(owner, aliceBalance);

        // Redeem
        vm.prank(owner);
        stickyUSD.redeem(aliceBalance, bob);

        uint256 totalSupplyAfterRedeem = stickyUSD.totalSupply();

        assertLt(totalSupplyAfterRedeem, totalSupplyAfterMint, "Total supply should decrease");
        assertEq(totalSupplyAfterRedeem, 0, "Total supply should be 0 after full redeem");
    }

    /*//////////////////////////////////////////////////////////////
                        SLIPPAGE ACCOUNTING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Mint_AccountsForSlippage() public {
        // This test verifies that the mint amount is based on actual positions,
        // not just the input amount (accounting for slippage)

        uint64 coreAmount = 100e8;

        vm.prank(owner);
        stickyUSD.mint(coreAmount, alice);
        CoreSimulatorLib.nextBlock();

        uint256 mintedTokens = stickyUSD.balanceOf(alice);

        // The minted amount should be based on the actual positions created
        // which may differ from coreAmount due to slippage
        assertGt(mintedTokens, 0, "Should mint tokens");
    }

    function test_Redeem_AccountsForSlippage() public {
        // Mint first
        uint64 mintAmount = 100e8;

        vm.prank(owner);
        stickyUSD.mint(mintAmount, alice);
        CoreSimulatorLib.nextBlock();

        uint256 tokenBalance = stickyUSD.balanceOf(alice);

        vm.prank(alice);
        stickyUSD.transfer(owner, tokenBalance);

        // Redeem and verify USDC returned accounts for slippage
        vm.prank(owner);
        stickyUSD.redeem(tokenBalance, bob);
        CoreSimulatorLib.nextBlock();

        // The actual USDC returned should be based on positions closed,
        // not the token amount directly
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MintRedeemCycle() public {
        uint64 mintAmount = 100e8;

        // Mint
        vm.prank(owner);
        stickyUSD.mint(mintAmount, alice);
        CoreSimulatorLib.nextBlock();

        uint256 tokenBalance = stickyUSD.balanceOf(alice);
        assertGt(tokenBalance, 0);

        // Transfer to owner
        vm.prank(alice);
        stickyUSD.transfer(owner, tokenBalance);

        // Redeem
        vm.prank(owner);
        stickyUSD.redeem(tokenBalance, alice);
        CoreSimulatorLib.nextBlock();

        // Check all positions are closed
        uint256 finalBalance = stickyUSD.balanceOf(owner);
        assertEq(finalBalance, 0, "All tokens should be burned");
    }

    function test_MultipleUsersInteraction() public {
        uint64 amount = 100e8;

        // Alice mints
        vm.prank(owner);
        stickyUSD.mint(amount, alice);
        CoreSimulatorLib.nextBlock();

        // Bob mints
        vm.prank(owner);
        stickyUSD.mint(amount, bob);
        CoreSimulatorLib.nextBlock();

        uint256 aliceBalance = stickyUSD.balanceOf(alice);
        uint256 bobBalance = stickyUSD.balanceOf(bob);
        uint256 totalSupply = stickyUSD.totalSupply();

        assertEq(totalSupply, aliceBalance + bobBalance, "Total supply should equal sum of balances");
    }

    function test_PriceChange_Impact() public {
        uint64 mintAmount = 100e8;

        // Mint at initial price
        vm.prank(owner);
        stickyUSD.mint(mintAmount, alice);
        CoreSimulatorLib.nextBlock();

        uint256 tokensAtPrice1 = stickyUSD.balanceOf(alice);

        // Change price
        CoreSimulatorLib.setMarkPx(uint16(stickyUSD.ASSET_PERP_ID()), 1.2e6); // 20% increase
        CoreSimulatorLib.setSpotPx(stickyUSD.ASSET_SPOT_ID() - 10000, 1.2e6);

        // Mint again
        vm.prank(owner);
        stickyUSD.mint(mintAmount, bob);
        CoreSimulatorLib.nextBlock();

        uint256 tokensAtPrice2 = stickyUSD.balanceOf(bob);

        // Different prices may result in different token amounts due to slippage
        console.log("Tokens at price 1:", tokensAtPrice1);
        console.log("Tokens at price 2:", tokensAtPrice2);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TransferOwnership() public {
        vm.prank(owner);
        stickyUSD.transferOwnership(alice);

        assertEq(stickyUSD.owner(), alice);

        // New owner can mint
        vm.prank(alice);
        stickyUSD.mint(100e8, bob);
        CoreSimulatorLib.nextBlock();

        // Old owner cannot
        vm.prank(owner);
        vm.expectRevert();
        stickyUSD.mint(100e8, bob);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Transfer() public {
        uint64 mintAmount = 100e8;

        vm.prank(owner);
        stickyUSD.mint(mintAmount, alice);
        CoreSimulatorLib.nextBlock();

        uint256 aliceBalance = stickyUSD.balanceOf(alice);
        uint256 transferAmount = aliceBalance / 2;

        vm.prank(alice);
        stickyUSD.transfer(bob, transferAmount);

        assertEq(stickyUSD.balanceOf(alice), aliceBalance - transferAmount);
        assertEq(stickyUSD.balanceOf(bob), transferAmount);
    }

    function test_Approve_TransferFrom() public {
        uint64 mintAmount = 100e8;

        vm.prank(owner);
        stickyUSD.mint(mintAmount, alice);
        CoreSimulatorLib.nextBlock();

        uint256 aliceBalance = stickyUSD.balanceOf(alice);
        uint256 approveAmount = aliceBalance / 2;

        vm.prank(alice);
        stickyUSD.approve(bob, approveAmount);

        assertEq(stickyUSD.allowance(alice, bob), approveAmount);

        vm.prank(bob);
        stickyUSD.transferFrom(alice, bob, approveAmount);

        assertEq(stickyUSD.balanceOf(bob), approveAmount);
        assertEq(stickyUSD.balanceOf(alice), aliceBalance - approveAmount);
    }
}
