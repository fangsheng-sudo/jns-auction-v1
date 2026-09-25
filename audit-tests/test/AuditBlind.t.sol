// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "../contracts/EnglishAuction.sol";
import "./mocks/MockWJ.sol";
import "./mocks/MockJNS.sol";

interface Vm {
    function warp(uint256) external;
    function prank(address) external;
    function expectRevert(bytes calldata) external;
    function getDeployedCode(string calldata) external returns (bytes memory);
    function etch(address, bytes calldata) external;
}

/**
 * @title  AuditBlind —— JNS 拍卖 EnglishAuction 盲审测试（重写版 · 永久保留）
 * @notice 目录 /data/workspace/audit-tests/ 为独立 Foundry 工程（不入侵被测仓库）；
 *         被测合约 ../jns-auction/contracts/EnglishAuction.sol 零改动（经符号链接只读引用）；
 *         mock 一律 vm.etch 挂到被测合约硬编码的 WJ/JNS 常量地址。
 *
 *  三组测试 ↔ 审计发现（详见同目录 README.md）：
 *    A1｜多签违规直转 NFT 给赢家 + 赢家甩给第二钱包 ⇒ 恰 45 天 claimTimeoutRefund
 *        放行退款：赢家拿回货款、NFT 留第二钱包、DAO 分文未得（R9-d 双花面）
 *    A2｜NFT 误入 + settle 前 emergencyCancel ⇒ escrow 永停 None（终态不可达）
 *        ⇒ returnNftToGovernance 恒 revert "EA: not terminal"，误入 NFT 永久锁死
 *    A3｜非本场 name 的 NFT 误入 ⇒ 无任何出口、永久锁死
 *        （Refunded / Released 两种终态各验一次：revert "EA: not minted" / "EA: no NFT held"）
 *
 *  运行：cd /data/workspace/audit-tests && forge test -vvv
 */
abstract contract AuditBase {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // ── 被测合约内硬编码的链上地址（与 EnglishAuction.WJ_ADDRESS / JNS_ADDRESS 逐字符一致）──
    address constant WJ_ADDR  = 0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD;
    address constant JNS_ADDR = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;

    address constant DAO      = address(0xD0A0);   // beneficiary（创建时快照的收款方）
    address constant MULTISIG = address(0x3C3C);   // MockJNS 治理 owner（真实为 3/2 多签）
    address constant ALICE    = address(0xA11CE);  // 申请人（起拍价出资方）
    address constant BOB      = address(0xB0B);    // 赢家（最高出价人）
    address constant CAROL    = address(0xCAC0);   // 第二钱包（A1 接收甩出的 NFT）

    MockWJ  wj;
    MockJNS jns;

    function setUp() public virtual {
        vm.warp(1_000_000);

        // 🔴 盲审铁律：不改被测合约 —— 两个 mock 全部经 vm.etch 挂到硬编码地址
        vm.etch(WJ_ADDR, vm.getDeployedCode("MockWJ.sol:MockWJ"));
        wj = MockWJ(WJ_ADDR);
        vm.etch(JNS_ADDR, vm.getDeployedCode("MockJNS.sol:MockJNS"));
        jns = MockJNS(JNS_ADDR);
        jns.initialize(MULTISIG);      // etch 不跑构造函数 ⇒ 在此补治理 owner / nextId

        wj.mint(ALICE, 1_000_000e18);
        wj.mint(BOB,   1_000_000e18);
    }

    /// @dev 直建拍卖（与工厂路径等价），复刻工厂「同 tx 拉起拍价」的账面；owner = 测试合约
    function _newAuction(string memory n, uint256 sp, uint256 bidAmt)
        internal returns (EnglishAuction a)
    {
        a = new EnglishAuction(n, 168, sp, ALICE, DAO, bytes32(uint256(0x5155)), address(this));
        vm.prank(ALICE);
        wj.transfer(address(a), sp);
        if (bidAmt > 0) {
            vm.prank(BOB);
            wj.approve(address(a), bidAmt);
            vm.prank(BOB);
            a.bid(bidAmt);
        }
    }
}

