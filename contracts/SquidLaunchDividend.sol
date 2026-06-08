// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

/**
 * @title SquidLaunchDividend
 * @notice 独立分红合约 — 专门处理代币的分红分发，与主代币合约解耦
 *
 * ★ Clone 模式（EIP-1167）：
 *   - 构造函数留空，初始化逻辑在 initialize() 中完成
 *   - token / platformOwner 从 immutable 改为普通状态变量
 */
contract SquidLaunchDividend {
    // ─── 基本信息（原 immutable → 普通 state var）─────────────────────
    address public token;
    address public platformOwner;

    // ─── 分红配置 ──────────────────────────────────────────────────
    address public rewardToken;
    uint256 public threshold;

    // DEX Router（用于 swap）
    IUniswapV2Router02 public router;
    address public lpPair;

    // ─── 累积与分发状态 ────────────────────────────────────────────
    uint256 public accumulated;
    uint256 public totalDistributed;
    bool   public inSwap;

    // ─── 持有人追踪 ────────────────────────────────────────────────
    address[] public holders;
    mapping(address => uint256) public holdings;
    mapping(address => uint256) public balances;        // BNB 分红余额
    uint256 public totalHoldings;

    uint256 public minHoldForDividend;
    mapping(address => bool) public excluded;

    // ERC20 分红余额（与 BNB 分开存储）
    mapping(address => uint256) public erc20Balances;
    address public currentRewardToken;

    // ─── 状态控制 ──────────────────────────────────────────────────
    bool public paused = false;

    // ─── 初始化守卫 ─────────────────────────────────────────────────
    bool private _initialized;

    modifier initializer() {
        require(!_initialized, "SquidLaunchDividend: already initialized");
        _;
        _initialized = true;
    }

    // ─── 事件 ──────────────────────────────────────────────────────
    event RewardReceived(uint256 amount, uint256 newTotal);
    event DividendProcessed(uint256 amountSwapped, uint256 holderCount, address rewardAsset);
    event DividendClaimed(address indexed user, uint256 amount);
    event HolderUpdated(address indexed user, uint256 holding);
    event HolderRemoved(address indexed user);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event RewardTokenUpdated(address oldToken, address newToken);
    event MinHoldUpdated(uint256 oldMin, uint256 newMin);
    event ExclusionUpdated(address indexed addr, bool excluded);
    event Paused(address indexed caller);
    event Unpaused(address indexed caller);
    event EmergencyWithdraw(address indexed asset, uint256 amount, address indexed to);
    event Initialized(address indexed initializer, address tokenAddr);

    // ─── Modifier ───────────────────────────────────────────────────
    modifier onlyPlatformOwner() {
        require(msg.sender == platformOwner, "SquidLaunchDividend: not platform owner");
        _;
    }

    modifier onlyTokenContract() {
        require(msg.sender == token, "SquidLaunchDividend: only token contract");
        _;
    }

    modifier lockSwap() {
        require(!inSwap, "SquidLaunchDividend: in swap");
        inSwap = true;
        _;
        inSwap = false;
    }

    // ══════════════════════════════════════════════════════════════════
    // 构造函数（模板部署用 — 留空）
    // ══════════════════════════════════════════════════════════════════

    constructor() { }

    // ══════════════════════════════════════════════════════════════════
    // ★ 初始化（Clone 后由 Factory 调用）
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice 初始化分红合约实例（仅可调用一次）
     */
    function initialize(
        address _token,
        address _platformOwner,
        address _rewardToken,
        uint256 _threshold,
        address _routerAddress
    ) external initializer {
        require(_token != address(0), "SquidLaunchDividend: zero token");
        require(_platformOwner != address(0), "SquidLaunchDividend: zero owner");
        require(_threshold > 0, "SquidLaunchDividend: zero threshold");

        token         = _token;
        platformOwner = _platformOwner;
        threshold     = _threshold;

        if (_routerAddress != address(0)) {
            router = IUniswapV2Router02(_routerAddress);

            if (_rewardToken == address(0)) {
                rewardToken = router.WETH();
            } else {
                rewardToken = _rewardToken;
            }
        } else if (_rewardToken != address(0)) {
            rewardToken = _rewardToken;
        }

        emit Initialized(msg.sender, _token);
    }

    // ══════════════════════════════════════════════════════════════════
    // ★ 主回调：主代币合约调用 — 接收税费中的分红部分
    // ══════════════════════════════════════════════════════════════════

    function onRewardReceived(
        address _from,
        uint256 _amount
    ) external onlyTokenContract {
        if (paused || _amount == 0) return;

        accumulated += _amount;

        emit RewardReceived(_amount, accumulated);

        if (_from != address(0)) {
            _updateHolder(_from);
        }
    }

    function onHoldersUpdate(address[] calldata _addresses) external onlyTokenContract {
        for (uint256 i = 0; i < _addresses.length; i++) {
            _updateHolder(_addresses[i]);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // 执行分红 — swap + 分配
    // ══════════════════════════════════════════════════════════════════

    function processDividend() external lockSwap {
        require(accumulated >= threshold, "SquidLaunchDividend: below threshold");

        uint256 amountToProcess = accumulated;
        accumulated = 0;

        IERC20(token).approve(address(router), amountToProcess);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = rewardToken;

        uint256 rewardBefore = _getRewardBalance();

        if (rewardToken == router.WETH()) {
            try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                amountToProcess, 0, path, address(this), block.timestamp + 300
            ) {
                uint256 bnbGained = address(this).balance - rewardBefore;
                if (bnbGained > 0) {
                    _distribute(bnbGained);
                    totalDistributed += bnbGained;
                    emit DividendProcessed(bnbGained, holders.length, address(0));
                } else {
                    accumulated += amountToProcess;
                    return;
                }
            } catch {
                accumulated += amountToProcess;
                return;
            }
        } else {
            try router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountToProcess, 0, path, address(this), block.timestamp + 300
            ) {
                uint256 tokenGained = IERC20(rewardToken).balanceOf(address(this)) - rewardBefore;
                if (tokenGained > 0) {
                    _distributeERC20(rewardToken, tokenGained);
                    totalDistributed += tokenGained;
                    emit DividendProcessed(tokenGained, holders.length, rewardToken);
                } else {
                    accumulated += amountToProcess;
                    return;
                }
            } catch {
                accumulated += amountToProcess;
                return;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // 用户提取分红
    // ══════════════════════════════════════════════════════════════════

    function claimDividend() external {
        uint256 owed = balances[msg.sender];
        require(owed > 0, "SquidLaunchDividend: nothing to claim");

        balances[msg.sender] = 0;

        (bool sent, ) = msg.sender.call{value: owed}("");
        require(sent, "SquidLaunchDividend: transfer failed");

        emit DividendClaimed(msg.sender, owed);
    }

    function claimDividendERC20() external {
        uint256 owed = erc20Balances[msg.sender];
        require(owed > 0, "SquidLaunchDividend: nothing to claim (ERC20)");

        erc20Balances[msg.sender] = 0;

        IERC20(rewardToken).transfer(msg.sender, owed);

        emit DividendClaimed(msg.sender, owed);
    }

    // ══════════════════════════════════════════════════════════════════
    // 查询函数
    // ══════════════════════════════════════════════════════════════════

    function getClaimable(address _user) external view returns (uint256 bnb, uint256 erc20) {
        bnb   = balances[_user];
        erc20 = erc20Balances[_user];
    }

    function getOverview() external view returns (
        uint256 _accumulated,
        uint256 _threshold,
        uint256 _totalDistributed,
        uint256 _holderCount,
        uint256 _totalHoldings,
        bool _isPaused,
        address _rewardToken,
        uint256 bnbBalance,
        uint256 tokenBalance
    ) {
        return (
            accumulated,
            threshold,
            totalDistributed,
            holders.length,
            totalHoldings,
            paused,
            rewardToken,
            address(this).balance,
            IERC20(token).balanceOf(address(this))
        );
    }

    function getHolders(uint256 _offset, uint256 _limit)
        external view returns (address[] memory result, uint256[] memory h)
    {
        uint256 end = _offset + _limit;
        if (end > holders.length) end = holders.length;
        result = new address[](end - _offset);
        h = new uint256[](end - _offset);
        for (uint256 i = _offset; i < end; i++) {
            result[i - _offset] = holders[i];
            h[i - _offset] = holdings[holders[i]];
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // 平台管理操作
    // ══════════════════════════════════════════════════════════════════

    function pause() external onlyPlatformOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyPlatformOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setThreshold(uint256 _newThreshold) external onlyPlatformOwner {
        require(_newThreshold > 0, "SquidLaunchDividend: zero threshold");
        emit ThresholdUpdated(threshold, _newThreshold);
        threshold = _newThreshold;
    }

    function setMinHold(uint256 _minHold) external onlyPlatformOwner {
        emit MinHoldUpdated(minHoldForDividend, _minHold);
        minHoldForDividend = _minHold;
    }

    function setExclusion(address _addr, bool _exclude) external onlyPlatformOwner {
        if (_exclude && !excluded[_addr]) {
            _removeHolder(_addr);
        }
        excluded[_addr] = _exclude;
        emit ExclusionUpdated(_addr, _exclude);
    }

    function emergencyWithdrawBNB(address _to) external onlyPlatformOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "SquidLaunchDividend: no BNB");
        (bool sent, ) = _to.call{value: bal}("");
        require(sent, "SquidLaunchDividend: withdraw failed");
        emit EmergencyWithdraw(address(0), bal, _to);
    }

    function emergencyWithdrawToken(address _asset, address _to, uint256 _amount)
        external onlyPlatformOwner
    {
        uint256 bal = IERC20(_asset).balanceOf(address(this));
        uint256 amt  = (_amount == 0 || _amount > bal) ? bal : _amount;
        require(amt > 0, "SquidLaunchDividend: no tokens");
        IERC20(_asset).transfer(_to, amt);
        emit EmergencyWithdraw(_asset, amt, _to);
    }

    // ══════════════════════════════════════════════════════════════════
    // 内部函数
    // ══════════════════════════════════════════════════════════════════

    function _getRewardBalance() internal view returns (uint256) {
        if (rewardToken == router.WETH()) {
            return address(this).balance;
        }
        return IERC20(rewardToken).balanceOf(address(this));
    }

    function _distribute(uint256 _bnbTotal) internal {
        if (holders.length == 0 || totalHoldings == 0) return;

        for (uint256 i = 0; i < holders.length; i++) {
            address hldr = holders[i];
            if (hldr == address(0)) continue;
            uint256 hld = holdings[hldr];
            if (hld == 0) continue;

            uint256 share = _bnbTotal * hld / totalHoldings;
            if (share > 0) {
                balances[hldr] += share;
            }
        }
    }

    function _distributeERC20(address _rewardToken, uint256 _total) internal {
        currentRewardToken = _rewardToken;
        if (holders.length == 0 || totalHoldings == 0) return;

        for (uint256 i = 0; i < holders.length; i++) {
            address hldr = holders[i];
            if (hldr == address(0)) continue;
            uint256 hld = holdings[hldr];
            if (hld == 0) continue;

            uint256 share = _total * hld / totalHoldings;
            if (share > 0) {
                erc20Balances[hldr] += share;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // 持有人管理
    // ══════════════════════════════════════════════════════════════════

    function _updateHolder(address _addr) internal {
        if (excluded[_addr]) return;

        uint256 bal = IERC20(token).balanceOf(_addr);

        if (bal == 0) {
            _removeHolder(_addr);
        } else if (minHoldForDividend == 0 || bal >= minHoldForDividend) {
            _addHolder(_addr, bal);
        } else {
            _removeHolder(_addr);
        }
    }

    function _addHolder(address _addr, uint256 _holding) internal {
        for (uint256 i = 0; i < holders.length; i++) {
            if (holders[i] == _addr) {
                _updateSnapshot(_addr, _holding);
                return;
            }
        }
        holders.push(_addr);
        _updateSnapshot(_addr, _holding);
    }

    function _removeHolder(address _addr) internal {
        uint256 len = holders.length;
        for (uint256 i = 0; i < len; i++) {
            if (holders[i] == _addr) {
                if (totalHoldings >= holdings[_addr]) {
                    totalHoldings -= holdings[_addr];
                }
                holdings[_addr] = 0;

                holders[i] = holders[len - 1];
                holders.pop();
                emit HolderRemoved(_addr);
                return;
            }
        }
    }

    function _updateSnapshot(address _addr, uint256 _newHolding) internal {
        uint256 oldHolding = holdings[_addr];
        if (_newHolding >= minHoldForDividend || minHoldForDividend == 0 || excluded[_addr]) {
            if (totalHoldings >= oldHolding) {
                totalHoldings += _newHolding - oldHolding;
            } else {
                totalHoldings = _newHolding;
            }
            holdings[_addr] = _newHolding;
            emit HolderUpdated(_addr, _newHolding);
        }
    }

    receive() external payable {}
}
