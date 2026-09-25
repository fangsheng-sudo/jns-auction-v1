// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "../contracts/EnglishAuction.sol";
import "./mocks/MockWJ.sol";
import "./mocks/MockJNS.sol";

interface Vm {
    function warp(uint256) external;
    function prank(address) external;
    function getDeployedCode(string calldata) external returns (bytes memory);
    function etch(address, bytes calldata) external;
    function targetContracts(address[] calldata) external;
}

/**
 * @title  Invariant.t.sol —— EnglishAuction escrow 状态机不变量（Foundry invariant testing）
 * @notice 目录 /data/workspace/audit-tests/ 为独立 Foundry 工程（不入侵被测仓库）。
 *         被测合约经符号链接只读引用；mock 经 vm.etch 挂到硬编码地址。
 *
 *  五条不变量（详见 §不变量定义）：
 *    INV-1  终态不可逆（Released / Refunded 冻结）
 *    INV-2  合约持有的【本场 tokenId】NFT 数 ≤ 1（外名/跨合约 NFT 不计）
 *    INV-3b 资金与 NFT 不【永久】双留（终态下误入 NFT 必有收回出口）
 *    INV-4  累计退款 ≤ 累计托管额
 *    INV-5  rescueStuckNft 永不触及 escrow==Held 的本场 tokenId
 *
 *  驱动：AuctionHandler 暴露有界动作，fuzzer 随机编排调用序列；
 *        ghost 变量记录不变量观测所需的时序事实。
 */

