// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SquidLaunchFactory
 * @notice SquidLaunch 平台工厂合约 — 一键部署 Token + Refund + (可选) Dividend
 *
 * 工作流程：
 * 1. 用户调用 launch() + 附带 BNB（发射手续费）
 * 2. 工厂部署 SquidLaunchToken（owner = 用户/项目方）
 * 3. 工厂部署 SquidLaunchRefund（platformOwner = 平台钱包）
 * 4. ★ 如果启用分红 → 额外部署 SquidLaunchDividend
 * 5. 自动绑定所有合约关系
 * 6. 返回 token 合约地址
 *
 * 权限模型：
 * - owner (工厂) = 平台管理员（= 部署者钱包地址）
 * - guardian (Token) = 平台地址 → 紧急暂停、强制退款
 * - token.owner = 项目方 → 正常操作
 * - refund.platformOwner = 平台 → LP 控制、退款管理
 * - dividend.platformOwner = 平台 → 分红紧急控制（暂停/提取卡住资产）
 *
 * ★ 分红是可选项：
 *   launch() 参数 _enableDividend 决定是否创建独立分红合约
 *   不启用时 distRewardPct 默认为0，税费只分三项（wallet/burn/liq）
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ISquidLaunchToken {
    function owner() external view returns (address);
    function setRefundContract(address _refundContract) external;
    function setDividendContract(address _dividendContract) external;
    function setGuardian(address _guardian) external;
    function setUniswapRouter(address _router) external;
}

