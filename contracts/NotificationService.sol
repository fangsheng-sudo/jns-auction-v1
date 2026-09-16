// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./deps/Deps.sol";

/**
 * @title  NotificationService —— JNS 域名到期/变更提醒服务（模式③ 预授权 + 按需拉取）
 * @notice 第四批交付 · 只读核查版（未部署、未上链、未 commit）
 *
 * ── 关键设计 ─────────────────────────────────────────────────────
 *  模式③：钱留在用户自己钱包。用户【显式链上授权】（authorizeForPulling，可随时 revoke），
 *         服务方按需 try 拉取，用户未授权一律跳过，绝不强扣。
 *  【不得每次提醒上链扣费】：提醒动作只写【链下记账】，按周期调用 settleBatch 批量结算。
 *
 * ── 费率设计（【J-53 裁定·2026-09-16】三档封顶）──────────────────
 *   ① PER_USE_FEE_CAP = 1 WJ   —— 单次提醒费硬上限
 *                                  【constant，任何角色（含 owner/developer）均不可改】
 *   ② MONTHLY_FEE_CAP = 30 WJ  —— 月费累计上限【constant，任何角色不可改】
 *                                  语义【A 包月制】：当月累计扣费达 30 WJ 后，
 *                                  当月【继续提醒、不再扣费】（不限次数，非硬截断）
 *   ③ perUseFee                —— 单次提醒费率，可调区间 0 ~ 1 WJ；【仅 developer】可调
 *  计价单位一律 **WJ**（J 仅作 gas）。
 *
 *  沿用既有【M2】裁定：owner 另可设 `feeCap`（下限 0.01 WJ）作为可下调的运营上限；
 *  实际费率取三者最小：perUseFee / feeCap / PER_USE_FEE_CAP。
 *  单用户单批欠费上限 5 WJ（封顶，防无限拉取）；逐笔 try/catch 标记，不整批回滚。
 *  记账明细 hash 上链（detailHash）；getBatch / chargesOf / arrearsOf / monthlyCharged 对账只读接口。
 *  权限：serviceFeeRecipient / perUseFee 变更【仅 developer】；两个 CAP 为常量，owner 亦不可改。
 *  模式①（预存余额）已实现 ⇒ withdrawBalance 无条件可提。
 */
