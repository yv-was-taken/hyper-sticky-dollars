//@dev note, currently, 'margin mode' for a perp order is selected on position opening
// and there is no way of selecting margin mode for a position from HyperEVM-HyperCORE interactions.
// ... what this means is, having multiAsset StickyHUSD/StickyBUSD/StickyEUSD creates a cross-margin contamination issue with
// the total margin for the account (coming from the deployed contract address for this contract) in total
// ideally we would want it to be isolated...
// but, actually, now that I think about it, we could have this logic set in the `StickyToken` contract where
// each token deployment is it's own deployment address and that address is the one being deposited to and making the hyperCORE orders.
// that might work actually...


//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

// Useful for debugging. Remove when deploying to a live network.
import "forge-std/console.sol";

import {CoreWriterLib, HLConstants, HLConversions} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/tokens/ERC20.sol";
import { Owned } from "solmate/auth/Owned.sol";
import { StickyUSD } from "./StickyUSD.sol";

contract StickySuper is Owned {
  using SafeTransferLib for ERC20;

  address USDC; 

  error AmountTooSmall();

  uint8 public nextStickyTokenIndex;

  event StickyTokenCreated(uint8 indexed tokenIndex, address indexed tokenAddress, uint32 perpID, uint32 spotID);

  constructor(address _USDC) Owned(msg.sender) {
    USDC = _USDC;
  }

  // @dev:
  // mapping that maps an index to the address for the deployed stickyUSD contract for the desired asset
  // each asset stablecoin has it's own contract so the margin can isolated for each asset into the designated contract address for the asset
  // this will need to be passed as an input parameter for minting and redeeming from parent with the proper designated index (all handled through frontend) for minting desired stable tokens as all mints and redemptions are handled in USDC.
  mapping (uint8 => address) internal stickyUSDs;


  function mintStickyToken(uint evmUsdcAmount, uint8 _stickyTokenIndex) public {
    console.log("=== MINT STICKY TOKEN START ===");
    console.log("EVM USDC amount:", evmUsdcAmount);
    console.log("Sticky token index:", _stickyTokenIndex);
    console.log("Sender:", msg.sender);

    //@TODO add check ensuring stickyTokenIndex is valid mapping

    //@dev setting 2 as the minimum, as we need to split 50/50 between spot and perp.
    // but could this allow for slippage calculation issues when an order is not large enough?
    // will have to test to figure out. may end up increasinng minimum order size constraint for this reason.
    if (evmUsdcAmount < 2) revert AmountTooSmall();

    console.log("Transferring USDC from user to contract...");
    ERC20(USDC).safeTransferFrom(msg.sender, address(this), evmUsdcAmount);

    console.log("Bridging to Core...");
    CoreWriterLib.bridgeToCore(USDC, evmUsdcAmount);

    // USDC is token 0 - no conversion needed (6 decimals EVM = 8 decimals core for USDC)
    uint64 tokenId = 0;
    uint64 coreAmount = uint64(evmUsdcAmount) * 100; // Convert 6 decimals to 8 decimals
    console.log("Token ID:", tokenId);
    console.log("Core amount:", coreAmount);

    address stickyMintContract = stickyUSDs[_stickyTokenIndex];
    console.log("Sticky mint contract:", stickyMintContract);
    console.log("Sending spot to sticky contract...");
    CoreWriterLib.spotSend(stickyMintContract, tokenId, coreAmount);

    //@dev transferring position execution logic over to sticky hype usd token contract
    // in order for isolated margin in that account on the core side
    console.log("Calling mint on sticky contract...");
    StickyUSD(stickyMintContract).mint(coreAmount, msg.sender);
    console.log("=== MINT STICKY TOKEN END ===");

  }

  function redeemStickyToken(uint tokenAmount, uint8 _stickyTokenIndex) public {
    console.log("=== REDEEM STICKY TOKEN START ===");
    console.log("Token amount:", tokenAmount);
    console.log("Sticky token index:", _stickyTokenIndex);
    console.log("Sender:", msg.sender);

    if (tokenAmount < 2) revert AmountTooSmall();

    address stickyRedeemContract = stickyUSDs[_stickyTokenIndex];
    console.log("Sticky redeem contract:", stickyRedeemContract);

    // Transfer sticky tokens from user to this contract
    console.log("Transferring sticky tokens from user...");
    ERC20(stickyRedeemContract).safeTransferFrom(msg.sender, address(this), tokenAmount);

    // Call redeem on StickyUSD - this handles closing positions and transferring USDC to user
    console.log("Calling redeem on sticky contract...");
    StickyUSD(stickyRedeemContract).redeem(tokenAmount, msg.sender);
    console.log("=== REDEEM STICKY TOKEN END ===");
  }

  //deploy new StickyUSD contract, add to mapping
  function createNewStickyToken(address _assetEvmAddress) public onlyOwner returns (uint8) {
    console.log("=== CREATE NEW STICKY TOKEN START ===");
    console.log("Asset EVM address:", _assetEvmAddress);

    // Deploy new StickyUSD contract - it will derive all IDs from the EVM address
    console.log("Deploying new StickyUSD contract...");
    StickyUSD newStickyToken = new StickyUSD(address(this), _assetEvmAddress, USDC);
    console.log("New sticky token address:", address(newStickyToken));

    // Get current index
    uint8 currentIndex = nextStickyTokenIndex;
    console.log("Current index:", currentIndex);

    // Add to mapping
    stickyUSDs[currentIndex] = address(newStickyToken);
    console.log("Added to mapping");

    // Increment counter for next token
    nextStickyTokenIndex++;
    console.log("Next index will be:", nextStickyTokenIndex);

    // Emit event with derived IDs
    emit StickyTokenCreated(
      currentIndex,
      address(newStickyToken),
      newStickyToken.ASSET_PERP_ID(),
      newStickyToken.ASSET_SPOT_ID()
    );
    console.log("=== CREATE NEW STICKY TOKEN END ===");

    return currentIndex;
  } 

}