contract SquidLaunchFactory {
    address public immutable platformOwner;      // 平台方地址（不可更改）= 0x8fDb...
    address public immutable guardian;           // 平台守护者地址（传给每个 Token）

    uint256 public launchFee;                    // 发射手续费（BNB）
    bool   public launchEnabled;                 // 是否开放发射

    // 已部署项目记录
    struct ProjectInfo {
        address tokenContract;       // 代币合约
        address refundContract;      // 退款合约
        address dividendContract;    // ★ 分红合约（address(0)=未启用分红）
        address projectOwner;        // 项目方地址
        string  name;                // 代币名称
        string  symbol;              // 代币符号
        uint256 totalSupply;         // 总供应量
        uint256 launchedAt;          // 部署时间戳
        bool    active;              // 是否活跃（未被平台下架）
        bool    isPlatformProject;   // 是否为平台方自己的项目
    }

    mapping(address => ProjectInfo) public projects;       // tokenAddr => info
    address[] public allProjects;                          // 所有已部署项目的 token 地址

    event ProjectLaunched(
        address indexed token,
        address indexed refund,
        address indexed dividend,     // ★ 新增：分红合约地址
        address indexed projectOwner,
        string name, string symbol, uint256 totalSupply,
        bool isPlatformProject, bool hasDividend
    );
    event LaunchFeeUpdated(uint256 oldFee, uint256 newFee);
    event LaunchToggled(bool enabled);
    event EmergencyPause(address indexed token, address indexed caller);
    event EmergencyForceRefund(address indexed token, address indexed caller);

    modifier onlyPlatformOwner() {
        require(msg.sender == platformOwner, "SquidLaunchFactory: not platform owner");
        _;
    }

    constructor(uint256 _launchFee) {
        require(_launchFee <= 1 ether, "SquidLaunchFactory: fee too high");
        platformOwner = msg.sender;
        guardian     = msg.sender;
        launchFee    = _launchFee;
        launchEnabled = true;
    }

    // ─── 一键发射 ──────────────────────────────────────────────────────

    /**
     * @notice 一键部署代币 + 退款合约 + (可选) 分红合约
     * @param _name             代币名称
     * @param _symbol           代币符号
     * @param _totalSupply      总供应量
     * @param _routerAddress    UniswapV2Router 地址
     * @param _enableDividend   ★ 是否启用独立分红合约
     * @param _rewardToken      分红发放资产（_enableDividend=true 时有效；address(0)=BNB）
     * @param _dividendThreshold 分红触发阈值（占总供应量的% × decimals）
     */
    function launch(
        string calldata _name,
        string calldata _symbol,
        uint256 _totalSupply,
        address _routerAddress,
        bool _enableDividend,
        address _rewardToken,
        uint256 _dividendThreshold
    ) external payable returns (
        address tokenAddr,
        address refundAddr,
        address dividendAddr   // ★ 返回分红合约地址（未启用则为 address(0)）
    ) {
        require(launchEnabled, "SquidLaunchFactory: launch disabled");
        require(bytes(_name).length > 0 && bytes(_symbol).length > 0, "SquidLaunchFactory: invalid name/symbol");
        require(_totalSupply > 0, "SquidLaunchFactory: zero supply");
        require(msg.value >= launchFee, "SquidLaunchFactory: fee too low");
        require(_routerAddress != address(0), "SquidLaunchFactory: zero router");

        // 如果启用了分红但参数不合法，回退到不启用
        if (_enableDividend) {
            if (_dividendThreshold == 0) _enableDividend = false;
        }

        // ★ 判断是否为平台方自己的项目
        bool _isPlatformProject = (msg.sender == platformOwner);

        // ── 1. 部署主代币合约 ──
        tokenAddr = address(new SquidLaunchToken{
            salt: keccak256(abi.encodePacked(msg.sender, _name, block.timestamp))
        }(
            _name, _symbol, _totalSupply, msg.sender,
            _routerAddress,
            _isPlatformProject
        ));

        // ── 2. 部署退款合约 ──
        refundAddr = address(new SquidLaunchRefund{
            salt: keccak256(abi.encodePacked(tokenAddr, block.timestamp))
        }(tokenAddr, platformOwner));

        // ── 3. ★ 可选：部署分红合约 ──
        if (_enableDividend) {
            dividendAddr = address(new SquidLaunchDividend{
                salt: keccak256(abi.encodePacked(tokenAddr, bytes1(0xFF), block.timestamp))
            }(
                tokenAddr,
                platformOwner,
                _rewardToken,          // address(0) 时分红合约内部用 WETH
                _dividendThreshold,
                _routerAddress
            ));
        }

        // ── 4. 绑定关系 ──
        ISquidLaunchToken(tokenAddr).setRefundContract(refundAddr);
        ISquidLaunchToken(tokenAddr).setGuardian(guardian);

        // 绑定分红合约（如果部署了的话）
        if (_enableDividend && dividendAddr != address(0)) {
            ISquidLaunchToken(tokenAddr).setDividendContract(dividendAddr);
        }

        // ── 5. 记录项目 ──
        allProjects.push(tokenAddr);
        projects[tokenAddr] = ProjectInfo({
            tokenContract:    tokenAddr,
            refundContract:   refundAddr,
            dividendContract: dividendAddr,   // ★
            projectOwner:     msg.sender,
            name:             _name,
            symbol:           _symbol,
            totalSupply:      _totalSupply,
            launchedAt:       block.timestamp,
            active:           true,
            isPlatformProject: _isPlatformProject
        });

        emit ProjectLaunched(
            tokenAddr, refundAddr, dividendAddr, msg.sender,
            _name, _symbol, _totalSupply, _isPlatformProject, _enableDividend
        );

        // ── 6. 找零 ──
        if (msg.value > launchFee) {
            (bool sent, ) = msg.sender.call{value: msg.value - launchFee}("");
            require(sent, "SquidLaunchFactory: change send failed");
        }
    }

    // ─── 平台管理 ──────────────────────────────────────────────────────

    /** @notice 设置发射手续费 */
    function setLaunchFee(uint256 _fee) external onlyPlatformOwner {
        emit LaunchFeeUpdated(launchFee, _fee);
        launchFee = _fee;
    }

    /** @notice 开关发射功能 */
    function toggleLaunch(bool _enabled) external onlyPlatformOwner {
        launchEnabled = _enabled;
        emit LaunchToggled(_enabled);
    }

    /** @notice 下架 / 上架项目 */
    function toggleProject(address _token, bool _active) external onlyPlatformOwner {
        require(projects[_token].tokenContract != address(0), "SquidLaunchFactory: unknown project");
        projects[_token].active = _active;
    }

    // ─── 紧急操作（平台对任意项目的监管）───────────────────────────────

    /** @notice 平台紧急暂停某项目的交易 */
    function emergencyPauseProject(address _token) external onlyPlatformOwner {
        ISquidLaunchToken(_token).emergencyPause();
        emit EmergencyPause(_token, msg.sender);
    }

    /** @notice 平台强制开启某项目的退款模式 */
    function emergencyForceRefundProject(address _token) external onlyPlatformOwner {
        ISquidLaunchToken(_token).emergencyForceRefund();
        emit EmergencyForceRefund(_token, msg.sender);
    }

    // ─── 查询 ──────────────────────────────────────────────────────────

    /** @notice 获取所有已部署项目数量 */
    function getProjectCount() external view returns (uint256) {
        return allProjects.length;
    }

    /** @notice 分页查询项目列表 */
    function getProjects(uint256 _offset, uint256 _limit)
        external view returns (ProjectInfo[] memory result)
    {
        uint256 end = _offset + _limit;
        if (end > allProjects.length) end = allProjects.length;
        result = new ProjectInfo[](end - _offset);
        for (uint256 i = _offset; i < end; i++) {
            result[i - _offset] = projects[allProjects[i]];
        }
    }

    /** @notice 提取工厂内累积的发射手续费 BNB */
    function withdrawFees() external onlyPlatformOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "SquidLaunchFactory: no fees");
        (bool sent, ) = platformOwner.call{value: bal}("");
        require(sent, "SquidLaunchFactory: withdraw failed");
    }

    receive() external payable {}
    fallback() external payable {}
}
