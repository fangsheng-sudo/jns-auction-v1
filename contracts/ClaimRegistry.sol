// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./deps/Deps.sol";

/**
 * @title  ClaimRegistry —— 待铸造任务登记处
 * @notice 第二批交付 · 2026-09-14 · 只读核查版（未部署、未上链、未 commit）
 *
 * ── 职责（【J-53 裁定】已调整）─────────────────────────────────────
 *   M1 改为链上校验后，本合约【不再是放款前置条件】。
 *   职责收缩为：【待铸造任务登记】——记录 auctionId / name / winner / 金额，
 *   供多签读取后执行 JNS.claim()。放款由 EnglishAuction.releaseToDAO 自行链上校验。
 *
 *   因此注册表【不持有资金、不阻塞放款】；仅作任务清单 + 链上事实同步（审计用）。
 */
contract ClaimRegistry is Ownable {

    address public constant JNS_ADDRESS = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;

    uint256 public constant PAYLOAD_MAX_LEN = 200;
    uint256 public constant REASON_MAX_LEN = 200;

    enum TaskState { None, Pending, Fulfilled, Cancelled }

    struct MintTask {
        address auction;      // 来源拍卖合约（auctionId == 该地址）
        string  name;         // 待铸造域名
        address winner;       // 应铸给谁
        uint256 amount;       // 对应金额（WJ，仅留痕，不托管）
        uint256 requestedAt;  // 登记时刻
        TaskState state;
        uint256 tokenId;      // 铸造后回填（链上同步）
        address mintedTo;     // 实际铸给谁（链上同步）
        uint256 fulfilledAt;
    }

    MintTask[] public tasks;
    /// @dev 允许登记任务的来源白名单（拍卖合约 / 工厂）
    mapping(address => bool) public isRegistrar;
    /// @dev name → taskId+1（0 表示无任务），防重复登记同一域名
    mapping(bytes32 => uint256) private _taskOfName;

    event RegistrarSet(address indexed registrar, bool ok, uint256 ts);
    event TaskRegistered(uint256 indexed taskId, address indexed auction, string name, address indexed winner, uint256 amount, uint256 ts);
    event TaskSynced(uint256 indexed taskId, string name, uint256 tokenId, address indexed mintedTo, uint256 ts);
    event TaskCancelled(uint256 indexed taskId, string reason, uint256 ts);

    constructor(address owner_) {
        _transferOwnership(owner_);
    }

    modifier onlyRegistrar() {
        require(msg.sender == owner() || isRegistrar[msg.sender], "CR: not registrar");
        _;
    }

    // ═══════════ 登记 ═══════════
    /// @dev 由拍卖合约在 settle 后调用（或 owner 代登记）。仅登记，不动资金。
    function registerTask(address auction, string calldata name, address winner, uint256 amount) external onlyRegistrar returns (uint256 taskId) {
        require(bytes(name).length > 0 && bytes(name).length <= PAYLOAD_MAX_LEN, "CR: bad name");
        require(winner != address(0), "CR: zero winner");
        bytes32 key = keccak256(bytes(name));
        require(_taskOfName[key] == 0, "CR: name already registered");

        tasks.push(MintTask({
            auction: auction,
            name: name,
            winner: winner,
            amount: amount,
            requestedAt: block.timestamp,
            state: TaskState.Pending,
            tokenId: 0,
            mintedTo: address(0),
            fulfilledAt: 0
        }));
        taskId = tasks.length - 1;
        _taskOfName[key] = taskId + 1;

        emit TaskRegistered(taskId, auction, name, winner, amount, block.timestamp);
    }

    // ═══════════ 状态流转 ═══════════
    /**
     * @dev 链上事实同步：任何人可调。以 `JNS._nslookup(name)` 为唯一判据。
     *      实测：不存在 → 0（不 revert）；tokenId 从 1 起算，0 永不出现。
     *      与 EnglishAuction.releaseToDAO 采用同一判据，二者结论必然一致。
     */
    function syncFromChain(uint256 taskId) external returns (bool fulfilled) {
        MintTask storage t = tasks[taskId];
        require(t.state == TaskState.Pending, "CR: not pending");

        uint256 tokenId = IJNS(JNS_ADDRESS)._nslookup(t.name);
        if (tokenId == 0) { return false; }        // 尚未铸造，保持 Pending

        t.state = TaskState.Fulfilled;
        t.tokenId = tokenId;
        t.mintedTo = IJNS(JNS_ADDRESS).ownerOf(tokenId);
        t.fulfilledAt = block.timestamp;

        emit TaskSynced(taskId, t.name, tokenId, t.mintedTo, block.timestamp);
        return true;
    }

    /// @dev 任务作废（owner），用于治理特别决议结束无法完成的任务
    function cancelTask(uint256 taskId, string calldata reason) external onlyOwner {
        MintTask storage t = tasks[taskId];
        require(t.state == TaskState.Pending, "CR: not pending");
        require(bytes(reason).length <= REASON_MAX_LEN, "CR: reason too long");
        // 【补2】同步释放 name 占用，否则被取消的域名永久无法再次登记
        delete _taskOfName[keccak256(bytes(t.name))];
        t.state = TaskState.Cancelled;
        emit TaskCancelled(taskId, reason, block.timestamp);
    }

    // ═══════════ 治理 ═══════════
    /// @dev 【补1】增删 registrar：仅 owner；有 emit。初始 registrar = JNSAuctionFactory 地址
    ///      （各拍卖实例地址在创建时由 owner 逐个 setRegistrar(true) 加入；亦可由工厂代登记）。
    function setRegistrar(address registrar, bool ok) external onlyOwner {
        require(registrar != address(0), "CR: zero registrar");
        isRegistrar[registrar] = ok;
        emit RegistrarSet(registrar, ok, block.timestamp);
    }

    /// @dev 【补1】批量初始化（部署时一次性加入 JNSAuctionFactory 及其已知实例）
    function setRegistrarBatch(address[] calldata registrars, bool ok) external onlyOwner {
        for (uint256 i = 0; i < registrars.length; i++) {
            require(registrars[i] != address(0), "CR: zero registrar");
            isRegistrar[registrars[i]] = ok;
            emit RegistrarSet(registrars[i], ok, block.timestamp);
        }
    }

    // ═══════════ 只读 ═══════════
    function taskCount() external view returns (uint256) { return tasks.length; }

    function taskOfName(string calldata name) external view returns (uint256 taskIdPlusOne) {
        return _taskOfName[keccak256(bytes(name))];
    }

    /// @dev 供多签一次性读取所有待办任务
    function pendingTasks() external view returns (uint256[] memory ids, string[] memory names, address[] memory winners) {
        uint256 n;
        for (uint256 i = 0; i < tasks.length; i++) { if (tasks[i].state == TaskState.Pending) { n++; } }
        ids = new uint256[](n); names = new string[](n); winners = new address[](n);
        uint256 k;
        for (uint256 i = 0; i < tasks.length; i++) {
            if (tasks[i].state == TaskState.Pending) {
                ids[k] = i; names[k] = tasks[i].name; winners[k] = tasks[i].winner; k++;
            }
        }
    }
}
