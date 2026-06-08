// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SquidLaunchDividend
 * @notice 独立分红合约 — 专门处理代币的分红分发，与主代币合约解耦
 *
 * 设计原则：
 * - 职责单一：只管分红，不管代币转账/税费/LP等
 * - 权限归平台：platformOwner（平台方钱包）拥有紧急干预权限
 * - 可选部署：Factory 在 launch() 时根据参数决定是否创建此合约
 *
 * 工作流程：
 * 1. 主合约交易税费中的 distReward 部分自动转入本合约累积
 * 2. 累积量 ≥ threshold 时，owner/processDividend() 触发分发
 * 3. 合约将累积的代币 swap 为 BNB（或指定 rewardToken）
 * 4. 按持有人持仓比例分配到每个用户的 claimable 余额
 * 5. 用户自行调用 claimDividend() 提取
 *
 * 安全保障：
 * - platformOwner 可暂停/恢复（防合约异常时扩大损失）
 * - platformOwner 可提取卡住的资产（异常恢复）
 * - 暂停后用户仍可 claim 已分配余额（不影响已得收益）
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract SquidLaunchDividend {
    // ─── 基本信息（不可更改）───────────────────────────────────────
    address public immutable token;            // 主代币合约地址（被分红的那个）
    address public immutable platformOwner;     // 平台方地址（监管权限）

    // ─── 分红配置 ──────────────────────────────────────────────────
    address public rewardToken;                // 发放什么：address(0)=BNB, 其他=ERC20代币
    uint256 public threshold;                   // 触发 swap+分发的最低累积阈值

    // DEX Router（用于 swap）
    IUniswapV2Router02 public router;
    address public lpPair;

    // ─── 累积与分发状态 ────────────────────────────────────────────
    uint256 public accumulated;                 // 已累积待处理的代币数量
    uint256 public totalDistributed;            // 历史累计已分发总量（换算后的 BNB/rewardToken）
    bool   public inSwap;                       // 防重入

    // ─── 持有人追踪 ────────────────────────────────────────────────
    address[] public holders;                   // 持有人列表
    mapping(address => uint256) public holdings;// 用户持币快照（用于算比例）
    mapping(address => uint256) public balances;// 用户可领取的分红余额
    uint256 public totalHoldings;               // 所有合格持有人总持仓

    uint256 public minHoldForDividend;          // 最低持币才参与分红（0=无门槛）

    mapping(address => bool) public excluded;   // 排除地址（不参与分红）

    // ─── 状态控制 ──────────────────────────────────────────────────
    bool public paused = false;                 // 平台暂停（阻止新累积进入，但可 claim）

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
    // 构造函数
    // ══════════════════════════════════════════════════════════════════

    /**
     * @param _token          被分红的代币地址
     * @param _platformOwner  平台方地址
     * @param _rewardToken    分红资产（address(0)=WBNB）
     * @param _threshold      触发阈值
     * @param _routerAddress  UniswapV2Router 地址
     */
    constructor(
        address _token,
        address _platformOwner,
        address _rewardToken,
        uint256 _threshold,
        address _routerAddress
    ) {
        require(_token != address(0), "SquidLaunchDividend: zero token");
        require(_platformOwner != address(0), "SquidLaunchDividend: zero owner");
        require(_threshold > 0, "SquidLaunchDividend: zero threshold");

        token         = _token;
        platformOwner = _platformOwner;
        rewardToken   = _rewardToken;           // address(0) 表示用 WBNB
        threshold     = _threshold;

        if (_routerAddress != address(0)) {
            router = IUniswapV2Router02(_routerAddress);

            // 如果有 router，确定 reward 目标和 pair
            if (_rewardToken == address(0)) {
                // 用 WBNB 作为中间目标（最终分发 BNB）
                rewardToken = router.WETH();
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // ★ 主回调：主代币合约调用 — 接收税费中的分红部分
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice 主合约在 _processTaxDistribution 中调用
     * @dev 将 distReward 部分的代币转入本合约累积。
     *      实际上主合约是直接 transfer 进来的，这个函数做记录+更新状态。
     */
    function onRewardReceived(
        address _from,       // 触发交易的地址（用于更新holder）
        uint256 _amount       // 本次收到的代币数量
    ) external onlyTokenContract {
        if (paused || _amount == 0) return;

        accumulated += _amount;

        emit RewardReceived(_amount, accumulated);

        // 更新相关地址的持有人状态
        if (_from != address(0)) {
            _updateHolder(_from);
        }
    }

    /**
     * @notice 批量更新持有人（主合约 _transfer 结束时可批量调）
     */
    function onHoldersUpdate(address[] calldata _addresses) external onlyTokenContract {
        for (uint256 i = 0; i < _addresses.length; i++) {
            _updateHolder(_addresses[i]);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // 执行分红 — swap + 分配
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice 执行一轮分红分发
     * @dev 1. 检查 accumulated >= threshold
     *      2. 取出 accumulated 数量的代币
     *      3. swap 为 rewardToken / BNB
     *      4. 按 holdings 比例分配到 balances[user]
     *
     * 可由 token.owner 或 platformOwner 调用
     */
    function processDividend() external lockSwap {
        require(accumulated >= threshold, "SquidLaunchDividend: below threshold");

        uint256 amountToProcess = accumulated;
        accumulated = 0;

        // Approve router
        IERC20(token).approve(address(router), amountToProcess);

        // 构建交换路径
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = rewardToken;

        uint256 rewardBefore = _getRewardBalance();

        if (rewardToken == router.WETH()) {
            // Swap → WBNB（然后我们直接分发 ETH/BNB）
            try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                amountToProcess, 0, path, address(this), block.timestamp + 300
            ) {
                // 成功 → balance 变化就是获得的 BNB
                uint256 bnbGained = address(this).balance - rewardBefore;
                if (bnbGained > 0) {
                    _distribute(bnbGained);
                    totalDistributed += bnbGained;
                    emit DividendProcessed(bnbGained, holders.length, address(0)); // 0 = BNB
                } else {
                    // swap 得到0，回滚
                    accumulated += amountToProcess;
                    return;
                }
            } catch {
                // swap 失败，回滚
                accumulated += amountToProcess;
                return;
            }
        } else {
            // Swap → 其他 ERC20
            try router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountToProcess, 0, path, address(this), block.timestamp + 300
            ) {
                uint256 tokenGained = IERC20(rewardToken).balanceOf(address(this)) - rewardBefore;
                if (tokenGained > 0) {
                    // 对于 ERC20 reward，记录到 balances 但用户需要 claim
                    // 这里我们存一个映射来区分 BNB 和 ERC20 余额
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

    /**
     * @notice 用户提取自己的 BNB 分红余额
     */
    function claimDividend() external {
        uint256 owed = balances[msg.sender];
        require(owed > 0, "SquidLaunchDividend: nothing to claim");

        balances[msg.sender] = 0;

        (bool sent, ) = msg.sender.call{value: owed}("");
        require(sent, "SquidLaunchDividend: transfer failed");

        emit DividendClaimed(msg.sender, owed);
    }

    /**
     * @notice 用户提取 ERC20 类型的分红余额
     */
    function claimDividendERC20() external {
        uint256 owed = erc20Balances[msg.sender];
        require(owed > 0, "SquidLaunchDividend: nothing to claim (ERC20)");

        erc20Balances[msg.sender] = 0;

        IERC20(rewardToken).transfer(msg.sender, owed);

        emit DividendClaimed(msg.sender, owed);
    }

    // ERC20 分红余额（与 BNB 分开存储）
    mapping(address => uint256) public erc20Balances;
    address public currentRewardToken;  // 当前使用的 reward token（用于判断用哪个余额）

    // ══════════════════════════════════════════════════════════════════
    // 查询函数
    // ══════════════════════════════════════════════════════════════════

    /** @notice 查询用户可领取的分红总额（BNB + ERC20）*/
    function getClaimable(address _user) external view returns (uint256 bnb, uint256 erc20) {
        bnb   = balances[_user];
        erc20 = erc20Balances[_user];
    }

    /** @notice 查询合约概览 */
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

    /** @notice 查询持有人列表（分页）*/
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
    // 平台管理操作（仅 platformOwner）
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice 暂停分红累积（已分配的不受影响，用户仍可 claim）
     * @dev 当发现分红逻辑问题时立即暂停，防止更多代币进入错误流程
     */
    function pause() external onlyPlatformOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /** @notice 恢复分红累积 */
    function unpause() external onlyPlatformOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice 修改触发阈值
     */
    function setThreshold(uint256 _newThreshold) external onlyPlatformOwner {
        require(_newThreshold > 0, "SquidLaunchDividend: zero threshold");
        emit ThresholdUpdated(threshold, _newThreshold);
        threshold = _newThreshold;
    }

    /**
     * @notice 修改最低持币门槛
     */
    function setMinHold(uint256 _minHold) external onlyPlatformOwner {
        emit MinHoldUpdated(minHoldForDividend, _minHold);
        minHoldForDividend = _minHold;
    }

    /**
     * @notice 设置/排除某个地址参与分红
     */
    function setExclusion(address _addr, bool _exclude) external onlyPlatformOwner {
        if (_exclude && !excluded[_addr]) {
            _removeHolder(_addr);
        }
        excluded[_addr] = _exclude;
        emit ExclusionUpdated(_addr, _exclude);
    }

    /**
     * @notice ★ 紧急提取合约内资产（分红系统严重故障时使用）
     * @dev 可提取：
     *      - BNB 余额（swap 后未领完的部分）
     *      - 累积的原始代币（如果决定取消分红，退给项目方或补偿用户）
     *      - rewardToken 余额
     *      提取后的资金由平台决定如何处理（理赔/退还等）
     */
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
            return address(this).balance;  // BNB
        }
        return IERC20(rewardToken).balanceOf(address(this));
    }

    /** @notice 按 holding 比例分发 BNB 到各用户 balances */
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

    /** @notice 按 holding 比例分发 ERC20 到各用户 erc20Balances */
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
        // 检查是否已在列表中
        for (uint256 i = 0; i < holders.length; i++) {
            if (holders[i] == _addr) {
                // 更新快照
                _updateSnapshot(_addr, _holding);
                return;
            }
        }
        // 新增
        holders.push(_addr);
        _updateSnapshot(_addr, _holding);
    }

    function _removeHolder(address _addr) internal {
        uint256 len = holders.length;
        for (uint256 i = 0; i < len; i++) {
            if (holders[i] == _addr) {
                // 清理快照
                if (totalHoldings >= holdings[_addr]) {
                    totalHoldings -= holdings[_addr];
                }
                holdings[_addr] = 0;

                // 替换并 pop
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

    // ══════════════════════════════════════════════════════════════════
    // 接收 BNB
    // ══════════════════════════════════════════════════════════════════

    receive() external payable {}
}
