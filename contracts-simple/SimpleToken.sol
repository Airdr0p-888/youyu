// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniswapV2Factory { function createPair(address a, address b) external returns (address); }
interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(address,uint,uint,uint,address,uint)
        external payable returns (uint,uint,uint);
}

interface IDistributor {
    function updateHolder(address addr, uint256 balance) external;
    function distribute() external;
    function holdersCount() external view returns (uint256);
}

/**
 * @title SimpleToken — Mint + 独立分红版
 * @notice 18(+1) 个平铺构造函数参数（兼容 ethers.js CREATE2 部署）
 *         税费代币直接转给外部 DividendDistributor 合约处理
 *         持币人追踪由 Token 合约推送给 Distributor
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

    // ── 开盘控制 ──
    bool    public tradingEnabled;
    uint8   public openMode;
    uint256 public openTime;
    uint256 public fullOpenDelay;

    // ── 白名单 ──
    bool    public whitelistOnly;
    mapping(address => bool) public whitelist;

    // ── 分红合约 ──
    address public distributor;

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
    event DistributorSet(address indexed distributor);

    address public pendingOwner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferPending(address indexed currentOwner, address indexed pendingOwner);

    // ── Custom Errors ──
    error EmptyNameSym();
    error SupplyZero();
    error OwnerZero();
    error PriceZero();
    error BadMode();
    error LimitOver100();
    error TaxTooHigh();
    error NotOwner();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    modifier onlyPendingOwner() {
        if (msg.sender != pendingOwner) revert NotOwner();
        _;
    }

    // ── Fair Launch 硬编码参数（不可篡改） ──
    // presalePct = 50 → 50% 代币用于 mint 发放，50% 留作加池消耗
    // 每次 mint tokenAmount：用户得 tokenAmount，加池消耗 tokenAmount，共消耗 2x
    uint256 public constant presalePct = 50;
    uint256 public constant liqPct      = 100;   // 100% BNB 用于加池，平台不抽 BNB

    /// @param _name          代币名称
    /// @param _symbol       代币符号
    /// @param _totalSupply  总供应量（如 1000000，自动 ×10^18）
    /// @param _owner        Owner 地址
    /// @param _platformOwner 平台方钱包（收 LP 和手续费）
    /// @param _routerAddress PancakeSwap Router
    /// @param _mintPrice    Mint 单价（wei）
    /// @param _hardCap      硬顶（wei）
    /// @param _buyTax       买入税（bps）
    /// @param _sellTax      卖出税（bps）
    /// @param _maxTxPct     单笔交易上限（%）
    /// @param _maxWalletPct 单钱包持仓上限（%）
    /// @param _openMode     开盘模式 0=定时 1=手动 2=满额
    /// @param _openTime     定时模式开盘时间戳（秒）
    /// @param _fullOpenDelay 满额模式达硬顶后延迟秒数
    /// @param _whitelistOnly 是否仅白名单可 mint
    /// @param _distributor   分红合约地址（可选，0x0=税费留在合约里）
    constructor(
        string  memory _name,
        string  memory _symbol,
        uint256         _totalSupply,
        address         _owner,
        address         _platformOwner,
        address         _routerAddress,
        uint256         _mintPrice,
        uint256         _hardCap,
        uint256         _buyTax,
        uint256         _sellTax,
        uint256         _maxTxPct,
        uint256         _maxWalletPct,
        uint8           _openMode,
        uint256         _openTime,
        uint256         _fullOpenDelay,
        bool            _whitelistOnly,
        address         _distributor
    ) {
        if (bytes(_name).length == 0 || bytes(_symbol).length == 0) revert EmptyNameSym();
        if (_totalSupply == 0) revert SupplyZero();
        if (_owner == address(0)) revert OwnerZero();
        if (_mintPrice == 0) revert PriceZero();
        if (_openMode > 2) revert BadMode();
        if (_maxTxPct > 100 || _maxWalletPct > 100) revert LimitOver100();
        if (_buyTax > MAX_TAX || _sellTax > MAX_TAX) revert TaxTooHigh();

        name          = _name;
        symbol        = _symbol;
        owner         = _owner;
        platformOwner = _platformOwner;
        lpReceiver    = _platformOwner;
        distributor   = _distributor;

        totalSupply   = _totalSupply * 10**decimals;

        // 公平发射：50% 代币用于 mint 发放，50% 留作加池消耗
        // 每次 mint tokenAmount：用户得 tokenAmount，加池消耗 tokenAmount，共消耗 2x
        presaleTokens = totalSupply * presalePct / 100;   // = totalSupply * 50%

        mintPrice     = _mintPrice;
        hardCap       = _hardCap;

        // 100% 代币留在合约（50% 发给用户 + 50% 加池消耗）
        balanceOf[address(this)] = totalSupply;
        emit Transfer(address(0), address(this), totalSupply);

        openMode      = _openMode;
        openTime      = _openTime;
        fullOpenDelay = _fullOpenDelay;

        whitelistOnly = _whitelistOnly;

        buyTax  = _buyTax;
        sellTax = _sellTax;

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

        emit DistributorSet(_distributor);
    }

    // ╍═══════ Mint ╍═══════

    function mint() external payable {
        if (msg.value == 0) revert PriceZero();
        if (totalMinted + msg.value > hardCap) revert("cap reached");
        if (whitelistOnly && !whitelist[msg.sender]) revert("not whitelisted");
        if (openMode == 0 && block.timestamp >= openTime) revert("mint closed");
        if (openMode == 2 && tradingEnabled) revert("trading started");

        uint256 tokenAmount = _calcTokenAmount(msg.value);
        // 每次 mint 消耗 2x：tokenAmount 给用户 + tokenAmount 加池
        // 只检查合约余额，presaleTokens 仅用于前端展示
        if (balanceOf[address(this)] < tokenAmount * 2) revert("insufficient contract balance");

        uint256 liqBNB    = msg.value;                     // liqPct=100 → 100% BNB 加池
        uint256 liqTokens = tokenAmount;                    // liqPct=100 → 等量代币加池

        if (liqBNB > 0 && liqTokens > 0) {
            _addLiquidity(liqTokens, liqBNB);
        }

        // 用户获得 tokenAmount，加池消耗 tokenAmount，共消耗 2x
        balanceOf[address(this)] -= tokenAmount * 2;
        balanceOf[msg.sender] += tokenAmount;
        emit Transfer(address(this), msg.sender, tokenAmount);

        totalMinted += msg.value;
        presaleSold += tokenAmount;  // 只记录发给用户的量

        emit Mint(msg.sender, msg.value, tokenAmount);

        // 通知 distributor 更新持仓
        _notifyDistributor(msg.sender);

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

    // ╍═══════ 开盘控制 ╍═══════

    function enableTrading() external {
        if (msg.sender != owner && msg.sender != platformOwner) revert NotOwner();
        tradingEnabled = true;
        emit TradingEnabled();
    }

    function setOpenConfig(uint8 _mode, uint256 _openTime, uint256 _delay) external onlyOwner {
        openMode  = _mode;
        openTime  = _openTime;
        fullOpenDelay = _delay;
    }

    // ╍═══════ 管理员 ╍═══════

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

    function setDistributor(address _distributor) external onlyOwner {
        distributor = _distributor;
        emit DistributorSet(_distributor);
    }

    // ╍═══════ 所有权转移（两阶段，防止转错地址） ╍═══════
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert OwnerZero();
        pendingOwner = newOwner;
        emit OwnershipTransferPending(owner, newOwner);
    }

    function acceptOwnership() external onlyPendingOwner {
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    // ╍═══════ 白名单管理 ╍═══════

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

    // ╍═══════ 转账 ╍═══════

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

        bool isSell = (to == uniswapPair);

        uint256 tax = 0;
        if (!isExcludedFromTax[from] && !isExcludedFromTax[to]) {
            bool isBuy = from == uniswapPair;
            if (isBuy)  tax = amount * buyTax / 10000;
            if (isSell) tax = amount * sellTax / 10000;
        }

        balanceOf[from] -= amount;
        uint256 sendAmount = amount - tax;
        balanceOf[to] += sendAmount;
        emit Transfer(from, to, sendAmount);

        if (tax > 0) {
            // 税费：转给 distributor 或留在合约
            if (distributor != address(0)) {
                balanceOf[distributor] += tax;
                emit Transfer(from, distributor, tax);
            } else {
                balanceOf[address(this)] += tax;
                emit Transfer(from, address(this), tax);
            }
        }

        // 通知 distributor 更新持仓
        _notifyDistributor(from);
        _notifyDistributor(to);

        // 卖出后触发分红检查
        if (isSell && distributor != address(0)) {
            try IDistributor(distributor).distribute() {} catch {}
        }
    }

    /// @dev 通知 distributor 更新某地址的持仓
    function _notifyDistributor(address addr) internal {
        if (distributor == address(0)) return;
        if (addr == address(0) || addr == address(this) || addr == uniswapPair) return;
        try IDistributor(distributor).updateHolder(addr, balanceOf[addr]) {} catch {}
    }

    // ╍═══════ 提取（若未设置 distributor，税费留在合约里可提取） ╍═══════

    function withdrawBNB() external onlyOwner {
        (bool sent,) = platformOwner.call{value: address(this).balance}("");
        if (!sent) revert("transfer fail");
    }

    function withdrawToken(address tkn, uint256 amount) external onlyOwner {
        IERC20(tkn).transfer(platformOwner, amount);
    }

    function holdersCount() external view returns (uint256) {
        if (distributor == address(0)) return 0;
        return IDistributor(distributor).holdersCount();
    }

    receive() external payable {}
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address,uint256) external returns (bool);
    function approve(address,uint256) external returns (bool);
    function transferFrom(address,address,uint256) external returns (bool);
}
