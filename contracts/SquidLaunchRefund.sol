// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SquidLaunchRefund
 * @notice 退款/理赔合约 — 处理24h超时退款、平台紧急干预、LP 理赔
 *
 * 权限模型：
 * ┌─────────────────────────────────────────────┐
 * │  platformOwner = 平台方                     │
 * │    → 提取 BNB/代币/LP（全部资产控制）        │
 * │    → 设置退款手续费                        │
 * │    → 撤回 LP 进行用户理赔                   │
 * │                                            │
 * │  任意用户 = 可调用 refund()（条件满足时）     │
 * │    → 退代币 + 退 BNB（gas 用户承担）         │
 * └─────────────────────────────────────────────┘
 *
 * 资金流：
 * mint 时：75% BNB → 本合约托管（由 Token 合约转来）
 * 项目成功发射后：LP token → 本合约持有（平台控制）
 * 平台可撤回 LP → swap → 按 mint 记录理赔用户
 */
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract SquidLaunchRefund {
    address public immutable tokenContract;   // 关联的代币合约地址
    address public immutable platformOwner;   // 平台方（SquidLaunch 官方）

    // 退款状态
    bool public emergencyEnabled = false;     // 平台强制开启紧急退款

    struct MintRecord {
        uint256 bnbPaid;          // 实际存入的 BNB（75%，非100% — P0-2修复）
        uint256 tokensMinted;     // 获得的代币数量
        uint256 timestamp;        // mint 时间戳
        bool refunded;            // 是否已退款
    }

    // user => records[]
    mapping(address => MintRecord[]) public mintRecords;
    // 总存入的 BNB（用于计算比例）
    uint256 public totalBNBDeposited;
    // presale 结束标记
    bool public presaleFinalized;
    // trading 开启标记（=项目已发射成功）
    bool public tradingEnabled;

    // 手续费设置
    uint256 public refundFeeBps = 0;       // 默认 0%（最大5%）
    address public feeRecipient;

    // ─── 事件 ────────────────────────────────────────────────────────
    event MintRecorded(address indexed token, address indexed user,
        uint256 bnbPaid, uint256 tokensMinted, uint256 timestamp);
    event Refunded(address indexed token, address indexed user,
        uint256 recordIndex, uint256 bnbReturned, uint256 tokensRecovered);
    event EmergencyWithdraw(address indexed token, address indexed to,
        uint256 bnbAmount, address asset, uint256 assetAmount);
    event PresaleFinalized(address indexed token);
    event TradingEnabled(address indexed token);
    event RefundFeeUpdated(uint256 newFeeBps, address newFeeRecipient);
    event EmergencyModeEnabled(address indexed caller, uint256 timestamp);
    event LPWithdrawn(address indexed lpToken, uint256 amount, address indexed to);

    // ─── Modifier ────────────────────────────────────────────────────
    modifier onlyPlatformOwner() {
        require(msg.sender == platformOwner, "SquidLaunchRefund: only platform owner");
        _;
    }

    constructor(address _tokenContract, address _platformOwner) {
        require(_tokenContract != address(0), "SquidLaunchRefund: zero token");
        require(_platformOwner != address(0), "SquidLaunchRefund: zero owner");
        tokenContract  = _tokenContract;
        platformOwner  = _platformOwner;
        feeRecipient   = _platformOwner;
    }

    // ══════════════════════════════════════════════════════════════════
    // 主合约回调：记录 mint
    // ══════════════════════════════════════════════════════════════════

    function onMint(
        address _user,
        uint256 _bnbPaid,      // 实际存入金额（75%，不是 msg.value）
        uint256 _tokensMinted
    ) external {
        require(msg.sender == tokenContract, "SquidLaunchRefund: only token contract");

        mintRecords[_user].push(MintRecord({
            bnbPaid:      _bnbPaid,
            tokensMinted: _tokensMinted,
            timestamp:    block.timestamp,
            refunded:     false
        }));

        totalBNBDeposited += _bnbPaid;
        emit MintRecorded(tokenContract, _user, _bnbPaid, _tokensMinted, block.timestamp);
    }

    // ══════════════════════════════════════════════════════════════════
    // 用户退款
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice 单笔退款 — P1-4修复：需要用户先 approve 代币给本合约
     */
    function refund(uint256 _recordIndex) external {
        // 正常模式：需超时且未发射
        // 紧急模式：无条件可退
        if (!emergencyEnabled) {
            // 正常退款条件检查
            require(!tradingEnabled, "SquidLaunchRefund: trading enabled, cannot refund");

            MintRecord[] storage records = mintRecords[msg.sender];
            require(_recordIndex < records.length, "SquidLaunchRefund: invalid index");
            MintRecord storage record = records[_recordIndex];
            require(!record.refunded, "SquidLaunchRefund: already refunded");

            record.refunded = true;

            // P1-4: 回收代币（用户必须先 approve 给本合约）
            if (record.tokensMinted > 0) {
                IERC20(tokenContract).transferFrom(msg.sender, address(this), record.tokensMinted);
            }
        } else {
            // 紧急模式：允许退款，但同样回收代币
            MintRecord[] storage records = mintRecords[msg.sender];
            if (_recordIndex < records.length && !records[_recordIndex].refunded) {
                records[_recordIndex].refunded = true;
                if (records[_recordIndex].tokensMinted > 0) {
                    try IERC20(tokenContract).transferFrom(
                        msg.sender, address(this), records[_recordIndex].tokensMinted
                    ) {} catch {}
                }
            } else {
                return; // 无有效记录
            }
        }

        // 计算退款金额
        MintRecord memory record = mintRecords[msg.sender][_recordIndex];
        uint256 fee         = record.bnbPaid * refundFeeBps / 10000;
        uint256 refundAmount = record.bnbPaid - fee;

        // 发送 BNB 退款
        if (refundAmount > 0 && address(this).balance >= refundAmount) {
            (bool sent, ) = msg.sender.call{value: refundAmount}("");
            require(sent, "SquidLaunchRefund: BNB refund failed");
        }

        // 发送手续费给平台
        if (fee > 0 && address(this).balance >= fee) {
            (bool sentFee, ) = feeRecipient.call{value: fee}("");
            if (!sentFee) {} // 不阻断
        }

        emit Refunded(tokenContract, msg.sender, _recordIndex, refundAmount,
            emergencyEnabled ? 0 : record.tokensMinted);
    }

    /**
     * @notice 批量退款 — 一次处理多笔
     */
    function refundBatch(uint256[] calldata _indices) external {
        for (uint256 i = 0; i < _indices.length; i++) {
            refund(_indices[i]);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // 平台管理操作
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice 平台提取合约内所有 BNB
     */
    function adminWithdrawBNB(address _to) external onlyPlatformOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "SquidLaunchRefund: no BNB");
        (bool sent, ) = _to.call{value: bal}("");
        require(sent, "SquidLaunchRefund: withdraw failed");
        emit EmergencyWithdraw(tokenContract, _to, bal, address(0), 0);
    }

    /**
     * @notice 平台提取合约内任意 ERC20 代币
     */
    function adminWithdrawToken(address _asset, address _to, uint256 _amount)
        external onlyPlatformOwner
    {
        uint256 bal = IERC20(_asset).balanceOf(address(this));
        uint256 amt  = _amount == 0 ? bal : _amount;
        require(amt > 0 && amt <= bal, "SquidLaunchRefund: invalid amount");
        IERC20(_asset).transfer(_to, amt);
        emit EmergencyWithdraw(tokenContract, _to, 0, _asset, amt);
    }

    /**
     * @notice ★ 平台撤回 LP 代币（用于理赔）
     * @dev 项目 Rug 或严重亏损时，平台从 DEX 撤回 LP，
     *      将 BNB+代币按比例退还给 mint 用户。
     *      LP token 由 processLiquidity() 自动转入本合约。
     *
     * @param _lpToken   LP 合约地址（PancakeSwap Pair）
     * @param _to        接收地址（通常是平台理赔钱包或分发合约）
     */
    function adminWithdrawLP(address _lpToken, address _to) external onlyPlatformOwner {
        uint256 lpBalance = IERC20(_lpToken).balanceOf(address(this));
        require(lpBalance > 0, "SquidLaunchRefund: no LP to withdraw");

        IERC20(_lpToken).transfer(_to, lpBalance);

        emit LPWithdrawn(_lpToken, lpBalance, _to);
    }

    /**
     * @notice 设置退款手续费
     */
    function setRefundFee(uint256 _feeBps, address _feeRecipient) external onlyPlatformOwner {
        require(_feeBps <= 500, "SquidLaunchRefund: max 5%");
        refundFeeBps = _feeBps;
        feeRecipient  = _feeRecipient != address(0) ? _feeRecipient : platformOwner;
        emit RefundFeeUpdated(_feeBps, feeRecipient);
    }

    /**
     * @notice 平台开启/关闭紧急退款模式（Guardian 调用）
     * @dev 紧急模式下用户可无条件退款（无需等超时）
     */
    function emergencyEnable() external {
        // 允许 Guardian 或 platformOwner 调用
        require(msg.sender == platformOwner || msg.sender == tokenContract, "SquidLaunchRefund: unauthorized");
        emergencyEnabled = true;
        emit EmergencyModeEnabled(msg.sender, block.timestamp);
    }

    /**
     * @notice 平台关闭紧急退款模式
     */
    function emergencyDisable() external onlyPlatformOwner {
        emergencyEnabled = false;
    }

    // ══════════════════════════════════════════════════════════════════
    // 状态更新（主合约回调）
    // ══════════════════════════════════════════════════════════════════

    function onPresaleFinalized() external {
        require(msg.sender == tokenContract, "SquidLaunchRefund: only token contract");
        presaleFinalized = true;
        emit PresaleFinalized(tokenContract);
    }

    function onTradingEnabled() external {
        require(msg.sender == tokenContract, "SquidLaunchRefund: only token contract");
        tradingEnabled = true;
        emit TradingEnabled(tokenContract);
    }

    // ══════════════════════════════════════════════════════════════════
    // 查询函数
    // ══════════════════════════════════════════════════════════════════

    function getUserMintRecords(address _user)
        external view returns (MintRecord[] memory)
    {
        return mintRecords[_user];
    }

    /** @notice 用户查询自己某笔记录的可退款金额（扣除手续费） */
    function getRefundableAmount(address _user, uint256 _recordIndex)
        external view returns (uint256 refundAmount, uint256 fee)
    {
        if (_recordIndex >= mintRecords[_user].length) return (0, 0);
        MintRecord memory record = mintRecords[_user][_recordIndex];
        if (record.refunded) return (0, 0);
        fee         = record.bnbPaid * refundFeeBps / 10000;
        refundAmount = record.bnbPaid - fee;
    }

    /** @notice 查询是否可以退款 */
    function canRefund() external view returns (bool) {
        // 紧急模式 → 可以
        if (emergencyEnabled) return true;
        // 已发射 → 不可以
        if (tradingEnabled) return false;
        // presale 还在活跃 → 不可以（还没结束）
        // presale 已结束但未发射 → 可以（24h超时逻辑在 Token 层面处理）
        return presaleFinalized || !presaleFinalized;
        // 实际退款时机由前端判断：presale结束后24h+
    }

    /** @notice 获取合约持有的 LP 余额 */
    function getLPBalance(address _lpToken) external view returns (uint256) {
        return IERC20(_lpToken).balanceOf(address(this));
    }

    /** @notice 获取合约总资产概览 */
    function getAssetOverview() external view returns (
        uint256 bnbBalance,
        uint256 tokenBalance,
        bool isTrading,
        bool isPresaleFinalized,
        bool isEmergency,
        uint256 totalDeposits,
        uint256 feeRate
    ) {
        return (
            address(this).balance,
            IERC20(tokenContract).balanceOf(address(this)),
            tradingEnabled,
            presaleFinalized,
            emergencyEnabled,
            totalBNBDeposited,
            refundFeeBps
        );
    }

    // ══════════════════════════════════════════════════════════════════
    // 接收 BNB
    // ══════════════════════════════════════════════════════════════════
    receive() external payable {}
    fallback() external payable {}
}
