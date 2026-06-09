// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 a) external returns (bool);
    function approve(address sp, uint256 a) external returns (bool);
}

/**
 * @title DividendDistributor
 * @notice 独立分红合约 —— 接收 BNB → 按持仓比例轮训分发
 *
 * 设计要点：
 *  1. platformOwner 由构造函数设定（平台方钱包）
 *  2. token 地址可后续 setToken() 绑定
 *  3. 持仓列表由 Token 合约通过 updateHolder(addr, balance) 推送更新
 *  4. distributeBNB() 为 payable 函数，接收 BNB 并自动分配
 *  5. 轮训机制：更新 accDividendPerShare → 按 cursor 每次发 4 人
 *  6. withdrawBNB() / withdrawToken() 只有 platformOwner 可调用
 *  7. 用户可通过 withdrawDividend() 主动领取
 */
contract DividendDistributor {
    address public immutable platformOwner;
    address public token;

    // ── 持仓列表（由 Token 合约推送） ──
    address[] public holders;
    mapping(address => uint256) public holderIndexPlus1;   // 1-based，0=未加入
    uint256 public totalShares;                             // 所有 holder 余额之和

    // ── 分红累计（精度 1e18） ──
    uint256 public accDividendPerShare;                      // BNB wei * 1e18 / share
    mapping(address => uint256) public lastAccDividendPerShare;

    // ── 轮训指针 ──
    uint256 public dividendCursor;

    // ── 配置 ──
    uint256 public constant DIVIDEND_BATCH = 4;           // 每次发 4 人
    uint256 public minDividendBalance;                       // 最低持币门槛（wei），0=无门槛
    uint256 public claimWait = 60;                          // 领取冷却时间（秒），默认 60 秒

    // ── 领取记录 ──
    mapping(address => uint256) public lastClaimTimes;        // 上次领取时间

    // ── 防重入 ──
    bool private inSwap;

    // ── Custom Errors ──
    error NotToken();
    error NotOwner();
    error TokenAlreadySet();
    error NoHolders();
    error TransferFail();

    event TokenSet(address indexed token);
    event HolderUpdated(address indexed addr, uint256 balance, bool added);
    event DividendDistributed(address indexed to, uint256 bnbAmount);
    event WithdrawBNB(address indexed to, uint256 amount);
    event WithdrawToken(address indexed tokenAddr, address indexed to, uint256 amount);
    event ClaimWaitUpdated(uint256 indexed newValue, uint256 indexed oldValue);
    event Claim(address indexed account, uint256 amount, bool indexed automatic);

    // ── 修饰符 ──
    modifier onlyToken() {
        if (msg.sender != token) revert NotToken();
        _;
    }
    modifier onlyOwner() {
        if (msg.sender != platformOwner) revert NotOwner();
        _;
    }
    modifier lockSwap() {
        if (inSwap) revert("reentrant");
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor(address _platformOwner, address /* _router 已不用 */, uint256 _minDividendBalance) {
        if (_platformOwner == address(0)) revert TokenAlreadySet();
        platformOwner = _platformOwner;
        minDividendBalance = _minDividendBalance;
    }

    // ── 绑定代币地址（只能调用一次，在 Token 部署后执行） ──
    function setToken(address _token) external onlyOwner {
        if (token != address(0)) revert TokenAlreadySet();
        if (_token == address(0)) revert NotToken();
        token = _token;
        emit TokenSet(_token);
    }

    // ╍═══════════════════════════════════════════════════
    //  ★ 由 Token 合约在每次 mint / _transfer 后调用
    //  ★ 推送最新持仓，保持 holders[] 与链上余额同步
    // ╍═══════════════════════════════════════════════════
    function updateHolder(address addr, uint256 newBalance) external onlyToken {
        uint256 idxPlus1 = holderIndexPlus1[addr];
        bool qualifies = newBalance >= minDividendBalance;

        if (qualifies && idxPlus1 == 0) {
            // 新达标者 → 加入列表，重置 cumulative 起点
            holderIndexPlus1[addr] = holders.length + 1;
            holders.push(addr);
            lastAccDividendPerShare[addr] = accDividendPerShare;
            emit HolderUpdated(addr, newBalance, true);
        } else if (!qualifies && idxPlus1 > 0) {
            // 不再达标 → 从列表移除
            uint256 idx = idxPlus1 - 1;
            address last = holders[holders.length - 1];
            if (addr != last) {
                holders[idx] = last;
                holderIndexPlus1[last] = idx + 1;
            }
            holderIndexPlus1[addr] = 0;
            holders.pop();
            emit HolderUpdated(addr, 0, false);
        }

        // 更新 totalShares（只统计达标者）
        _recalcTotalShares();
    }

    // ── 重算 totalShares（当 holder 列表变化时调用） ──
    function _recalcTotalShares() internal {
        uint256 sum;
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 bal = IERC20(token).balanceOf(holders[i]);
            if (bal >= minDividendBalance) {
                sum += bal;
            }
        }
        totalShares = sum;
    }

    // ── 内部函数 ──
    function canAutoClaim(uint256 lastClaimTime) private view returns (bool) {
        if (lastClaimTime > block.timestamp) return false;
        return block.timestamp - lastClaimTime >= claimWait;
    }

    // ── 用户主动领取分红 ──
    function withdrawDividend() external {
        if (totalShares == 0) return;
        uint256 bal = IERC20(token).balanceOf(msg.sender);
        if (bal < minDividendBalance) return;

        uint256 pending = (bal * accDividendPerShare - lastAccDividendPerShare[msg.sender]) / 1e18;
        if (pending > 0 && address(this).balance >= pending && canAutoClaim(lastClaimTimes[msg.sender])) {
            lastAccDividendPerShare[msg.sender] = accDividendPerShare;
            lastClaimTimes[msg.sender] = block.timestamp;
            (bool ok,) = msg.sender.call{value: pending}("");
            if (ok) {
                emit Claim(msg.sender, pending, false);
            }
        }
    }

    // ── 设置领取冷却时间（仅 owner） ──
    function setClaimWait(uint256 newClaimWait) external onlyOwner {
        uint256 old = claimWait;
        claimWait = newClaimWait;
        emit ClaimWaitUpdated(newClaimWait, old);
    }

    // ── 设置最低持币门槛（仅 owner） ──
    function setMinDividendBalance(uint256 _min) external onlyOwner {
        minDividendBalance = _min;
    }

    // ╍═══════════════════════════════════════════════════
    //  ★ 接收 BNB 并自动分配（由 Token 合约调用）
    //  ★ Token 合约把税费代币 swap 成 BNB 后，直接调用此函数
    // ╍═══════════════════════════════════════════════════
    function distributeBNB() external payable {
        if (totalShares == 0 || msg.value == 0) return;

        // 更新 accDividendPerShare
        accDividendPerShare += (msg.value * 1e18) / totalShares;

        emit DividendDistributed(address(0), msg.value);

        // 批量分发（最多 4 人）
        _distributeBatch();
    }

    // ── 轮训：从 cursor 开始，最多发 4 人 ──
    function _distributeBatch() internal {
        if (holders.length == 0) return;

        uint256 sent;
        uint256 attempts;
        uint256 cursor = dividendCursor;

        while (sent < DIVIDEND_BATCH && attempts < holders.length) {
            if (cursor >= holders.length) cursor = 0;

            address holder = holders[cursor];
            uint256 balance = IERC20(token).balanceOf(holder);

            if (balance >= minDividendBalance) {
                uint256 pending = (balance * accDividendPerShare - lastAccDividendPerShare[holder]) / 1e18;
                if (pending > 0 && address(this).balance >= pending && canAutoClaim(lastClaimTimes[holder])) {
                    lastAccDividendPerShare[holder] = accDividendPerShare;
                    lastClaimTimes[holder] = block.timestamp;
                    (bool ok,) = holder.call{value: pending}("");
                    if (ok) {
                        emit DividendDistributed(holder, pending);
                        sent++;
                    }
                }
            }

            cursor++;
            attempts++;
        }

        dividendCursor = cursor;
    }

    // ╍═══════════════════════════════════════════════════
    //  ★ 管理员提取（平台方钱包）
    //  ★ 如果出现问题，平台方可以提取合约中的 BNB
    // ╍═══════════════════════════════════════════════════
    function withdrawBNB() external onlyOwner {
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok,) = platformOwner.call{value: bal}("");
        if (!ok) revert TransferFail();
        emit WithdrawBNB(platformOwner, bal);
    }

    function withdrawToken(address _token, uint256 amount) external onlyOwner {
        if (_token == address(0)) revert NotToken();
        IERC20(_token).transfer(platformOwner, amount);
        emit WithdrawToken(_token, platformOwner, amount);
    }

    // ── 查询 ──
    function pendingDividend(address addr) external view returns (uint256) {
        if (totalShares == 0) return 0;
        uint256 bal = IERC20(token).balanceOf(addr);
        if (bal < minDividendBalance) return 0;
        return (bal * accDividendPerShare - lastAccDividendPerShare[addr]) / 1e18;
    }

    function holdersCount() external view returns (uint256) {
        return holders.length;
    }

    // ── 接收 BNB（Token 合约直接打 BNB 到这里） ──
    receive() external payable {
        // 如果来自 Token 合约，不自动分配（由 Token 调用 distributeBNB）
        // 如果是其他地址打 BNB，也不自动分配（需要调用 distributeBNB）
    }
}
