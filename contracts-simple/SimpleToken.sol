// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniswapV2Factory { function createPair(address a, address b) external returns (address); }
interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(address,uint,uint,uint,address,uint) external payable returns (uint,uint,uint);
}
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112,uint112,uint32);
}

/**
 * @title SimpleToken
 * @notice 极简发币合约 — 构造函数接受 BNB，自动加初始流动性
 */
contract SimpleToken {
    string public name;
    string public symbol;
    uint8  public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;
    address public platformOwner;
    address public lpReceiver;

    // 税费（基点，100=1%）
    uint256 public buyTax  = 500;
    uint256 public sellTax = 500;
    uint256 public constant MAX_TAX = 2500;

    // 交易限制
    uint256 public maxTxAmount;
    uint256 public maxWalletAmount;
    bool    public limitsEnabled = true;

    // 开盘控制
    bool    public tradingEnabled;
    uint8  public openMode;
    uint256 public openTime;
    uint256 public hardCapBNB;

    // Uniswap
    address public uniswapRouter;
    address public uniswapPair;

    // 排除列表
    mapping(address => bool) public isExcludedFromTax;
    mapping(address => bool) public isExcludedFromLimits;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TradingEnabled();
    event TaxSet(uint256 buyTax, uint256 sellTax);
    event LimitsSet(uint256 maxTx, uint256 maxWallet);
    event LiquidityAdded(uint256 tokenAmount, uint256 bnbAmount, uint256 lpTokens);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    /**
     * @param _initialLiquidityPct 多少百分比代币用于初始流动性 (1-100)，0=不加池子
     */
    constructor(
        string  memory _name,
        string  memory _symbol,
        uint256        _totalSupply,
        address        _owner,
        address        _platformOwner,
        address        _routerAddress,
        uint256        _buyTax,
        uint256        _sellTax,
        uint256        _maxTxPct,
        uint256        _maxWalletPct,
        uint256        _initialLiquidityPct
    ) payable {
        require(bytes(_name).length > 0 && bytes(_symbol).length > 0, "empty");
        require(_totalSupply > 0, "zero supply");
        require(_owner != address(0), "zero owner");
        require(_initialLiquidityPct <= 100, "pct>100");

        name   = _name;
        symbol = _symbol;
        owner  = _owner;
        platformOwner = _platformOwner;
        lpReceiver = _platformOwner;

        totalSupply = _totalSupply * 10**decimals;

        // 根据 _initialLiquidityPct 分配代币
        uint256 liqTokens = totalSupply * _initialLiquidityPct / 100;
        uint256 ownerTokens = totalSupply - liqTokens;

        if (ownerTokens > 0) {
            balanceOf[_owner] = ownerTokens;
            emit Transfer(address(0), _owner, ownerTokens);
        }
        if (liqTokens > 0) {
            balanceOf[address(this)] = liqTokens;
            emit Transfer(address(0), address(this), liqTokens);
        }

        // 设置 router + 创建交易对
        uniswapRouter = _routerAddress;
        IUniswapV2Router02 router = IUniswapV2Router02(_routerAddress);
        uniswapPair = IUniswapV2Factory(router.factory()).createPair(address(this), router.WETH());

        // 税费
        require(_buyTax <= MAX_TAX && _sellTax <= MAX_TAX, "tax too high");
        buyTax  = _buyTax;
        sellTax = _sellTax;

        // 限制
        if (_maxTxPct > 0)      maxTxAmount = totalSupply * _maxTxPct / 100;
        if (_maxWalletPct > 0) maxWalletAmount = totalSupply * _maxWalletPct / 100;

        // 排除
        isExcludedFromTax[_owner] = true;
        isExcludedFromTax[address(this)] = true;
        isExcludedFromLimits[_owner] = true;
        isExcludedFromLimits[address(this)] = true;
        isExcludedFromLimits[uniswapPair] = true;

        // ── 自动加初始流动性 ──
        if (liqTokens > 0 && msg.value > 0) {
            _addInitialLiquidity(liqTokens, msg.value);
        }
    }

    /**
     * @dev 内部函数：加流动性 + 转 LP + 开启交易
     */
    function _addInitialLiquidity(uint256 tokenAmount, uint256 bnbAmount) internal {
        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);

        // approve router 花费代币
        allowance[address(this)][uniswapRouter] = tokenAmount;

        // 加流动性，LP 先发给合约自己
        (, , uint256 lpTokens) = router.addLiquidityETH{value: bnbAmount}(
            address(this),
            tokenAmount,
            0,              // amountTokenMin (设为0，不设置最小)
            0,              // amountETHMin
            address(this),  // LP 先到合约
            block.timestamp + 3600
        );

        // 把 LP token（ERC20）转给平台方
        IERC20(uniswapPair).transfer(lpReceiver, lpTokens);

        // 开启交易
        tradingEnabled = true;
        emit TradingEnabled();
        emit LiquidityAdded(tokenAmount, bnbAmount, lpTokens);
    }

    // ═══════════ 转账 ═══════════
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");

        // 交易开关（跳过 owner 和合约自己）
        if (from != owner && to != owner && from != address(this)) {
            require(tradingEnabled, "trading not enabled");
        }

        // 交易限制检查
        if (limitsEnabled) {
            if (!isExcludedFromLimits[from] && !isExcludedFromLimits[to]) {
                if (to != uniswapPair && to != address(this)) {
                    require(balanceOf[to] + amount <= maxWalletAmount || maxWalletAmount == 0, "exceeds max wallet");
                }
                if (from != uniswapPair) {
                    require(amount <= maxTxAmount || maxTxAmount == 0, "exceeds max tx");
                }
            }
        }

        // 税费计算
        uint256 tax = 0;
        if (!isExcludedFromTax[from] && !isExcludedFromTax[to]) {
            bool isBuy  = from == uniswapPair;
            bool isSell = to == uniswapPair;
            if (isBuy)  tax = amount * buyTax / 10000;
            if (isSell) tax = amount * sellTax / 10000;
        }

        balanceOf[from] -= amount;
        uint256 sendAmount = amount - tax;
        balanceOf[to] += sendAmount;
        emit Transfer(from, to, sendAmount);

        if (tax > 0) {
            balanceOf[address(this)] += tax;
            emit Transfer(from, address(this), tax);
        }
    }

    // ═══════════ 开盘控制 ═══════════
    function enableTrading() external onlyOwner {
        tradingEnabled = true;
        emit TradingEnabled();
    }

    function setOpenMode(uint8 _mode, uint256 _time, uint256 _cap) external onlyOwner {
        openMode = _mode;
        openTime = _time;
        hardCapBNB = _cap;
    }

    // ═══════════ 管理员设置 ═══════════
    function setTax(uint256 _buyTax, uint256 _sellTax) external onlyOwner {
        require(_buyTax <= MAX_TAX && _sellTax <= MAX_TAX, "tax too high");
        buyTax = _buyTax;
        sellTax = _sellTax;
        emit TaxSet(_buyTax, _sellTax);
    }

    function setLimits(uint256 _maxTxPct, uint256 _maxWalletPct) external onlyOwner {
        maxTxAmount = totalSupply * _maxTxPct / 100;
        maxWalletAmount = totalSupply * _maxWalletPct / 100;
        emit LimitsSet(maxTxAmount, maxWalletAmount);
    }

    function disableLimits() external onlyOwner {
        limitsEnabled = false;
    }

    function setLpReceiver(address _lpReceiver) external onlyOwner {
        lpReceiver = _lpReceiver;
    }

    function withdrawStuckBNB() external onlyOwner {
        (bool sent,) = lpReceiver.call{value: address(this).balance}("");
        require(sent);
    }

    function withdrawStuckToken(address token) external onlyOwner {
        IERC20(token).transfer(lpReceiver, IERC20(token).balanceOf(address(this)));
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address,uint256) external returns (bool);
    function transferFrom(address,address,uint256) external returns (bool);
}
