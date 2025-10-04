pragma solidity >=0.8.0 <0.9.0;

// Useful for debugging. Remove when deploying to a live network.
import "forge-std/console.sol";

import {CoreWriterLib, HLConstants, HLConversions, PreCompileLib } from "@hyper-evm-lib/src/CoreWriterLib.sol";
import { SafeTransferLib } from "@solmate/src/utils/SafeTransferLib.sol";


contract StickyUSD() is ERC20 {

  //constants
  //
  address stickySuper;
  address USDC_TOKEN_ADDRESS;
  uint32 ASSET_PERP_ID;
  uint32 ASSET_SPOT_ID;


  //@dev `_mintAmount` differs from `_depositAmount` after accounting for fees and slippage
  event Mint(address _token, address indexed _minter, uint64 _depositAmount, uint64 _mintAmount);

  //@dev `_redeemAmount` differs from `_withdrawAmount` after accounting for fees and slippage
  event Redeem(address _token, address indexed _redeemer, uint64 _withdrawAmount, uint64 _redeemAmount);


  error OnlyStickySuper();
  modifier onlyStickySuper() {
     if (msg.sender !== stickySuper) revert OnlyStickySuper();
     _;
  }

  constructor(address _stickySuper, uint32 _perpID, uint32 _spotID, _USDC_TOKEN_ADDRESS) {
    _USDC_TOKEN_ADDRESS = USDC_TOKEN_ADDRESS;
    stickySuper = _stickySuper;
    ASSET_PERP_ID = _perpID;
    ASSET_SPOT_ID = _spotID;

  }

  //@dev structs from PrecompileLib calls return shapes
  // putting here for reference
  //struct Position {
  //      int64 szi;
  //      uint64 entryNtl;
  //      int64 isolatedRawUsd;
  //      uint32 leverage;
  //      bool isIsolated;
  //}

  //struct SpotBalance {
  //      uint64 total;
  //      uint64 hold;
  //      uint64 entryNtl;
  //}


  function mint(uint64 _coreAmount, address _recipient, ) onlyStickySuper {
    //2. send half to perp
    uint64 usdcPerpAmount = HLConversions.weiToPerp(_coreAmount)/2;
    CoreWriterLib.transferUsdcClass(usdcPerpAmount, true);

    (int64 perpPositionSizeBefore,,,,) = PreCompileLib.position(address(this),ASSET_PERP_ID);
    (uint64 spotBalanceBefore,,) = PreCompileLib.spotBalance(address(this), ASSET_SPOT_ID);

    uint64 spotOrderSize = HLConversions.weiToSz(ASSET_SPOT_ID, _coreAmount);
    uint64 perpOrderSize = HLConversions.weiToSz(ASSET_PERP_ID, _coreAmount);

    //buy spot HYPE IOC at market
    CoreWriterLib.placeLimitOrder(ASSET_SPOT_ID, true, type(uint64).max, spotOrderSize, false, 3, 0);

    //sell perp HYPE IOC at market
    CoreWriterLib.placeLimitOrder(ASSET_PERP_ID, false, 1, perpOrderSize, false, 3, 0);

    //get data, do calculations
    (int64 perpPositionSizeAfter,,,,) = PreCompileLib.position(address(this),ASSET_PERP_ID);
    (uint64 spotBalanceAfter,,) = PreCompileLib.spotBalance(address(this), ASSET_SPOT_ID);

    int64 perpPositionSizeDiffBeforeAndAfter = perpPositionSizeAfter - perpPositionSizeBefore;
    uint64 spotBalanceDiffBeforeAndAfter = spotBalanceAfter - spotBalanceBefore;

    //so, the reason for me getting this data is to infer the slippage from the trades and account that into the calculation for how much to mint...
    // so, the calculation to do here, in order to ensure proper accounting across the board for not minting more than we should, or things such as, is this:
    // take:
    // - perpDiffBeforeAndAfter (ex, 0 before, 50 after = 50), 
    // - spotBalanceDiffBeforeAndAfter(ex, 0 before, 50 after = 50),
    // ...add them together, and that's your total to mint.
    // ...just remember to convert the value back to the evmAmount before minting.
    uint64 perpDiffAmountInWei = HLConversions.szToWei(ASSET_PERP_ID, perpPositionSizeDiffBeforeAndAfter);
    uint64 spotDiffAmountInWei = HLConversions.szToWei(ASSET_SPOT_ID, spotBalanceDiffBeforeAndAfter);

    uint netDiffInWei = perpDiffAmountInWei + spotDiffAmountInWei;
    uint mintAmount = HLConversions.weiToEvm(USDC_TOKEN_ADDRESS, netDiffInWei);

    //@TODO call ERC20 mint here
  }

  function redeem() onlyStickySuper {

  }

}
