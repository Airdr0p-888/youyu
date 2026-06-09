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
    function distributeBNB() external payable;
}

/**
 * @title SimpleToken — Mint + 独立分红版
 * @notice 税费代币 swap 成 BNB 后发送给分红合约，由分红合约完成分配
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
    uint256 public mintBatchSize;

    // ── 开盘控制 ──
    bool    public tradingEnabled;
    uint8   public openMode;
    uint256 public openTime;
    uint256 public fullOpenDelay;
    uint256 public capReachedTime;

    // ── 白名单 ──
    bool    public whitelistOnly;
    mapping(address => bool) public whitelist;

    // ── 分红合约 ──
    address public distributor;

    // ── 税收四路分配 ──
    uint256 public taxAllocMarketing;
    uint256 public taxAllocBurn;
    uint256 public taxAllocLp;
    uint256 public taxAllocDistribute;
    address public marketingWallet;
    uint256 public pendingMarketingTokens;
    uint256 public marketingSwapThreshold;
    uint256 public pendingLpTokens;
    uint256 public lpSwapThreshold;
    uint256 public pendingDividendTokens;
    uint256 public dividendSwapThreshold;
    bool    public swapEnabled = true;
    bool    private _inSwap;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ── Uniswap ──
    address public uniswapRouter;
    address public uniswapPair;

    // ── 排除 ──
    mapping(address => bool) public isExcludedFromTax;
    mapping(address => bool) public isExcludedFromLimits;

    // ── Events ──
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
    event SwapAndDistributeFailed(string reason, uint256 amount);

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
    error CapReached();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyPendingOwner() {
        if (msg.sender != pendingOwner) revert NotOwner();
        _;
    }

    uint256 public constant presalePct = 50;
    uint256 public constant liqPct      = 100;

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

        name               = _name;
        symbol             = _symbol;
        owner              = _owner;
        platformOwner      = _platformOwner;
        lpReceiver         = _platformOwner;
        distributor        = _distributor;
        taxAllocMarketing = _taxAllocMarketing;
        taxAllocBurn      = _taxAllocBurn;
        taxAllocLp        = _taxAllocLp;
        taxAllocDistribute = _taxAllocDistribute;
        marketingWallet    = _marketingWallet;
        lpSwapThreshold   = _totalSupply * 10**decimals / 100000;   // 0.001%
        dividendSwapThreshold = _totalSupply * 10**decimals / 100000; // 0.001%
        marketingSwapThreshold = _totalSupply * 10**decimals / 100000; // 0.001%

        totalSupply = _totalSupply * 10**decimals;
        presaleTokens = totalSupply * presalePct / 100;

        mintPrice     = _mintPrice;
        hardCap       = _hardCap;
        mintBatchSize = _mintBatchSize;

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

        uniswapRouter = _routerAddress;
        IUniswapV2Router02 router = IUniswapV2Router02(_routerAddress);
        uniswapPair = IUniswapV2Factory(router.factory()).createPair(address(this), router.WETH());

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
        if (totalMinted + msg.value > hardCap) revert CapReached();
        if (whitelistOnly && !whitelist[msg.sender]) revert("not whitelisted");
        if (openMode == 0 && block.timestamp >= openTime) revert("mint closed");
        if (openMode == 2 && tradingEnabled) revert("trading started");

        uint256 tokenAmount = _calcTokenAmount(msg.value);
        // 用 presaleTokens - presaleSold 检查剩余可 mint 量，不受税费代币影响
        if (presaleTokens - presaleSold < tokenAmount) revert("insufficient contract balance");

        uint256 liqBNB    = msg.value;
        uint256 liqTokens = tokenAmount;

        if (liqBNB > 0 && liqTokens > 0) {
            _addLiquidity(liqTokens, liqBNB);
        }

        balanceOf[address(this)] -= tokenAmount;
        balanceOf[msg.sender] += tokenAmount;
        hasMinted[msg.sender] = true;
        emit Transfer(address(this), msg.sender, tokenAmount);

        totalMinted += msg.value;
        presaleSold += tokenAmount;

        emit Mint(msg.sender, msg.value, tokenAmount);
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

    /**
     * @notice 丢弃 owner 权限（不可逆！）
     * @dev 执行后 owner = address(0)，只有 admin 函数永久锁定。
     *      platformOwner 仍可调用 enableTrading / withdrawBNB / withdrawStuckToken
     */
    function renounceOwnership() external onlyOwner {
        address old = owner;
        owner = address(0);
        pendingOwner = address(0);
        emit OwnershipTransferred(old, address(0));
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
            if (taxAllocLp > 0) {
                uint256 lpAmt = tax * taxAllocLp / 10000;
                if (lpAmt > 0) {
                    balanceOf[address(this)] += lpAmt;
                    pendingLpTokens += lpAmt;
                    emit Transfer(from, address(this), lpAmt);
                }
            }
            if (taxAllocBurn > 0) {
                uint256 burnAmt = tax * taxAllocBurn / 10000;
                if (burnAmt > 0) {
                    balanceOf[DEAD] += burnAmt;
                    emit Transfer(from, DEAD, burnAmt);
                }
            }
            if (taxAllocMarketing > 0 && marketingWallet != address(0)) {
                uint256 mktAmt = tax * taxAllocMarketing / 10000;
                if (mktAmt > 0) {
                    balanceOf[address(this)] += mktAmt;
                    pendingMarketingTokens += mktAmt;
                    emit Transfer(from, address(this), mktAmt);
                }
            }
            if (taxAllocDistribute > 0) {
                uint256 distAmt = tax * taxAllocDistribute / 10000;
                if (distAmt > 0) {
                    balanceOf[address(this)] += distAmt;
                    pendingDividendTokens += distAmt;
                    emit Transfer(from, address(this), distAmt);
                }
            }
            // 自动触发 LP 回流
            if (swapEnabled && !_inSwap && pendingLpTokens >= lpSwapThreshold && lpSwapThreshold > 0) {
                _swapAndLiquify();
            }
            // 自动触发分红代币 swap
            if (swapEnabled && !_inSwap && pendingDividendTokens >= dividendSwapThreshold && dividendSwapThreshold > 0) {
                _swapAndDistributeDividend();
            }
            // 自动触发营销代币 swap
            if (swapEnabled && !_inSwap && pendingMarketingTokens >= marketingSwapThreshold && marketingSwapThreshold > 0) {
                _swapAndSendMarketing();
            }
        }

        _notifyDistributor(from);
        _notifyDistributor(to);

        if (isSell && distributor != address(0)) {
            emit SellOccurred(from, amount);
        }
    }

    function _notifyDistributor(address addr) internal {
        if (distributor == address(0)) return;
        if (addr == address(0) || addr == address(this) || addr == uniswapPair) return;
        try IDistributor(distributor).updateHolder(addr, balanceOf[addr]) {} catch {}
    }

    // ╍═══════ 提取 ╍═══════

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

        allowance[address(this)][uniswapRouter] = half;
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            half, 0, path, address(this), block.timestamp + 60
        ) {} catch {
            pendingLpTokens = half + otherHalf;
            _inSwap = false;
            emit SwapAndDistributeFailed("lp swap failed", half);
            return;
        }

        uint256 bnbGot = address(this).balance;
        _inSwap = false;

        if (bnbGot > 0 && otherHalf > 0) {
            allowance[address(this)][uniswapRouter] = allowance[address(this)][uniswapRouter] + otherHalf;
            try router.addLiquidityETH{value: bnbGot}(
                address(this), otherHalf, 0, 0, DEAD, block.timestamp + 3600
            ) {} catch {}
        }
        emit SwapAndLiquify(half + otherHalf, bnbGot);
    }

    receive() external payable {}

    // ╍═════ 分红代币 Swap 与分发 ╍═════

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
            pendingDividendTokens = tokensToSwap;
            _inSwap = false;
            emit SwapAndDistributeFailed("dividend swap failed", tokensToSwap);
            return;
        }

        uint256 bnbReceived = address(this).balance - bnbBefore;
        _inSwap = false;

        if (bnbReceived > 0 && distributor != address(0)) {
            (bool sent,) = distributor.call{value: bnbReceived}("");
            if (!sent) {
                emit SwapAndDistributeFailed("bnb send failed", bnbReceived);
            }
        }
    }

    // ╍═════ 营销代币 Swap 并发送 BNB ╍═════

    function swapAndSendMarketing() external {
        if (_inSwap) revert SwapInProgress();
        if (pendingMarketingTokens == 0) return;
        _swapAndSendMarketing();
    }

    function _swapAndSendMarketing() internal {
        _inSwap = true;

        uint256 tokensToSwap = pendingMarketingTokens;
        pendingMarketingTokens = 0;

        IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        allowance[address(this)][uniswapRouter] = tokensToSwap;

        uint256 bnbBefore = address(this).balance;

        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokensToSwap, 0, path, address(this), block.timestamp + 60
        ) {} catch {
            pendingMarketingTokens = tokensToSwap;
            _inSwap = false;
            emit SwapAndDistributeFailed("marketing swap failed", tokensToSwap);
            return;
        }

        uint256 bnbReceived = address(this).balance - bnbBefore;
        _inSwap = false;

        if (bnbReceived > 0 && marketingWallet != address(0)) {
            (bool sent,) = marketingWallet.call{value: bnbReceived}("");
            if (!sent) {
                emit SwapAndDistributeFailed("marketing bnb send failed", bnbReceived);
            }
        }
    }

    function setMarketingSwapThreshold(uint256 _threshold) external onlyOwner {
        marketingSwapThreshold = _threshold;
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address,uint256) external returns (bool);
    function approve(address,uint256) external returns (bool);
    function transferFrom(address,address,uint256) external returns (bool);
}
