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

import {CoreWriterLib, HLConstants, HLConversions, PreCompileLib } from "@hyper-evm-lib/src/CoreWriterLib.sol";
import { SafeTransferLib } from "@solmate/src/utils/SafeTransferLib.sol";

contract StickySuper {
  using SafeTransferLib for ERC20;

  error AmountTooSmall();

  constructor(address _USDC) {
    USDC = _USDC;
    HYPE = _HYPE;
    BTC = _BTC;
    ETH = _ETH;
  }



  address USDC = ""; 
  address HYPE = ""; 
  address BTC = ""; 
  address ETH = ""; 

  address sHUSD = ""; 
  address sBUSD = ""; 
  address sEUSD = ""; 

  // @dev:
  // mapping that maps an index to the address for the deployed stickyUSD contract for the desired asset
  // each asset stablecoin has it's own contract so the margin can isolated for each asset into the designated contract address for the asset
  // this will need to be passed as an input parameter for minting and redeeming from parent with the proper designated index (all handled through frontend) for minting desired stable tokens as all mints and redemptions are handled in USDC.
  mapping (uint8 => address) internal stickyUSDs;


  function mintStickyToken(uint evmUsdcAmount, uint8 _stickyTokenIndex) {

    //@TODO add check ensuring stickyTokenIndex is valid mapping

    //@dev setting 2 as the minimum, as we need to split 50/50 between spot and perp.
    // but could this allow for slippage calculation issues when an order is not large enough?
    // will have to test to figure out. may end up increasinng minimum order size constraint for this reason.
    if (evmUsdcAmount < 2) revert AmountTooSmall();

    ERC20(USDC).safeTransferFrom(msg.sender, address(this), _amount);



    CoreWriterLib.bridgeToCore(USDC, evmUsdcAmount);

    uint64 tokenId = PrecompileLib.getTokenIndex(USDC);
    uint64 coreAmount = HLConversions.evmToWei(tokenId, evmAmount);

    address stickyMintContract = stickyUSDs[_stickyTokenIndex];
    CoreWriterLib.spotSend(stickyMintContract, tokenId, coreAmount);

    //@dev transferring position execution logic over to sticky hype usd token contract
    // in order for isolated margin in that account on the core side
    StickyUSD(stickyMintContract).mint(coreAmount, msg.sender);

  }

  //@TODO
  function redeemStickyToken(uint evmUsdcAmount, uint8 _stickyTokenIndex) {

  }

  //deploy new StickyUSD contract, add to mapping
  //@TODO
  function createNewStickyToken() onlyOwner {


  } 

}
