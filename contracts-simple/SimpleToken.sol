// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniswapV2Factory { function createPair(address a, address b) external returns (address); }
interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(address,uint,uint,uint,address,uint)
        external payable returns (uint,uint,uint);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint,uint,address[] calldata,address,uint) external;
}

interface IDistributor {
    function updateHolder(address addr, uint256 balance) external;
    function distribute() external;
    function holdersCount() external view returns (uint256);
    function distributeBNB() external payable;  // 新增：接收 BNB 并分配
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
    mapping(address => bool) public hasMinted;
    uint256 public mintBatchSize;  // 0=任意金额, >0=固定单次BNB数量

    // ── 开盘控制 ──
    bool    public tradingEnabled;
    uint8   public openMode;
    uint256 public openTime;
    uint256 public fullOpenDelay;
    uint256 public capReachedTime;     // 满额模式：达到硬顶的时间戳，0=未满额

    // ── 白名单 ──
    bool    public whitelistOnly;
    mapping(address => bool) public whitelist;

    // ── 分红合约 ──
    address public distributor;

    // ── 税收四路分配 ──
    uint256 public taxAllocMarketing;    // bps (万分之一)
    uint256 public taxAllocBurn;         // bps
    uint256 public taxAllocLp;           // bps
    uint256 public taxAllocDistribute;   // bps
    address public marketingWallet;
    uint256 public pendingLpTokens;
    uint256 public lpSwapThreshold;
    uint256 public pendingDividendTokens;  // 累积的分红代币
    uint256 public dividendSwapThreshold;  // 分红 swap 阈值
    bool    public swapEnabled = true;
    bool    private _inSwap;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

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
    event TaxAllocationSet(uint256 marketing, uint256 burn, uint256 lp, uint256 distribute);
    event MarketingWalletSet(address indexed wallet);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 bnbAdded);
    event SellOccurred(address indexed seller, uint256 amount);

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
    error AlreadyMinted();
    error WrongMintAmount();
    error AllocSumNot100();
    error SwapInProgress();

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
    /// @param _mintBatchSize 单次固定 Mint BNB 量（wei, 0=任意）
    /// @param _buyTax       买入税（bps）
    /// @param _sellTax      卖出税（bps）
    /// @param _maxTxPct     单笔交易上限（%）
    /// @param _maxWalletPct 单钱包持仓上限（%）
    /// @param _openMode     开盘模式 0=定时 1=手动 2=满额
    /// @param _openTime     定时模式开盘时间戳（秒）
    /// @param _fullOpenDelay 满额模式达硬顶后延迟秒数
    /// @param _whitelistOnly 是否仅白名单可 mint
    /// @param _distributor   分红合约地址（可选，0x0=税费留在合约里）
    /// @param _taxAllocMarketing 营销比例（bps）
    /// @param _taxAllocBurn      销毁比例（bps）
    /// @param _taxAllocLp        回流底池比例（bps）
    /// @param _taxAllocDistribute 分红比例（bps）
    /// @param _marketingWallet   营销收款地址
    constructor(
        string  memory _name,
        string  memory _symbol,
        uint256         _totalSupply,
        address         _owner,
        address         _platformOwner,
        address         _routerAddress,
        uint256         _mintPrice,
        uint256         _hardCap,
        uint256         _mintBatchSize,
        uint256         _buyTax,
        uint256         _sellTax,
        uint256         _maxTxPct,
        uint256         _maxWalletPct,
        uint8           _openMode,
        uint256         _openTime,
        uint256         _fullOpenDelay,
        bool            _whitelistOnly,
        address         _distributor,
        uint256         _taxAllocMarketing,
        uint256         _taxAllocBurn,
        uint256         _taxAllocLp,
        uint256         _taxAllocDistribute,
        address         _marketingWallet
    ) {
        if (bytes(_name).length == 0 || bytes(_symbol).length == 0) revert EmptyNameSym();
        if (_totalSupply == 0) revert SupplyZero();
        if (_owner == address(0)) revert OwnerZero();
        if (_mintPrice == 0) revert PriceZero();
        if (_openMode > 2) revert BadMode();
        if (_maxTxPct > 100 || _maxWalletPct > 100) revert LimitOver100();
        if (_buyTax > MAX_TAX || _sellTax > MAX_TAX) revert TaxTooHigh();
        if (_taxAllocMarketing + _taxAllocBurn + _taxAllocLp + _taxAllocDistribute != 10000) revert AllocSumNot100();

        name            = _name;
        symbol          = _symbol;
        owner           = _owner;
        platformOwner   = _platformOwner;
        lpReceiver      = _platformOwner;
        distributor     = _distributor;
        taxAllocMarketing = _taxAllocMarketing;
        taxAllocBurn      = _taxAllocBurn;
        taxAllocLp        = _taxAllocLp;
        taxAllocDistribute = _taxAllocDistribute;
        marketingWallet      = _marketingWallet;
        lpSwapThreshold      = totalSupply * 1 / 100000;   // 0.001% 总供应量
        dividendSwapThreshold = totalSupply * 1 / 100000;   // 0.001% 总供应量

        totalSupply   = _totalSupply * 10**decimals;

        // 公平发射：50% 代币用于 mint 发放，50% 留作加池消耗
        // 每次 mint tokenAmount：用户得 tokenAmount，加池消耗 tokenAmount，共消耗 2x
        presaleTokens = totalSupply * presalePct / 100;   // = totalSupply * 50%

        mintPrice     = _mintPrice;
        hardCap       = _hardCap;
        mintBatchSize = _mintBatchSize;

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
        if (_distributor != address(0)) {
            isExcludedFromTax[_distributor] = true;
        }

        emit DistributorSet(_distributor);
    }

    // ╍═══════ Mint ╍═══════

    function mint() external payable {
        if (msg.value == 0) revert PriceZero();
        if (hasMinted[msg.sender]) revert AlreadyMinted();
        if (mintBatchSize > 0 && msg.value != mintBatchSize) revert WrongMintAmount();
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
            // ⚠️ _addLiquidity → addLiquidityETH → _transfer 已扣了 LP 部分
            //    这里只需再扣用户部分，不能重复扣 LP 部分
        }

        // 用户获得 tokenAmount
        // LP 部分已在 _addLiquidity 内部的 _transfer 中扣除 (balanceOf[this] -= amountA)
        balanceOf[address(this)] -= tokenAmount;
        balanceOf[msg.sender] += tokenAmount;
        hasMinted[msg.sender] = true;
        emit Transfer(address(this), msg.sender, tokenAmount);

        totalMinted += msg.value;
        presaleSold += tokenAmount;  // 只记录发给用户的量

        emit Mint(msg.sender, msg.value, tokenAmount);

        // 通知 distributor 更新持仓
        _notifyDistributor(msg.sender);

        if (openMode == 2 && totalMinted >= hardCap && capReachedTime == 0) {
            capReachedTime = block.timestamp;
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
        if (_distributor != address(0)) {
            isExcludedFromTax[_distributor] = true;
        }
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
            // Mode 2 (满额模式): capReachedTime + fullOpenDelay 后才算开启
            bool isOpen = tradingEnabled;
            if (!isOpen && openMode == 2 && capReachedTime > 0 && block.timestamp >= capReachedTime + fullOpenDelay) {
                isOpen = true;
            }
            if (!isOpen) revert("not open");
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
            // LP回流：累积到合约，后续 swapAndLiquify
            if (taxAllocLp > 0) {
                uint256 lpAmt = tax * taxAllocLp / 10000;
                if (lpAmt > 0) {
                    balanceOf[address(this)] += lpAmt;
                    pendingLpTokens += lpAmt;
                    emit Transfer(from, address(this), lpAmt);
                }
            }
            // 销毁：发送到 0xdead
            if (taxAllocBurn > 0) {
                uint256 burnAmt = tax * taxAllocBurn / 10000;
                if (burnAmt > 0) {
                    balanceOf[DEAD] += burnAmt;
                    emit Transfer(from, DEAD, burnAmt);
                }
            }
            // 营销：发送到项目方钱包
            if (taxAllocMarketing > 0 && marketingWallet != address(0)) {
                uint256 mktAmt = tax * taxAllocMarketing / 10000;
                if (mktAmt > 0) {
                    balanceOf[marketingWallet] += mktAmt;
                    emit Transfer(from, marketingWallet, mktAmt);
                }
            }
            // 分红：累积到合约，由合约统一 swap 后发给分红合约
            if (taxAllocDistribute > 0) {
                uint256 distAmt = tax * taxAllocDistribute / 10000;
                if (distAmt > 0) {
                    balanceOf[address(this)] += distAmt;
                    pendingDividendTokens += distAmt;
                    emit Transfer(from, address(this), distAmt);
                }
            }
            // 自动触发 LP 回流（超过阈值且非 swap 中）
            if (swapEnabled && !_inSwap && pendingLpTokens >= lpSwapThreshold && lpSwapThreshold > 0) {
                _swapAndLiquify();
            }
            // 自动触发分红代币 swap（超过阈值且非 swap 中）
            if (swapEnabled && !_inSwap && pendingDividendTokens >= dividendSwapThreshold && dividendSwapThreshold > 0) {
                _swapAndDistributeDividend();
            }
        }

        // 通知 distributor 更新持仓
        _notifyDistributor(from);
        _notifyDistributor(to);

        // 卖出后仅发出事件，由外部独立调用 distribute()
        if (isSell && distributor != address(0)) {
            emit SellOccurred(from, amount);
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

    // ╍═══════ 税收分配管理 ╍═══════

    function setTaxAllocation(uint256 _marketing, uint256 _burn, uint256 _lp, uint256 _distribute) external onlyOwner {
        if (_marketing + _burn + _lp + _distribute != 10000) revert AllocSumNot100();
        taxAllocMarketing = _marketing;
        taxAllocBurn      = _burn;
        taxAllocLp        = _lp;
        taxAllocDistribute = _distribute;
        emit TaxAllocationSet(_marketing, _burn, _lp, _distribute);
    }

    function setMarketingWallet(address _wallet) external onlyOwner {
        marketingWallet = _wallet;
        emit MarketingWalletSet(_wallet);
    }

    function setSwapThreshold(uint256 _threshold) external onlyOwner {
        lpSwapThreshold = _threshold;
    }

    function setDividendSwapThreshold(uint256 _threshold) external onlyOwner {
        dividendSwapThreshold = _threshold;
    }

    function setSwapEnabled(bool _enabled) external onlyOwner {
        swapEnabled = _enabled;
    }

    // ╍═══════ LP 回流 ╍═══════

    /// @notice 任何人可调用，将累积的 LP 税款兑换成 BNB 并添加流动性
    function swapAndLiquify() external {
        if (_inSwap) revert SwapInProgress();
        if (pendingLpTokens == 0) return;
        _swapAndLiquify();
    }

    function _swapAndLiquify() internal {
        _inSwap = true;

        uint256 half = pendingLpTokens / 2;
        uint256 otherHalf = pendingLpTokens - half;
        pendingLpTokens = 0;

        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        // 一半换 BNB
        allowance[address(this)][uniswapRouter] = half;
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            half, 0, path, address(this), block.timestamp
        ) {} catch {
            // swap 失败，恢复 pendingLpTokens
            pendingLpTokens = half + otherHalf;
            _inSwap = false;
            return;
        }

        uint256 bnbGot = address(this).balance;
        if (bnbGot > 0 && otherHalf > 0) {
            allowance[address(this)][uniswapRouter] = allowance[address(this)][uniswapRouter] + otherHalf;
            try router.addLiquidityETH{value: bnbGot}(
                address(this), otherHalf, 0, 0, DEAD, block.timestamp + 3600
            ) {} catch {}
        }
        _inSwap = false;
        emit SwapAndLiquify(half + otherHalf, bnbGot);
    }

    receive() external payable {}

    // ╍═════ 分红代币 Swap 与分发 ╍═════

    /// @notice 任何人可调用，将累积的分红代币兑换成 BNB 并发送给分红合约
    function swapAndDistributeDividend() external {
        if (_inSwap) revert SwapInProgress();
        if (pendingDividendTokens == 0) return;
        _swapAndDistributeDividend();
    }

    function _swapAndDistributeDividend() internal {
        _inSwap = true;

        uint256 tokensToSwap = pendingDividendTokens;
        pendingDividendTokens = 0;

        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        allowance[address(this)][uniswapRouter] = tokensToSwap;

        uint256 bnbBefore = address(this).balance;

        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokensToSwap, 0, path, address(this), block.timestamp + 60
        ) {} catch {
            // swap 失败，恢复 pendingDividendTokens
            pendingDividendTokens = tokensToSwap;
            _inSwap = false;
            return;
        }

        uint256 bnbReceived = address(this).balance - bnbBefore;
        _inSwap = false;

        // 直接将 BNB 发送给分红合约，触发 receive() → distributeBNB()
        if (bnbReceived > 0 && distributor != address(0)) {
            (bool sent,) = distributor.call{value: bnbReceived}("");
            // sent=false 说明发送失败，BNB 留在代币合约，可由 owner 通过 withdrawBNB() 取出
            if (!sent) {
                pendingDividendTokens = bnbReceived; // 恢复待处理量，等待下次重试
            }
        }
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address,uint256) external returns (bool);
    function approve(address,uint256) external returns (bool);
    function transferFrom(address,address,uint256) external returns (bool);
}
