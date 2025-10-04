pragma solidity >=0.8.0 <0.9.0;

// Useful for debugging. Remove when deploying to a live network.
import "forge-std/console.sol";

import {CoreWriterLib, HLConstants, HLConversions, PreCompileLib } from "@hyper-evm-lib/src/CoreWriterLib.sol";
import { SafeTransferLib } from "@solmate/src/utils/SafeTransferLib.sol";
import { ERC20 } from "@solmate/src/tokens/ERC20.sol";
import { Owned } from "@solmate/src/auth/Owned.sol";


contract StickyUSD is ERC20, Owned {
  using SafeTransferLib for ERC20;

  address USDC_TOKEN_ADDRESS;
  uint32 ASSET_PERP_ID;
  uint32 ASSET_SPOT_ID;


  //@dev `_mintAmount` differs from `_depositAmount` after accounting for fees and slippage
  event Mint(address _token, address indexed _minter, uint64 _depositAmount, uint64 _mintAmount);

  //@dev `_redeemAmount` differs from `_withdrawAmount` after accounting for fees and slippage
  event Redeem(address _token, address indexed _redeemer, uint64 _withdrawAmount, uint64 _redeemAmount);

  constructor(address _stickySuper, uint32 _perpID, uint32 _spotID, address _USDC_TOKEN_ADDRESS)
    ERC20("Sticky USD", "sUSD", 18)
    Owned(_stickySuper)
  {
    USDC_TOKEN_ADDRESS = _USDC_TOKEN_ADDRESS;
    ASSET_PERP_ID = _perpID;
    ASSET_SPOT_ID = _spotID;

  }

  function mint(uint64 _coreAmount, address _recipient, ) onlyOwner {
    console.log("=== MINT START ===");
    console.log("Core amount:", _coreAmount);
    console.log("Recipient:", _recipient);

    //2. send half to perp
    uint64 usdcPerpAmount = HLConversions.weiToPerp(_coreAmount)/2;
    console.log("USDC perp amount:", usdcPerpAmount);
    CoreWriterLib.transferUsdcClass(usdcPerpAmount, true);

    (int64 perpPositionSizeBefore,,,,) = PreCompileLib.position(address(this),ASSET_PERP_ID);
    (uint64 spotBalanceBefore,,) = PreCompileLib.spotBalance(address(this), ASSET_SPOT_ID);
    console.log("Perp position before:", uint64(perpPositionSizeBefore));
    console.log("Spot balance before:", spotBalanceBefore);

    uint64 spotOrderSize = HLConversions.weiToSz(ASSET_SPOT_ID, _coreAmount);
    uint64 perpOrderSize = HLConversions.weiToSz(ASSET_PERP_ID, _coreAmount);
    console.log("Spot order size:", spotOrderSize);
    console.log("Perp order size:", perpOrderSize);

    console.log("Placing BUY spot order...");
    CoreWriterLib.placeLimitOrder(ASSET_SPOT_ID, true, type(uint64).max, spotOrderSize, false, 3, 0);

    console.log("Placing SELL perp order...");
    CoreWriterLib.placeLimitOrder(ASSET_PERP_ID, false, 1, perpOrderSize, false, 3, 0);

    (int64 perpPositionSizeAfter,,,,) = PreCompileLib.position(address(this),ASSET_PERP_ID);
    (uint64 spotBalanceAfter,,) = PreCompileLib.spotBalance(address(this), ASSET_SPOT_ID);
    console.log("Perp position after:", uint64(perpPositionSizeAfter));
    console.log("Spot balance after:", spotBalanceAfter);

    int64 perpPositionSizeDiffBeforeAndAfter = perpPositionSizeAfter - perpPositionSizeBefore;
    uint64 spotBalanceDiffBeforeAndAfter = spotBalanceAfter - spotBalanceBefore;
    console.log("Perp position diff:", uint64(perpPositionSizeDiffBeforeAndAfter));
    console.log("Spot balance diff:", spotBalanceDiffBeforeAndAfter);

    //so, the reason for me getting this data is to infer the slippage from the trades and account that into the calculation for how much to mint...
    // so, the calculation to do here, in order to ensure proper accounting across the board for not minting more than we should, or things such as, is this:
    // take:
    // - perpDiffBeforeAndAfter (ex, 0 before, 50 after = 50),
    // - spotBalanceDiffBeforeAndAfter(ex, 0 before, 50 after = 50),
    // ...add them together, and that's your total to mint.
    // ...just remember to convert the value back to the evmAmount before minting.
    uint64 perpDiffAmountInWei = HLConversions.szToWei(ASSET_PERP_ID, perpPositionSizeDiffBeforeAndAfter);
    uint64 spotDiffAmountInWei = HLConversions.szToWei(ASSET_SPOT_ID, spotBalanceDiffBeforeAndAfter);
    console.log("Perp diff in wei:", perpDiffAmountInWei);
    console.log("Spot diff in wei:", spotDiffAmountInWei);

    uint netDiffInWei = perpDiffAmountInWei + spotDiffAmountInWei;
    uint mintAmount = HLConversions.weiToEvm(USDC_TOKEN_ADDRESS, netDiffInWei);
    console.log("Net diff in wei:", netDiffInWei);
    console.log("Mint amount:", mintAmount);

    _mint(_recipient, mintAmount);
    console.log("=== MINT END ===");
  }

  function redeem(uint _tokenAmount, address _recipient) onlyOwner {
    console.log("=== REDEEM START ===");
    console.log("Token amount:", _tokenAmount);
    console.log("Recipient:", _recipient);

    _burn(msg.sender, _tokenAmount);
    console.log("Burned tokens from:", msg.sender);

    (int64 perpPositionSizeBefore,,,,) = PreCompileLib.position(address(this), ASSET_PERP_ID);
    (uint64 spotBalanceBefore,,) = PreCompileLib.spotBalance(address(this), ASSET_SPOT_ID);
    console.log("Perp position before:", uint64(perpPositionSizeBefore));
    console.log("Spot balance before:", spotBalanceBefore);

    uint64 coreAmount = uint64(HLConversions.evmToWei(USDC_TOKEN_ADDRESS, _tokenAmount));
    uint64 spotOrderSize = HLConversions.weiToSz(ASSET_SPOT_ID, coreAmount);
    uint64 perpOrderSize = HLConversions.weiToSz(ASSET_PERP_ID, coreAmount);
    console.log("Core amount:", coreAmount);
    console.log("Spot order size:", spotOrderSize);
    console.log("Perp order size:", perpOrderSize);

    console.log("Placing SELL spot order...");
    CoreWriterLib.placeLimitOrder(ASSET_SPOT_ID, false, 1, spotOrderSize, false, 3, 0);

    console.log("Placing BUY perp order...");
    CoreWriterLib.placeLimitOrder(ASSET_PERP_ID, true, type(uint64).max, perpOrderSize, false, 3, 0);

    (int64 perpPositionSizeAfter,,,,) = PreCompileLib.position(address(this), ASSET_PERP_ID);
    (uint64 spotBalanceAfter,,) = PreCompileLib.spotBalance(address(this), ASSET_SPOT_ID);
    console.log("Perp position after:", uint64(perpPositionSizeAfter));
    console.log("Spot balance after:", spotBalanceAfter);

    int64 perpPositionSizeDiffBeforeAndAfter = perpPositionSizeBefore - perpPositionSizeAfter;
    uint64 spotBalanceDiffBeforeAndAfter = spotBalanceBefore - spotBalanceAfter;
    console.log("Perp position diff:", uint64(perpPositionSizeDiffBeforeAndAfter));
    console.log("Spot balance diff:", spotBalanceDiffBeforeAndAfter);

    uint64 perpDiffAmountInWei = HLConversions.szToWei(ASSET_PERP_ID, perpPositionSizeDiffBeforeAndAfter);
    uint64 spotDiffAmountInWei = HLConversions.szToWei(ASSET_SPOT_ID, spotBalanceDiffBeforeAndAfter);
    console.log("Perp diff in wei:", perpDiffAmountInWei);
    console.log("Spot diff in wei:", spotDiffAmountInWei);

    uint netDiffInWei = perpDiffAmountInWei + spotDiffAmountInWei;
    console.log("Net diff in wei:", netDiffInWei);

    uint64 usdcPerpAmount = HLConversions.weiToPerp(netDiffInWei) / 2;
    console.log("Transferring USDC from perp to core:", usdcPerpAmount);
    CoreWriterLib.transferUsdcClass(usdcPerpAmount, false);

    uint withdrawAmount = HLConversions.weiToEvm(USDC_TOKEN_ADDRESS, netDiffInWei);
    console.log("Withdraw amount:", withdrawAmount);
    console.log("Transferring USDC to recipient...");
    ERC20(USDC_TOKEN_ADDRESS).safeTransfer(_recipient, withdrawAmount);
    console.log("=== REDEEM END ===");
  }

}
