// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.2;
pragma abicoder v2;

import "./interfaces/ISwapRouter.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IBentoBox.sol";
import "./interfaces/IFlashLoan.sol";

import "./base/Multicall.sol";
import "./base/SelfPermit.sol";
import "./deployer/MasterDeployer.sol";

import "./libraries/TransferHelper.sol";

import "hardhat/console.sol";

contract SwapRouter is ISwapRouter, Multicall, SelfPermit {
    address public immutable WETH;
    address public immutable masterDeployer;
    address public immutable bento;

    constructor(
        address _WETH,
        address _masterDeployer,
        address _bento
    ) {
        WETH = _WETH;
        masterDeployer = _masterDeployer;
        bento = _bento;
        IBentoBoxV1(_bento).registerProtocol();
    }

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, "Transaction too old");
        _;
    }

    receive() external payable {
        require(msg.sender == WETH, "Not WETH");
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        pay(params.tokenIn, msg.sender, params.pool, params.amountIn);
        amountOut = IPool(params.pool).swapExactIn(
            params.tokenIn,
            params.tokenOut,
            params.recipient,
            params.unwrapBento,
            params.amountIn
        );
        require(amountOut >= params.amountOutMinimum, "Too little received");
    }

    function exactInput(ExactInputParams memory params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amount)
    {
        amount = params.amountIn;
        // Pay the first pool directly
        pay(params.path[0].tokenIn, msg.sender, params.path[0].pool, amount);
        return _preFundedExactInput(params);
    }

    function complexPath(ComplexPathParams memory params) external payable checkDeadline(params.deadline) {
        for (uint256 i; i < params.initialPath.length; i++) {
            if (!params.initialPath[i].preFunded) {
                pay(params.initialPath[i].tokenIn, msg.sender, params.initialPath[i].pool, params.initialPath[i].amountIn);
            }
            IPool(params.initialPath[i].pool).swapWithContext(
                params.initialPath[i].tokenIn,
                params.initialPath[i].tokenOut,
                params.initialPath[i].context,
                address(this),
                false,
                params.initialPath[i].amountIn,
                0
            );
        }

        for (uint256 i; i < params.percentagePath.length; i++) {
            uint256 balanceShares = IBentoBoxV1(bento).balanceOf(IERC20(params.percentagePath[i].tokenIn), address(this));
            uint256 balanceAmount = IBentoBoxV1(bento).toAmount(IERC20(params.percentagePath[i].tokenIn), balanceShares, false);
            uint256 transferAmount = (balanceAmount * params.percentagePath[i].balancePercentage) / uint256(10)**6;
            pay(params.percentagePath[i].tokenIn, address(this), params.percentagePath[i].pool, transferAmount);
            IPool(params.percentagePath[i].pool).swapWithContext(
                params.percentagePath[i].tokenIn,
                params.percentagePath[i].tokenOut,
                params.percentagePath[i].context,
                address(this),
                false,
                transferAmount,
                0
            );
        }

        for (uint256 i; i < params.output.length; i++) {
            uint256 balanceShares = IBentoBoxV1(bento).balanceOf(IERC20(params.output[i].token), address(this));
            uint256 balanceAmount = IBentoBoxV1(bento).toAmount(IERC20(params.output[i].token), balanceShares, false);
            require(balanceAmount >= params.output[i].minAmount, "Too little received");
            if (params.output[i].unwrapBento) {
                IBentoBoxV1(bento).withdraw(IERC20(params.output[i].token), address(this), params.output[i].to, 0, balanceShares);
            } else {
                pay(params.output[i].token, address(this), params.output[i].to, balanceShares);
            }
        }
    }

    function exactInputSingleWithNativeToken(ExactInputSingleParams calldata params)
        external
        payable
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        IBentoBoxV1(bento).deposit(IERC20(params.tokenIn), msg.sender, params.pool, params.amountIn, 0);
        amountOut = IPool(params.pool).swapExactIn(
            params.tokenIn,
            params.tokenOut,
            params.recipient,
            params.unwrapBento,
            params.amountIn
        );
        require(amountOut >= params.amountOutMinimum, "Too little received");
    }

    function exactInputWithNativeToken(ExactInputParams memory params)
        external
        payable
        checkDeadline(params.deadline)
        returns (uint256 amount)
    {
        amount = params.amountIn;
        IBentoBoxV1(bento).deposit(IERC20(params.path[0].tokenIn), msg.sender, params.path[0].pool, amount, 0);
        return _preFundedExactInput(params);
    }

    function addLiquidityUnbalanced(
        IPool.liquidityInputOptimal[] calldata liquidityInput,
        address pool,
        address to,
        uint256 deadline,
        uint256 minLiquidity
    ) external checkDeadline(deadline) returns (uint256 liquidity) {
        for (uint256 i; i < liquidityInput.length; i++) {
            if (liquidityInput[i].native) {
                IBentoBoxV1(bento).deposit(IERC20(liquidityInput[i].token), msg.sender, pool, liquidityInput[i].amount, 0);
            } else {
                uint256 shares = IBentoBoxV1(bento).toShare(IERC20(liquidityInput[i].token), liquidityInput[i].amount, false);
                IBentoBoxV1(bento).transfer(IERC20(liquidityInput[i].token), msg.sender, pool, shares);
            }
        }
        liquidity = IPool(pool).mint(to);
        require(liquidity >= minLiquidity, "Not enough liquidity minted");
    }

    function addLiquidityBalanced(
        IPool.liquidityInput[] calldata liquidityInput,
        address pool,
        address to,
        uint256 deadline
    ) external checkDeadline(deadline) returns (IPool.liquidityAmount[] memory liquidityOptimal, uint256 liquidity) {
        liquidityOptimal = IPool(pool).getOptimalLiquidityInAmounts(liquidityInput);
        for (uint256 i; i < liquidityOptimal.length; i++) {
            require(liquidityOptimal[i].amount >= liquidityInput[i].amountMin, "Amount not Optimal");
            if (liquidityInput[i].native) {
                IBentoBoxV1(bento).deposit(IERC20(liquidityOptimal[i].token), msg.sender, pool, liquidityOptimal[i].amount, 0);
            } else {
                uint256 shares = IBentoBoxV1(bento).toShare(IERC20(liquidityOptimal[i].token), liquidityOptimal[i].amount, false);
                IBentoBoxV1(bento).transfer(IERC20(liquidityOptimal[i].token), msg.sender, pool, shares);
            }
        }
        liquidity = IPool(pool).mint(to);
    }

    function depositToBentoBox(
        address token,
        uint256 amount,
        address recipient
    ) external payable {
        IBentoBoxV1(bento).deposit(IERC20(token), msg.sender, recipient, amount, 0);
    }

    function sweepBentoBoxToken(
        address token,
        uint256 amountMinimum,
        address recipient
    ) external payable {
        uint256 balanceShares = IBentoBoxV1(bento).balanceOf(IERC20(token), address(this));
        require(IBentoBoxV1(bento).toAmount(IERC20(token), balanceShares, false) >= amountMinimum, "Insufficient token");

        if (balanceShares > 0) {
            IBentoBoxV1(bento).withdraw(IERC20(token), address(this), recipient, 0, balanceShares);
        }
    }

    function sweepNativeToken(
        address token,
        uint256 amountMinimum,
        address recipient
    ) external payable {
        uint256 balanceToken = IERC20(token).balanceOf(address(this));
        require(balanceToken >= amountMinimum, "Insufficient token");

        if (balanceToken > 0) {
            TransferHelper.safeTransfer(token, recipient, balanceToken);
        }
    }

    function refundETH() external payable {
        if (address(this).balance > 0) TransferHelper.safeTransferETH(msg.sender, address(this).balance);
    }

    function unwrapWETH(uint256 amountMinimum, address recipient) external payable {
        uint256 balanceWETH = IWETH(WETH).balanceOf(address(this));
        require(balanceWETH >= amountMinimum, "Insufficient WETH");

        if (balanceWETH > 0) {
            IWETH(WETH).withdraw(balanceWETH);
            TransferHelper.safeTransferETH(recipient, balanceWETH);
        }
    }

    function _preFundedExactInput(ExactInputParams memory params) internal returns (uint256 amount) {
        amount = params.amountIn;

        for (uint256 i; i < params.path.length; i++) {
            if (params.path.length == i + 1) {
                // last hop
                amount = IPool(params.path[i].pool).swapExactIn(
                    params.path[i].tokenIn,
                    params.tokenOut,
                    params.recipient,
                    params.unwrapBento,
                    amount
                );
            } else {
                amount = IPool(params.path[i].pool).swapExactIn(
                    params.path[i].tokenIn,
                    params.path[i + 1].tokenIn,
                    params.path[i + 1].pool,
                    false,
                    amount
                );
            }
        }

        require(amount >= params.amountOutMinimum, "Too little received");
    }

    /// @param token The token to pay
    /// @param payer The entity that must pay
    /// @param recipient The entity that will receive payment
    /// @param value The amount to pay
    function pay(
        address token,
        address payer,
        address recipient,
        uint256 value
    ) internal {
        if (token == WETH && address(this).balance >= value) {
            // Deposit eth into recipient bentobox
            IBentoBoxV1(bento).deposit{value: value}(IERC20(address(0)), address(this), recipient, value, 0);
        } else {
            // Process payment via bentobox
            IBentoBoxV1(bento).transfer(IERC20(token), payer, recipient, IBentoBoxV1(bento).toShare(IERC20(token), value, false));
        }
    }
    
    function onFlashLoan(
        address sender, // account that activates flash loan from BENTO
        IERC20 token, // token to flash borrow
        uint256 amount, // token amount flash borrowed
        uint256 fee, // BENTO flash loan fee
        bytes calldata // data involved in flash loan
    ) external override {
        /// @dev Run flash loan strategy through {multiCall}.
        multiCall(data);
        /// @dev Pay back borrowed token to BENTO with fee and send any winnings to `sender`.
        uint256 payback = amount + fee; // calculate `payback` to BENTO as borrowed token `amount` + `fee`
        token.safeTransfer(msg.sender, payback); // send `payback` to BENTO
        token.safeTransfer(sender, token.balanceOf(address(this)) - payback); // skim remainder token winnings to `sender`
    }
}
