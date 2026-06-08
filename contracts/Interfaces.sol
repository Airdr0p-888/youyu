// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice 共享接口定义 — 避免多合约重复声明导致 Identifier already declared
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
}

// ══════════════════════════════════════════════════════════════════
// SquidLaunch 子合约接口（Factory 只依赖这些，不 import 实现）
// ══════════════════════════════════════════════════════════════════

/// @notice 代币合约接口 — Factory 通过此接口调用 Token 实例
interface ISquidLaunchToken {
    function owner() external view returns (address);
    function initialize(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply,
        address _owner,
        address _routerAddress,
        bool _isPlatformProject
    ) external;
    function setRefundContract(address _refundContract) external;
    function setDividendContract(address _dividendContract) external;
    function setGuardian(address _guardian) external;
    function setUniswapRouter(address _router) external;
    function emergencyPause() external;
    function emergencyForceRefund() external;
    function transferOwnership(address _newOwner) external;
}

/// @notice 退款合约接口
interface ISquidLaunchRefund {
    function owner() external view returns (address); // actually platformOwner
    function initialize(address _tokenContract, address _platformOwner) external;
}

/// @notice 分红合约接口
interface ISquidLaunchDividend {
    function owner() external view returns (address); // actually platformOwner
    function initialize(
        address _token,
        address _platformOwner,
        address _rewardToken,
        uint256 _threshold,
        address _routerAddress
    ) external;
}
