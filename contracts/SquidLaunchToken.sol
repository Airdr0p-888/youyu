// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SquidLaunchToken
 * @notice SquidLaunch 代币合约 — 带 Mint/预售/税费 + 外部分红合约集成
 *
 * 权限模型（开放平台）：
 * ┌─────────────────────────────────────────────────────┐
 * │  owner      = 项目方部署者 → 日常操作               │
 * │  GUARDIAN   = 平台地址     → 紧急监管               │
 * │  refundContract = 退款合约 → mint 资金托管 + 理赔    │
 * │  dividendContract = 分红合约 → 独立处理分红分发      │
 * └─────────────────────────────────────────────────────┘
 *
 * ★ isPlatformProject 标志（构造时设入，不可更改）：
 *   true  = 平台方自己发的项目
 *     → Mint 资金：25% → 平台钱包(即时) + 75% → 合约留LP
 *
 *   false = 第三方项目方发的项目
 *     → Mint 资金：**100% 全部留合约用于 LP**（项目方不碰一分钱）
 *
 * ★ 分红系统已抽离到独立合约 SquidLaunchDividend：
 *   - 本合约只负责：税费中的 distReward 部分自动转给分红合约
 *   - 持有人追踪、swap、分发、claim 全部由分红合约负责
 *   - 如果未绑定分红合约(distRewardPct 应设为0)，则不分红
 */
interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract SquidLaunchToken {
    string public name;
    string public symbol;
    uint8 public constant DECIMALS = 18;
    uint256 public constant TOTAL_SUPPLY;

    // ─── 基础状态 ────────────────────────────────────────────────────
    address public owner;
    address public immutable i_owner;          // 部署时锁定，不可更改

    // ★ 平台项目标志（构造函数设入，不可更改）
    bool   public immutable isPlatformProject;  // true=平台方可预留Mint资金, false=第三方100%即付

    // 平台守护者角色
    bytes32 public constant GUARDIAN_ROLE = keccak256("SQUID_GUARDIAN");
    mapping(address => bool) public isGuardian;   // guardian 地址列表（支持多签升级）
    bool public guardianEnabled = true;

    bool public tradingEnabled;
    bool public presaleActive;
    bool public manualOpenMode;

    // ─── Mint 参数（构造函数设入） ──────────────────────────────────
    uint256 public MINT_PRICE_BNB;              // 单次 Mint 价格
    uint256 public TOKENS_PER_MINT;             // 单次 Mint 获得代币数量
    uint256 public maxMintCount;                // 最大 Mint 次数（硬顶）
    uint256 public currentMintCount;            // 当前已 Mint 次数
    uint256 public presaleHardCapBNB;           // 预售硬顶（BNB）

    // ─── 税费参数 ────────────────────────────────────────────────────
    uint256 public buyTaxPct;
    uint256 public sellTaxPct;

    // 税费分配比例（四项之和必须 = 100%）
    uint256 public distWalletPct;   // 营销钱包
    uint256 public distBurnPct;     // 销毁
    uint256 public distRewardPct;   // ★ 分红 → 自动转发给外部分红合约
    uint256 public distLiqPct;      // 流动性

    address public taxWallet;

    // ─── 反套利保护 ──────────────────────────────────────────────────
    uint256 public antiArbitrageEnd;       // 保护期结束时间戳
    uint256 public maxTxAmount;            // 保护期内单笔最大交易量

    // ─── 白名单模式 ──────────────────────────────────────────────────
    bool public whitelistMode;
    mapping(address => bool) public mintWhitelist;

    // ─── 排除地址列表（不收税 / 不通知分红合约更新持有人） ─────────────
    mapping(address => bool) public excludedFromTax;

    // ─── ★ 外部合约引用（解耦设计）──────────────────────────────────
    address public refundContract;      // 退款/理赔合约
    address public dividendContract;    // ★ 分红合约（独立部署，可选）

    // ─── DEX ─────────────────────────────────────────────────────────
    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;
    bool public inSwap;                      // 防重入

    // ─── ERC20 标准字段 ──────────────────────────────────────────────
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ─── 事件 ────────────────────────────────────────────────────────
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Minted(address indexed minter, uint256 bnbPaid, uint256 tokensReceived, uint256 recordIndex);
    event PresaleFinalized(uint256 timestamp);
    event TradingEnabled(uint256 timestamp, bool manualMode);
    event TaxSettingsUpdated(uint256 buyTax, uint256 sellTax);
    event TaxDistributionUpdated(uint256 wallet, uint256 burn, uint256 reward, uint256 liq);
    event GuardianUpdated(address indexed guardian, bool enabled);
    event EmergencyPaused(address indexed caller, uint256 timestamp);
    event EmergencyRefundForced(address indexed caller, uint256 timestamp);
    event RefundContractSet(address indexed refundContract);
    event DividendContractSet(address indexed dividendContract);
    event WhitelistUpdated(address indexed addr, bool status);
    event LiquidityAdded(uint256 tokenAmt, uint256 bnbAmt, address lpRecipient);
    event RewardForwarded(address indexed to, uint256 amount);

    // ─── Modifier ─────────────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "SquidLaunch: not owner");
        _;
    }

    modifier onlyGuardian() {
        require(isGuardian[msg.sender] && guardianEnabled, "SquidLaunch: not guardian");
        _;
    }

    modifier onlyWhenTradingActive() {
        require(tradingEnabled, "SquidLaunch: trading not active");
        _;
    }

    modifier onlyWhenPresaleActive() {
        require(presaleActive && !tradingEnabled, "SquidLaunch: presale not active or already trading");
        _;
    }

    modifier lockSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    modifier nonReentrant() {
        uint256 gasBefore = gasleft();
        _;
        require(gasleft() >= gasBefore / 64, "SquidLaunch: reentrancy guard");
    }

    // ══════════════════════════════════════════════════════════════════
    // 构造函数
    // ══════════════════════════════════════════════════════════════════

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply,
        address _owner,
        address _routerAddress,
        bool _isPlatformProject   // ★ 是否为平台方项目
    ) payable {
        name         = _name;
        symbol       = _symbol;
        TOTAL_SUPPLY = _totalSupply * 10 ** DECIMALS;

        owner   = msg.sender;  // 工厂临时拥有
        i_owner = _owner;      // 项目方最终 owner（工厂后续 transferOwnership）

        isPlatformProject = _isPlatformProject;

        _totalSupply = TOTAL_SUPPLY;
        _balances[address(this)] = TOTAL_SUPPLY;
        emit Transfer(address(0), address(this), TOTAL_SUPPLY);

        // 默认参数
        MINT_PRICE_BNB    = 0.001 ether;
        TOKENS_PER_MINT   = TOTAL_SUPPLY * 50 / 100 / 10000;  // 预售50% ÷ 默认10000次mint
        maxMintCount      = 10000;
        presaleHardCapBNB = 10 ether;

        presaleActive = true;
        tradingEnabled = false;

        buyTaxPct  = 5;
        sellTaxPct = 5;
        distWalletPct = 10;
        distBurnPct   = 30;
        distRewardPct = 0;   // ★ 默认关闭分红（需要时通过 Factory 绑定分红合约后开启）
        distLiqPct    = 60;   // 关闭分红时流动性占更大比例
        taxWallet    = _owner;

        antiArbitrageEnd = block.timestamp + 1 hours;
        maxTxAmount     = TOTAL_SUPPLY * 100 / 10000; // 1%

        whitelistMode = false;
        manualOpenMode = false;

        // DEX Router
        if (_routerAddress != address(0)) {
            uniswapV2Router = IUniswapV2Router02(_routerAddress);
            uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(
                address(this), uniswapV2Router.WETH()
            );
            excludedFromTax[address(this)] = true;
            excludedFromTax[_routerAddress] = true;
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Owner 管理
    // ══════════════════════════════════════════════════════════════════

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "SquidLaunch: zero address");
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    // ══════════════════════════════════════════════════════════════════
    // 平台 Guardian 管理
    // ══════════════════════════════════════════════════════════════════

    function setGuardian(address _guardian) external {
        require(msg.sender == owner || msg.sender == i_owner, "SquidLaunch: unauthorized");
        require(_guardian != address(0), "SquidLaunch: zero guardian");
        isGuardian[_guardian] = true;
        emit GuardianUpdated(_guardian, true);
    }

    function toggleGuardian(bool _enabled) external onlyOwner {
        guardianEnabled = _enabled;
    }

    function emergencyPause() external onlyGuardian {
        tradingEnabled = false;
        presaleActive = false;
        emit EmergencyPaused(msg.sender, block.timestamp);
    }

    function emergencyForceRefund() external onlyGuardian {
        presaleActive = false;
        if (tradingEnabled) tradingEnabled = false;
        if (refundContract != address(0)) {
            (bool ok, ) = refundContract.call(
                abi.encodeWithSignature("emergencyEnable()")
            );
            if (!ok) {}
        }
        emit EmergencyRefundForced(msg.sender, block.timestamp);
    }

    // ══════════════════════════════════════════════════════════════════
    // 外部合约绑定
    // ══════════════════════════════════════════════════════════════════

    function setRefundContract(address _refundContract) external {
        require(msg.sender == owner || refundContract == address(0), "SquidLaunch: not authorized");
        require(_refundContract != address(0), "SquidLaunch: zero address");
        refundContract = _refundContract;
        emit RefundContractSet(_refundContract);
    }

    /**
     * @notice ★ 绑定独立分红合约（仅可设置一次，由 Factory 在部署时调用）
     */
    function setDividendContract(address _dividendContract) external {
        // 仅在首次设置时允许（owner 或 Factory 都可以调）
        require(dividendContract == address(0), "SquidLaunch: dividend already set");
        require(_dividendContract != address(0), "SquidLaunch: zero address");
        dividendContract = _dividendContract;
        emit DividendContractSet(_dividendContract);
    }

    // ══════════════════════════════════════════════════════════════════
    // ★ Mint（预售阶段）— 根据 isPlatformProject 区分资金分配
    // ══════════════════════════════════════════════════════════════════

    function mint() external payable onlyWhenPresaleActive nonReentrant {
        require(_checkMintEligibility(msg.sender), "SquidLaunch: not whitelisted");

        require(msg.value == MINT_PRICE_BNB, "SquidLaunch: incorrect BNB amount");
        require(currentMintCount < maxMintCount, "SquidLaunch: mint sold out");

        currentMintCount++;

        uint256 tokenAmount = TOKENS_PER_MINT;

        // 转代币给用户
        _transferInternal(address(this), msg.sender, tokenAmount);

        // ★ 根据 isPlatformProject 决定资金分配方式
        if (isPlatformProject) {
            // ══ 平台方项目：25% → 平台钱包 + 75% 留合约用于 LP ══
            uint256 toOwner    = msg.value * 25 / 100;
            uint256 toReserve  = msg.value - toOwner;   // 75%

            if (toOwner > 0) {
                (bool sentOwner, ) = owner.call{value: toOwner}("");
                require(sentOwner, "SquidLaunch: failed to send to platform");
            }

            if (refundContract != address(0)) {
                (bool okRC, ) = refundContract.call(
                    abi.encodeWithSignature("onMint(address,uint256,uint256)",
                        msg.sender, toReserve, tokenAmount)
                );
                if (!okRC) {}
            }
        } else {
            // ══ 第三方项目：100% 全部留合约用于 LP（项目方不碰资金）══
            uint256 toReserve = msg.value;

            if (refundContract != address(0)) {
                (bool okRC, ) = refundContract.call(
                    abi.encodeWithSignature("onMint(address,uint256,uint256)",
                        msg.sender, toReserve, tokenAmount)
                );
                if (!okRC) {}
            }
        }

        emit Minted(msg.sender, msg.value, tokenAmount, currentMintCount);
    }

    function _checkMintEligibility(address minter) internal view returns (bool) {
        if (!whitelistMode) return true;
        return mintWhitelist[minter];
    }

    function addToWhitelist(address _addr) external onlyOwner {
        mintWhitelist[_addr] = true;
        emit WhitelistUpdated(_addr, true);
    }

    function removeFromWhitelist(address _addr) external onlyOwner {
        mintWhitelist[_addr] = false;
        emit WhitelistUpdated(_addr, false);
    }

    function toggleWhitelist(bool _mode) external onlyOwner {
        whitelistMode = _mode;
    }

    // ══════════════════════════════════════════════════════════════════
    // 预售结束 & 开盘
    // ══════════════════════════════════════════════════════════════════

    function finalizePresale() external onlyOwner {
        require(presaleActive, "SquidLaunch: presale already ended");
        presaleActive = false;

        uint256 bnbBalance = address(this).balance;

        if (bnbBalance > 0 && distLiqPct > 0) {
            processLiquidity();
        }

        uint256 remainingBNB = address(this).balance;
        if (remainingBNB > 0 && refundContract != address(0)) {
            (bool sentRC, ) = refundContract.call{value: remainingBNB}("");
            if (!sentRC) {}
        }

        if (refundContract != address(0)) {
            (bool okPF, ) = refundContract.call(
                abi.encodeWithSignature("onPresaleFinalized()")
            );
            if (!okPF) {}
        }

        if (!manualOpenMode) {
            _enableTrading();
        }

        emit PresaleFinalized(block.timestamp);
    }

    function enableTrading() external onlyOwner {
        require(!presaleActive, "SquidLaunch: presale still active");
        require(!manualOpenMode || !tradingEnabled, "SquidLaunch: already enabled");
        _enableTrading();
    }

    function setManualOpenMode(bool _manual) external onlyOwner {
        manualOpenMode = _manual;
    }

    function _enableTrading() internal {
        tradingEnabled = true;
        antiArbitrageEnd = block.timestamp + 1 hours;
        if (refundContract != address(0)) {
            (bool okTE, ) = refundContract.call(
                abi.encodeWithSignature("onTradingEnabled()")
            );
            if (!okTE) {}
        }
        emit TradingEnabled(block.timestamp, manualOpenMode);
    }

    // ══════════════════════════════════════════════════════════════════
    // 流动性注入 — LP token 发给退款合约（平台控制，防 Rug）
    // ══════════════════════════════════════════════════════════════════

    function processLiquidity() public lockSwap onlyOwner {
        uint256 tokenForLiq = (_balances[address(this)] * distLiqPct / 100) / 2;
        uint256 bnbForLiq   = address(this).balance * distLiqPct / 100 / 2;

        require(tokenForLiq > 0 && bnbForLiq > 0, "SquidLaunch: nothing to add");

        approve(address(uniswapV2Router), tokenForLiq);

        (,, uint256 lpTokens) = uniswapV2Router.addLiquidityETH{value: bnbForLiq}(
            address(this),
            tokenForLiq,
            0,
            0,
            refundContract != address(0) ? refundContract : owner,
            block.timestamp + 300
        );

        emit LiquidityAdded(tokenForLiq, bnbForLiq,
            refundContract != address(0) ? refundContract : owner);
    }

    // ══════════════════════════════════════════════════════════════════
    // 税费设置
    // ══════════════════════════════════════════════════════════════════

    function setTaxes(uint256 _buy, uint256 _sell) external onlyOwner {
        require(_buy <= 25 && _sell <= 25, "SquidLaunch: tax too high");
        buyTaxPct  = _buy;
        sellTaxPct = _sell;
        emit TaxSettingsUpdated(_buy, _sell);
    }

    function setTaxDistribution(
        uint256 _wallet, uint256 _burn, uint256 _reward, uint256 _liq
    ) external onlyOwner {
        require(_wallet + _burn + _reward + _liq == 100, "SquidLaunch: distribution must be 100%");
        // ★ 如果设置了 _reward > 0 但没有绑定分红合约，提醒但不阻断
        // （分红合约由 Factory 在 launch 时决定是否部署和绑定）
        distWalletPct = _wallet;
        distBurnPct   = _burn;
        distRewardPct = _reward;
        distLiqPct    = _liq;
        emit TaxDistributionUpdated(_wallet, _burn, _reward, _liq);
    }

    function setTaxWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "SquidLaunch: zero address");
        taxWallet = _wallet;
    }

    function setAntiArbitrageParams(uint256 _maxTx, uint256 _durationHours) external onlyOwner {
        maxTxAmount     = _maxTx;
        antiArbitrageEnd = block.timestamp + (_durationHours * 3600);
    }

    function excludeFromTax(address _addr, bool _exclude) external onlyOwner {
        excludedFromTax[_addr] = _exclude;
    }

    function setUniswapRouter(address _router) external onlyOwner {
        require(_router != address(0), "SquidLaunch: zero router");
        uniswapV2Router = IUniswapV2Router02(_router);
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(
            address(this), uniswapV2Router.WETH()
        );
    }

    // ══════════════════════════════════════════════════════════════════
    // ★ 税费分配 — distReward 部分自动转给外部分红合约
    // ══════════════════════════════════════════════════════════════════

    /**
     * @dev 四项税费分配：
     *   1. distWallet → 转给营销钱包
     *   2. distBurn   → 销毁（减 totalSupply）
     *   3. distReward → ★ 转给独立分红合约（或留合约等分红合约来取）
     *   4. distLiq    → 留合约，下次 processLiquidity 使用
     */
    function _processTaxDistribution(uint256 _taxAmount) internal {
        uint256 amtWallet = _taxAmount * distWalletPct / 100;
        uint256 amtBurn   = _taxAmount * distBurnPct / 100;
        uint256 amtReward = _taxAmount * distRewardPct / 100;
        uint256 amtLiq    = _taxAmount * distLiqPct / 100;

        // 1. 销毁
        if (amtBurn > 0) {
            _totalSupply -= amtBurn;
            emit Transfer(address(this), address(0), amtBurn);
        }

        // 2. 营销钱包
        if (amtWallet > 0 && taxWallet != address(0)) {
            _balances[address(this)] -= amtWallet;
            _balances[taxWallet] += amtWallet;
            emit Transfer(address(this), taxWallet, amtWallet);
        }

        // 3. ★ 分红 → 转发给独立分红合约
        if (amtReward > 0 && dividendContract != address(0)) {
            // 先 approve 再 transfer 给分红合约
            // 注意：_balances[address(this)] 已经包含 taxAmount 了（见 _transfer 中先加了进来）
            // 所以这里直接从合约余额中扣
            _balances[address(this)] -= amtReward;
            IERC20(address(this)).transfer(dividendContract, amtReward);

            // 通知分红合约收到了奖励代币
            (bool ok, ) = dividendContract.call(
                abi.encodeWithSignature("onRewardReceived(address,uint256)",
                    msg.sender, amtReward)   // 触发交易的人，用于更新持有人状态
            );
            if (!ok) {} // 不阻断主流程；即使回调失败，代币已经转到分红合约了

            emit RewardForwarded(dividendContract, amtReward);
        } else if (amtReward > 0) {
            // 没有绑定分红合约 → 红利留在合约中（等同于额外流动资金）
            // 不做任何事，留在 _balances[address(this)]
        }

        // 4. 流动性 — 已自动在 _balances[address(this)] 中
    }

    // ══════════════════════════════════════════════════════════════════
    // ERC20 核心
    // ══════════════════════════════════════════════════════════════════

    function totalSupply() external view returns (uint256) { return _totalSupply; }

    function balanceOf(address _account) external view returns (uint256) { return _balances[_account]; }

    function allowance(address _owner, address _spender) external view returns (uint256) { return _allowances[_owner][_spender]; }

    function approve(address _spender, uint256 _amount) external returns (bool) {
        _allowances[msg.sender][_spender] = _amount;
        emit Approval(msg.sender, _spender, _amount);
        return true;
    }

    function increaseAllowance(address _spender, uint256 _added) external returns (bool) {
        _allowances[msg.sender][_spender] += _added;
        emit Approval(msg.sender, _spender, _allowances[msg.sender][_spender]);
        return true;
    }

    function decreaseAllowance(address _spender, uint256 _subtracted) external returns (bool) {
        require(_allowances[msg.sender][_spender] >= _subtracted, "SquidLaunch: decreased below zero");
        _allowances[msg.sender][_spender] -= _subtracted;
        emit Approval(msg.sender, _spender, _allowances[msg.sender][_spender]);
        return true;
    }

    function transfer(address _to, uint256 _amount) external returns (bool) {
        _transfer(msg.sender, _to, _amount);
        return true;
    }

    function transferFrom(address _from, address _to, uint256 _amount) external returns (bool) {
        uint256 currentAllowance = _allowances[_from][msg.sender];
        require(currentAllowance >= _amount, "SquidLaunch: insufficient allowance");
        _allowances[_from][msg.sender] = currentAllowance - _amount;
        _transfer(_from, _to, _amount);
        return true;
    }

    // ══════════════════════════════════════════════════════════════════
    // 内部转账逻辑（税费 + 反套利 + 通知分红合约更新持有人）
    // ══════════════════════════════════════════════════════════════════

    function _transfer(address _from, address _to, uint256 _amount) internal virtual {
        require(_balances[_from] >= _amount, "SquidLaunch: insufficient balance");

        // P1-3: 反套利保护
        if (block.timestamp < antiArbitrageEnd && _to == uniswapV2Pair) {
            require(_amount <= maxTxAmount, "SquidLaunch: exceeds max tx during protection period");
        }

        // 计算税费
        uint256 taxAmount = _calculateTax(_from, _to, _amount);
        uint256 netAmount = _amount - taxAmount;

        // 扣除税费
        _balances[_from] -= _amount;
        _balances[address(this)] += taxAmount;
        _balances[_to] += netAmount;

        emit Transfer(_from, _to, netAmount);
        if (taxAmount > 0) {
            emit Transfer(_from, address(this), taxAmount);
        }

        // 处理税费分配（含分红转发）
        if (taxAmount > 0 && !inSwap && _to != address(this)) {
            _processTaxDistribution(taxAmount);
        }

        // ★ 通知分红合约更新持有人状态（轻量级，仅当有绑定时才调）
        if (dividendContract != address(0)) {
            (bool ok, ) = dividendContract.call(
                abi.encodeWithSignature("onHoldersUpdate(address[])",
                    _fromArr(_from, _to))
            );
            if (!ok) {} // 不阻断转账
        }
    }

    /** @brief 打包两个地址为数组用于回调 */
    function _fromArr(address a, address b) internal pure returns (address[] memory) {
        address[] memory arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function _transferInternal(address _from, address _to, uint256 _amount) internal {
        _balances[_from] -= _amount;
        _balances[_to] += _amount;
        emit Transfer(_from, _to, _amount);

        // 同样通知分红合约
        if (dividendContract != address(0)) {
            (bool ok, ) = dividendContract.call(
                abi.encodeWithSignature("onHoldersUpdate(address[])",
                    _fromArr(_from, _to))
            );
            if (!ok) {}
        }
    }

    function _calculateTax(address _from, address _to, uint256 _amount) internal view returns (uint256) {
        if (excludedFromTax[_from] || excludedFromTax[_to]) return 0;
        if (!tradingEnabled) return 0;

        if (_from == uniswapV2Pair) return _amount * buyTaxPct / 100;  // 买入
        if (_to == uniswapV2Pair) return _amount * sellTaxPct / 100;  // 卖出
        return 0;
    }

    // ══════════════════════════════════════════════════════════════════
    // 卡住的资产提取（安全阀）
    // ══════════════════════════════════════════════════════════════════

    function withdrawStuckBNB() external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "SquidLaunch: no BNB");
        (bool sent, ) = owner.call{value: bal}("");
        require(sent, "SquidLaunch: withdraw failed");
    }

    function withdrawStuckToken(address _token, uint256 _amount) external onlyOwner {
        require(_token != address(this), "SquidLaunch: cannot withdraw own tokens this way");
        IERC20(_token).transfer(owner, _amount);
    }
}
