// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./deps/Deps.sol";

/**
 * @title  EnglishAuction —— JNS 一级域名英式拍卖（单品）
 * @notice 第一批交付 · 2026-09-14 · 只读核查版（未部署、未上链、未 commit）
 *
 * ── 既定参数 ─────────────────────────────────────────────────────
 *  起拍价 = 申请人首次出价（无流拍）；取消独立 reservePrice
 *  整数规则：≥1 WJ 且 %1e18==0；最小加价 = ceil(最高价×5%) 取整到整 WJ，下限 1 WJ
 *  168h；末 10 分钟出价 → +10min；总时长上限 192h；block.timestamp
 *  settle 后资金暂存本合约；任何人可 releaseToDAO；赢家 45 天可 claimTimeoutRefund
 *  编译 --evm-version istanbul
 */
contract EnglishAuction is ReentrancyGuard, Ownable {

    // ═══════════ 链上常量（【链上查明】）═══════════
    //
    //  ⚠️ 以下两个地址尾部相似，务必区分，勿混用：
    //    WJ  : …24203c6AD（小写 c）—— 代币，18 位，可自由 transfer
    //    JNS : …2035b89（无 2420…c6AD 段）—— NFT，有 owner，不可升级
    //
    /// @dev WJ 代币。出处：EIP-55 独立复核 PASS + 链上 name()=="Wrapped Joule"、decimals()==18
    address public constant WJ_ADDRESS  = 0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD;
    /// @dev JNS 域名 NFT。出处：链上 name()=="J Name Service"、totalSupply()==822
    address public constant JNS_ADDRESS = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;

    uint256 public constant ONE_WJ          = 1e18;      // 整数 WJ 的最小单位
    uint256 public constant MAX_DURATION    = 192 hours; // 168h + 24h 封顶
    uint256 public constant EXTEND_WINDOW   = 10 minutes;
    uint256 public constant EXTEND_STEP     = 10 minutes;
    // 【P2-1 已删】MIN_INCREMENT_FLOOR(0.01 ether) 为死常量，从未使用；
    //   实际最小加价下限 = 1 WJ（见 minIncrement()），文档已统一为「下限 1 WJ」。
    // 【P2-2 已删】DEFAULT_DURATION(168h) 为死常量；工厂侧 DEFAULT_DURATION_HOURS 负责默认值。
    uint256 public constant DEFAULT_TIMEOUT = 45 days;
    uint256 public constant MAX_TIMEOUT_EXTEND = 45 days; // 每次最多 +45 天，最多延长 3 次
    uint8   public constant MAX_TIMEOUT_EXTENDS = 3;
    uint256 public constant REASON_MAX_LEN  = 200;

    // ═══════════ 状态 ═══════════
    string  public name_;             // 拍卖标的域名（全串，匹配 JNS _nslookup 语义）
    address public applicant;         // 申请人（= 首位出价人）
    address public immutable beneficiary; // 【快照】创建时锁定的收款地址，不可再改
    bytes32 public immutable reviewRef;   // 审核留痕锚点

    uint256 public immutable startTime;
    uint256 public endTime;

    address public highestBidder;
    uint256 public highestBid;        // 单位 WJ

    bool public settled;
    bool public cancelled;

    /// @dev 结算后资金托管状态机：Held → Released（放款 DAO） 或 → Refunded（超时退赢家），互斥
    enum EscrowState { None, Held, Released, Refunded }
    EscrowState public escrow;
    uint256 public requestedAt;       // MintRequested 发出时刻（45 天计时起点）
    uint256 public timeoutWindow;     // 当前超时窗口
    uint8   public timeoutExtends;    // 已延长次数

    mapping(address => uint256) public pendingReturns;

    // ═══════════ 事件 ═══════════
    event Bid(string name, address indexed bidder, uint256 amount, uint256 newEndTime, uint256 ts);
    event Outbid(string name, address indexed outbidder, uint256 refundAmount, uint256 ts);
    event Extended(string name, uint256 newEndTime, uint256 ts);
    event RefundClaimed(string name, address indexed user, uint256 amount, uint256 ts);
    event Settled(string name, address indexed winner, uint256 amount, address beneficiary, uint256 ts);
    event ApplicantWonInDefault(string name, address indexed applicant, uint256 amount, uint256 ts);
    event MintRequested(string name, address indexed winner, bytes32 reviewRef, uint256 requestedAt);
    event WJReleasedToDAO(string name, uint256 tokenId, address indexed currentOwner, uint256 amount, address indexed beneficiary, uint256 ts);
    event WinnerOwnershipMismatch(string name, uint256 tokenId, address indexed winner, address indexed currentOwner, uint256 ts);
    event TimeoutRefunded(string name, address indexed winner, uint256 amount, uint256 ts);
    event EmergencyCancelled(string name, string reason, uint256 ts);
    event TimeoutWindowExtended(string name, uint256 oldWindow, uint256 newWindow, string reason, uint256 ts);
    /// @dev 【P0-2】域名占用（requestOfName）已释放，允许重新申请该域名
    event NameReservationReleased(string name, uint256 ts);

    // ═══════════ 构造 ═══════════
    constructor(
        string  memory name__,
        uint256 durationHours_,
        uint256 startingPrice_,
        address applicant_,
        address beneficiary_,
        bytes32 reviewRef_,
        address owner_
    ) {
        require(bytes(name__).length > 0, "EA: empty name");
        require(startingPrice_ >= ONE_WJ && startingPrice_ % ONE_WJ == 0, "EA: startingPrice must be integer >=1 WJ");
        require(applicant_ != address(0), "EA: zero applicant");
        // 【WJ 陷阱】收款地址不得为 0 或 WJ 合约本体，否则 WJ.transfer 会走「烧 WJ + 退 J」分支
        require(beneficiary_ != address(0) && beneficiary_ != WJ_ADDRESS, "EA: bad beneficiary");
        require(durationHours_ > 0 && durationHours_ * 1 hours <= MAX_DURATION, "EA: bad duration");

        name_       = name__;
        applicant   = applicant_;
        beneficiary = beneficiary_;
        reviewRef   = reviewRef_;
        timeoutWindow = DEFAULT_TIMEOUT;

        startTime = block.timestamp;
        endTime   = block.timestamp + durationHours_ * 1 hours;

        // 起拍价 = 申请人首次出价（资金已由工厂在本 tx 内转入）
        highestBidder = applicant_;
        highestBid    = startingPrice_;

        _transferOwnership(owner_);
    }

    // ═══════════ WJ 陷阱防护（唯一出口）═══════════
    /**
     * @dev 【WJ 陷阱防护】本合约【所有】对外 WJ 转账都必须经此函数。
     *
     *      原因（【链上查明】WJ.sol L300 / L332）：
     *        WJ 的 transfer/transferFrom 有分支 —— 若 to == address(0) 或 to == WJ 合约地址，
     *        则【不转账】，而是烧掉等量 WJ，并把等量【原生 J】退还给 msg.sender（即本合约）。
     *        对本合约而言：WJ 凭空销毁、J 被困在合约里，且合约无提款入口 ⇒ 永久损失。
     */
    function _wjSafeTransfer(address to, uint256 value) internal {
        require(to != address(0) && to != WJ_ADDRESS, "WJ trap: recipient must not be 0 or WJ");
        if (value == 0) { return; }
        SafeERC20.safeTransfer(IERC20(WJ_ADDRESS), to, value);
    }

    // ═══════════ 整数规则 + ceil 最小加价 ═══════════
    /**
     * @dev 最小加价 = ceil(最高价 × 5%)，向上取整到整数 WJ；结果 < 1 WJ 时取 1 WJ。
     *      ⚠️ 必须 ceil，不得 floor / 四舍五入（否则低价区 5% 被算成 0，规则失效）。
     *      实测：溢出阈值 ≈ 2.3158e58 WJ；WJ 总量 ≈ 5.4468e26 WJ ⇒ 余量 4.25e49 倍。
     */
    function minIncrement() public view returns (uint256) {
        uint256 inc = highestBid * 5 / 100;
        uint256 r = inc % ONE_WJ;
        if (r != 0) { inc = (inc / ONE_WJ + 1) * ONE_WJ; }   // 向上取整到整 WJ
        if (inc < ONE_WJ) { inc = ONE_WJ; }                   // 下限 1 WJ
        return inc;
    }

    /// @dev 下一笔有效出价的下限
    function nextMinimumBid() external view returns (uint256) {
        return highestBid + minIncrement();
    }

    // ═══════════ 出价 ═══════════
    function bid(uint256 amount) external nonReentrant {
        require(!cancelled, "EA: cancelled");
        require(!settled, "EA: settled");
        // 【防同 tx 成交】bid 要求 ts < endTime；settle 要求 ts >= endTime ⇒ 条件互补，不可能同 tx
        require(block.timestamp < endTime, "EA: auction ended");
        require(amount % ONE_WJ == 0, "EA: amount must be integer WJ");
        require(amount >= highestBid + minIncrement(), "EA: below minimum");

        // 拉取 WJ（to = address(this)，非 0、非 WJ，安全）
        SafeERC20.safeTransferFrom(IERC20(WJ_ADDRESS), msg.sender, address(this), amount);

        // 前手最高价 → pull 退款台账
        if (highestBidder != address(0)) {
            pendingReturns[highestBidder] += highestBid;
            emit Outbid(name_, highestBidder, highestBid, block.timestamp);
        }

        highestBidder = msg.sender;
        highestBid    = amount;

        // 防狙击：末 10 分钟内出价 → +10min，总时长不超 192h
        if (endTime - block.timestamp <= EXTEND_WINDOW) {
            uint256 newEnd = endTime + EXTEND_STEP;
            uint256 cap    = startTime + MAX_DURATION;
            if (newEnd > cap) { newEnd = cap; }
            if (newEnd > endTime) {
                endTime = newEnd;
                emit Extended(name_, newEnd, block.timestamp);
            }
        }

        emit Bid(name_, msg.sender, amount, endTime, block.timestamp);
    }

    /**
     * @dev 【P0-2】自动释放域名占用：当拍卖【已终结且确未铸造】时，
     *      通知工厂释放 requestOfName[name]，否则该域名（因 X-3 占用机制）将永久无法再申请。
     *      条件严格：① 本合约 escrow 已进终态（Released / Refunded）或已 cancelled；
     *                ② JNS._nslookup(name) == 0（确未铸造）。
     *      失败【不阻断】主流程（释放属补偿性动作，另有工厂侧双保险与治理口 releaseName）。
     */
    function _notifyReleaseName() internal {
        bool ended = cancelled
            || escrow == EscrowState.Released
            || escrow == EscrowState.Refunded;
        if (!ended) { return; }
        if (IJNS(JNS_ADDRESS)._nslookup(name_) != 0) { return; }   // 已铸造 ⇒ 无法也不应释放
        // 低层 call：即使工厂侧拒绝也不回滚本交易
        address f = owner();
        if (f.code.length == 0) { return; }
        (bool ok, ) = f.call(abi.encodeWithSignature("releaseNameReservation(string)", name_));
        if (ok) { emit NameReservationReleased(name_, block.timestamp); }
    }

    // ═══════════ 退款（pull）═══════════
    function withdrawRefund() external nonReentrant {
        uint256 amount = pendingReturns[msg.sender];
        require(amount > 0, "EA: nothing to refund");
        pendingReturns[msg.sender] = 0;
        _wjSafeTransfer(msg.sender, amount);   // 【WJ2】退款出口
        emit RefundClaimed(name_, msg.sender, amount, block.timestamp);
    }

    // ═══════════ 结算（进入托管，不立即放款）═══════════
    function settle() external nonReentrant {
        require(!cancelled, "EA: cancelled");
        require(!settled, "EA: already settled");
        require(block.timestamp >= endTime, "EA: auction not ended");
        settled = true;
        escrow  = EscrowState.Held;

        uint256 amount = highestBid;
        requestedAt = block.timestamp;

        if (highestBidder == applicant) {
            emit ApplicantWonInDefault(name_, applicant, amount, block.timestamp);
        }
        emit Settled(name_, highestBidder, amount, beneficiary, block.timestamp);
        emit MintRequested(name_, highestBidder, reviewRef, block.timestamp);
    }

    // ═══════════ 出口①：放款给 DAO（任何人可触发，收款方固定）═══════════
    /**
     * @dev 【J-53 裁定】去权限化：任何人可触发，但收款地址 = 创建时快照的 beneficiary，调用者无法指定。
     *      前置 = 链上可验证的铸造事实：JNS._nslookup(name) != 0。
     *      实测：不存在的 name 返回 0（不 revert）⇒ 无需 try/catch。
     *      与 claimTimeoutRefund 通过 EscrowState 互斥。
     *
     *      【白名单软校验】curOwner 必须 ∈ {winner, JNS.owner()}：
     *        · 铸给 winner            → 通过（正常）
     *        · 铸给多签（claim 后未转出的中间态，claim 为 _safeMint(_msgSender())）→ 通过
     *        · 铸给无关第三方          → revert（资金停 Held，等治理纠正；避免「铸错人还照付钱」）
     */
    function releaseToDAO() external nonReentrant {
        require(escrow == EscrowState.Held, "EA: not in escrow");
        uint256 tokenId = IJNS(JNS_ADDRESS)._nslookup(name_);
        require(tokenId != 0, "EA: name not minted yet");   // 链上铸造事实

        address curOwner = IJNS(JNS_ADDRESS).ownerOf(tokenId);
        require(
            curOwner == highestBidder || curOwner == IJNS(JNS_ADDRESS).owner(),
            "EA: minted to unexpected address"
        );

        uint256 amount = highestBid;
        escrow = EscrowState.Released;

        // 【P1-2】仅当实际不匹配（铸给多签中间态）时才 emit；正常铸给赢家不得误报
        if (curOwner != highestBidder) {
            emit WinnerOwnershipMismatch(name_, tokenId, highestBidder, curOwner, block.timestamp);
        }

        _wjSafeTransfer(beneficiary, amount);   // 【WJ2】结算出口（收款方固定）
        emit WJReleasedToDAO(name_, tokenId, curOwner, amount, beneficiary, block.timestamp);
        // 注：已放款 ⇒ 域名已铸造，占用【不得】释放（已铸名不可再申请），故此处不调 _notifyReleaseName
    }

    // ═══════════ 出口②：超时退款（仅赢家本人）═══════════
    /**
     * @dev 【X-3 必修·安全阀】放行条件由「未铸造」改为「releaseToDAO 必定 revert」。
     *
     *  背景：同一 name 可能存在两场拍卖（历史数据/边界）；先铸造者占走域名后，
     *        另一场的 releaseToDAO 会因白名单校验恒 revert；而旧逻辑又要求
     *        「未铸造」才能退款 ⇒ 该场资金【无任何出口、永久锁死】。
     *
     *  新判据（三支）：
     *    ① tokenId == 0（未铸造）                       → 放行退款
     *    ② 已铸造且 curOwner ∈ {highestBidder, JNS.owner()} → revert（走 releaseToDAO，正常路径）
     *    ③ 已铸造且 curOwner 为无关第三方                 → 放行退款（releaseToDAO 必 revert，故需安全阀）
     */
    function claimTimeoutRefund() external nonReentrant {
        require(escrow == EscrowState.Held, "EA: not in escrow");
        require(msg.sender == highestBidder, "EA: only winner");

        uint256 tokenId = IJNS(JNS_ADDRESS)._nslookup(name_);
        if (tokenId != 0) {
            address cur = IJNS(JNS_ADDRESS).ownerOf(tokenId);
            // 仅当 releaseToDAO 必定 revert 时放行退款
            require(
                cur != highestBidder && cur != IJNS(JNS_ADDRESS).owner(),
                "EA: already minted, use releaseToDAO"
            );
        }
        require(block.timestamp >= requestedAt + timeoutWindow, "EA: timeout window not reached");

        uint256 amount = highestBid;
        escrow = EscrowState.Refunded;

        _wjSafeTransfer(highestBidder, amount);   // 【WJ2】退款出口
        emit TimeoutRefunded(name_, highestBidder, amount, block.timestamp);
        _notifyReleaseName();   // 【P0-2】已终结且未铸造 ⇒ 释放域名占用，允许重新申请
    }

    // ═══════════ 紧急叫停（仅 owner，仅未 settle）═══════════
    function emergencyCancel(string calldata reason) external onlyOwner {
        require(!settled, "EA: settled");
        require(!cancelled, "EA: already cancelled");
        require(bytes(reason).length <= REASON_MAX_LEN, "EA: reason too long");
        cancelled = true;

        // 所有出价（含申请人的起拍价）挂 pull 退款
        if (highestBidder != address(0) && highestBid > 0) {
            pendingReturns[highestBidder] += highestBid;
        }
        // 【P2-7】同步清理 highestBidder，避免「bid 已清零但 bidder 残留」的账面对齐歧义
        highestBid = 0;
        highestBidder = address(0);
        emit EmergencyCancelled(name_, reason, block.timestamp);
        _notifyReleaseName();   // 【P0-2】已取消且未铸造 ⇒ 释放域名占用
    }

    // ═══════════ 超时窗口可延长、不可暂停（M3）═══════════
    function extendTimeoutWindow(uint256 extra, string calldata reason) external onlyOwner {
        require(escrow == EscrowState.Held, "EA: not in escrow");
        require(timeoutExtends < MAX_TIMEOUT_EXTENDS, "EA: extend limit");
        require(extra > 0 && extra <= MAX_TIMEOUT_EXTEND, "EA: extra out of range");
        uint256 old = timeoutWindow;
        timeoutWindow = old + extra;     // 只能延长，不可缩短、不可暂停
        timeoutExtends += 1;
        emit TimeoutWindowExtended(name_, old, timeoutWindow, reason, block.timestamp);
    }

    // ═══════════ 只读 ═══════════
    function isEnded() external view returns (bool) { return block.timestamp >= endTime; }
}
