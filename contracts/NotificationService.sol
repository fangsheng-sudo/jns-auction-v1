// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./deps/Deps.sol";

/**
 * @title  NotificationService —— JNS 域名到期/变更提醒服务（模式③ 预授权 + 按需拉取）
 * @notice 第四批交付 · 2026-09-14 · 只读核查版（未部署、未上链、未 commit）
 *
 * ── 关键设计 ─────────────────────────────────────────────────────
 *  模式③：钱留在用户自己钱包。用户【显式链上授权】（authorizeForPulling，可随时 revoke），
 *         服务方按需 try 拉取，用户未授权一律跳过，绝不强扣。
 *  【不得每次提醒上链扣费】：提醒动作只写【链下记账】，按周期调用 settleBatch 批量结算。
 *  perUseFee = 0.05 WJ（即时型，每次读当前值）；monthlyFee 同期实现但【默认不启用】。
 *  单用户欠费上限 5 WJ（封顶，防无限拉取）；逐笔 try/catch 标记，不整批回滚。
 *  记账明细 hash 上链（detailHash）；getBatch / chargesOf / arrearsOf 对账只读接口。
 *  权限：serviceFeeRecipient 变更【仅 developer】；feeCap 由 owner 设，下限 0.01 WJ。
 *  模式①（预存余额）已实现 ⇒ withdrawBalance 无条件可提。
 */
