// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniswapV2Factory { function createPair(address a, address b) external returns (address); }
interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(address,uint,uint,uint,address,uint) external payable returns (uint,uint,uint);
}

/**
 * @title SimpleToken — Mint 版（一键部署，构造函数含全部参数）
 * @notice 部署者 1 笔交易完成全部配置
 *         用户通过 mint() 用 BNB 购买代币 → 自动加池子 → LP 归平台方
 */
contract SimpleToken {
    // ── Structs（避免 stack too deep） ──
    struct TokenConfig {
        string  name;
        string  symbol;
        uint256 totalSupply;
        uint256 mintPrice;       // BNB/代币（wei）
        uint256 hardCap;          // BNB 硬顶（wei）
        uint256 presalePct;       // 预售占比（%）
        uint8   openMode;         // 0=定时 1=手动 2=满额
        uint256 openTime;         // 定时模式：开盘时间戳（秒）
        uint256 fullOpenDelay;    // 满额模式：达硬顶后延迟秒数（暂未使用，预留）
        bool    whitelistOnly;    // 是否开启白名单 mint
    }
    struct FeeConfig {
        uint256 liquidityPct;     // 每笔 mint 加池子比例（%）
        uint256 buyTax;           // 基点
        uint256 sellTax;
        uint256 maxTxPct;         // %
        uint256 maxWalletPct;     // %
    }

    string public name;
    string public symbol;
    uint8  public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;
    address public platformOwner;
    address public lpReceiver;

    // ── 税费 ──
    uint256 public buyTax;
    uint256 public sellTax;
    uint256 public constant MAX_TAX = 2500;

    // ── 交易限制 ──
    uint256 public maxTxAmount;
    uint256 public maxWalletAmount;
    bool    public limitsEnabled = true;

    // ── Mint 参数 ──
    uint256 public mintPrice;
    uint256 public hardCap;
    uint256 public totalMinted;
    uint256 public presaleTokens;
    uint256 public presaleSold;
    uint256 public liquidityPct;

    // ── 开盘控制 ──
    bool    public tradingEnabled;
    uint8   public openMode;         // 0=定时 1=手动 2=满额
    uint256 public openTime;
    uint256 public fullOpenDelay;

    // ── 白名单 ──
    bool    public whitelistOnly;
    mapping(address => bool) public whitelist;

    // ── Uniswap ──
    address public uniswapRouter;
    address public uniswapPair;

    // ── 排除 ──
    mapping(address => bool) public isExcludedFromTax;
    mapping(address => bool) public isExcludedFromLimits;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Mint(address indexed buyer, uint256 bnbIn, uint256 tokenOut);
    event LiquidityAdded(uint256 tokenAmount, uint256 bnbAmount);
    event TradingEnabled();
    event TaxSet(uint256 buyTax, uint256 sellTax);
    event LimitsSet(uint256 maxTx, uint256 maxWallet);
    event WhitelistUpdated(address indexed addr, bool added);
    event WhitelistModeSet(bool enabled);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    constructor(
        address     _owner,
        address     _platformOwner,
        address     _routerAddress,
        TokenConfig memory _tc,
        FeeConfig   memory _fc
    ) {
        require(bytes(_tc.name).length > 0 && bytes(_tc.symbol).length > 0, "empty name/sym");
        require(_tc.totalSupply > 0,          "supply=0");
        require(_owner != address(0),         "owner=0");
        require(_tc.mintPrice > 0,            "price=0");
        require(_tc.presalePct <= 100,        "presale>100");
        require(_fc.liquidityPct <= 100,       "liqPct>100");
        require(_tc.openMode <= 2,            "bad mode");
        require(_fc.maxTxPct <= 100 && _fc.maxWalletPct <= 100, "limit>100");
        require(_fc.buyTax <= MAX_TAX && _fc.sellTax <= MAX_TAX, "tax high");

        name          = _tc.name;
        symbol        = _tc.symbol;
        owner         = _owner;
        platformOwner = _platformOwner;
        lpReceiver    = _platformOwner;

        totalSupply   = _tc.totalSupply * 10**decimals;

        // 分配
        presaleTokens = totalSupply * _tc.presalePct / 100;
        if (presaleTokens > 0) {
            balanceOf[address(this)] = presaleTokens;
            emit Transfer(address(0), address(this), presaleTokens);
        }
        uint256 ownerTokens = totalSupply - presaleTokens;
        if (ownerTokens > 0) {
            balanceOf[_owner] = ownerTokens;
            emit Transfer(address(0), _owner, ownerTokens);
        }

        mintPrice    = _tc.mintPrice;
        hardCap      = _tc.hardCap;
        liquidityPct = _fc.liquidityPct;

        // 开盘
        openMode      = _tc.openMode;
        openTime      = _tc.openTime;
        fullOpenDelay = _tc.fullOpenDelay;

        // 白名单
        whitelistOnly = _tc.whitelistOnly;

        // 税费
        buyTax  = _fc.buyTax;
        sellTax = _fc.sellTax;

        // 交易限制
        if (_fc.maxTxPct > 0)     maxTxAmount     = totalSupply * _fc.maxTxPct / 100;
        if (_fc.maxWalletPct > 0) maxWalletAmount  = totalSupply * _fc.maxWalletPct / 100;

        // PancakeSwap（直调，不用 try/catch——优化器会剥掉 catch 里的 revert 字符串导致 0x0x）
        uniswapRouter = _routerAddress;
        IUniswapV2Router02 router = IUniswapV2Router02(_routerAddress);
        uniswapPair   = IUniswapV2Factory(router.factory()).createPair(address(this), router.WETH());

        // 排除
        isExcludedFromTax[_owner] = true;
        isExcludedFromTax[address(this)] = true;
        isExcludedFromLimits[_owner] = true;
        isExcludedFromLimits[address(this)] = true;
        isExcludedFromLimits[uniswapPair] = true;
    }

    // ═══════════ Mint ═══════════

    function mint() external payable {
        require(msg.value > 0, "zero val");
        require(totalMinted + msg.value <= hardCap, "cap reached");

        // 白名单检查
        if (whitelistOnly) require(whitelist[msg.sender], "not whitelisted");

        // 定时模式：到时间后禁止 mint
        if (openMode == 0) require(block.timestamp < openTime, "mint closed");

        // 满额模式：开盘后禁止 mint
        if (openMode == 2 && tradingEnabled) revert("trading started");

        uint256 tokenAmount = _calcTokenAmount(msg.value);
        require(presaleSold + tokenAmount <= presaleTokens, "sold out");

        uint256 liqBNB   = msg.value * liquidityPct / 100;
        uint256 liqTokens = tokenAmount * liquidityPct / 100;

        if (liqBNB > 0 && liqTokens > 0) {
            _addLiquidity(liqTokens, liqBNB);
        }

        uint256 buyAmount = tokenAmount - liqTokens;
        balanceOf[address(this)] -= tokenAmount;
        balanceOf[msg.sender] += buyAmount;
        emit Transfer(address(this), msg.sender, buyAmount);

        totalMinted += msg.value;
        presaleSold += tokenAmount;

        emit Mint(msg.sender, msg.value, buyAmount);

        // 满额模式：达到硬顶自动开盘
        if (openMode == 2 && totalMinted >= hardCap) {
            tradingEnabled = true;
            emit TradingEnabled();
        }
    }

    function _calcTokenAmount(uint256 bnbAmount) internal view returns (uint256) {
        return bnbAmount * 10**decimals / mintPrice;
    }

    function _addLiquidity(uint256 tokenAmount, uint256 bnbAmount) internal {
        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);
        allowance[address(this)][uniswapRouter] = tokenAmount;
        (, , uint256 lpTokens) = router.addLiquidityETH{value: bnbAmount}(
            address(this), tokenAmount, 0, 0, address(this), block.timestamp + 3600
        );
        IERC20(uniswapPair).transfer(lpReceiver, lpTokens);
        emit LiquidityAdded(tokenAmount, bnbAmount);
    }

    // ═══════════ 开盘控制 ═══════════

    /// 手动开盘（仅 owner / platformOwner）
    function enableTrading() external {
        require(msg.sender == owner || msg.sender == platformOwner, "not allowed");
        tradingEnabled = true;
        emit TradingEnabled();
    }

    /// 修改开盘配置（仅 owner，手动模式可后续调整）
    function setOpenConfig(uint8 _mode, uint256 _openTime, uint256 _delay) external onlyOwner {
        openMode      = _mode;
        openTime      = _openTime;
        fullOpenDelay = _delay;
    }

    // ═══════════ 管理员 ═══════════

    function setTax(uint256 _buyTax, uint256 _sellTax) external onlyOwner {
        require(_buyTax <= MAX_TAX && _sellTax <= MAX_TAX, "tax high");
        buyTax  = _buyTax;
        sellTax = _sellTax;
        emit TaxSet(_buyTax, _sellTax);
    }

    function setLimits(uint256 _maxTxPct, uint256 _maxWalletPct) external onlyOwner {
        require(_maxTxPct <= 100 && _maxWalletPct <= 100, "bad pct");
        maxTxAmount     = totalSupply * _maxTxPct / 100;
        maxWalletAmount  = totalSupply * _maxWalletPct / 100;
        emit LimitsSet(maxTxAmount, maxWalletAmount);
    }

    function disableLimits() external onlyOwner {
        limitsEnabled = false;
    }

    // ═══════════ 白名单管理 ═══════════

    /// 批量添加
    function addToWhitelist(address[] calldata addrs) external onlyOwner {
        for (uint i = 0; i < addrs.length; i++) {
            whitelist[addrs[i]] = true;
            emit WhitelistUpdated(addrs[i], true);
        }
    }

    /// 移除
    function removeFromWhitelist(address addr) external onlyOwner {
        whitelist[addr] = false;
        emit WhitelistUpdated(addr, false);
    }

    /// 开关白名单模式
    function setWhitelistOnly(bool _enabled) external onlyOwner {
        whitelistOnly = _enabled;
        emit WhitelistModeSet(_enabled);
    }

    // ═══════════ 转账 ═══════════

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "insuf");
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
        require(balanceOf[from] >= amount, "insuf bal");

        if (from != owner && to != owner && from != address(this)) {
            require(tradingEnabled, "not open");
        }

        if (limitsEnabled) {
            if (!isExcludedFromLimits[from] && !isExcludedFromLimits[to]) {
                if (to != uniswapPair && to != address(this)) {
                    require(balanceOf[to] + amount <= maxWalletAmount || maxWalletAmount == 0, "wallet cap");
                }
                if (from != uniswapPair) {
                    require(amount <= maxTxAmount || maxTxAmount == 0, "tx cap");
                }
            }
        }

        uint256 tax = 0;
        if (!isExcludedFromTax[from] && !isExcludedFromTax[to]) {
            bool isBuy  = from == uniswapPair;
            bool isSell = to == uniswapPair;
            if (isBuy)  tax = amount * buyTax  / 10000;
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

    // ═══════════ 提取 ═══════════

    function withdrawBNB() external onlyOwner {
        (bool sent,) = lpReceiver.call{value: address(this).balance}("");
        require(sent);
    }

    function withdrawToken(address tkn) external onlyOwner {
        IERC20(tkn).transfer(lpReceiver, IERC20(tkn).balanceOf(address(this)));
    }

    receive() external payable {}
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address,uint256) external returns (bool);
}
