// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV2Router02 {
    function WETH() external view returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path,
        address to, uint deadline
    ) external;
}

/**
 * @title SimpleDividend
 * @notice 持币分红 BNB — 按持仓比例分配
 *          每笔 BNB 打入即按比例分配（通过 accPerShare 机制）
 */
contract SimpleDividend {
    address public immutable TOKEN;
    address public immutable ADMIN;   // 平台方
    address public constant PANCAKE = 0x10ed43C718714Eb63d5aa57B78b5c4bF50eBF4E7;

    uint256 public totalDistributed;
    uint256 public accPerShare;        // 每单位 token 累计分红
    uint256 public precision = 1e18;

    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public realised;
    mapping(address => bool) public isExcluded;

    event Distribute(uint256 amount);
    event Claim(address indexed user, uint256 amount);

    constructor(address _token, address _admin) {
        TOKEN = _token;
        ADMIN = _admin;
    }

    receive() external payable {
        _distribute(msg.value);
    }

    function _distribute(uint256 amount) internal {
        uint256 supply = IERC20(TOKEN).totalSupply();
        if (supply == 0 || amount == 0) return;
        accPerShare += amount * precision / supply;
        totalDistributed += amount;
        emit Distribute(amount);
    }

    function _update(address user) internal {
        if (isExcluded[user]) return;
        uint256 bal = IERC20(TOKEN).balanceOf(user);
        uint256 pending = bal * accPerShare / precision - rewardDebt[user];
        rewardDebt[user] = bal * accPerShare / precision;
        realised[user] += pending;
    }

    function claim() external {
        _update(msg.sender);
        uint256 bal = IERC20(TOKEN).balanceOf(msg.sender);
        uint256 pending = bal * accPerShare / precision - rewardDebt[msg.sender];
        if (pending > 0) {
            rewardDebt[msg.sender] = bal * accPerShare / precision;
            (bool sent,) = msg.sender.call{value: pending}("");
            require(sent, "claim failed");
            emit Claim(msg.sender, pending);
        }
    }

    // ===== 管理员 =====
    function distributeBNB() external payable onlyAdmin {
        _distribute(msg.value);
    }

    function swapTokensForBNB(uint256 amount) external onlyAdmin {
        address[] memory path = new address[](2);
        path[0] = TOKEN;
        path[1] = IUniswapV2Router02(PANCAKE).WETH();
        IERC20(TOKEN).approve(PANCAKE, amount);
        IUniswapV2Router02(PANCAKE).swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), block.timestamp + 3600
        );
    }

    function setExcluded(address user, bool excluded) external onlyAdmin {
        isExcluded[user] = excluded;
        if (excluded) {
            rewardDebt[user] = IERC20(TOKEN).balanceOf(user) * accPerShare / precision;
        }
    }

    function withdrawStuckBNB(address to) external onlyAdmin {
        (bool sent,) = to.call{value: address(this).balance}("");
        require(sent);
    }

    modifier onlyAdmin() {
        require(msg.sender == ADMIN, "not admin");
        _;
    }
}
