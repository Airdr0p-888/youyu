// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

/**
 * @title SquidLaunchFactory
 * @notice 发射平台工厂合约 — 使用 EIP-1167 Minimal Proxy Clone 模式
 *
 * ★ 为什么用 Clone 而非 CREATE2 内联部署？
 *   原设计：Factory import Token(30KB) + Refund(15KB) + Dividend(22KB) = ~68KB
 *   → 编译后 creation bytecode 远超 EIP-170 限制（24,576 bytes）
 *   → 部署直接失败！
 *
 * ★ 现在的架构：
 *   1. 子合约（Token/Refund/Dividend）各自独立部署为「模板合约」
 *   2. Factory 只存储模板地址，不包含任何实现代码
 *   3. launch() 时通过 EIP-1167 cloneDeterministic 创建极小的代理合约（~45字节）
 *   4. 每个 clone 自动 delegatecall 到模板的逻辑
 *   5. clone 后立即调用 initialize() 注入实例参数
 *
 * ★ 部署顺序：
 *   Step 1: 分别部署 Token / Refund / Dividend 作为模板（空构造参数）
 *   Step 2: 部署 Factory，传入模板地址
 *   Step 3: （可选）验证模板合约代码
 *   Step 4: 完成！可以调用 launch() 了
 */
contract SquidLaunchFactory {
    // ─── 模板地址（部署后由平台方设置）───────────────────────────────
    address public tokenTemplate;
    address public refundTemplate;
    address public dividendTemplate;

    address public immutable platformOwner;
    address public immutable guardian;

    uint256 public launchFee;
    bool public launchEnabled;

    struct ProjectInfo {
        address tokenContract;
        address refundContract;
        address dividendContract;
        address projectOwner;
        string  name;
        string  symbol;
        uint256 totalSupply;
        uint256 launchedAt;
        bool    active;
        bool    isPlatformProject;
    }

    struct LaunchParams {
        string  name;
        string  symbol;
        uint256 totalSupply;
        address routerAddress;
        bool    enableDividend;
        address rewardToken;
        uint256 dividendThreshold;
    }

    mapping(address => ProjectInfo) public projects;
    address[] public allProjects;

    event ProjectLaunched(
        address indexed token,
        address indexed refund,
        address indexed projectOwner,
        address dividend,
        string name,
        string symbol,
        uint256 totalSupply,
        bool isPlatformProject,
        bool hasDividend
    );
    event TemplateUpdated(string contractType, address oldTemplate, address newTemplate);
    event LaunchFeeUpdated(uint256 oldFee, uint256 newFee);
    event LaunchToggled(bool enabled);
    event EmergencyPause(address indexed token, address indexed caller);
    event EmergencyForceRefund(address indexed token, address indexed caller);

    modifier onlyPlatformOwner() {
        require(msg.sender == platformOwner, "SquidLaunchFactory: not platform owner");
        _;
    }

    /**
     * @notice 部署 Factory 时不需要传入模板地址；模板地址后续由 setTemplates() 设置
     * @param _launchFee      每次发射手续费（wei）
     * @param _platformOwner  平台方钱包地址（同时设为 guardian）
     */
    constructor(uint256 _launchFee, address _platformOwner) {
        require(_launchFee <= 1 ether, "SquidLaunchFactory: fee too high");
        require(_platformOwner != address(0), "SquidLaunchFactory: zero platform owner");
        platformOwner = _platformOwner;
        guardian     = _platformOwner;
        launchFee    = _launchFee;
        launchEnabled = true;
    }

    // ══════════════════════════════════════════════════════════════════
    // ★ 模板管理（部署后必须先设置才能 launch）
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice 设置三个子合约的模板地址（仅一次机会或可更新）
     * @dev 在分别部署 Token/Refund/Dividend 模板后调用此函数注册
     */
    function setTemplates(
        address _tokenTemplate,
        address _refundTemplate,
        address _dividendTemplate
    ) external onlyPlatformOwner {
        require(_tokenTemplate != address(0), "SquidLaunchFactory: zero token template");
        require(_refundTemplate != address(0), "SquidLaunchFactory: zero refund template");
        // dividendTemplate 可以为 address(0) — 表示不支持分红

        if (tokenTemplate != _tokenTemplate) {
            emit TemplateUpdated("Token", tokenTemplate, _tokenTemplate);
            tokenTemplate = _tokenTemplate;
        }
        if (refundTemplate != _refundTemplate) {
            emit TemplateUpdated("Refund", refundTemplate, _refundTemplate);
            refundTemplate = _refundTemplate;
        }
        if (dividendTemplate != _dividendTemplate) {
            emit TemplateUpdated("Dividend", dividendTemplate, _dividendTemplate);
            dividendTemplate = _dividendTemplate;
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // ★ EIP-1167 Minimal Proxy — 核心克隆逻辑
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice EIP-1167 CREATE2 克隆 — 返回确定性地址
     * @dev bytecode: 0x3d602d80600a3d3981f3 [impl 20B] 5af43d82803e903d91602b57fd5bf300 (55 bytes)
     */
    function _cloneDeterministic(bytes32 _salt, address _implementation)
        internal returns (address instance)
    {
        assembly {
            let ptr := mload(0x40)

            // [00-09]  0x3d602d80600a3d3981f3 - CODECOPY + RETURN 头部
            mstore(ptr, 0x3d602d80600a3d3981f3)
            // [0a-1d]  implementation address (left-padded to 32 bytes)
            mstore(add(ptr, 0x0a), shl(0x60, _implementation))
            // [1e-28]  0x5af43d82803e903d91602b57fd5bf3 - DELEGATECALL + RETURN 数据
            mstore(add(ptr, 0x1e), 0x5af43d82803e903d91602b57fd5bf3)
            // [29]     0x00 - STOP (padding for even length)
            mstore8(add(ptr, 0x29), 0x00)

            instance := create2(0, ptr, 0x37, _salt)
        }

        require(instance != address(0), "SquidLaunchFactory: clone create2 failed");
    }

    // ══════════════════════════════════════════════════════════════════
    // ★ 一键发射
    // ══════════════════════════════════════════════════════════════════

    function launch(LaunchParams calldata params)
        external
        payable
        returns (address tokenAddr, address refundAddr, address dividendAddr)
    {
        require(launchEnabled, "SquidLaunchFactory: launch disabled");
        require(tokenTemplate != address(0), "SquidLaunchFactory: token template not set");
        require(refundTemplate != address(0), "SquidLaunchFactory: refund template not set");
        require(bytes(params.name).length > 0 && bytes(params.symbol).length > 0, "invalid name/symbol");
        require(params.totalSupply > 0, "zero supply");
        require(msg.value >= launchFee, "fee too low");
        require(params.routerAddress != address(0), "zero router");

        // 分红检查
        bool enableDividend = params.enableDividend;
        if (enableDividend) {
            require(dividendTemplate != address(0), "SquidLaunchFactory: dividend template not set");
            if (params.dividendThreshold == 0) {
                enableDividend = false;
            }
        }

        bool isPlatformProject = (msg.sender == platformOwner);

        // ─── 1. Clone Token 并初始化 ───────────────────────────────
        bytes32 tokenSalt = keccak256(abi.encodePacked(msg.sender, params.name, block.timestamp));
        tokenAddr = _cloneDeterministic(tokenSalt, tokenTemplate);

        ISquidLaunchToken(tokenAddr).initialize(
            params.name,
            params.symbol,
            params.totalSupply,
            msg.sender,           // i_owner → 项目方最终 owner
            params.routerAddress,
            isPlatformProject
        );

        // ─── 2. Clone Refund 并初始化 ──────────────────────────────
        bytes32 refundSalt = keccak256(abi.encodePacked(tokenAddr, block.timestamp));
        refundAddr = _cloneDeterministic(refundSalt, refundTemplate);

        ISquidLaunchRefund(refundAddr).initialize(tokenAddr, platformOwner);

        // ─── 3. 可选：Clone Dividend 并初始化 ─────────────────────
        dividendAddr = address(0);
        if (enableDividend) {
            bytes32 divSalt = keccak256(abi.encodePacked(tokenAddr, bytes1(0xFF), block.timestamp));
            dividendAddr = _cloneDeterministic(divSalt, dividendTemplate);

            ISquidLaunchDividend(dividendAddr).initialize(
                tokenAddr,
                platformOwner,
                params.rewardToken,
                params.dividendThreshold,
                params.routerAddress
            );
        }

        // ─── 4. 绑定关系 ─────────────────────────────────────────
        ISquidLaunchToken(tokenAddr).setRefundContract(refundAddr);
        ISquidLaunchToken(tokenAddr).setGuardian(guardian);

        if (enableDividend && dividendAddr != address(0)) {
            ISquidLaunchToken(tokenAddr).setDividendContract(dividendAddr);
        }

        // ─── 5. 转移所有权给项目方 ────────────────────────────────
        // Factory 是临时 owner，现在转移给真正的项目方（msg.sender）
        ISquidLaunchToken(tokenAddr).transferOwnership(msg.sender);

        // ─── 6. 记录 + 事件 ────────────────────────────────────────
        _recordAndEmit(
            tokenAddr,
            refundAddr,
            dividendAddr,
            msg.sender,
            params.name,
            params.symbol,
            params.totalSupply,
            isPlatformProject,
            enableDividend
        );

        // ─── 7. 找零 ────────────────────────────────────────────────
        if (msg.value > launchFee) {
            (bool sent, ) = msg.sender.call{value: msg.value - launchFee}("");
            require(sent, "change send failed");
        }
    }

    function _recordAndEmit(
        address tokenAddr,
        address refundAddr,
        address dividendAddr,
        address projectOwner_,
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        bool isPlatformProject_,
        bool hasDividend_
    ) private {
        allProjects.push(tokenAddr);

        projects[tokenAddr] = ProjectInfo({
            tokenContract:    tokenAddr,
            refundContract:   refundAddr,
            dividendContract: dividendAddr,
            projectOwner:     projectOwner_,
            name:             name_,
            symbol:           symbol_,
            totalSupply:      totalSupply_,
            launchedAt:       block.timestamp,
            active:           true,
            isPlatformProject: isPlatformProject_
        });

        emit ProjectLaunched(
            tokenAddr,
            refundAddr,
            projectOwner_,
            dividendAddr,
            name_,
            symbol_,
            totalSupply_,
            isPlatformProject_,
            hasDividend_
        );
    }

    // ══════════════════════════════════════════════════════════════════
    // 平台管理函数
    // ══════════════════════════════════════════════════════════════════

    function setLaunchFee(uint256 _fee) external onlyPlatformOwner {
        emit LaunchFeeUpdated(launchFee, _fee);
        launchFee = _fee;
    }

    function toggleLaunch(bool _enabled) external onlyPlatformOwner {
        launchEnabled = _enabled;
        emit LaunchToggled(_enabled);
    }

    function toggleProject(address _token, bool _active) external onlyPlatformOwner {
        require(projects[_token].tokenContract != address(0), "unknown project");
        projects[_token].active = _active;
    }

    function emergencyPauseProject(address _token) external onlyPlatformOwner {
        ISquidLaunchToken(_token).emergencyPause();
        emit EmergencyPause(_token, msg.sender);
    }

    function emergencyForceRefundProject(address _token) external onlyPlatformOwner {
        ISquidLaunchToken(_token).emergencyForceRefund();
        emit EmergencyForceRefund(_token, msg.sender);
    }

    // ══════════════════════════════════════════════════════════════════
    // 查询函数
    // ══════════════════════════════════════════════════════════════════

    function getProjectCount() external view returns (uint256) {
        return allProjects.length;
    }

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

    function getProjectsByOwner(address _owner) external view returns (address[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < allProjects.length; i++) {
            if (projects[allProjects[i]].projectOwner == _owner) count++;
        }
        address[] memory result = new address[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < allProjects.length; i++) {
            if (projects[allProjects[i]].projectOwner == _owner) {
                result[j++] = allProjects[i];
            }
        }
        return result;
    }

    function getProjectInfo(address _token) external view returns (
        address owner,
        address tokenContract,
        address refundContract,
        address dividendContract,
        bool isPlatformProject,
        bool active,
        uint256 launchTime
    ) {
        ProjectInfo memory p = projects[_token];
        require(p.tokenContract != address(0), "unknown project");
        return (
            p.projectOwner,
            p.tokenContract,
            p.refundContract,
            p.dividendContract,
            p.isPlatformProject,
            p.active,
            p.launchedAt
        );
    }

    /** @notice 预测 Token clone 地址（用于前端展示预期地址） */
    function predictTokenAddress(address _user, string calldata _name)
        external view returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(_user, _name, block.timestamp)); // ⚠️ 含 timestamp 所以只能实时调用
        // 实际上因为含 timestamp，这个只能在同一 block 内预测
        // 更实用的方式：前端自行计算相同 salt 的 CREATE2 地址
        return address(uint160(uint256(keccak256(abi.encodePacked(
            hex'ff',
            address(this),
            salt,
            keccak256(abi.encodePacked(hex"3d602d80600a3d3981f3", tokenTemplate, hex"5af43d82803e903d91602b57fd5bf300"))
        )))));
    }

    function withdrawFees() external onlyPlatformOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "no fees");
        (bool sent, ) = platformOwner.call{value: bal}("");
        require(sent, "withdraw failed");
    }

    receive() external payable {}
    fallback() external payable {}
}