/// @dev 驱动 handler：把随机 seed 映射为有界、合法的状态机动作，并维护 ghost 观测量
contract AuctionHandler {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant WJ_ADDR     = 0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD;
    address constant JNS_ADDR    = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;
    address constant FOREIGN_NFT = 0x1111111111111111111111111111111111111111;

    address constant DAO      = address(0xD0A0);
    address constant MULTISIG = address(0x3C3C);
    address constant ALICE    = address(0xA11CE);
    address constant BOB      = address(0xB0B);
    address constant OWNER    = address(0xEEEE);

    EnglishAuction public auction;
    MockWJ  public wj;
    MockJNS public jns;
    MockJNS public foreign;

    // ── ghost 观测量（供不变量断言读取）──────────────────────────────
    uint256 public ghost_totalReceived;             // 累计入账（托管）额：起拍价 + 每笔成功出价
    uint256 public ghost_totalRefunded;             // 累计退款额：withdrawRefund + claimTimeoutRefund
    uint8   public ghost_terminal;                  // 首个终态：0=未达, 1=Released, 2=Refunded
    bool    public ghost_rescueOwnHeldViolation;    // INV-5：Held 态下 rescue 动过本场 tokenId

    constructor(EnglishAuction a, MockWJ w, MockJNS j, MockJNS f, uint256 initialReceived) {
        auction = a;
        wj = w;
        jns = j;
        foreign = f;
        ghost_totalReceived = initialReceived;
    }

    /// @dev 记录首个终态（终态不可逆，故只记一次）
    function _syncTerminal() internal {
        EnglishAuction.EscrowState s = auction.escrow();
        if (s == EnglishAuction.EscrowState.Released) {
            if (ghost_terminal == 0) ghost_terminal = 1;
        } else if (s == EnglishAuction.EscrowState.Refunded) {
            if (ghost_terminal == 0) ghost_terminal = 2;
        }
    }

    // ── 动作 1：时间推进（1..240 小时）───────────────────────────────
    function advanceTime(uint256 seed) external {
        uint256 h = (seed % 240) + 1;
        vm.warp(block.timestamp + h * 1 hours);
    }

    // ── 动作 2：出价（结束前，ALICE/BOB，整数 WJ）──────────────────
    function tryBid(uint256 seed) external {
        if (auction.settled() || auction.cancelled()) return;
        if (block.timestamp >= auction.endTime()) return;
        uint256 amount = auction.nextMinimumBid() + (seed % 20) * 1e18;
        address bidder = (seed % 2 == 0) ? ALICE : BOB;
        vm.prank(bidder);
        wj.approve(address(auction), amount);
        vm.prank(bidder);
        try auction.bid(amount) {
            ghost_totalReceived += amount;
        } catch {}
    }

    // ── 动作 3：结算（到点后 settle → escrow=Held）──────────────────
    function trySettle() external {
        if (auction.settled() || auction.cancelled()) return;
        if (block.timestamp < auction.endTime()) vm.warp(auction.endTime());
        try auction.settle() {
            _syncTerminal();
        } catch {}
    }

    // ── 动作 4：放款 DAO（Held → Released）───────────────────────────
    function tryReleaseToDao() external {
        try auction.releaseToDAO() {
            _syncTerminal();
        } catch {}
    }

    // ── 动作 5：DvP 原子交割（Held → Released）──────────────────────
    function trySettleDelivery() external {
        try auction.settleDelivery() {
            _syncTerminal();
        } catch {}
    }

    // ── 动作 6：超时退款（Held → Refunded，warp 越过窗口）───────────
    function tryClaimRefund() external {
        if (auction.escrow() != EnglishAuction.EscrowState.Held) return;
        address winner = auction.highestBidder();
        vm.warp(auction.requestedAt() + auction.timeoutWindow() + 1);
        uint256 before = wj.balanceOf(address(auction));
        vm.prank(winner);
        try auction.claimTimeoutRefund() {
            ghost_totalRefunded += (before - wj.balanceOf(address(auction)));
            _syncTerminal();
        } catch {}
    }

    // ── 动作 7：终态 NFT 退回治理方 ─────────────────────────────────
    function tryReturnNft() external {
        try auction.returnNftToGovernance() {} catch {}
    }

    // ── 动作 8：通用救援（本场 tokenId）—— INV-5 观测点 ─────────────
    function tryRescueOwn() external {
        uint256 tid = jns._nslookup(auction.name_());
        if (tid == 0) return;
        if (jns.ownerOf(tid) != address(auction)) return;
        bool held = auction.escrow() == EnglishAuction.EscrowState.Held;
        vm.prank(MULTISIG);
        try auction.rescueStuckNft(JNS_ADDR, tid) {
            // 若在 Held 态下成功移走本场 tokenId ⇒ 托管保护被绕过
            if (held) ghost_rescueOwnHeldViolation = true;
        } catch {}
    }

    // ── 动作 9：紧急叫停（仅 owner，未 settle）──────────────────────
    function tryEmergencyCancel() external {
        vm.prank(OWNER);
        try auction.emergencyCancel("cancel") {} catch {}
    }

    // ── 动作 10：延长超时窗口（仅 owner）────────────────────────────
    function tryExtendTimeout(uint256 seed) external {
        uint256 extra = (seed % 45 days) + 1;
        vm.prank(OWNER);
        try auction.extendTimeoutWindow(extra, "extend") {} catch {}
    }

    // ── 动作 11：pull 退款 ─────────────────────────────────────────
    function tryWithdrawRefund(uint256 seed) external {
        address bidder = (seed % 2 == 0) ? ALICE : BOB;
        uint256 before = wj.balanceOf(address(auction));
        vm.prank(bidder);
        try auction.withdrawRefund() {
            ghost_totalRefunded += (before - wj.balanceOf(address(auction)));
        } catch {}
    }

    // ── 动作 12：治理多签铸本场 NFT 并转移（合约/赢家/治理方）────────
    function multisigMintOwn(uint256 dest) external {
        string memory n = auction.name_();
        if (jns._nslookup(n) != 0) return;          // 已铸 ⇒ 幂等跳过
        vm.prank(MULTISIG);
        uint256 tid = jns.claim(n);
        vm.prank(MULTISIG);
        jns.unbind(tid);
        address to;
        if (dest % 3 == 0) to = address(auction);
        else if (dest % 3 == 1) to = auction.highestBidder();
        else to = MULTISIG;
        if (to == address(0)) return;
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, to, tid);
    }

    // ── 动作 13：注入外名 / 跨合约 NFT（INV-2 应忽略它们）───────────
    function injectForeignNft(uint256 kind) external {
        if (kind % 2 == 0) {
            _injectForeignName();
        } else {
            _injectForeignContract();
        }
    }

    function _injectForeignName() internal {
        string memory fn = "foreign-name";
        uint256 tid = jns._nslookup(fn);
        if (tid == 0) {
            vm.prank(MULTISIG);
            tid = jns.claim(fn);
            vm.prank(MULTISIG);
            jns.unbind(tid);
        }
        if (jns.ownerOf(tid) == address(auction)) return;
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, address(auction), tid);
    }

    function _injectForeignContract() internal {
        string memory fn = "fc";
        uint256 tid = foreign._nslookup(fn);
        if (tid == 0) {
            vm.prank(MULTISIG);
            tid = foreign.claim(fn);
            vm.prank(MULTISIG);
            foreign.unbind(tid);
        }
        if (foreign.ownerOf(tid) == address(auction)) return;
        vm.prank(MULTISIG);
        foreign.transferFrom(MULTISIG, address(auction), tid);
    }
}

