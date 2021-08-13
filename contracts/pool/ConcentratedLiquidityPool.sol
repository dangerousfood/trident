// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.0;

import "../deployer/MasterDeployer.sol";
import "../interfaces/IBentoBoxMinimal.sol";
import "../interfaces/IPool.sol";
import "../interfaces/ITridentCallee.sol";
import "../libraries/concentratedPool/TickMath.sol";
import "../libraries/concentratedPool/FullMath.sol";
import "../libraries/concentratedPool/UnsafeMath.sol";
import "../libraries/concentratedPool/DyDxMath.sol";
import "hardhat/console.sol";

/// @notice Trident exchange pool template with concentrated liquidity and constant product formula for swapping between an ERC-20 token pair.
/// @dev The reserves are stored as bento shares.
///      The curve is applied to shares as well. This pool does not care about the underlying amounts.
contract ConcentratedLiquidityPool is IPool {
    event Mint(address indexed sender, uint256 amount0, uint256 amount1, address indexed recipient);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed recipient);
    event Sync(uint256 reserveShares0, uint256 reserveShares1);

    uint256 internal constant MAX_FEE = 10000; /// @dev 100%.
    uint256 internal constant MAX_FEE_SQUARE = 100000000;
    uint256 internal immutable MAX_FEE_MINUS_SWAP_FEE;
    uint24 public immutable swapFee; /// @dev 1000 corresponds to 0.1% fee.

    address public immutable barFeeTo;
    IBentoBoxMinimal public immutable bento;
    MasterDeployer public immutable masterDeployer;
    address public immutable token0;
    address public immutable token1;

    uint128 public liquidity;
    uint160 public price; /// @dev sqrt of price aka. √(y/x), multiplied by 2^96.
    int24 public nearestTick; /// @dev Tick that is just below the current price.

    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    uint128 internal reserve0;
    uint128 internal reserve1;

    uint32 internal blockTimestampLast;

    mapping(int24 => Tick) public ticks;
    mapping(address => mapping(int24 => mapping(int24 => Position))) public positions;

    struct Tick {
        int24 previousTick;
        int24 nextTick;
        uint128 liquidity;
        uint256 feeGrowthOutside0X128; /// @dev Per unit of liquidity.
        uint256 feeGrowthOutside1X128;
    }

    struct Position {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
    }

    bytes32 public constant override poolIdentifier = "Trident:ConcentratedLiquidity";

    uint256 private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, "LOCKED");
        unlocked = 2;
        _;
        unlocked = 1;
    }

    /// @dev Only set immutable variables here - state changes made here will not be used.
    constructor(bytes memory _deployData, address _masterDeployer) {
        (address _token0, address _token1, uint24 _swapFee, uint160 _price) = abi.decode(
            _deployData,
            (address, address, uint24, uint160)
        );

        require(_token0 != address(0), "ZERO_ADDRESS");
        require(_token0 != _token1, "IDENTICAL_ADDRESSES");
        require(_swapFee <= MAX_FEE, "INVALID_SWAP_FEE");

        token0 = _token0;
        token1 = _token1;

        swapFee = _swapFee;
        MAX_FEE_MINUS_SWAP_FEE = MAX_FEE - _swapFee;

        price = _price;

        ticks[TickMath.MIN_TICK] = Tick(TickMath.MIN_TICK, TickMath.MAX_TICK, uint128(0), 0, 0);
        ticks[TickMath.MAX_TICK] = Tick(TickMath.MIN_TICK, TickMath.MAX_TICK, uint128(0), 0, 0);

        nearestTick = TickMath.MIN_TICK;

        bento = IBentoBoxMinimal(MasterDeployer(_masterDeployer).bento());
        barFeeTo = MasterDeployer(_masterDeployer).barFeeTo();
        masterDeployer = MasterDeployer(_masterDeployer);
    }

    function mint(bytes calldata data) public override lock returns (uint256 minted) {
        (int24 lowerOld, int24 lower, int24 upperOld, int24 upper, uint128 amount, address recipient) = abi.decode(
            data,
            (int24, int24, int24, int24, uint128, address)
        );

        uint160 priceLower = TickMath.getSqrtRatioAtTick(lower);
        uint160 priceUpper = TickMath.getSqrtRatioAtTick(upper);
        uint160 currentPrice = price;

        if (priceLower < currentPrice && currentPrice < priceUpper) liquidity += amount;

        setPosition(recipient, lower, upper, int128(amount));

        updateLinkedList(lowerOld, lower, upperOld, upper, amount, currentPrice);

        (uint128 amount0, uint128 amount1) = getAssetsForLiquidity(
            uint256(priceLower),
            uint256(priceUpper),
            uint256(currentPrice),
            uint256(amount)
        );

        if (amount0 > 0) {
            amount0 += reserve0;
            require(uint256(amount0) <= bento.balanceOf(token0, address(this)), "Didn't deposit token0");
            reserve0 = amount0;
            /** @dev `reserve0 = bento.balanceOf` doesn't help anyone and coins will be stuck */
        }

        if (amount1 > 0) {
            amount1 += reserve1;
            require(uint256(amount1) <= bento.balanceOf(token1, address(this)), "Didn't deposit token1");
            reserve1 = amount1;
        }

        minted = amount;

        emit Mint(msg.sender, amount0, amount1, recipient);
    }

    function burn(bytes calldata data) public override lock returns (IPool.TokenAmount[] memory withdrawnAmounts) {
        (int24 lower, int24 upper, uint128 amount, address recipient, bool unwrapBento) = abi.decode(
            data,
            (int24, int24, uint128, address, bool)
        );

        uint160 priceLower = TickMath.getSqrtRatioAtTick(lower);
        uint160 priceUpper = TickMath.getSqrtRatioAtTick(upper);
        uint160 currentPrice = price;

        if (priceLower < currentPrice && currentPrice < priceUpper) liquidity -= amount;

        // TODO
        uint256 amount0;
        uint256 amount1;

        withdrawnAmounts = new TokenAmount[](2);
        withdrawnAmounts[0] = TokenAmount({token: token0, amount: amount0});
        withdrawnAmounts[1] = TokenAmount({token: token1, amount: amount1});

        _transfer(token0, amount0, recipient, unwrapBento);
        _transfer(token1, amount1, recipient, unwrapBento);

        emit Burn(msg.sender, amount0, amount1, recipient);
    }

    function getAssets() public view override returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = token0;
        assets[1] = token1;
    }

    function burnSingle(bytes calldata data) external override returns (uint256 amount) {
        // TODO
        return 0;
    }

    function getAmountOut(bytes calldata data) public view override returns (uint256 finalAmountOut) {
        // TODO
        return 0;
    }

    function flashSwap(bytes calldata data) external override returns (uint256 finalAmountOut) {
        // TODO
        return 0;
    }

    /// @dev price is √(y/x)
    // x is token0
    // zero for one -> price will move down.
    function swap(bytes calldata data) public override lock returns (uint256 amountOut) {
        (bool zeroForOne, uint256 inAmount, address recipient, bool unwrapBento) = abi.decode(
            data,
            (bool, uint256, address, bool)
        );

        amountOut;
        {
            int24 nextTickToCross = zeroForOne ? nearestTick : ticks[nearestTick].nextTick;
            uint256 currentPrice = uint256(price);
            uint256 currentLiquidity = uint256(liquidity);

            uint256 input = inAmount;
            uint256 feeGrowthGlobal = zeroForOne ? feeGrowthGlobal1X128 : feeGrowthGlobal0X128; /// @dev take fees in the output token.

            while (input > 0) {
                uint256 nextTickPrice = uint256(TickMath.getSqrtRatioAtTick(nextTickToCross));
                uint256 output;
                uint256 feeAmount;
                bool cross = false;

                if (zeroForOne) {
                    /// @dev x for y
                    // price is going down
                    // max swap input within current tick range: Δx = Δ(1/√𝑃) · L.
                    uint256 maxDx = DyDxMath.getDx(currentLiquidity, nextTickPrice, currentPrice, false);
                    if (input <= maxDx) {
                        /// @dev We can swap only within the current range.
                        uint256 liquidityPadded = currentLiquidity << 96;
                        /// @dev Calculate new price after swap: L · √𝑃 / (L + Δx · √𝑃)
                        // alternatively: L / (L / √𝑃 + Δx).
                        uint256 newPrice = uint160(
                            FullMath.mulDivRoundingUp(
                                liquidityPadded,
                                currentPrice,
                                liquidityPadded + currentPrice * input
                            )
                        );

                        if (!(nextTickPrice <= newPrice && newPrice < currentPrice)) {
                            /// @dev Overflow -> use a modified version of the formula.
                            newPrice = uint160(
                                UnsafeMath.divRoundingUp(liquidityPadded, liquidityPadded / currentPrice + input)
                            );
                        }
                        /// @dev Calculate output of swap
                        // Δy = Δ√P · L.
                        output = DyDxMath.getDy(currentLiquidity, newPrice, currentPrice, false);
                        currentPrice = newPrice;
                        input = 0;
                    } else {
                        /// @dev Swap & cross the tick.
                        output = DyDxMath.getDy(currentLiquidity, nextTickPrice, currentPrice, false);
                        currentPrice = nextTickPrice;
                        cross = true;
                        input -= maxDx;
                    }
                } else {
                    /// @dev Price is going up
                    // max swap within current tick range: Δy = Δ√P · L.
                    uint256 maxDy = DyDxMath.getDy(currentLiquidity, currentPrice, nextTickPrice, false);
                    if (input <= maxDy) {
                        /// @dev We can swap only within the current range
                        // calculate new price after swap ( ΔP = Δy/L ).
                        uint256 newPrice = currentPrice +
                            FullMath.mulDiv(input, 0x1000000000000000000000000, currentLiquidity);
                        /// @dev calculate output of swap
                        // Δx = Δ(1/√P) · L.
                        output = DyDxMath.getDx(currentLiquidity, currentPrice, newPrice, false);
                        currentPrice = newPrice;
                        input = 0;
                    } else {
                        /// @dev Swap & cross the tick.
                        output = DyDxMath.getDx(currentLiquidity, currentPrice, nextTickPrice, false);
                        currentPrice = nextTickPrice;
                        cross = true;
                        input -= maxDy;
                    }
                }

                feeAmount = FullMath.mulDivRoundingUp(output, swapFee, 1e6);
                feeGrowthGlobal += FullMath.mulDiv(feeAmount, 0x100000000000000000000000000000000, currentLiquidity);
                amountOut += output - feeAmount;

                if (cross) {
                    ticks[nextTickToCross].feeGrowthOutside0X128 =
                        feeGrowthGlobal -
                        ticks[nextTickToCross].feeGrowthOutside0X128;
                    if (zeroForOne) {
                        /// @dev Goin' left.
                        if (nextTickToCross % 2 == 0) {
                            currentLiquidity -= ticks[nextTickToCross].liquidity;
                        } else {
                            currentLiquidity += ticks[nextTickToCross].liquidity;
                        }

                        nextTickToCross = ticks[nextTickToCross].previousTick;
                    } else {
                        /// @dev Goin' right.
                        if (nextTickToCross % 2 == 0) {
                            currentLiquidity += ticks[nextTickToCross].liquidity;
                        } else {
                            currentLiquidity -= ticks[nextTickToCross].liquidity;
                        }

                        nextTickToCross = ticks[nextTickToCross].nextTick;
                    }
                }
            }

            liquidity = uint128(currentLiquidity);
            price = uint160(currentPrice);
            nearestTick = zeroForOne ? nextTickToCross : ticks[nextTickToCross].previousTick;
        }

        (uint256 amount0, uint256 amount1) = _balance();

        if (zeroForOne) {
            uint128 newBalance = reserve0 + uint128(inAmount);
            require(uint256(newBalance) <= amount0, "MISSING_X_DEPOSIT");
            reserve0 = newBalance;
            reserve1 -= uint128(amountOut);
            _transfer(token1, amountOut, recipient, unwrapBento);
            emit Swap(recipient, token0, token1, inAmount, amountOut);
        } else {
            uint128 newBalance = reserve1 + uint128(inAmount);
            require(uint256(newBalance) <= amount1, "MISSING_Y_DEPOSIT");
            reserve1 = newBalance;
            reserve0 -= uint128(amountOut);
            _transfer(token0, amountOut, recipient, unwrapBento);
            emit Swap(recipient, token1, token0, inAmount, amountOut);
        }
    }

    function _transfer(
        address token,
        uint256 shares,
        address to,
        bool unwrapBento
    ) internal {
        if (unwrapBento) {
            bento.withdraw(token, address(this), to, 0, shares);
        } else {
            bento.transfer(token, address(this), to, shares);
        }
    }

    function _balance() internal view returns (uint256 balance0, uint256 balance1) {
        balance0 = bento.balanceOf(token0, address(this));
        balance1 = bento.balanceOf(token1, address(this));
    }

    function getPositionAssets(
        uint256 priceLower,
        uint256 priceUpper,
        uint256 currentPrice,
        uint256 liquidityAmount
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (priceUpper <= currentPrice) {
            /// @dev only supply token1 (token1 is Y).
            amount1 = uint128(DyDxMath.getDy(liquidityAmount, priceLower, priceUpper, true));
        } else if (currentPrice <= priceLower) {
            /// @dev only supply token0 (token0 is X).
            amount0 = uint128(DyDxMath.getDx(liquidityAmount, priceLower, priceUpper, true));
        } else {
            /// @dev supply both tokens.
            amount0 = uint128(DyDxMath.getDx(liquidityAmount, currentPrice, priceUpper, true));
            amount1 = uint128(DyDxMath.getDy(liquidityAmount, priceLower, currentPrice, true));
        }

        (uint256 balance0, uint256 balance1) = _balance();

        if (amount0 != 0) {
            amount0 += reserve0;
            require(uint256(amount0) <= balance0, "TOKEN_NOT_RECEIVED");
            reserve0 = uint128(amount0);
            /// @dev `reserve0 = token0.balanceOf(address(this))` doesn't help anyone as coins will be stuck.
        }

        if (amount1 != 0) {
            amount1 += reserve1;
            require(uint256(amount1) <= balance1, "TOKEN_NOT_RECEIVED");
            reserve1 = uint128(amount1);
        }

        emit Sync(balance0, balance1);
    }

    //                  u         ▼         v
    // ----|----|-------|xxxxxxxxxxxxxxxxxxx|--------|---------

    //             ▼    u                   v
    // ----|----|-------|xxxxxxxxxxxxxxxxxxx|--------|---------

    //                  u                   v    ▼
    // ----|----|-------|xxxxxxxxxxxxxxxxxxx|--------|---------

    // fees: global, outside u, outside v - we are interested in the 'xxxx' zone

    function getFeeGrowthInside(int24 lowerTick, int24 upperTick)
        public
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        int24 currentTick = nearestTick;

        Tick storage lower = ticks[lowerTick];
        Tick storage upper = ticks[upperTick];

        // calculate fee growth below & above
        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;

        if (lowerTick <= currentTick) {
            feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
        }

        if (currentTick < upperTick) {
            feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
        }

        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }

    function getAssetsForLiquidity(
        uint256 priceLower,
        uint256 priceUpper,
        uint256 currentPrice,
        uint256 liquidityAmount
    ) internal returns (uint128 token0amount, uint128 token1amount) {
        if (priceUpper <= currentPrice) {
            // only supply token1 (token1 is Y)

            token1amount = uint128(DyDxMath.getDy(liquidityAmount, priceLower, priceUpper, true));
        } else if (currentPrice <= priceLower) {
            // only supply token0 (token0 is X)

            token0amount = uint128(DyDxMath.getDx(liquidityAmount, priceLower, priceUpper, true));
        } else {
            // supply both tokens

            token0amount = uint128(DyDxMath.getDx(liquidityAmount, currentPrice, priceUpper, true));
            token1amount = uint128(DyDxMath.getDy(liquidityAmount, priceLower, currentPrice, true));
        }
    }

    function updateLinkedList(
        int24 lowerOld,
        int24 lower,
        int24 upperOld,
        int24 upper,
        uint128 amount,
        uint160 currentPrice
    ) internal {
        require(uint24(lower) % 2 == 0, "Lower even");
        require(uint24(upper) % 2 == 1, "Upper odd");

        require(lower < upper, "Order");

        require(TickMath.MIN_TICK <= lower && lower < TickMath.MAX_TICK, "Lower range");
        require(TickMath.MIN_TICK < upper && upper <= TickMath.MAX_TICK, "Upper range");

        int24 currentNearestTick = nearestTick;

        if (ticks[lower].liquidity > 0 || lower == TickMath.MIN_TICK) {
            // we are adding liquidity to an existing tick

            ticks[lower].liquidity += amount;
        } else {
            // inserting a new tick

            Tick storage old = ticks[lowerOld];

            require(
                (old.liquidity > 0 || lowerOld == TickMath.MIN_TICK) && lowerOld < lower && lower < old.nextTick,
                "Lower order"
            );

            if (lower <= currentNearestTick) {
                ticks[lower] = Tick(lowerOld, old.nextTick, amount, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
            } else {
                ticks[lower] = Tick(lowerOld, old.nextTick, amount, 0, 0);
            }

            old.nextTick = lower;
        }

        if (ticks[upper].liquidity > 0 || upper == TickMath.MAX_TICK) {
            // we are adding liquidity to an existing tick

            ticks[upper].liquidity += amount;
        } else {
            // inserting a new tick
            Tick storage old = ticks[upperOld];

            require(old.liquidity > 0 && old.nextTick > upper && upperOld < upper, "Upper order");

            if (upper <= currentNearestTick) {
                ticks[upper] = Tick(upperOld, old.nextTick, amount, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
            } else {
                ticks[upper] = Tick(upperOld, old.nextTick, amount, 0, 0);
            }

            old.nextTick = upper;
        }

        int24 actualNearestTick = TickMath.getTickAtSqrtRatio(currentPrice);

        if (currentNearestTick < lower && lower <= actualNearestTick) currentNearestTick = lower;

        if (currentNearestTick < upper && upper <= actualNearestTick) currentNearestTick = upper;

        nearestTick = currentNearestTick;
    }

    function setPosition(
        address recipient,
        int24 lower,
        int24 upper,
        int128 amount
    ) internal {
        Position storage position = positions[recipient][lower][upper];
        if (amount < 0) position.liquidity -= uint128(amount);
        if (amount > 0) position.liquidity += uint128(amount);
    }
}