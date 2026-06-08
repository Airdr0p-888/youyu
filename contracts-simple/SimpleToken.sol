// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniswapV2Factory { function createPair(address a, address b) external returns (address); }
interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(address,uint,uint,uint,address,uint) external payable returns (uint,uint,uint);
}

/**
 * @title SimpleToken — Mint 版（扁平参数，兼容 ethers.js CREATE2 部署）
 * @notice 18 个平铺构造函数参数（无 struct，避免 ABI 编码问题）
 *         用户通过 mint() 用 BNB 购买代币 → 自动加池子 → LP 归平台方
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
    uint8   public openMode;
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

    // ── Custom errors ──
    error EmptyNameSym();
    error SupplyZero();
    error OwnerZero();
    error PriceZero();
    error PresaleOver100();
    error LiqPctOver100();
    error BadMode();
    error LimitOver100();
    error TaxTooHigh();
    error NotOwner();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    /// @param _name           代币名称
    /// @param _symbol         代币符号
    /// @param _totalSupply    总供应量（如 1000000，自动×10^18）
    /// @param _owner          Owner 地址
    /// @param _platformOwner  平台方钱包（收 LP）
    /// @param _routerAddress  PancakeSwap Router
    /// @param _mintPrice      Mint 单价（wei，如 0.001 ether = 1000000000000000）
    /// @param _hardCap        硬顶（wei）
    /// @param _presalePct     预售占比（%）
    /// @param _liqPct         每笔 mint 加池子比例（%）
    /// @param _buyTax         买入税（bps）
    /// @param _sellTax        卖出税（bps）
    /// @param _maxTxPct       单笔交易上限（%）
    /// @param _maxWalletPct   单钱包持仓上限（%）
    /// @param _openMode       开盘模式 0=定时 1=手动 2=满额
    /// @param _openTime       定时模式开盘时间戳（秒，其他模式传 0）
    /// @param _fullOpenDelay  满额模式达硬顶后延迟秒数（传 0 用默认 300）
    /// @param _whitelistOnly  是否仅白名单可 mint
    constructor(
        string  memory _name,
        string  memory _symbol,
        uint256         _totalSupply,
        address         _owner,
        address         _platformOwner,
        address         _routerAddress,
        uint256         _mintPrice,
        uint256         _hardCap,
        uint256         _presalePct,
        uint256         _liqPct,
        uint256         _buyTax,
        uint256         _sellTax,
        uint256         _maxTxPct,
        uint256         _maxWalletPct,
        uint8           _openMode,
        uint256         _openTime,
        uint256         _fullOpenDelay,
        bool            _whitelistOnly
    ) {
        if (bytes(_name).length == 0 || bytes(_symbol).length == 0) revert EmptyNameSym();
        if (_totalSupply == 0) revert SupplyZero();
        if (_owner == address(0)) revert OwnerZero();
        if (_mintPrice == 0) revert PriceZero();
        if (_presalePct > 100) revert PresaleOver100();
        if (_liqPct > 100) revert LiqPctOver100();
        if (_openMode > 2) revert BadMode();
        if (_maxTxPct > 100 || _maxWalletPct > 100) revert LimitOver100();
        if (_buyTax > MAX_TAX || _sellTax > MAX_TAX) revert TaxTooHigh();

        name          = _name;
        symbol        = _symbol;
        owner         = _owner;
        platformOwner = _platformOwner;
        lpReceiver    = _platformOwner;

        totalSupply   = _totalSupply * 10**decimals;

        // 代币分配
        presaleTokens = totalSupply * _presalePct / 100;
        if (presaleTokens > 0) {
            balanceOf[address(this)] = presaleTokens;
            emit Transfer(address(0), address(this), presaleTokens);
        }
        uint256 ownerTokens = totalSupply - presaleTokens;
        if (ownerTokens > 0) {
            balanceOf[_owner] = ownerTokens;
            emit Transfer(address(0), _owner, ownerTokens);
        }

        mintPrice    = _mintPrice;
        hardCap      = _hardCap;
        liquidityPct = _liqPct;

        // 开盘模式
        openMode      = _openMode;
        openTime      = _openTime;
        fullOpenDelay = _fullOpenDelay;

        // 白名单
        whitelistOnly = _whitelistOnly;

        // 税费
        buyTax  = _buyTax;
        sellTax = _sellTax;

        // 交易限制
        if (_maxTxPct > 0)     maxTxAmount    = totalSupply * _maxTxPct / 100;
        if (_maxWalletPct > 0) maxWalletAmount = totalSupply * _maxWalletPct / 100;

        // PancakeSwap 创建交易对
        uniswapRouter = _routerAddress;
        IUniswapV2Router02 router = IUniswapV2Router02(_routerAddress);
        uniswapPair = IUniswapV2Factory(router.factory()).createPair(address(this), router.WETH());

        // 排除
        isExcludedFromTax[_owner] = true;
        isExcludedFromTax[address(this)] = true;
        isExcludedFromLimits[_owner] = true;
        isExcludedFromLimits[address(this)] = true;
        isExcludedFromLimits[uniswapPair] = true;
    }

    // ═══════════ Mint ═══════════

    function mint() external payable {
        if (msg.value == 0) revert PriceZero();
        if (totalMinted + msg.value > hardCap) revert("cap reached");
        if (whitelistOnly && !whitelist[msg.sender]) revert("not whitelisted");
        if (openMode == 0 && block.timestamp >= openTime) revert("mint closed");
        if (openMode == 2 && tradingEnabled) revert("trading started");

        uint256 tokenAmount = _calcTokenAmount(msg.value);
        if (presaleSold + tokenAmount > presaleTokens) revert("sold out");

        uint256 liqBNB    = msg.value * liquidityPct / 100;
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

    function enableTrading() external {
        if (msg.sender != owner && msg.sender != platformOwner) revert NotOwner();
        tradingEnabled = true;
        emit TradingEnabled();
    }

    function setOpenConfig(uint8 _mode, uint256 _openTime, uint256 _delay) external onlyOwner {
        openMode      = _mode;
        openTime      = _openTime;
        fullOpenDelay = _delay;
    }

    // ═══════════ 管理员 ═══════════

    function setTax(uint256 _buyTax, uint256 _sellTax) external onlyOwner {
        if (_buyTax > MAX_TAX || _sellTax > MAX_TAX) revert TaxTooHigh();
        buyTax  = _buyTax;
        sellTax = _sellTax;
        emit TaxSet(_buyTax, _sellTax);
    }

    function setLimits(uint256 _maxTxPct, uint256 _maxWalletPct) external onlyOwner {
        if (_maxTxPct > 100 || _maxWalletPct > 100) revert LimitOver100();
        maxTxAmount    = totalSupply * _maxTxPct / 100;
        maxWalletAmount = totalSupply * _maxWalletPct / 100;
        emit LimitsSet(maxTxAmount, maxWalletAmount);
    }

    function disableLimits() external onlyOwner {
        limitsEnabled = false;
    }

    // ═══════════ 白名单管理 ═══════════

    function addToWhitelist(address[] calldata addrs) external onlyOwner {
        for (uint i = 0; i < addrs.length; i++) {
            whitelist[addrs[i]] = true;
            emit WhitelistUpdated(addrs[i], true);
        }
    }

    function removeFromWhitelist(address addr) external onlyOwner {
        whitelist[addr] = false;
        emit WhitelistUpdated(addr, false);
    }

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
        if (allowance[from][msg.sender] < amount) revert("insuf");
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
        if (balanceOf[from] < amount) revert("insuf bal");
        if (from != owner && to != owner && from != address(this)) {
            if (!tradingEnabled) revert("not open");
        }

        if (limitsEnabled) {
            if (!isExcludedFromLimits[from] && !isExcludedFromLimits[to]) {
                if (to != uniswapPair && to != address(this)) {
                    if (balanceOf[to] + amount > maxWalletAmount && maxWalletAmount > 0) revert("wallet cap");
                }
                if (from != uniswapPair) {
                    if (amount > maxTxAmount && maxTxAmount > 0) revert("tx cap");
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
        if (!sent) revert("transfer fail");
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