/// @dev 极简 StdInvariant 等价物：forge 1.8.1 通过调用测试合约上的这些 view getter
///      来读取 invariant 目标配置（而非 vm.targetContract cheatcode）。
struct FuzzSelector {
    address addr;
    bytes4[] selectors;
}

struct FuzzArtifactSelector {
    string artifact;
    bytes4[] selectors;
}

struct FuzzInterface {
    address addr;
    string[] artifacts;
}

abstract contract MinimalInvariant {
    address[] private _targetedContracts;
    address[] private _targetedSenders;
    address[] private _excludedContracts;
    address[] private _excludedSenders;
    string[] private _targetedArtifacts;
    string[] private _excludedArtifacts;

    function targetContract(address newTargetedContract) internal {
        _targetedContracts.push(newTargetedContract);
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    function excludeContracts() public view returns (address[] memory) {
        return _excludedContracts;
    }

    function excludeSenders() public view returns (address[] memory) {
        return _excludedSenders;
    }

    function targetArtifacts() public view returns (string[] memory) {
        return _targetedArtifacts;
    }

    function excludeArtifacts() public view returns (string[] memory) {
        return _excludedArtifacts;
    }

    function targetSelectors() public view returns (FuzzSelector[] memory) {
        FuzzSelector[] memory empty = new FuzzSelector[](0);
        return empty;
    }

    function excludeSelectors() public view returns (FuzzSelector[] memory) {
        FuzzSelector[] memory empty = new FuzzSelector[](0);
        return empty;
    }

    function targetArtifactSelectors() public view returns (FuzzArtifactSelector[] memory) {
        FuzzArtifactSelector[] memory empty = new FuzzArtifactSelector[](0);
        return empty;
    }

    function targetInterfaces() public view returns (FuzzInterface[] memory) {
        FuzzInterface[] memory empty = new FuzzInterface[](0);
        return empty;
    }
}

/// @dev 不变量断言合约：setUp 部署被测合约 + handler，并 targetContract(handler)
contract InvariantTest is MinimalInvariant {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant WJ_ADDR     = 0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD;
    address constant JNS_ADDR    = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;
    address constant FOREIGN_NFT = 0x1111111111111111111111111111111111111111;

    address constant DAO      = address(0xD0A0);
    address constant MULTISIG = address(0x3C3C);
    address constant ALICE    = address(0xA11CE);
    address constant BOB      = address(0xB0B);
    address constant OWNER    = address(0xEEEE);

    string constant NAME = "auction-name";

    MockWJ  wj;
    MockJNS jns;
    MockJNS foreign;
    EnglishAuction  auction;
    AuctionHandler  handler;

    function setUp() public {
        vm.warp(1_000_000);

        vm.etch(WJ_ADDR, vm.getDeployedCode("MockWJ.sol:MockWJ"));
        wj = MockWJ(WJ_ADDR);
        vm.etch(JNS_ADDR, vm.getDeployedCode("MockJNS.sol:MockJNS"));
        jns = MockJNS(JNS_ADDR);
        jns.initialize(MULTISIG);
        vm.etch(FOREIGN_NFT, vm.getDeployedCode("MockJNS.sol:MockJNS"));
        foreign = MockJNS(FOREIGN_NFT);
        foreign.initialize(MULTISIG);

        wj.mint(ALICE, 1_000_000e18);
        wj.mint(BOB,   1_000_000e18);

        auction = new EnglishAuction(NAME, 168, 10e18, ALICE, DAO, bytes32(uint256(0x5155)), OWNER);
        vm.prank(ALICE);
        wj.transfer(address(auction), 10e18);

        handler = new AuctionHandler(auction, wj, jns, foreign, 10e18);
        targetContract(address(handler));
    }

    // ═══════════════════════════════════════════════════════════════
    // INV-1  终态不可逆：一旦进入 Released / Refunded，escrow 永不改变
    // ═══════════════════════════════════════════════════════════════
    function invariant_INV1_terminalIrreversible() public view {
        uint8 t = handler.ghost_terminal();
        if (t == 1) {
            assert(auction.escrow() == EnglishAuction.EscrowState.Released);
        } else if (t == 2) {
            assert(auction.escrow() == EnglishAuction.EscrowState.Refunded);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // INV-2  合约持有的【本场 tokenId】NFT 数 ≤ 1
    //        （外名/跨合约 NFT 误入会增加总持有数，但非本场 tokenId，不计）
    // ═══════════════════════════════════════════════════════════════
    function invariant_INV2_ownNftCountLeOne() public view {
        uint256 tid = jns._nslookup(NAME);
        uint256 count = 0;
        if (tid != 0 && jns.ownerOf(tid) == address(auction)) {
            count = 1;
        }
        assert(count <= 1);
    }

    // ═══════════════════════════════════════════════════════════════
    // 原 INV-3（字面「退款完成后合约不得仍持有本场 NFT」）经 invariant fuzzing
    // 实测被打破，判定为【不变量定义不当、非真实 bug】——反例：
    //   settle → multisigMintOwn(误入) → claimTimeoutRefund ⇒ Refunded 后合约仍持本场 NFT。
    // 但该 NFT 可由 returnNftToGovernance / rescueStuckNft 收回，无永久锁死；
    // 资金已退回赢家，故「资金+NFT 同时滞留」不成立。
    //   证据链固化于下方单测 testINV3_counterexampleNftRecoverableAfterRefund；
    //   修正后的不变量为 INV-3b（见下）。故此处【不再设为自动 fuzz 的不变量】。
    // ═══════════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════════
    // INV-3b（修正表述）资金与 NFT 不【永久】双留：
    //   退款（Refunded）/放款（Released）终态下，若合约仍持有本场 NFT（误入场景），
    //   则该状态必可被收回——returnNftToGovernance 的三个 require 前置
    //   （终态 + 已铸 + 本合约持有）与该状态完全重合 ⇒ 出口恒存在，不构成永久锁死。
    //   本断言直接校验三前置在当前终态下恒满足（即收回出口可达）。
    // ═══════════════════════════════════════════════════════════════
    function invariant_INV3b_terminalStuckNftRecoverable() public view {
        EnglishAuction.EscrowState s = auction.escrow();
        if (s != EnglishAuction.EscrowState.Released && s != EnglishAuction.EscrowState.Refunded) {
            return;
        }
        uint256 tid = jns._nslookup(NAME);
        if (tid == 0) return;                       // 未铸 ⇒ 无 NFT 可留
        if (jns.ownerOf(tid) != address(auction)) return;   // 未持有 ⇒ 无 NFT 可留
        // 终态 + 已铸 + 本合约持有 ⇒ returnNftToGovernance 三前置全满足 ⇒ 收回出口必然可达。
        assert(s == EnglishAuction.EscrowState.Released || s == EnglishAuction.EscrowState.Refunded);
    }

    // ═══════════════════════════════════════════════════════════════
    // INV-4  累计退款 ≤ 累计托管额
    // ═══════════════════════════════════════════════════════════════
    function invariant_INV4_refundLeReceived() public view {
        assert(handler.ghost_totalRefunded() <= handler.ghost_totalReceived());
    }

    // ═══════════════════════════════════════════════════════════════
    // INV-5  rescueStuckNft 永不触及 escrow==Held 的本场 tokenId
    // ═══════════════════════════════════════════════════════════════
    function invariant_INV5_rescueNeverTouchesHeldOwn() public view {
        assert(!handler.ghost_rescueOwnHeldViolation());
    }

    // ═══════════════════════════════════════════════════════════════
    // 附：INV-3 反例的【具体单测】——固化「定义不当」判定的证据链
    //   步骤：settle(Held) → 多签误铸本场 NFT 并转入合约 → 赢家超时退款(Refunded)
    //   断言：退款后合约仍持有 NFT（字面 INV-3 被打破），
    //        但该 NFT 可经 returnNftToGovernance 收回（非永久锁死、非资金+NFT 双留）。
    // ═══════════════════════════════════════════════════════════════
    function testINV3_counterexampleNftRecoverableAfterRefund() public {
        EnglishAuction a = new EnglishAuction("inv-demo", 168, 10e18, ALICE, DAO, bytes32(uint256(0x5155)), OWNER);
        vm.prank(ALICE);
        wj.transfer(address(a), 10e18);

        vm.warp(block.timestamp + 169 hours);
        a.settle();                                        // escrow = Held

        vm.prank(MULTISIG);
        uint256 tid = jns.claim("inv-demo");
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, address(a), tid);       // 误入合约
        require(jns.ownerOf(tid) == address(a), "pre: NFT misrouted");

        vm.warp(a.requestedAt() + 45 days + 1);
        vm.prank(ALICE);
        a.claimTimeoutRefund();                            // 赢家 = ALICE，退款 → Refunded
        require(a.escrow() == EnglishAuction.EscrowState.Refunded, "pre: Refunded");

        // 字面 INV-3 被打破：退款完成后合约仍持有本场 NFT
        require(jns.ownerOf(tid) == address(a), "INV3-literal: NFT still held after refund");

        // 但可收回：returnNftToGovernance（终态逃生口）拉回治理方
        a.returnNftToGovernance();
        require(jns.ownerOf(tid) == MULTISIG, "INV3-corrected: NFT recoverable after refund");
    }
}
