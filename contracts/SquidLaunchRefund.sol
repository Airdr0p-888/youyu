// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

/**
 * @title SquidLaunchRefund
 * @notice 退款/理赔合约 — 处理24h超时退款、平台紧急干预、LP 理赔
 *
 * ★ Clone 模式（EIP-1167）：
 *   - 构造函数留空，初始化逻辑在 initialize() 中完成
 *   - tokenContract / platformOwner 从 immutable 改为普通状态变量
 */
contract SquidLaunchRefund {
    // ─── 基本信息原 immutable → 普通 state var ─────────────────────
    address public tokenContract;
    address public platformOwner;

    // 退款状态
    bool public emergencyEnabled = false;

    struct MintRecord {
        uint256 bnbPaid;
        uint256 tokensMinted;
        uint256 timestamp;
        bool refunded;
    }

    mapping(address => MintRecord[]) public mintRecords;
    uint256 public totalBNBDeposited;
    bool public presaleFinalized;
    bool public tradingEnabled;

    // 手续费设置
    uint256 public refundFeeBps = 0;
    address public feeRecipient;

    // ─── 初始化守卫 ─────────────────────────────────────────────────
    bool private _initialized;

    modifier initializer() {
        require(!_initialized, "SquidLaunchRefund: already initialized");
        _;
        _initialized = true;
    }

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
    event Initialized(address indexed initializer, address token);

    // ─── Modifier ────────────────────────────────────────────────────
    modifier onlyPlatformOwner() {
        require(msg.sender == platformOwner, "SquidLaunchRefund: only platform owner");
        _;
    }

    // ══════════════════════════════════════════════════════════════════
    // 构造函数（模板部署用 — 留空）
    // ══════════════════════════════════════════════════════════════════

    constructor() { }

    // ══════════════════════════════════════════════════════════════════
    // ★ 初始化（Clone 后由 Factory 调用）
    // ══════════════════════════════════════════════════════════════════

    function initialize(address _tokenContract, address _platformOwner)
        external initializer
    {
        require(_tokenContract != address(0), "SquidLaunchRefund: zero token");
        require(_platformOwner != address(0), "SquidLaunchRefund: zero owner");
        tokenContract  = _tokenContract;
        platformOwner  = _platformOwner;
        feeRecipient   = _platformOwner;
        emit Initialized(msg.sender, _tokenContract);
    }

    // ══════════════════════════════════════════════════════════════════
    // 主合约回调：记录 mint
    // ══════════════════════════════════════════════════════════════════

    function onMint(
        address _user,
        uint256 _bnbPaid,
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

    function _doRefund(address _user, uint256 _recordIndex) internal {
        if (!emergencyEnabled) {
            require(!tradingEnabled, "SquidLaunchRefund: trading enabled, cannot refund");

            MintRecord[] storage records = mintRecords[_user];
            require(_recordIndex < records.length, "SquidLaunchRefund: invalid index");
            MintRecord storage record = records[_recordIndex];
            require(!record.refunded, "SquidLaunchRefund: already refunded");

            record.refunded = true;

            if (record.tokensMinted > 0) {
                IERC20(tokenContract).transferFrom(_user, address(this), record.tokensMinted);
            }
        } else {
            MintRecord[] storage records = mintRecords[_user];
            if (_recordIndex < records.length && !records[_recordIndex].refunded) {
                records[_recordIndex].refunded = true;
                if (records[_recordIndex].tokensMinted > 0) {
                    try IERC20(tokenContract).transferFrom(
                        _user, address(this), records[_recordIndex].tokensMinted
                    ) {} catch {}
                }
            } else {
                return;
            }
        }

        MintRecord memory finalRecord = mintRecords[_user][_recordIndex];
        uint256 fee         = finalRecord.bnbPaid * refundFeeBps / 10000;
        uint256 refundAmount = finalRecord.bnbPaid - fee;

        if (refundAmount > 0 && address(this).balance >= refundAmount) {
            (bool sent, ) = _user.call{value: refundAmount}("");
            require(sent, "SquidLaunchRefund: BNB refund failed");
        }

        if (fee > 0 && address(this).balance >= fee) {
            (bool sentFee, ) = feeRecipient.call{value: fee}("");
            if (!sentFee) {}
        }

        emit Refunded(tokenContract, _user, _recordIndex, refundAmount,
            emergencyEnabled ? 0 : finalRecord.tokensMinted);
    }

    function refund(uint256 _recordIndex) external {
        _doRefund(msg.sender, _recordIndex);
    }

    function refundBatch(uint256[] calldata _indices) external {
        for (uint256 i = 0; i < _indices.length; i++) {
            _doRefund(msg.sender, _indices[i]);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // 平台管理操作
    // ══════════════════════════════════════════════════════════════════

    function adminWithdrawBNB(address _to) external onlyPlatformOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "SquidLaunchRefund: no BNB");
        (bool sent, ) = _to.call{value: bal}("");
        require(sent, "SquidLaunchRefund: withdraw failed");
        emit EmergencyWithdraw(tokenContract, _to, bal, address(0), 0);
    }

    function adminWithdrawToken(address _asset, address _to, uint256 _amount)
        external onlyPlatformOwner
    {
        uint256 bal = IERC20(_asset).balanceOf(address(this));
        uint256 amt  = _amount == 0 ? bal : _amount;
        require(amt > 0 && amt <= bal, "SquidLaunchRefund: invalid amount");
        IERC20(_asset).transfer(_to, amt);
        emit EmergencyWithdraw(tokenContract, _to, 0, _asset, amt);
    }

    function adminWithdrawLP(address _lpToken, address _to) external onlyPlatformOwner {
        uint256 lpBalance = IERC20(_lpToken).balanceOf(address(this));
        require(lpBalance > 0, "SquidLaunchRefund: no LP to withdraw");
        IERC20(_lpToken).transfer(_to, lpBalance);
        emit LPWithdrawn(_lpToken, lpBalance, _to);
    }

    function setRefundFee(uint256 _feeBps, address _feeRecipient) external onlyPlatformOwner {
        require(_feeBps <= 500, "SquidLaunchRefund: max 5%");
        refundFeeBps = _feeBps;
        feeRecipient  = _feeRecipient != address(0) ? _feeRecipient : platformOwner;
        emit RefundFeeUpdated(_feeBps, feeRecipient);
    }

    function emergencyEnable() external {
        require(msg.sender == platformOwner || msg.sender == tokenContract, "SquidLaunchRefund: unauthorized");
        emergencyEnabled = true;
        emit EmergencyModeEnabled(msg.sender, block.timestamp);
    }

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

    function getRefundableAmount(address _user, uint256 _recordIndex)
        external view returns (uint256 refundAmount, uint256 fee)
    {
        if (_recordIndex >= mintRecords[_user].length) return (0, 0);
        MintRecord memory record = mintRecords[_user][_recordIndex];
        if (record.refunded) return (0, 0);
        fee         = record.bnbPaid * refundFeeBps / 10000;
        refundAmount = record.bnbPaid - fee;
    }

    function canRefund() external view returns (bool) {
        if (emergencyEnabled) return true;
        if (tradingEnabled) return false;
        return presaleFinalized || !presaleFinalized;
    }

    function getLPBalance(address _lpToken) external view returns (uint256) {
        return IERC20(_lpToken).balanceOf(address(this));
    }

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

    receive() external payable {}
    fallback() external payable {}
}
