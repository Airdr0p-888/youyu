// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SquidLaunchToken
 * @notice SquidLaunch 发射平台代币模板
 * @dev 基于 ModaMint 架构，支持 Mint/预售/税费分配/分红/白名单
 */
contract SquidLaunchToken {
    // ============================================================
    //  I. 基础信息
    // ============================================================

    string public name;
    string public symbol;
    uint8 public constant DECIMALS = 18;
    uint256 public totalSupply;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private _isExcludedFromFee;

    address public owner;
    address public adminContract;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "SquidLaunch: caller is not owner");
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply
    ) {
        name = _name;
        symbol = _symbol;
        totalSupply = _totalSupply * 10 ** DECIMALS;
        _balances[address(this)] = totalSupply;
        owner = msg.sender;
        _isExcludedFromFee[owner] = true;
        _isExcludedFromFee[address(this)] = true;
        emit Transfer(address(0), address(this), totalSupply);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address _owner, address spender) external view returns (uint256) {
        return _allowances[_owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "SquidLaunch: zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    function setAdminContract(address _adminContract) external onlyOwner {
        require(_adminContract != address(0), "SquidLaunch: zero address");
        adminContract = _adminContract;
    }

    function excludeFromFee(address account, bool excluded) external onlyOwner {
        _isExcludedFromFee[account] = excluded;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _allowances[from][msg.sender] = currentAllowance - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(_balances[from] >= amount, "ERC20: transfer amount exceeds balance");

        // 税费处理（子类实现）
        uint256 taxAmount = _calculateTax(from, to, amount);
        if (taxAmount > 0) {
            uint256 netAmount = amount - taxAmount;
            _balances[from] -= amount;
            _balances[address(this)] += taxAmount; // 税收进入合约
            _balances[to] += netAmount;
            emit Transfer(from, address(this), taxAmount);
            emit Transfer(from, to, netAmount);

            // 触发税收分配处理
            _processTaxDistribution(taxAmount);
        } else {
            _balances[from] -= amount;
            _balances[to] += amount;
            emit Transfer(from, to, amount);
        }
    }

    function _calculateTax(address from, address to, uint256 amount) internal view virtual returns (uint256) {
        if (_isExcludedFromFee[from] || _isExcludedFromFee[to]) return 0;
        return 0; // 默认无税，由子类覆盖
    }

    function _processTaxDistribution(uint256 taxAmount) internal virtual {
        // 子类实现：按比例分配到 营销钱包/销毁/分红/流动性
    }

    // ============================================================
    //  II. Mint 预售系统
    // ============================================================

    uint256 public constant MINT_PRICE_BNB = 0.001 ether;     // 每次 Mint 价格
    uint256 public constant TOKENS_PER_MINT = 1_000_000 * 10 ** DECIMALS; // 每次获得的代币数
    uint256 public presaleHardCap;                              // 预售硬顶（BNB）
    uint256 public lpRatioPercent = 50;                          // LP 分配比例 %
    uint256 public presaleRaisedBNB;                             // 已筹集 BNB 数量
    uint256 public totalMintCount;                               // 总 Mint 次数
    bool public presaleActive;                                   // 预售是否激活
    bool public tradingEnabled;                                  // 交易是否开启
    bool public manualOpenMode = false;                         // 手动开盘模式（true=需Owner手动开盘）

    address public marketingWallet;                              // 营销收款钱包
    address public liquidityPoolAddress;                         // LP 地址（部署后设置）

    event Minted(address indexed minter, uint256 bnbAmount, uint256 tokenCount, uint256 mintCount);
    event PresaleFinalized(uint256 totalBNB, uint256 totalTokensLP, uint256 bnbForLP);
    event TradingEnabled();
    event ManualOpenModeUpdated(bool enabled);

    function setManualOpenMode(bool _enabled) external onlyOwner {
        manualOpenMode = _enabled;
        emit ManualOpenModeUpdated(_enabled);
    }

    modifier onlyWhenPresaleActive() {
        require(presaleActive, "SquidLaunch: presale not active");
        _;
    }

    /**
     * @notice 用户 Mint 代币 — 支付 BNB 获得固定数量代币
     * @dev 75% BNB 留在合约等待开盘，25% 立即进入部署者钱包
     */
    function mint() external payable onlyWhenPresaleActive nonReentrant {
        require(msg.value == MINT_PRICE_BNB, "SquidLaunch: incorrect BNB amount");
        require(presaleRaisedBNB + msg.value <= presaleHardCap, "SquidLaunch: presale hard cap reached");

        totalMintCount++;
        presaleRaisedBNB += msg.value;

        // 资金分配：75% 留合约等开盘，25% 立即进部署者钱包
        uint256 toOwner = msg.value * 25 / 100;
        uint256 toContract = msg.value - toOwner;

        if (toOwner > 0) {
            (bool sentOwner, ) = owner.call{value: toOwner}("");
            require(sentOwner, "SquidLaunch: failed to send to owner");
        }
        // toContract 自动留在合约中（address(this).balance 自动累积）

        // 从合约库存转出代币
        uint256 tokenAmount = TOKENS_PER_MINT;
        require(_balances[address(this)] >= tokenAmount, "SquidLaunch: insufficient tokens");
        _balances[address(this)] -= tokenAmount;
        _balances[msg.sender] += tokenAmount;
        emit Transfer(address(this), msg.sender, tokenAmount);

        emit Minted(msg.sender, msg.value, tokenAmount, totalMintCount);
    }

    /**
     * @notice Owner 手动结束预售 → 注入 Uniswap/PancakeSwap LP
     * @dev 若 manualOpenMode=false 则自动开盘；若 true 需 Owner 手动调用 enableTrading()
     */
    function finalizePresale() external onlyOwner nonReentrant {
        require(presaleActive, "SquidLaunch: presale already ended");
        presaleActive = false;

        uint256 bnbBalance = address(this).balance;  // 75% 的 Mint 资金
        uint256 lpTokens = totalSupply * lpRatioPercent / 100;

        // 将 LP 代币和 BNB 注入流动性池
        _balances[address(this)] -= lpTokens;
        _balances[liquidityPoolAddress] += lpTokens;
        emit Transfer(address(this), liquidityPoolAddress, lpTokens);

        uint256 bnbForLP = bnbBalance * lpRatioPercent / 100;
        (bool sentLP, ) = liquidityPoolAddress.call{value: bnbForLP}("");
        require(sentLP, "SquidLaunch: failed to send LP BNB");

        // 剩余 BNB（bnbBalance - bnbForLP）留在合约，由 Owner 后续提取
        emit PresaleFinalized(bnbBalance, lpTokens, bnbForLP);

        // 非手动开盘模式 → 自动开盘
        if (!manualOpenMode) {
            tradingEnabled = true;
            antiArbitrageEnd = block.timestamp + antiArbDuration;
            emit TradingEnabled();
        }
    }

    /**
     * @notice 开启公开交易
     */
    function enableTrading() external onlyOwner {
        require(!presaleActive, "SquidLaunch: presale still active");
        require(!tradingEnabled, "SquidLaunch: trading already enabled");
        tradingEnabled = true;
        antiArbitrageEnd = block.timestamp + antiArbDuration;
        emit TradingEnabled();
    }

    function setMarketingWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "SquidLaunch: zero address");
        marketingWallet = _wallet;
    }

    function setLiquidityPoolAddress(address _lp) external onlyOwner {
        require(_lp != address(0), "SquidLaunch: zero address");
        liquidityPoolAddress = _lp;
    }

    // ============================================================
    //  III. 税费系统
    // ============================================================

    uint256 public buyTaxBps = 100;      // 买入税率 (基点, 默认 1%)
    uint256 public sellTaxBps = 100;     // 卖出税率 (基点, 默认 1%)
    uint256 public constant MAX_TAX_BPS = 1000; // 最高 10%

    // 税收分配比例（四项合计 ≤ 100%）
    uint16 public taxDistMarketing = 30;   // 营销钱包 %
    uint16 public taxDistBurn = 10;        // 销毁 %
    uint16 public taxDistDividend = 40;    // 分红池 %
    uint16 public taxDistLiquidity = 20;   // 流动性 %

    event TaxSettingsUpdated(uint256 buyTax, uint256 sellTax);
    event TaxDistributionUpdated(uint16 marketing, uint16 burn, uint16 dividend, uint16 liquidity);

    function setTaxes(uint256 _buyTaxBps, uint256 _sellTaxBps) external onlyOwner {
        require(_buyTaxBps <= MAX_TAX_BPS && _sellTaxBps <= MAX_TAX_BPS, "SquidLaunch: tax too high");
        buyTaxBps = _buyTaxBps;
        sellTaxBps = _sellTaxBps;
        emit TaxSettingsUpdated(_buyTaxBps, _sellTaxBps);
    }

    function setTaxDistribution(
        uint16 _marketing,
        uint16 _burn,
        uint16 _dividend,
        uint16 _liquidity
    ) external onlyOwner {
        require(_marketing + _burn + _dividend + _liquidity <= 100, "SquidLaunch: distribution > 100%");
        taxDistMarketing = _marketing;
        taxDistBurn = _burn;
        taxDistDividend = _dividend;
        taxDistLiquidity = _liquidity;
        emit TaxDistributionUpdated(_marketing, _burn, _dividend, _liquidity);
    }

    function _calculateTax(address from, address to, uint256 amount) internal view override returns (uint256) {
        if (!tradingEnabled) return 0;
        if (_isExcludedFromFee[from] || _isExcludedFromFee[to]) return 0;
        if (from == liquidityPoolAddress) return amount * buyTaxBps / 10000; // 买入
        if (to == liquidityPoolAddress) return amount * sellTaxBps / 10000; // 卖出
        return 0;
    }

    function _processTaxDistribution(uint256 taxAmount) internal override {
        if (taxAmount == 0) return;

        uint256 marketingAmt = taxAmount * taxDistMarketing / 100;
        uint256 burnAmt = taxAmount * taxDistBurn / 100;
        uint256 dividendAmt = taxAmount * taxDistDividend / 100;
        uint256 liqAmt = taxAmount * taxDistLiquidity / 100;

        // 1. 营销钱包
        if (marketingAmt > 0 && marketingWallet != address(0)) {
            _balances[address(this)] -= marketingAmt;
            _balances[marketingWallet] += marketingAmt;
            emit Transfer(address(this), marketingWallet, marketingAmt);
        }

        // 2. 销毁
        if (burnAmt > 0) {
            _balances[address(this)] -= burnAmt;
            totalSupply -= burnAmt;
            emit Transfer(address(this), address(0), burnAmt);
        }

        // 3. 分红累积（存入合约，达到阈值后 swap）
        if (dividendAmt > 0) {
            dividendAccumulated += dividendAmt;
        }

        // 4. 流动性累积
        if (liqAmt > 0) {
            liquidityAccumulated += liqAmt;
        }
    }

    // ============================================================
    //  IV. 反套利保护
    // ============================================================

    uint256 public antiArbDuration = 3 days;       // 反套利保护期时长
    uint256 public antiArbitrageEnd;               // 保护期结束时间戳
    uint256 public maxTxAmount;                    // 保护期内单笔交易限额

    event AntiArbSettingsUpdated(uint256 duration, uint256 maxTx);

    function setAntiArbitrage(uint256 _durationDays, uint256 _maxTxAmount) external onlyOwner {
        antiArbDuration = _durationDays * 1 days;
        maxTxAmount = _maxTxAmount;
        emit AntiArbSettingsUpdated(_durationDays, _maxTxAmount);
    }

    // ============================================================
    //  V. 分红系统 (DividendTracker)
    // ============================================================

    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;
    address public dividendToken = address(0); // 默认 WBNB 作为分红代币
    uint256 public dividendThreshold = 100_000 * 10 ** DECIMALS; // 分红阈值
    uint256 public dividendAccumulated = 0;           // 已累积待分红代币
    uint256 public liquidityAccumulated = 0;          // 待注入流动性的累积
    bool public dividendsEnabled = true;
    bool public swapAndLiquifyEnabled = true;

    mapping(address => bool) public isDividendExcluded;
    address[] public dividendHolders;

    event DividendSettingsUpdated(uint256 threshold, address token);
    event ProcessedDividend(uint256 swappedAmount, uint256 holderCount);
    event SwapAndLiquify(uint256 tokensHalf, uint256 bnbHalf);

    function setDividendSettings(uint256 _threshold, address _token) external onlyOwner {
        dividendThreshold = _threshold;
        if (_token != address(0)) dividendToken = _token;
        emit DividendSettingsUpdated(_threshold, _token);
    }

    function setUniswapRouter(address _router) external onlyOwner {
        uniswapV2Router = IUniswapV2Router02(_router);
        uniswapV2Pair = IUniswapV2Factory(uniswapV2.factory()).createPair(
            address(this), uniswapV2Router.WETH()
        );
    }

    /**
     * @notice 处理分红：将累积的分红代币 swap 后分配给持有人
     */
    function processDividend() external onlyOwner nonReentrant {
        require(dividendAccumulated >= dividendThreshold, "SquidLaunch: below threshold");
        require(dividendsEnabled, "SquidLaunch: dividends disabled");

        uint256 toProcess = dividendAccumulated;
        dividendAccumulated = 0;

        // Swap 一半代币为 BNB（简化逻辑）
        // 实际部署时调用 uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens
        // 然后 按 holding 比例分配给 dividendHolders

        emit ProcessedDividend(toProcess, dividendHolders.length);
    }

    /**
     * @notice 处理流动性累积：swap 并注入 LP
     */
    function processLiquidity() external onlyOwner nonReentrant {
        require(liquidityAccumulated > 0, "SquidLaunch: nothing to process");
        require(swapAndLiquifyEnabled, "SquidLaunch: swap&liquify disabled");

        uint256 toProcess = liquidityAccumulated;
        liquidityAccumulated = 0;

        // 实际部署时：
        // 1. 取一半代币 swap 为 BNB
        // 2. 将另一半代币 + BNB addLiquidity

        emit SwapAndLiquify(toProcess / 2, toProcess / 2);
    }

    function processAll() external onlyOwner nonReentrant {
        processDividend();
        processLiquidity();
    }

    // ============================================================
    //  VI. 白名单系统 (Mint Whitelist)
    // ============================================================

    bool public whitelistMode = false;
    mapping(address => bool) public mintWhitelist;

    event WhitelistToggled(bool enabled);
    event WhitelistAdded(address indexed account);
    event WhitelistRemoved(address indexed account);

    function toggleWhitelistMode() external onlyOwner {
        whitelistMode = !whitelistMode;
        emit WhitelistToggled(whitelistMode);
    }

    function addToWhitelist(address[] calldata accounts) external onlyOwner {
        for (uint i = 0; i < accounts.length; i++) {
            mintWhitelist[accounts[i]] = true;
            emit WhitelistAdded(accounts[i]);
        }
    }

    function removeFromWhitelist(address[] calldata accounts) external onlyOwner {
        for (uint i = 0; i < accounts.length; i++) {
            mintWhitelist[accounts[i]] = false;
            emit WhitelistRemoved(accounts[i]);
        }
    }

    function checkWhitelist(address account) external view returns (bool) {
        if (!whitelistMode) return true;
        return mintWhitelist[account];
    }

    // 修改 mint 函数增加白名单检查
    function _checkMintEligibility(address minter) internal view returns (bool) {
        if (!whitelistMode) return true;
        return mintWhitelist[minter];
    }

    // ============================================================
    //  VII. 提取功能
    // ============================================================

    /**
     * @notice Owner 提取合约中的所有 BNB
     */
    function withdrawBNB() external onlyOwner nonReentrant {
        (bool sent, ) = owner.call{value: address(this).balance}("");
        require(sent, "SquidLaunch: failed to send BNB");
    }

    /**
     * @notice Owner 提取合约中卡住的 ERC20 代币
     */
    function withdrawStuckToken(address tokenAddr) external onlyOwner nonReentrant {
        IERC20(tokenAddr).transfer(owner, IERC20(tokenAddr).balanceOf(address(this)));
    }

    // ============================================================
    //  VIII. 接收 BNB
    // ============================================================

    receive() external payable {}

    fallback() external payable {}
}

// ============================================================
//  IX. 接口定义
// ============================================================

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

// ============================================================
//  X. 重入锁
// ============================================================

abstract contract ReentrancyGuard {
    uint256 private _status = 1;
    modifier nonReentrant() {
        require(_status == 1, "ReentrancyGuard: reentrant call");
        _status = 2;
        _;
        _status = 1;
    }
}
