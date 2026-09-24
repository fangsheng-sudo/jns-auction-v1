// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./deps/Deps.sol";
import "./EnglishAuction.sol";
import "./EnglishAuctionDeployer.sol";

/**
 * @title  JNSAuctionFactory —— JNS 一级拍卖工厂（含链上审核留痕）
 * @notice 第一批交付 · 2026-09-14 · 只读核查版（未部署、未上链、未 commit）
 *
 * 流程：submitRequest → approveRequest ×signersRequired → createAuctionFromRequest
 * 审核留痕：审核人【用自己钱包】签名，地址上链（可与 core-contributors.md 的 Core ID 映射）
 *
 * ═════════════════════════════════════════════════════════════
 * 【开发规范·必读】（P0-1 修复引入）
 *   拍卖实例 EnglishAuction 的 owner = 【本工厂】。
 *   ⇒ 凡在 EnglishAuction 上新增任何 onlyOwner 函数，
 *     【必须同步在本工厂加一个等价转发函数】，否则该治理能力
 *     将【永久不可达】（除非将来把实例 owner 转走）。
 *   当前已对齐的转发口见「拍卖实例转发」一节；
 *   新增时请连同测试一并补齐（见 test/TestP0Fix.t.sol 的转发可达性用例）。
 * ═════════════════════════════════════════════════════════════
 */
