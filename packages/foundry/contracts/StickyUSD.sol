pragma solidity >=0.8.0 <0.9.0;

// Useful for debugging. Remove when deploying to a live network.
import "forge-std/console.sol";

import {CoreWriterLib, HLConstants, HLConversions} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/tokens/ERC20.sol";
import { Owned } from "solmate/auth/Owned.sol";


contract StickyUSD is ERC20, Owned {
  using SafeTransferLib for ERC20;

  address public immutable USDC_TOKEN_ADDRESS;
  address public immutable ASSET_EVM_ADDRESS;

  uint64 public immutable ASSET_TOKEN_INDEX; // The underlying asset token index (e.g. HYPE = 150)
  uint32 public immutable ASSET_PERP_ID;     // Perpetual market ID
  uint32 public immutable ASSET_SPOT_ID;     // Spot asset ID (10000 + spot market index)


  //@dev `_mintAmount` differs from `_depositAmount` after accounting for fees and slippage
  event Mint(address _token, address indexed _minter, uint64 _depositAmount, uint64 _mintAmount);

  //@dev `_redeemAmount` differs from `_withdrawAmount` after accounting for fees and slippage
  event Redeem(address _token, address indexed _redeemer, uint64 _withdrawAmount, uint64 _redeemAmount);

  constructor(
    address _stickySuper,
    address _assetEvmAddress,
    address _usdcAddress
  )
    ERC20("Sticky USD", "sUSD", 18)
    Owned(_stickySuper)
  {
    console.log("=== STICKY USD CONSTRUCTOR ===");
    console.log("Asset EVM address:", _assetEvmAddress);
    console.log("USDC address:", _usdcAddress);

    // Store EVM addresses
    USDC_TOKEN_ADDRESS = _usdcAddress;
    ASSET_EVM_ADDRESS = _assetEvmAddress;

    // Get token index from EVM address using TokenRegistry
    ASSET_TOKEN_INDEX = uint64(PrecompileLib.getTokenIndex(_assetEvmAddress));
    console.log("Token index:", ASSET_TOKEN_INDEX);

    // Get spot market index for ASSET/USDC pair
    uint64 spotMarketIndex = PrecompileLib.getSpotIndex(ASSET_TOKEN_INDEX);
    console.log("Spot market index:", spotMarketIndex);

    // Get SpotInfo to access token pair
    PrecompileLib.SpotInfo memory spotInfo = PrecompileLib.spotInfo(spotMarketIndex);
    console.log("Base token (from spotInfo):", spotInfo.tokens[0]);
    console.log("Quote token (from spotInfo):", spotInfo.tokens[1]);

    // Calculate spot asset ID (10000 + spot market index)
    ASSET_SPOT_ID = uint32(10000 + spotMarketIndex);
    console.log("Spot asset ID:", ASSET_SPOT_ID);

    // For standard (non-builder-deployed) perps, perp ID equals spot market index
    ASSET_PERP_ID = uint32(spotMarketIndex);
    console.log("Perp ID:", ASSET_PERP_ID);

    console.log("=== CONSTRUCTOR COMPLETE ===");
  }

  function mint(uint64 _coreAmount, address _recipient) public onlyOwner {
    console.log("=== MINT START ===");
    console.log("Core amount:", _coreAmount);
    console.log("Recipient:", _recipient);

    //2. send half to perp
    uint64 usdcPerpAmount = HLConversions.weiToPerp(_coreAmount)/2;
    console.log("USDC perp amount:", usdcPerpAmount);
    CoreWriterLib.transferUsdClass(usdcPerpAmount, true);

    PrecompileLib.Position memory perpPosBefore = PrecompileLib.position(address(this), uint16(ASSET_PERP_ID));
    PrecompileLib.SpotBalance memory spotBalBefore = PrecompileLib.spotBalance(address(this), ASSET_SPOT_ID);
    int64 perpPositionSizeBefore = perpPosBefore.szi;
    uint64 spotBalanceBefore = spotBalBefore.total;
    console.log("Perp position before:", uint64(perpPositionSizeBefore));
    console.log("Spot balance before:", spotBalanceBefore);

    // Get current prices to calculate order sizes
    // spotPx expects spot market ID (asset - 10000), not full asset ID
    uint64 spotPx = PrecompileLib.spotPx(ASSET_SPOT_ID - 10000);
    uint64 markPx = PrecompileLib.markPx(uint16(ASSET_PERP_ID));

    // Calculate HYPE amount from USDC: USDC_wei / price = HYPE_wei
    // Then convert HYPE_wei to size
    uint64 hypeAmountForSpot = (_coreAmount * 1e6) / spotPx; // price is in 1e6 format
    uint64 hypeAmountForPerp = (_coreAmount * 1e6) / markPx;

    uint64 spotOrderSize = HLConversions.weiToSz(ASSET_TOKEN_INDEX, hypeAmountForSpot);
    uint64 perpOrderSize = HLConversions.weiToSz(ASSET_TOKEN_INDEX, hypeAmountForPerp);
    console.log("Spot order size:", spotOrderSize);
    console.log("Perp order size:", perpOrderSize);

    console.log("Placing BUY spot order at market price...");
    CoreWriterLib.placeLimitOrder(ASSET_SPOT_ID, true, type(uint64).max, spotOrderSize, false, 3, 0);

    console.log("Placing SHORT perp order at market price...");
    CoreWriterLib.placeLimitOrder(ASSET_PERP_ID, false, 0, perpOrderSize, false, 3, 0);

    PrecompileLib.Position memory perpPosAfter = PrecompileLib.position(address(this), uint16(ASSET_PERP_ID));
    PrecompileLib.SpotBalance memory spotBalAfter = PrecompileLib.spotBalance(address(this), ASSET_SPOT_ID);
    int64 perpPositionSizeAfter = perpPosAfter.szi;
    uint64 spotBalanceAfter = spotBalAfter.total;
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
    uint64 perpDiffAmountInWei = HLConversions.szToWei(ASSET_TOKEN_INDEX, uint64(perpPositionSizeDiffBeforeAndAfter));
    uint64 spotDiffAmountInWei = HLConversions.szToWei(ASSET_TOKEN_INDEX, spotBalanceDiffBeforeAndAfter);
    console.log("Perp diff in wei:", perpDiffAmountInWei);
    console.log("Spot diff in wei:", spotDiffAmountInWei);

    uint64 netDiffInWei = perpDiffAmountInWei + spotDiffAmountInWei;
    // USDC is token 0 and doesn't need conversion (already in correct format)
    uint mintAmount = netDiffInWei;
    console.log("Net diff in wei:", netDiffInWei);
    console.log("Mint amount:", mintAmount);

    _mint(_recipient, mintAmount);
    console.log("=== MINT END ===");
  }

  function redeem(uint _tokenAmount, address _recipient) public onlyOwner {
    console.log("=== REDEEM START ===");
    console.log("Token amount:", _tokenAmount);
    console.log("Recipient:", _recipient);

    _burn(msg.sender, _tokenAmount);
    console.log("Burned tokens from:", msg.sender);

    PrecompileLib.Position memory perpPosBefore = PrecompileLib.position(address(this), uint16(ASSET_PERP_ID));
    PrecompileLib.SpotBalance memory spotBalBefore = PrecompileLib.spotBalance(address(this), ASSET_SPOT_ID);
    int64 perpPositionSizeBefore = perpPosBefore.szi;
    uint64 spotBalanceBefore = spotBalBefore.total;
    console.log("Perp position before:", uint64(perpPositionSizeBefore));
    console.log("Spot balance before:", spotBalanceBefore);

    // USDC is token 0 and doesn't need conversion (already in wei/core format)
    uint64 coreAmount = uint64(_tokenAmount);
    uint64 spotOrderSize = HLConversions.weiToSz(ASSET_SPOT_ID, coreAmount);
    uint64 perpOrderSize = HLConversions.weiToSz(ASSET_PERP_ID, coreAmount);
    console.log("Core amount:", coreAmount);
    console.log("Spot order size:", spotOrderSize);
    console.log("Perp order size:", perpOrderSize);

    console.log("Placing SELL spot order at market price...");
    CoreWriterLib.placeLimitOrder(ASSET_SPOT_ID, false, 0, spotOrderSize, false, 3, 0);

    console.log("Placing LONG perp order at market price...");
    CoreWriterLib.placeLimitOrder(ASSET_PERP_ID, true, type(uint64).max, perpOrderSize, false, 3, 0);

    PrecompileLib.Position memory perpPosAfter = PrecompileLib.position(address(this), uint16(ASSET_PERP_ID));
    PrecompileLib.SpotBalance memory spotBalAfter = PrecompileLib.spotBalance(address(this), ASSET_SPOT_ID);
    int64 perpPositionSizeAfter = perpPosAfter.szi;
    uint64 spotBalanceAfter = spotBalAfter.total;
    console.log("Perp position after:", uint64(perpPositionSizeAfter));
    console.log("Spot balance after:", spotBalanceAfter);

    int64 perpPositionSizeDiffBeforeAndAfter = perpPositionSizeBefore - perpPositionSizeAfter;
    uint64 spotBalanceDiffBeforeAndAfter = spotBalanceBefore - spotBalanceAfter;
    console.log("Perp position diff:", uint64(perpPositionSizeDiffBeforeAndAfter));
    console.log("Spot balance diff:", spotBalanceDiffBeforeAndAfter);

    uint64 perpDiffAmountInWei = HLConversions.szToWei(ASSET_TOKEN_INDEX, uint64(perpPositionSizeDiffBeforeAndAfter));
    uint64 spotDiffAmountInWei = HLConversions.szToWei(ASSET_TOKEN_INDEX, spotBalanceDiffBeforeAndAfter);
    console.log("Perp diff in wei:", perpDiffAmountInWei);
    console.log("Spot diff in wei:", spotDiffAmountInWei);

    uint64 netDiffInWei = perpDiffAmountInWei + spotDiffAmountInWei;
    console.log("Net diff in wei:", netDiffInWei);

    uint64 usdcPerpAmount = HLConversions.weiToPerp(netDiffInWei) / 2;
    console.log("Transferring USDC from perp to core:", usdcPerpAmount);
    CoreWriterLib.transferUsdClass(usdcPerpAmount, false);

    // USDC is token 0 and doesn't need conversion (already in correct format)
    uint withdrawAmount = netDiffInWei;
    console.log("Withdraw amount:", withdrawAmount);
    console.log("Transferring USDC to recipient...");
    ERC20(USDC_TOKEN_ADDRESS).safeTransfer(_recipient, withdrawAmount);
    console.log("=== REDEEM END ===");
  }

}
