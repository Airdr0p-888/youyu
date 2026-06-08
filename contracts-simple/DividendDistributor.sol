// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 a) external returns (bool);
    function approve(address sp, uint256 a) external returns (bool);
}

interface IPancakeRouter {
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 aIn, uint256 aMin, address[] calldata path,
        address to, uint256 deadline
    ) external;
    function getAmountsOut(uint256 aIn, address[] calldata path)
        external view returns (uint256[] memory);
}

/**
 * @title DividendDistributor
 * @notice 独立分红合约 —— 接收代币税费 → swap 成 BNB → 按持仓比例轮训分发
 *
 * 设计要点：
 *  1. platformOwner 由构造函数设定（定死为平台方钱包 0x8fDb...CBb36）
 *  2. token 地址可后续 setToken() 绑定（支持先部署 Distributor 再部署 Token）
 *  3. 持仓列表由 Token 合约通过 updateHolder(addr, balance) 推送更新
 *  4. distribute() 公开函数，任何人可触发（不依赖 owner）
 *  5. 轮训机制：累积到阈值 → swap → 按 cursor 每次发 4 人 → 循环往复
 *  6. withdrawBNB() / withdrawToken() 只有 platformOwner 可调用
 */
contract DividendDistributor {
    address public immutable platformOwner;
    address public immutable PANCAKE;
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
    uint256 public constant DIVIDEND_THRESHOLD = 0.01 ether; // 0.01 BNB（代币等值）
    uint256 public constant DIVIDEND_BATCH    = 4;           // 每次发 4 人

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
    event DividendSwapped(uint256 tokenAmount, uint256 bnbReceived);
    event DividendDistributed(address indexed to, uint256 bnbAmount);
    event WithdrawBNB(address indexed to, uint256 amount);
    event WithdrawToken(address indexed tokenAddr, address indexed to, uint256 amount);

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

    constructor(address _platformOwner, address _router) {
        if (_platformOwner == address(0)) revert TokenAlreadySet(); // 复用 error
        if (_router == address(0)) revert NotToken(); // 复用 error
        platformOwner = _platformOwner;
        PANCAKE       = _router;
    }

    // ── 绑定代币地址（只能调用一次，在 Token 部署后执行） ──
    function setToken(address _token) external onlyOwner {
        if (token != address(0)) revert TokenAlreadySet();
        if (_token == address(0)) revert NotToken();
        token = _token;
        emit TokenSet(_token);
    }

    // ╍══════════════════════════════════════════════════════
    //  ★ 由 Token 合约在每次 mint / _transfer 后调用
    //  ★ 推送最新持仓，保持 holders[] 与链上余额同步
    // ╍══════════════════════════════════════════════════════
    function updateHolder(address addr, uint256 newBalance) external onlyToken {
        uint256 idxPlus1 = holderIndexPlus1[addr];

        if (newBalance > 0 && idxPlus1 == 0) {
            // 新持币者 → 加入列表
            holderIndexPlus1[addr] = holders.length + 1;
            holders.push(addr);
            emit HolderUpdated(addr, newBalance, true);
        } else if (newBalance == 0 && idxPlus1 > 0) {
            // 清仓 → 从列表移除（与最后一个元素交换）
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

        // 更新 totalShares
        _recalcTotalShares();
    }

    // ── 重算 totalShares（当 holder 列表变化时调用） ──
    function _recalcTotalShares() internal {
        uint256 sum;
        for (uint256 i = 0; i < holders.length; i++) {
            sum += IERC20(token).balanceOf(holders[i]);
        }
        totalShares = sum;
    }

    // ╍══════════════════════════════════════════════════════
    //  ★ 公开函数：任何人可触发分红
    //  ★ 流程：估算代币价值 → 达到阈值 → swap → 更新累计 → 发 4 人
    // ╍══════════════════════════════════════════════════════
    function distribute() external {
        if (holders.length == 0) revert NoHolders();
        if (inSwap) return;

        uint256 tokenBal = IERC20(token).balanceOf(address(this));
        if (tokenBal == 0) return;

        // 估算 BNB 价值
        uint256 bnbValue = _estimateBNBValue(tokenBal);
        if (bnbValue < DIVIDEND_THRESHOLD) return;

        _doSwapAndDistribute(tokenBal);
    }

    // ── 内部：swap + 分发 ──
    function _doSwapAndDistribute(uint256 tokenAmount) internal lockSwap {
        // 1. approve router
        IERC20(token).approve(address(PANCAKE), tokenAmount);

        // 2. swap tokens → BNB
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = IPancakeRouter(PANCAKE).WETH();

        uint256 bnbBefore = address(this).balance;

        IPancakeRouter(PANCAKE).swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp + 60
        );

        uint256 bnbReceived = address(this).balance - bnbBefore;
        if (bnbReceived == 0 || totalShares == 0) return;

        // 3. 更新 accDividendPerShare
        accDividendPerShare += (bnbReceived * 1e18) / totalShares;

        emit DividendSwapped(tokenAmount, bnbReceived);

        // 4. 轮训分发（最多 4 人）
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

            if (balance > 0) {
                uint256 pending = (balance * accDividendPerShare - lastAccDividendPerShare[holder]) / 1e18;
                if (pending > 0 && address(this).balance >= pending) {
                    lastAccDividendPerShare[holder] = accDividendPerShare;
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

    // ── 估算代币的 BNB 价值（通过 PancakeSwap） ──
    function _estimateBNBValue(uint256 tokenAmount) internal view returns (uint256) {
        if (tokenAmount == 0) return 0;
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = IPancakeRouter(PANCAKE).WETH();
        try IPancakeRouter(PANCAKE).getAmountsOut(tokenAmount, path) returns (uint256[] memory a) {
            return a[a.length - 1];
        } catch { return 0; }
    }

    // ╍══════════════════════════════════════════════════════
    //  ★ 管理员提取（平台方钱包）
    // ╍══════════════════════════════════════════════════════
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
        if (bal == 0) return 0;
        return (bal * accDividendPerShare - lastAccDividendPerShare[addr]) / 1e18;
    }

    function holdersCount() external view returns (uint256) {
        return holders.length;
    }

    // ── 接收 BNB（swap 回调） ──
    receive() external payable {}
}