contract AuditBlind is AuditBase {

    // ═══════════════════════════════════════════════════════════════
    // A1｜发现：多签违规直转 + 赢家甩 NFT ⇒ 45 天超时退款放行（R9-d 双花面）
    //     赢家拿回货款、NFT 留在第二钱包、DAO 拿不到款
    // ═══════════════════════════════════════════════════════════════
    function testA1_winnerDumpsNftThenTimeoutRefund() public {
        EnglishAuction a = _newAuction("a1-name", 10e18, 12e18);
        vm.warp(block.timestamp + 169 hours);
        a.settle();                                    // escrow = Held，requestedAt 起算

        // 多签 claim + unbind 后【绕过 settleDelivery】直转赢家（违规路径）
        vm.prank(MULTISIG);
        uint256 tid = jns.claim("a1-name");
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, BOB, tid);
        // 赢家把 NFT 甩给第二钱包 CAROL
        vm.prank(BOB);
        jns.transferFrom(BOB, CAROL, tid);
        require(jns.ownerOf(tid) == CAROL, "A1 pre: NFT must be at second wallet");

        uint256 daoBefore = wj.balanceOf(DAO);

        // DAO 出口已死：curOwner(CAROL) != highestBidder(BOB)
        vm.expectRevert(bytes("EA: unexpected owner"));
        a.releaseToDAO();

        // 差 1 秒仍被超时窗口挡住 —— 挡住退款的只剩时间，持有检查已放行
        vm.warp(a.requestedAt() + 45 days - 1);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: timeout window not reached"));
        a.claimTimeoutRefund();

        // 恰 45 天：claimTimeoutRefund 放行（curOwner = CAROL != highestBidder ⇒ 落入退款分支）
        vm.warp(a.requestedAt() + 45 days);
        vm.prank(BOB);
        a.claimTimeoutRefund();

        // 赢家拿回全部货款
        require(wj.balanceOf(BOB) == 1_000_000e18, "A1: winner must recover full payment");
        // DAO 分文未得
        require(wj.balanceOf(DAO) == daoBefore, "A1: DAO must get nothing");
        // NFT 留在第二钱包
        require(jns.ownerOf(tid) == CAROL, "A1: NFT must stay at second wallet");
        // 终态 = Refunded；合约仅剩申请人待退的起拍价；WJ 陷阱未触发
        require(a.escrow() == EnglishAuction.EscrowState.Refunded, "A1: escrow must be Refunded");
        require(wj.balanceOf(address(a)) == 10e18, "A1: only applicant's pending remains");
        require(wj.trappedAmount() == 0, "A1: WJ trap must not fire");

        // 退款后 DAO 出口彻底关死
        vm.expectRevert(bytes("EA: not in escrow"));
        a.releaseToDAO();
    }

    // ═══════════════════════════════════════════════════════════════
    // A2｜发现：NFT 误入 + settle 前 emergencyCancel ⇒ escrow 永停 None
    //     （终态不可达）⇒ returnNftToGovernance 恒 revert，误入 NFT 永久锁死
    // ═══════════════════════════════════════════════════════════════
    function testA2_misroutedNftEmergencyCancelNeverTerminal() public {
        EnglishAuction a = _newAuction("a2-name", 10e18, 12e18);
        vm.warp(block.timestamp + 169 hours);          // 到点、未 settle

        // 多签误把本场 NFT 转进拍卖合约（本应转赢家 / 授权托管）
        vm.prank(MULTISIG);
        uint256 tid = jns.claim("a2-name");
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, address(a), tid);
        require(jns.ownerOf(tid) == address(a), "A2 pre: NFT misrouted into auction");

        // settle 前紧急叫停（owner = 测试合约）
        a.emergencyCancel("misrouted nft, cancel before settle");

        require(a.cancelled(), "A2: must be cancelled");
        require(a.escrow() == EnglishAuction.EscrowState.None, "A2: escrow must stay None");

        // 唯一 NFT 出口：被 "EA: not terminal" 挡死
        vm.expectRevert(bytes("EA: not terminal"));
        a.returnNftToGovernance();

        // 终态不可达：settle 被 cancelled 永久挡死，其余出口全部 not-in-escrow
        vm.expectRevert(bytes("EA: cancelled"));
        a.settle();
        vm.expectRevert(bytes("EA: not in escrow"));
        a.releaseToDAO();
        vm.expectRevert(bytes("EA: not in escrow"));
        a.settleDelivery();
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: not in escrow"));
        a.claimTimeoutRefund();

        // 不对称即发现：资金可退、NFT 永锁
        vm.prank(BOB);
        a.withdrawRefund();
        require(wj.balanceOf(BOB) == 1_000_000e18, "A2: bidder refund must work");
        require(jns.ownerOf(tid) == address(a), "A2: misrouted NFT must stay locked");
        require(wj.trappedAmount() == 0, "A2: WJ trap must not fire");
    }

    // ═══════════════════════════════════════════════════════════════
    // A3｜发现：非本场 name 的 NFT 误入 ⇒ 无任何出口、永久锁死
    //     两个子场景（两条 revert 串均贴）：
    //       ① 本场 name 未铸（超时退款 Refunded 终态）→ "EA: not minted"
    //       ② 本场 name 已铸且在赢家手里（放款 Released 终态）→ "EA: no NFT held"
    // ═══════════════════════════════════════════════════════════════
    function testA3_foreignNameNftPermanentlyLocked() public {
        // ── ① Refunded 终态 + 外名 NFT 误入 ──
        EnglishAuction a1 = _newAuction("a3-foo", 10e18, 12e18);
        vm.warp(block.timestamp + 169 hours);
        a1.settle();
        vm.warp(a1.requestedAt() + 46 days);           // "a3-foo" 全程未铸
        vm.prank(BOB);
        a1.claimTimeoutRefund();                        // escrow = Refunded（终态）
        require(a1.escrow() == EnglishAuction.EscrowState.Refunded, "A3-1 pre: Refunded");

        vm.prank(MULTISIG);
        uint256 tidO1 = jns.claim("a3-bar");            // 属于【另一场】的 name
        vm.prank(MULTISIG);
        jns.unbind(tidO1);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, address(a1), tidO1); // 误入本场合约

        vm.expectRevert(bytes("EA: not minted"));
        a1.returnNftToGovernance();
        vm.expectRevert(bytes("EA: not in escrow"));
        a1.settleDelivery();
        // 连治理方也无法凭 JNS.owner() 身份把别家的 NFT 拉走（无授权 ⇒ 拒）
        vm.prank(MULTISIG);
        vm.expectRevert(bytes("MockJNS: not authorized"));
        jns.transferFrom(address(a1), MULTISIG, tidO1);
        require(jns.ownerOf(tidO1) == address(a1), "A3-1: foreign NFT must stay locked");

        // ── ② Released 终态（正常放款完成后）+ 外名 NFT 误入 ──
        EnglishAuction a2 = _newAuction("a3-z", 10e18, 12e18);
        vm.warp(block.timestamp + 169 hours);
        a2.settle();
        vm.prank(MULTISIG);
        uint256 tidZ = jns.claim("a3-z");
        vm.prank(MULTISIG);
        jns.unbind(tidZ);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, BOB, tidZ);          // 直转赢家 ⇒ releaseToDAO 可放款
        uint256 daoBefore = wj.balanceOf(DAO);
        a2.releaseToDAO();                               // escrow = Released，DAO 收款
        require(wj.balanceOf(DAO) == daoBefore + 12e18, "A3-2 pre: DAO paid");
        require(a2.escrow() == EnglishAuction.EscrowState.Released, "A3-2 pre: Released");

        vm.prank(MULTISIG);
        uint256 tidO2 = jns.claim("a3-other");          // 又一枚外名 NFT
        vm.prank(MULTISIG);
        jns.unbind(tidO2);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, address(a2), tidO2); // 误入

        vm.expectRevert(bytes("EA: no NFT held"));
        a2.returnNftToGovernance();
        require(jns.ownerOf(tidO2) == address(a2), "A3-2: foreign NFT must stay locked");
        require(wj.trappedAmount() == 0, "A3: WJ trap must not fire");
    }
}
