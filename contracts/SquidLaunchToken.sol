// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

/**
 * @title SquidLaunchToken
 * @notice SquidLaunch 代币合约 — 带 Mint/预售/税费 + 外部分红合约集成
 *
 * ★ Clone 模式（EIP-1167）：
 *   - 构造函数留空（模板部署时调用，无实际逻辑）
 *   - 所有初始化逻辑移入 initialize()，由 Factory 在 clone 后调用
 *   - immutable 变量改为普通状态变量以支持 clone 后初始化
 *
 * 权限模型（开放平台）：
 * ┌─────────────────────────────────────────────────────┐
 * │  owner      = 项目方部署者 → 日常操作               │
 * │  GUARDIAN   = 平台地址     → 紧急监管               │
 * │  refundContract = 退款合约 → mint 资金托管 + 理赔    │
 * │  dividendContract = 分红合约 → 独立处理分红分发      │
 * └─────────────────────────────────────────────────────┘
 *
 * ★ isPlatformProject 标志（initialize 时设入，不可更改）：
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
contract SquidLaunchToken {
    string public name;
    string public symbol;
    uint8 public constant DECIMALS = 18;
    uint256 public TOTAL_SUPPLY;              // 原 immutable → 普通 state var（支持 clone 初始化）

    // ─── 基础状态 ────────────────────────────────────────────────────
    address public owner;
    address public i_owner;                   // 原 immutable → 项目方最终 owner

    // ★ 平台项目标志（initialize 时设入，不可更改）
    bool   public isPlatformProject;          // 原 immutable → 普通 state var

    // 平台守护者角色
    bytes32 public constant GUARDIAN_ROLE = keccak256("SQUID_GUARDIAN");
    mapping(address => bool) public isGuardian;
    bool public guardianEnabled = true;

    bool public tradingEnabled;
    bool public presaleActive;
    bool public manualOpenMode;

    // ─── Mint 参数（initialize 时设入） ──────────────────────────────
    uint256 public MINT_PRICE_BNB;
    uint256 public TOKENS_PER_MINT;
    uint256 public maxMintCount;
    uint256 public currentMintCount;
    uint256 public presaleHardCapBNB;

    // ─── 税费参数 ────────────────────────────────────────────────────
    uint256 public buyTaxPct;
    uint256 public sellTaxPct;

    // 税费分配比例（四项之和必须 = 100%）
    uint256 public distWalletPct;
    uint256 public distBurnPct;
    uint256 public distRewardPct;
    uint256 public distLiqPct;

    address public taxWallet;

    // ─── 反套利保护 ──────────────────────────────────────────────────
    uint256 public antiArbitrageEnd;
    uint256 public maxTxAmount;

    // ─── 白名单模式 ──────────────────────────────────────────────────
    bool public whitelistMode;
    mapping(address => bool) public mintWhitelist;

    // ─── 排除地址列表 ────────────────────────────────────────────────
    mapping(address => bool) public excludedFromTax;

    // ─── ★ 外部合约引用（解耦设计）──────────────────────────────────
    address public refundContract;
    address public dividendContract;

    // ─── DEX ─────────────────────────────────────────────────────────
    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;
    bool public inSwap;

    // ─── ERC20 标准字段 ──────────────────────────────────────────────
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ─── 初始化守卫（Clone 模式必需）────────────────────────────────
    bool private _initialized;

    modifier initializer() {
        require(!_initialized, "SquidLaunch: already initialized");
        _;
        _initialized = true;
    }

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
    event LiquidityAdded(uint256 tokenAmt, uint256 bnbAmt, uint256 lpTokens, address lpRecipient);
    event RewardForwarded(address indexed to, uint256 amount);
    event Initialized(address indexed initializer, string name, string symbol);

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
    // 构造函数（模板部署时调用 — 留空）
    // ══════════════════════════════════════════════════════════════════

    /** @notice 模板部署用的空构造函数；实际初始化在 initialize() 中完成 */
    constructor() { }

    // ══════════════════════════════════════════════════════════════════
    // ★ 初始化（Clone 后由 Factory 调用，替代构造函数）
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice 初始化代币实例（仅可调用一次）
     * @param _name             代币名称
     * @param _symbol           代币符号
     * @param _totalSupply      总供应量（会乘以 10^DECIMALS）
     * @param _owner            项目方最终 owner 地址
     * @param _routerAddress    UniswapV2Router02 地址
     * @param _isPlatformProject 是否为平台方项目
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply,
        address _owner,
        address _routerAddress,
        bool _isPlatformProject
    ) external initializer {
        require(_owner != address(0), "SquidLaunch: zero owner");

        name         = _name;
        symbol       = _symbol;
        TOTAL_SUPPLY = _totalSupply * 10 ** DECIMALS;

        owner   = msg.sender;  // Factory 临时拥有
        i_owner = _owner;      // 项目方最终 owner（Factory 后续 transferOwnership）

        isPlatformProject = _isPlatformProject;

        _totalSupply = TOTAL_SUPPLY;
        _balances[address(this)] = TOTAL_SUPPLY;
        emit Transfer(address(0), address(this), TOTAL_SUPPLY);

        // 默认参数
        MINT_PRICE_BNB    = 0.001 ether;
        TOKENS_PER_MINT   = TOTAL_SUPPLY * 50 / 100 / 10000;
        maxMintCount      = 10000;
        presaleHardCapBNB = 10 ether;

        presaleActive = true;
        tradingEnabled = false;

        buyTaxPct  = 5;
        sellTaxPct = 5;
        distWalletPct = 10;
        distBurnPct   = 30;
        distRewardPct = 0;
        distLiqPct    = 60;
        taxWallet    = _owner;

        antiArbitrageEnd = block.timestamp + 1 hours;
        maxTxAmount     = TOTAL_SUPPLY * 100 / 10000;

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

        emit Initialized(msg.sender, _name, _symbol);
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

    function setDividendContract(address _dividendContract) external {
        require(dividendContract == address(0), "SquidLaunch: dividend already set");
        require(_dividendContract != address(0), "SquidLaunch: zero address");
        dividendContract = _dividendContract;
        emit DividendContractSet(_dividendContract);
    }

    // ══════════════════════════════════════════════════════════════════
    // ★ Mint（预售阶段）
    // ══════════════════════════════════════════════════════════════════

    function mint() external payable onlyWhenPresaleActive nonReentrant {
        require(_checkMintEligibility(msg.sender), "SquidLaunch: not whitelisted");

        require(msg.value == MINT_PRICE_BNB, "SquidLaunch: incorrect BNB amount");
        require(currentMintCount < maxMintCount, "SquidLaunch: mint sold out");

        currentMintCount++;

        uint256 tokenAmount = TOKENS_PER_MINT;

        _transferInternal(address(this), msg.sender, tokenAmount);

        if (isPlatformProject) {
            uint256 toOwner   = msg.value * 25 / 100;
            uint256 toReserve  = msg.value - toOwner;

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
    // 流动性注入
    // ══════════════════════════════════════════════════════════════════

    function processLiquidity() public lockSwap onlyOwner {
        uint256 tokenForLiq = (_balances[address(this)] * distLiqPct / 100) / 2;
        uint256 bnbForLiq   = address(this).balance * distLiqPct / 100 / 2;

        require(tokenForLiq > 0 && bnbForLiq > 0, "SquidLaunch: nothing to add");

        IERC20(address(this)).approve(address(uniswapV2Router), tokenForLiq);

        (,, uint256 lpTokens) = uniswapV2Router.addLiquidityETH{value: bnbForLiq}(
            address(this),
            tokenForLiq,
            0,
            0,
            refundContract != address(0) ? refundContract : owner,
            block.timestamp + 300
        );

        emit LiquidityAdded(tokenForLiq, bnbForLiq, lpTokens,
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
        distWalletPct = _wallet;
        distBurnPct   = _burn;
        distRewardPct = _reward;
        distLiqPct    = _liq;
        emit TaxDistributionUpdated(_wallet, _burn, _reward, _liq);
    }

    function setTaxWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "SquidLaunch: zero router");
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
    // ★ 税费分配
    // ══════════════════════════════════════════════════════════════════

    function _processTaxDistribution(uint256 _taxAmount) internal {
        uint256 amtWallet = _taxAmount * distWalletPct / 100;
        uint256 amtBurn   = _taxAmount * distBurnPct / 100;
        uint256 amtReward = _taxAmount * distRewardPct / 100;

        if (amtBurn > 0) {
            _totalSupply -= amtBurn;
            emit Transfer(address(this), address(0), amtBurn);
        }

        if (amtWallet > 0 && taxWallet != address(0)) {
            _balances[address(this)] -= amtWallet;
            _balances[taxWallet] += amtWallet;
            emit Transfer(address(this), taxWallet, amtWallet);
        }

        if (amtReward > 0 && dividendContract != address(0)) {
            _balances[address(this)] -= amtReward;
            IERC20(address(this)).transfer(dividendContract, amtReward);

            (bool ok, ) = dividendContract.call(
                abi.encodeWithSignature("onRewardReceived(address,uint256)",
                    msg.sender, amtReward)
            );
            if (!ok) {}

            emit RewardForwarded(dividendContract, amtReward);
        } else if (amtReward > 0) {
            // 无分红合约 → 留在合约中作为额外流动资金
        }
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
    // 内部转账逻辑
    // ══════════════════════════════════════════════════════════════════

    function _transfer(address _from, address _to, uint256 _amount) internal virtual {
        require(_balances[_from] >= _amount, "SquidLaunch: insufficient balance");

        if (block.timestamp < antiArbitrageEnd && _to == uniswapV2Pair) {
            require(_amount <= maxTxAmount, "SquidLaunch: exceeds max tx during protection period");
        }

        uint256 taxAmount = _calculateTax(_from, _to, _amount);
        uint256 netAmount = _amount - taxAmount;

        _balances[_from] -= _amount;
        _balances[address(this)] += taxAmount;
        _balances[_to] += netAmount;

        emit Transfer(_from, _to, netAmount);
        if (taxAmount > 0) {
            emit Transfer(_from, address(this), taxAmount);
        }

        if (taxAmount > 0 && !inSwap && _to != address(this)) {
            _processTaxDistribution(taxAmount);
        }

        if (dividendContract != address(0)) {
            (bool ok, ) = dividendContract.call(
                abi.encodeWithSignature("onHoldersUpdate(address[])",
                    _fromArr(_from, _to))
            );
            if (!ok) {}
        }
    }

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
        if (_from == uniswapV2Pair) return _amount * buyTaxPct / 100;
        if (_to == uniswapV2Pair) return _amount * sellTaxPct / 100;
        return 0;
    }

    // ══════════════════════════════════════════════════════════════════
    // 卡住的资产提取
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