contract NotificationService is ReentrancyGuard, Ownable, DeveloperRole {

    // ⚠️ 两常量尾部相似，务必区分：WJ …24203c6AD（小写 c）｜JNS …2035b89
    address public constant WJ_ADDRESS  = 0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD;
    address public constant JNS_ADDRESS = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;

    uint256 public constant ONE_WJ = 1e18;

    // ═══════════ 费率三档（【J-53 裁定·2026-09-16】）═══════════
    /// @dev ① 单次提醒费硬上限 1 WJ。【constant】任何角色（含 owner/developer）均不可改。
    uint256 public constant PER_USE_FEE_CAP = 1e18;
    /// @dev ② 月费累计上限 30 WJ。【constant】任何角色不可改。
    ///      语义【A 包月制】：当月累计扣费达此值后，当月【继续提醒、不再扣费】（不限次数）。
    uint256 public constant MONTHLY_FEE_CAP = 30e18;
    /// @dev 月窗口长度（用于「当月累计」的分桶滚动）
    uint256 public constant MONTH_WINDOW = 30 days;
    /// @dev 单用户单批欠费上限 5 WJ（防无限拉取）
    uint256 public constant ARREARS_CAP = 5e18;
    /// @dev 单次提醒费【启用时的建议初始价】0.05 WJ（v1 仍为 0 ⇒ 休眠）
    uint256 public constant DEFAULT_PER_USE_FEE = 0.05e18;
    /// @dev 【M2】owner 可下调的运营上限之绝对下限 0.01 WJ
    uint256 public constant FEE_CAP_FLOOR = 0.01e18;

    uint256 public constant MAX_BATCH_USERS = 200;        // 单批上限，防 gas / 阻塞
    uint256 public constant REASON_MAX_LEN = 200;

    // ═══════════ 收入参数（三模块独立，禁止全局 feeRecipient）═══════════
    /// @dev 仅 developer 可变
    address public serviceFeeRecipient;
    /// @dev 单次提醒费率。可调区间 0 ~ PER_USE_FEE_CAP；【仅 developer】可调。
    ///      【v1 休眠】= 0 ⇒ 提醒服务不启用（settleBatch 逐笔 hit "zero amount" 跳过）。
    ///      【J-53 裁定·2026-09-15】developer 填 J-53 本人地址；变更权仅其本人（自转让）。
    uint256 public perUseFee = 0;
    /// @dev 【M2】owner 设定的运营上限（≥ FEE_CAP_FLOOR）；实际费率由 unitFee() 取最小
    uint256 public feeCap = 1e18;

    // ═══════════ 授权（模式③）═══════════
    mapping(address => bool) public authorized;           // 链上授权同意拉取
    mapping(address => bool) public optedOut;             // 显式拒收（可复授权）

    // ═══════════ 模式① 预存余额（可选）═══════════
    mapping(address => uint256) public balanceOf;         // 用户预存（WJ）

    // ═══════════ 对账台账 ═══════════
    mapping(address => uint256) public chargesOf;         // 历史累计【已收】
    mapping(address => uint256) public arrearsOf;         // 历史累计【欠费】
    /// @dev 【A 包月制】当月累计【已收】（以 MONTH_WINDOW 分桶滚动）
    mapping(address => uint256) public monthlyCharged;
    /// @dev 【A 包月制】用户当前所属月份桶（= periodEnd / MONTH_WINDOW）
    mapping(address => uint256) public monthlyAnchor;
    /// @dev 【M-D】每用户已结算到的周期末：要求 periodStart > lastSettledEnd[u]，防周期重放
    mapping(address => uint256) public lastSettledEnd;

    struct Batch {
        address user;
        uint256 count;        // 提醒条数（链下记账后提交）
        uint256 amount;       // 实际应扣金额（已封顶）
        uint256 collected;    // 实际收到
        uint256 periodStart;
        uint256 periodEnd;
        bytes32 detailHash;   // 链下记账明细 hash
        uint256 ts;
        bool    capped;       // 是否触发封顶（单批欠费上限 / 当月额度上限）
    }
    Batch[] public batches;
    /// @dev 用户 → 该用户的 batchId 列表（对账）
    mapping(address => uint256[]) private _batchesOf;

    event AuthorizedForPulling(address indexed user, uint256 ts);
    event AuthorizationRevoked(address indexed user, uint256 ts);
    event Deposited(address indexed user, uint256 amount, uint256 ts);
    event BalanceWithdrawn(address indexed user, uint256 amount, uint256 ts);
    event BatchSettled(uint256 indexed batchId, address indexed user, uint256 count, uint256 amount, uint256 periodStart, uint256 periodEnd, uint256 ts);
    event ChargeSkipped(uint256 indexed batchId, address indexed user, uint256 amount, string reason, uint256 ts);
    event ArrearsCapped(address indexed user, uint256 arrears, uint256 ts);   // 【M-C】累计欠费达上限而跳过
    /// @dev 【A 包月制】当月付满 MONTHLY_FEE_CAP ⇒ 继续提醒、不再扣费
    event MonthlyCapReached(address indexed user, uint256 count, uint256 monthlyCharged, uint256 ts);
    event ServiceFeeRecipientChanged(address indexed oldAddr, address indexed newAddr, uint256 ts);
    event PerUseFeeUpdated(uint256 oldFee, uint256 newFee, uint256 ts);
    event FeeCapChanged(uint256 oldCap, uint256 newCap, uint256 ts);

    constructor(address owner_, address developer_, address serviceFeeRecipient_) {
        require(serviceFeeRecipient_ != address(0) && serviceFeeRecipient_ != WJ_ADDRESS, "NS: bad fee recipient");
        serviceFeeRecipient = serviceFeeRecipient_;
        _transferOwnership(owner_);
        _initDeveloper(developer_);
    }

    // ═══════════ WJ 陷阱防护（唯一出口）═══════════
    function _wjSafeTransfer(address to, uint256 value) internal {
        require(to != address(0) && to != WJ_ADDRESS, "WJ trap: recipient must not be 0 or WJ");
        if (value == 0) { return; }
        SafeERC20.safeTransfer(IERC20(WJ_ADDRESS), to, value);
    }

    // ═══════════ 授权 / 撤销（用户自主）═══════════
    /// @dev 模式③ 授权：同意服务方按需拉取。用户可随时 revoke ⇒ 一律不强扣。
    function authorizeForPulling() external {
        authorized[msg.sender] = true;
        optedOut[msg.sender] = false;
        emit AuthorizedForPulling(msg.sender, block.timestamp);
    }

    function revokeAuthorization() external {
        authorized[msg.sender] = false;      // 立即生效，后续 settleBatch 一律跳过
        optedOut[msg.sender] = true;
        emit AuthorizationRevoked(msg.sender, block.timestamp);
    }

    // ═══════════ 模式① 预存余额：存取 ═══════════
    function deposit(uint256 amount) external nonReentrant {
        require(amount % ONE_WJ == 0, "NS: amount must be integer WJ");
        require(amount > 0, "NS: zero");
        SafeERC20.safeTransferFrom(IERC20(WJ_ADDRESS), msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
        emit Deposited(msg.sender, amount, block.timestamp);
    }

    /// @dev 【无条件可取】模式①预存余额，任何状态下用户都可提回自己的钱
    function withdrawBalance() external nonReentrant {
        uint256 amount = balanceOf[msg.sender];
        require(amount > 0, "NS: nothing to withdraw");
        balanceOf[msg.sender] = 0;
        _wjSafeTransfer(msg.sender, amount);
        emit BalanceWithdrawn(msg.sender, amount, block.timestamp);
    }

    // ═══════════ 批量结算（仅 developer）═══════════
    /// @dev 结算上下文打包（memory struct 只占一个栈槽，避免 stack too deep）
    struct SettleCtx {
        uint256 periodStart;
        uint256 periodEnd;
        bytes32 detailHash;
    }

    /**
     * @dev 链下记账 → 周期批量结算。要点：
     *      · 仅 developer 可调；
     *      · 逐笔 try/catch（低层 call 判 bool），【失败不整批回滚】，逐笔标记；
     *      · 未授权 / 已撤销 ⇒ 跳过并 emit ChargeSkipped（绝不强扣）；
     *      · 单笔金额 = counts[i] × 当前费率，先封【单批欠费上限 5 WJ】，再封【当月剩余额度】；
     *      · 【A 包月制】当月付满 30 WJ ⇒ 继续提醒、不再扣费（emit MonthlyCapReached）；
     *      · 明细 hash 上链，提供 getBatch / chargesOf / arrearsOf / monthlyCharged 对账。
     */
    function settleBatch(
        uint256 periodStart,
        uint256 periodEnd,
        address[] calldata users,
        uint256[] calldata counts,
        bytes32 detailHash
    ) external onlyDeveloper nonReentrant returns (uint256 batchCount_) {
        require(users.length == counts.length, "NS: length mismatch");
        require(users.length > 0 && users.length <= MAX_BATCH_USERS, "NS: bad batch size");
        require(periodEnd >= periodStart, "NS: bad period");
        require(periodEnd <= block.timestamp, "NS: future period");   // 【补2】防误传未来周期锁死该用户后续结算

        SettleCtx memory ctx = SettleCtx(periodStart, periodEnd, detailHash);
        for (uint256 i = 0; i < users.length; i++) {
            _settleOne(users[i], counts[i], ctx);
            batchCount_ += 1;
        }
    }

    /// @dev 单用户结算（抽离以避开 stack too deep）
    function _settleOne(address u, uint256 count, SettleCtx memory ctx) internal {
        // 【M-C】累计欠费达上限 ⇒ 跳过，不再继续计费（当前仅封单笔，跨批次累计须在此封顶）
        if (arrearsOf[u] >= ARREARS_CAP) {
            emit ArrearsCapped(u, arrearsOf[u], block.timestamp);
            return;
        }
        // 【P1-3】周期重放改为【逐笔跳过】而非整批 revert：单个用户的脏数据不得砖化整批结算
        if (ctx.periodStart <= lastSettledEnd[u]) {
            emit ChargeSkipped(batches.length, u, 0, "period already settled", block.timestamp);
            return;
        }

        // ① 未授权 / 已撤销 ⇒ 跳过，绝不强扣
        if (!authorized[u] || optedOut[u]) {
            emit ChargeSkipped(batches.length, u, 0, "not authorized", block.timestamp);
            return;
        }

        // ② 【A 包月制】跨月滚动 ⇒ 重置当月累计
        uint256 m = ctx.periodEnd / MONTH_WINDOW;
        if (monthlyAnchor[u] != m) {
            monthlyAnchor[u] = m;
            monthlyCharged[u] = 0;
        }

        // ③ 金额：即时读当前费率（不快照）
        uint256 amount = count * unitFee();
        bool capped = false;
        //   先封【单批欠费上限 5 WJ】
        if (amount > ARREARS_CAP) { amount = ARREARS_CAP; capped = true; }

        //   再封【当月剩余额度】——月费对单次费【真正起封顶作用】，非两套独立收费
        uint256 mCharged = monthlyCharged[u];
        if (mCharged >= MONTHLY_FEE_CAP) {
            // 【A 包月制】当月已付满 30 WJ ⇒ 继续提醒、不再扣费（不限次数）
            emit MonthlyCapReached(u, count, mCharged, block.timestamp);
            return;
        }
        uint256 remaining = MONTHLY_FEE_CAP - mCharged;
        if (amount > remaining) { amount = remaining; capped = true; }

        if (amount == 0) {
            emit ChargeSkipped(batches.length, u, 0, "zero amount", block.timestamp);
            return;
        }

        // ④ 优先从预存余额抵扣，不足部分再按需拉取
        uint256 collected = balanceOf[u] >= amount ? amount : balanceOf[u];
        if (collected > 0) { balanceOf[u] -= collected; }
        uint256 toPull = amount - collected;

        // ⑤ 逐笔 try（低层 call，不 revert 整批）
        if (toPull > 0) {
            // 【M-A】绕过 _wjSafeTransfer 的拉取点须内联同一道门槛，否则收款方为 0/WJ 时
            //        首次结算即烧 WJ、J 退本合约，永久损失
            require(serviceFeeRecipient != address(0) && serviceFeeRecipient != WJ_ADDRESS, "WJ trap: bad fee recipient");
            bool ok = SafeERC20.trySafeTransferFrom(IERC20(WJ_ADDRESS), u, serviceFeeRecipient, toPull);
            if (ok) { collected += toPull; }
        }

        // ⑥ 记账（成功部分计入已收与当月累计，失败部分计入欠费）
        chargesOf[u] += collected;
        monthlyCharged[u] = mCharged + collected;
        if (collected < amount) { arrearsOf[u] += (amount - collected); }

        uint256 bid = batches.length;
        batches.push(Batch({
            user: u, count: count, amount: amount, collected: collected,
            periodStart: ctx.periodStart, periodEnd: ctx.periodEnd,
            detailHash: ctx.detailHash, ts: block.timestamp, capped: capped
        }));
        _batchesOf[u].push(bid);
        lastSettledEnd[u] = ctx.periodEnd;   // 【补1】仅在实际记账后推进周期水位

        if (collected < amount) {
            emit ChargeSkipped(bid, u, amount - collected, "pull failed", block.timestamp);
        }
        emit BatchSettled(bid, u, count, collected, ctx.periodStart, ctx.periodEnd, block.timestamp);
    }

    /// @dev 当前单位费率（即时型，每次读当前值）。
    ///      取三者最小：perUseFee / feeCap（owner 可下调）/ PER_USE_FEE_CAP（常量硬上限）
    function unitFee() public view returns (uint256) {
        uint256 f = perUseFee;
        if (f > feeCap) { f = feeCap; }
        if (f > PER_USE_FEE_CAP) { f = PER_USE_FEE_CAP; }
        return f;
    }

    // ═══════════ 收入参数权限校验 ═══════════
    /// @dev 收款方变更【仅 developer】；且须非 0、非 WJ（防陷阱）
    function setServiceFeeRecipient(address newAddr) external onlyDeveloper {
        require(newAddr != address(0) && newAddr != WJ_ADDRESS, "NS: bad recipient");
        emit ServiceFeeRecipientChanged(serviceFeeRecipient, newAddr, block.timestamp);
        serviceFeeRecipient = newAddr;
    }

    /// @dev 单次提醒费调整【仅 developer】；须 ≤ 常量硬上限 PER_USE_FEE_CAP（1 WJ）
    function setPerUseFee(uint256 newFee) external onlyDeveloper {
        require(newFee <= PER_USE_FEE_CAP, "NS: above per-use cap");
        emit PerUseFeeUpdated(perUseFee, newFee, block.timestamp);
        perUseFee = newFee;
    }

    /// @dev 【M2】owner 可下调运营上限（下限 FEE_CAP_FLOOR）；不影响常量硬上限。
    ///      建议下调走 Timelock；变更必须 emit。
    function setFeeCap(uint256 newCap) external onlyOwner {
        require(newCap >= FEE_CAP_FLOOR, "NS: feeCap below floor");
        emit FeeCapChanged(feeCap, newCap, block.timestamp);
        feeCap = newCap;
    }

    // ═══════════ 对账只读接口 ═══════════
    function getBatch(uint256 batchId) external view returns (
        address user, uint256 count, uint256 amount, uint256 collected,
        uint256 periodStart, uint256 periodEnd, bytes32 detailHash, uint256 ts, bool capped
    ) {
        Batch storage b = batches[batchId];
        return (b.user, b.count, b.amount, b.collected, b.periodStart, b.periodEnd, b.detailHash, b.ts, b.capped);
    }

    function batchesOf(address user) external view returns (uint256[] memory) { return _batchesOf[user]; }
    function batchCount() external view returns (uint256) { return batches.length; }
}