contract JNSAuctionFactory is Ownable {

    // ⚠️ 两个常量尾部相似，务必区分：
    //    WJ  : …24203c6AD（小写 c）—— 代币
    //    JNS : …2035b89           —— NFT
    address public constant WJ_ADDRESS  = 0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD;
    address public constant JNS_ADDRESS = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;

    uint256 public constant ONE_WJ = 1e18;
    uint256 public constant BATCH_SIZE = 5;   // WP-5：每场拍卖 5 个 JNS 域名
    uint256 public constant DEFAULT_DURATION_HOURS = 168;
    uint256 public constant PAYLOAD_LEN_MAX = 200;
    uint256 public constant REASON_LEN_MAX = 200;

    enum Status { None, Pending, Approved, Created, Rejected, Cancelled }

    struct Request {
        address applicant;
        string  name;
        uint256 startingPrice;   // 单位 WJ，须 ≥1 WJ 且整数
        bytes32 payloadHash;     // 链下申请材料 hash（链上锚点）
        uint256 createdAt;
        Status  status;
        uint256 approvals;
    }

    Request[] public requests;
    /// @dev requestId → 审核人 → 是否已签（去重）
    mapping(uint256 => mapping(address => bool)) public approvedBy;
    /// @dev requestId → 审核人地址列表（留痕）
    mapping(uint256 => address[]) private _reviewersOf;

    /// @dev 【X-3 必修】name → (存活申请 requestId + 1)；0 表示无存活申请。
    ///      目的：防止同一 name 的多个申请并行存在 → 两场拍卖锁定同一域名 →
    ///      一方必被铸造占走，另一方的 Held 资金因 releaseToDAO 恒 revert、
    ///      超时退款又要求未铸造，而【永久锁死】。
    ///      生命周期：submitRequest 写入；rejectRequest / cancelRequest 删除；
    ///      已创建拍卖至 settle 待铸造期间【不删除】（域名所有权未落定）。
    mapping(string => uint256) public requestOfName;

    mapping(address => bool) public isReviewer;
    uint256 public signersRequired = 1;      // 默认单人，可配置会签

    /// @dev 一级收入归属；【快照】在 createAuctionFromRequest 时写入拍卖实例
    address public auctionBeneficiary;

    /// @dev 拍卖实例部署器；创建码从本工厂剥离，构造时注入（immutable）
    address public immutable deployer;

    address[] public auctions;
    mapping(address => bool) public isAuction;
    /// @dev 已创建批次计数（每批 BATCH_SIZE 个）
    uint256 public batchCount;

    // ═══════════ 事件 ═══════════
    event RequestSubmitted(uint256 indexed requestId, address indexed applicant, string name, uint256 startingPrice, bytes32 payloadHash, uint256 ts);
    event RequestApproved(uint256 indexed requestId, address indexed reviewer, uint256 approvals, uint256 ts);
    event RequestRejected(uint256 indexed requestId, address indexed reviewer, string reason, uint256 ts);
    event AuctionCreated(uint256 indexed requestId, address indexed auction, address indexed requester, string name, uint256 startingPrice, uint256 durationHours, bytes32 reviewRef, uint256 ts);
    event BatchCreated(uint256 indexed batchId, uint256 count, address indexed requester, uint256 ts);
    event ReviewerSet(address indexed reviewer, bool ok, uint256 ts);
    event SignersRequiredChanged(uint256 oldN, uint256 newN, uint256 ts);
    event BeneficiaryChanged(address indexed oldAddr, address indexed newAddr, uint256 ts);
    /// @dev 【X-3 必修】申请人撤回申请（释放 name 占用）
    event RequestCancelled(uint256 indexed requestId, string name, address indexed applicant, uint256 ts);
    /// @dev 【P0-2②】拍卖实例自动通知工厂释放域名占用
    event NameReservationReleasedByAuction(string name, uint256 indexed requestId, address indexed auction, uint256 ts);
    /// @dev 【P0-2③】治理兜底释放域名占用
    event NameReservationReleasedByGov(string name, uint256 indexed requestId, uint256 ts);
    /// @dev 【P0-1】工厂代实例转发 owner-only 调用（链上留痕）
    event AuctionOwnerCallForwarded(address indexed auction, string fn, uint256 ts);

    constructor(address owner_, address auctionBeneficiary_, address deployer_) {
        require(auctionBeneficiary_ != address(0) && auctionBeneficiary_ != WJ_ADDRESS, "FAC: bad beneficiary");
        require(deployer_ != address(0), "FAC: zero deployer");
        auctionBeneficiary = auctionBeneficiary_;
        deployer = deployer_;
        _transferOwnership(owner_);
    }

    modifier onlyApproved() {
        require(msg.sender == owner() || isReviewer[msg.sender], "FAC: not approved");
        _;
    }

    // ═══════════ 申请人：提交申请 ═══════════
    function submitRequest(string calldata name_, uint256 startingPrice, bytes32 payloadHash) external returns (uint256 requestId) {
        require(bytes(name_).length > 0, "FAC: empty name");
        require(startingPrice >= ONE_WJ && startingPrice % ONE_WJ == 0, "FAC: startingPrice must be integer >=1 WJ");
        // 【补测1】重名防护①：已铸造的 name 不得再申请。
        //  IJNS._nslookup(name)：不存在返回 0（不 revert）⇒ 无需 try/catch。
        //  tokenId 从 1 起算、0 永不出现 ⇒ `!= 0` 即「已铸造」。
        require(IJNS(JNS_ADDRESS)._nslookup(name_) == 0, "FAC: name already minted");
        // 【X-3 必修】重名防护②：同一 name 不得有第二个【存活申请】。
        //  否则两场拍卖争同一域名：一方铸造占走，另一方资金永久锁死（无出口）。
        require(requestOfName[name_] == 0, "FAC: name has live request");

        requests.push(Request({
            applicant: msg.sender,
            name: name_,
            startingPrice: startingPrice,
            payloadHash: payloadHash,
            createdAt: block.timestamp,
            status: Status.Pending,
            approvals: 0
        }));
        requestId = requests.length - 1;
        requestOfName[name_] = requestId + 1;   // 【X-3】登记存活申请（+1 以区分 0）

        emit RequestSubmitted(requestId, msg.sender, name_, startingPrice, payloadHash, block.timestamp);
    }

    /// @dev 【X-3 必修】申请人主动撤回【尚未创建拍卖】的申请（Pending / Approved 均可）。
    ///      释放 name 占用，允许此后重新提交。
    function cancelRequest(uint256 requestId) external {
        require(requestId < requests.length, "FAC: no such request");
        Request storage r = requests[requestId];
        require(msg.sender == r.applicant, "FAC: only applicant");
        require(r.status == Status.Pending || r.status == Status.Approved, "FAC: cannot cancel");

        r.status = Status.Cancelled;
        // 【X-3】释放 name 占用（仅当本申请正是当前占位者）
        if (requestOfName[r.name] == requestId + 1) {
            delete requestOfName[r.name];
        }
        emit RequestCancelled(requestId, r.name, msg.sender, block.timestamp);
    }

    // ═══════════ 审核人：逐人签名（防自审）═══════════
    function approveRequest(uint256 requestId) external {
        require(isReviewer[msg.sender], "FAC: not reviewer");
        Request storage r = requests[requestId];
        require(r.status == Status.Pending, "FAC: not pending");
        // 【硬约束·防自审】申请人不得审核自己的申请
        require(msg.sender != r.applicant, "FAC: reviewer cannot be applicant");
        require(!approvedBy[requestId][msg.sender], "FAC: already approved");

        approvedBy[requestId][msg.sender] = true;
        r.approvals += 1;
        _reviewersOf[requestId].push(msg.sender);

        if (r.approvals >= signersRequired) {
            r.status = Status.Approved;
        }
        emit RequestApproved(requestId, msg.sender, r.approvals, block.timestamp);
    }

    /// @dev 显式拒绝 + reason 上链（D-4 已裁定采纳）
    function rejectRequest(uint256 requestId, string calldata reason) external {
        require(isReviewer[msg.sender], "FAC: not reviewer");
        Request storage r = requests[requestId];
        require(r.status == Status.Pending, "FAC: not pending");
        require(msg.sender != r.applicant, "FAC: reviewer cannot be applicant");
        require(bytes(reason).length <= REASON_LEN_MAX, "FAC: reason too long");

        r.status = Status.Rejected;
        // 【X-3 必修】拒绝 ⇒ 释放 name 占用
        delete requestOfName[r.name];
        emit RequestRejected(requestId, msg.sender, reason, block.timestamp);
    }

    // ═══════════ 创建拍卖（同 tx 拉取起拍价）═══════════
    modifier canCreate(uint256 requestId) {
        require(requestId < requests.length, "FAC: no such request");
        Request storage r = requests[requestId];
        require(
            msg.sender == owner() || isReviewer[msg.sender] || msg.sender == r.applicant,
            "FAC: not allowed"
        );
        _;
    }

    function createAuctionFromRequest(uint256 requestId, uint256 durationHours)
        external canCreate(requestId) returns (address auction)
    {
        return _createAuction(requestId, durationHours, msg.sender);
    }

    /// @dev D-5 已裁定：同批实现。一次创建整场 5 个（内部直调，避免 this.xxx 使 msg.sender 变为合约自身）
    function createBatch(uint256[] calldata requestIds, uint256 durationHours)
        external onlyApproved returns (address[] memory created)
    {
        require(requestIds.length == BATCH_SIZE, "FAC: batch size must be 5");
        created = new address[](BATCH_SIZE);
        for (uint256 i = 0; i < BATCH_SIZE; i++) {
            created[i] = _createAuction(requestIds[i], durationHours, msg.sender);
        }
        emit BatchCreated(batchCount, BATCH_SIZE, msg.sender, block.timestamp);
        batchCount += 1;
    }

    function _createAuction(uint256 requestId, uint256 durationHours, address requester)
        internal returns (address auction)
    {
        Request storage r = requests[requestId];
        // 【硬约束】必须已通过审核
        require(r.status == Status.Approved, "FAC: request not approved");

        uint256 hours_ = durationHours == 0 ? DEFAULT_DURATION_HOURS : durationHours;

        auction = IAuctionDeployer(deployer).deploy(
            r.name,
            hours_,
            r.startingPrice,
            r.applicant,
            auctionBeneficiary,     // 【快照】受益地址在创建时锁定，此后不可再改
            r.payloadHash,
            address(this)           // owner = 工厂（日常治理经工厂转发）
        );

        // 【同 tx 拉取起拍价】applicant → 拍卖实例；只发生 1 次 transfer，工厂不持有资金
        SafeERC20.safeTransferFrom(IERC20(WJ_ADDRESS), r.applicant, auction, r.startingPrice);

        r.status = Status.Created;
        auctions.push(auction);
        isAuction[auction] = true;

        emit AuctionCreated(requestId, auction, requester, r.name, r.startingPrice, hours_, r.payloadHash, block.timestamp);
    }

    // ═══════════ 治理（owner）═══════════
    function setReviewer(address reviewer, bool ok) external onlyOwner {
        require(reviewer != address(0), "FAC: zero reviewer");
        isReviewer[reviewer] = ok;
        emit ReviewerSet(reviewer, ok, block.timestamp);
    }

    function setSignersRequired(uint256 n) external onlyOwner {
        require(n >= 1, "FAC: must be >=1");
        emit SignersRequiredChanged(signersRequired, n, block.timestamp);
        signersRequired = n;
    }

    function setAuctionBeneficiary(address newBeneficiary) external onlyOwner {
        require(newBeneficiary != address(0) && newBeneficiary != WJ_ADDRESS, "FAC: bad beneficiary");
        emit BeneficiaryChanged(auctionBeneficiary, newBeneficiary, block.timestamp);
        auctionBeneficiary = newBeneficiary;   // 只影响此后新建实例（快照语义）
    }

    /// @dev 工厂是各拍卖实例的 owner，故紧急叫停经工厂转发。
    function emergencyCancelAuction(address auction, string calldata reason) external onlyOwner {
        require(isAuction[auction], "FAC: unknown auction");
        EnglishAuction(auction).emergencyCancel(reason);
    }

    // ═══════════ 拍卖实例转发（【P0-1】系统性补齐）═══════════
    //  EA 的全部 onlyOwner 函数在此逐一对齐；将来 EA 新增时【必须同步加口】。

    /// @dev 【P0-1】转发 extendTimeoutWindow（M3：窗口可延长、不可暂停；每次 ≤45d，最多 3 次）
    function extendTimeoutWindowAuction(address auction, uint256 extra, string calldata reason) external onlyOwner {
        require(isAuction[auction], "FAC: unknown auction");
        EnglishAuction(auction).extendTimeoutWindow(extra, reason);
        emit AuctionOwnerCallForwarded(auction, "extendTimeoutWindow", block.timestamp);
    }

    /// @dev 【P0-1】转发 transferOwnership（把实例 owner 交还多签/新任治理）
    ///      ⚠️ 一旦转出，本工厂将【不再拥有】该实例，emergencyCancel / extendTimeout 转发均失效。
    function transferAuctionOwnership(address auction, address newOwner) external onlyOwner {
        require(isAuction[auction], "FAC: unknown auction");
        require(newOwner != address(0), "FAC: zero new owner");
        EnglishAuction(auction).transferOwnership(newOwner);
        emit AuctionOwnerCallForwarded(auction, "transferOwnership", block.timestamp);
    }

    /// @dev 说明：EnglishAuction 继承的 renounceOwnership 已【全局覆写禁用】（P2-4），
    ///      故无需也无法转发；若将来需冻结参数，用 transferAuctionOwnership 转到黑洞地址。

    // ═══════════ 域名占用释放（【P0-2】双保险）═══════════
    /**
     * @dev 【P0-2②】自动释放：由拍卖实例在【已终结且确未铸造】时调用。
     *      权限：仅已知拍卖实例（isAuction）；校验 name 与登记一致、且确未铸造。
     *      幂等：无占用则直接返回，不 revert（供实例低层 call 使用）。
     */
    function releaseNameReservation(string calldata name_) external {
        uint256 v = requestOfName[name_];
        if (v == 0) { return; }                       // 无占用 ⇒ 幂等返回
        require(isAuction[msg.sender], "FAC: not auction");
        uint256 rid = v - 1;
        Request storage r = requests[rid];
        require(keccak256(bytes(r.name)) == keccak256(bytes(name_)), "FAC: name mismatch");
        require(IJNS(JNS_ADDRESS)._nslookup(name_) == 0, "FAC: already minted");
        delete requestOfName[name_];
        emit NameReservationReleasedByAuction(name_, rid, msg.sender, block.timestamp);
    }

    /// @dev 【P0-2③】治理兜底：处理未预料的异常状态组合（仅 owner）
    function releaseName(uint256 requestId) external onlyOwner {
        require(requestId < requests.length, "FAC: no such request");
        Request storage r = requests[requestId];
        require(requestOfName[r.name] == requestId + 1, "FAC: not the holder");
        delete requestOfName[r.name];
        emit NameReservationReleasedByGov(r.name, requestId, block.timestamp);
    }

    // ═══════════ 只读 ═══════════
    function requestCount() external view returns (uint256) { return requests.length; }
    function reviewersOf(uint256 requestId) external view returns (address[] memory) { return _reviewersOf[requestId]; }
    function auctionCount() external view returns (uint256) { return auctions.length; }
    function allAuctions() external view returns (address[] memory) { return auctions; }
    function getRequest(uint256 requestId) external view returns (address, string memory, uint256, bytes32, uint256, Status, uint256) {
        Request storage r = requests[requestId];
        return (r.applicant, r.name, r.startingPrice, r.payloadHash, r.createdAt, r.status, r.approvals);
    }
}