contract NotificationService is ReentrancyGuard, Ownable, DeveloperRole {

    // ⚠️ 两常量尾部相似，务必区分：WJ …24203c6AD（小写 c）｜JNS …2035b89
    address public constant WJ_ADDRESS  = 0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD;
    address public constant JNS_ADDRESS = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;

    uint256 public constant ONE_WJ = 1e18;
    uint256 public constant FEE_CAP_FLOOR = 0.01e18;      // feeCap 绝对下限 0.01 WJ（M2）
    uint256 public constant DEFAULT_PER_USE_FEE = 0.05e18;
    uint256 public constant DEFAULT_MONTHLY_FEE = 10e18;
    uint256 public constant ARREARS_CAP = 5e18;           // 单用户欠费上限 5 WJ
    uint256 public constant MAX_BATCH_USERS = 200;        // 单批上限，防 gas / 阻塞
    uint256 public constant REASON_MAX_LEN = 200;

    // ═══════════ 收入参数（三模块独立，禁止全局 feeRecipient）═══════════
    /// @dev 仅 developer 可变；owner 只能设 feeCap 上限
    address public serviceFeeRecipient;
    /// @dev 【v1 休眠】perUseFee = 0 ⇒ 提醒服务不启用（settleBatch 逐笔 hit "zero amount" 跳过）。
    ///      【J-53 裁定·2026-09-15】developer 填 J-53 本人地址；变更权仅其本人（自转让）。
    uint256 public perUseFee = 0;                         // 即时型：每次读当前值（v1 = 0）
    uint256 public monthlyFee = DEFAULT_MONTHLY_FEE;
    bool    public monthlyEnabled = false;                // 【v1 默认不启用】
    /// @dev owner 设定的费率上限（≥ FEE_CAP_FLOOR）
    uint256 public feeCap = 1e18;

    // ═══════════ 授权（模式③）═══════════
    mapping(address => bool) public authorized;           // 链上授权同意拉取
    mapping(address => bool) public optedOut;             // 显式拒收（可复授权）

    // ═══════════ 模式① 预存余额（可选）═══════════
    mapping(address => uint256) public balanceOf;         // 用户预存（WJ）

    // ═══════════ 对账台账 ═══════════
    mapping(address => uint256) public chargesOf;         // 历史累计【已收】
    mapping(address => uint256) public arrearsOf;         // 历史累计【欠费】
    /// @dev 【M-D】每用户已结算到的周期末：要求 periodStart > lastSettledEnd[u]，防周期重放
    mapping(address => uint256) public lastSettledEnd;

    struct Batch {
        address user;
        uint256 count;        // 提醒条数（链下记账后提交）
        uint256 amount;       // 实际金额（已封顶）
        uint256 collected;    // 实际收到
        uint256 periodStart;
        uint256 periodEnd;
        bytes32 detailHash;   // 链下记账明细 hash
        uint256 ts;
        bool    capped;       // 是否触发欠费封顶
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
    event ServiceFeeRecipientChanged(address indexed oldAddr, address indexed newAddr, uint256 ts);
    event PerUseFeeChanged(uint256 oldFee, uint256 newFee, uint256 ts);
    event MonthlyFeeChanged(uint256 oldFee, uint256 newFee, uint256 ts);
    event MonthlyEnabledChanged(bool enabled, uint256 ts);
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
     *      · 单笔金额按 counts[i] × 当前费率 计算；超过 ARREARS_CAP(5 WJ) ⇒ 封顶；
     *      · 明细 hash 上链，提供 getBatch / chargesOf / arrearsOf 对账。
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

        // ② 金额：即时读当前费率（不快照）
        uint256 amount = count * unitFee();
        bool capped = false;
        if (amount > ARREARS_CAP) { amount = ARREARS_CAP; capped = true; }
        if (amount == 0) {
            emit ChargeSkipped(batches.length, u, 0, "zero amount", block.timestamp);
            return;
        }

        // ③ 优先从预存余额抵扣，不足部分再按需拉取
        uint256 collected = balanceOf[u] >= amount ? amount : balanceOf[u];
        if (collected > 0) { balanceOf[u] -= collected; }
        uint256 toPull = amount - collected;

        // ④ 逐笔 try（低层 call，不 revert 整批）
        if (toPull > 0) {
            // 【M-A】绕过 _wjSafeTransfer 的拉取点须内联同一道门槛，否则收款方为 0/WJ 时
            //        首次结算即烧 WJ、J 退本合约，永久损失
            require(serviceFeeRecipient != address(0) && serviceFeeRecipient != WJ_ADDRESS, "WJ trap: bad fee recipient");
            bool ok = SafeERC20.trySafeTransferFrom(IERC20(WJ_ADDRESS), u, serviceFeeRecipient, toPull);
            if (ok) { collected += toPull; }
        }

        // ⑤ 记账（成功部分计入已收，失败部分计入欠费）
        chargesOf[u] += collected;
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

    /// @dev 当前单位费率（即时型，每次读当前值）；【M-B】读取时以 feeCap 钳制，owner 可随时下调
    function unitFee() public view returns (uint256) {
        uint256 f = monthlyEnabled ? monthlyFee : perUseFee;
        if (f > feeCap) { f = feeCap; }     // 钳制：避免 owner 下调 feeCap 后造成死锁
        return f;
    }

    // ═══════════ 收入参数权限校验 ═══════════
    /// @dev 收款方变更【仅 developer】；且须非 0、非 WJ（防陷阱）
    function setServiceFeeRecipient(address newAddr) external onlyDeveloper {
        require(newAddr != address(0) && newAddr != WJ_ADDRESS, "NS: bad recipient");
        emit ServiceFeeRecipientChanged(serviceFeeRecipient, newAddr, block.timestamp);
        serviceFeeRecipient = newAddr;
    }

    function setPerUseFee(uint256 newFee) external onlyDeveloper {
        require(newFee <= feeCap, "NS: above feeCap");
        emit PerUseFeeChanged(perUseFee, newFee, block.timestamp);
        perUseFee = newFee;
    }

    function setMonthlyFee(uint256 newFee) external onlyDeveloper {
        require(newFee <= feeCap, "NS: above feeCap");
        emit MonthlyFeeChanged(monthlyFee, newFee, block.timestamp);
        monthlyFee = newFee;
    }

    function setMonthlyEnabled(bool enabled) external onlyDeveloper {
        emit MonthlyEnabledChanged(enabled, block.timestamp);
        monthlyEnabled = enabled;
    }

    /// @dev feeCap 由 owner 设；硬下限 0.01 WJ（M2）。
    ///      【M-B】已移除「不得低于当前费率」的限制：owner 可随时下调（超限部分由 unitFee() 钳制），
    ///      不再死锁。建议下调走 Timelock；变更必须 emit。
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
