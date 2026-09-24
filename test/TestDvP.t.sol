// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Base.sol";

/**
 * @title  第四方案 DvP 原子交割 —— 新增用例（T / R / E 三组）
 *
 *  分组口径（依 J-53 施工指令语义）：
 *    T = settleDelivery() 原子交割（6 例）
 *    R = releaseToDAO() 硬化 + claimTimeoutRefund() 三分支（6 例）
 *    E = returnNftToGovernance() 逃生口（3 例）
 *
 *  硬约束复核点：
 *    · 所有 WJ 转账经 _wjSafeTransfer ⇒ 全组断言 MockWJ 陷阱计数 _trap() == 0
 *    · NFT 一律 transferFrom（非 safe）⇒ 可向无 onERC721Received 的合约地址交割
 *    · Released / Refunded 互斥 | 新函数无 onlyOwner | settleDelivery 走 CEI
 */
contract TestDvP_T is Base {

    /// T1｜托管态 + 治理方已授权 ⇒ 一手交 NFT、一手付 WJ、emit DeliverySettled
    function testT1_settleDeliveryAtomicSuccess() public {
        address a = _settledAuction("t1", 10e18, 12e18);
        vm.prank(MULTISIG);
        uint256 tid = jns.claim("t1");                 // 铸给治理方（多签）
        require(jns.ownerOf(tid) == MULTISIG, "T1 pre: governance-held");

        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.setApprovalForAll(a, true);

        uint256 dao0 = wj.balanceOf(DAO);
        vm.recordLogs();
        EnglishAuction(a).settleDelivery();
        Log[] memory logs = vm.getRecordedLogs();

        require(jns.ownerOf(tid) == BOB, "T1: NFT must reach winner");
        require(wj.balanceOf(DAO) == dao0 + 12e18, "T1: WJ must reach beneficiary");
        require(uint256(EnglishAuction(a).escrow()) == 2, "T1: not Released");

        bytes32 ev = keccak256("DeliverySettled(string,uint256,address,uint256,address,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ev) { found = true; }
        }
        require(found, "T1: DeliverySettled not emitted");
        require(_trap() == 0, "trap");
    }

    /// T2｜治理方【未授权】⇒ 整笔原子回滚：NFT 未动、WJ 未动、escrow 退回 Held
    function testT2_settleDeliveryUnauthorizedRevertsAtomically() public {
        address a = _settledAuction("t2", 10e18, 12e18);
        vm.prank(MULTISIG);
        uint256 tid = jns.claim("t2");
        vm.prank(MULTISIG);
        jns.unbind(tid);                                // 已可转，但【不授权】
        require(jns.isApprovedForAll(MULTISIG, a) == false, "T2 pre: not approved");

        uint256 dao0 = wj.balanceOf(DAO);
        vm.expectRevert(bytes("ERC721: not authorized"));
        EnglishAuction(a).settleDelivery();

        require(jns.ownerOf(tid) == MULTISIG, "T2: NFT must not move");
        require(wj.balanceOf(DAO) == dao0, "T2: no WJ may move");
        require(uint256(EnglishAuction(a).escrow()) == 1, "T2: escrow must roll back to Held");
        require(_trap() == 0, "trap");
    }

    /// T3｜终态互斥：交割后再调 settleDelivery / claimTimeoutRefund 均拒
    function testT3_settleDeliveryTwiceAndRefundReverts() public {
        address a = _settledAuction("t3", 10e18, 12e18);
        vm.prank(MULTISIG);
        uint256 tid = jns.claim("t3");
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.setApprovalForAll(a, true);
        EnglishAuction(a).settleDelivery();

        vm.expectRevert(bytes("EA: not in escrow"));
        EnglishAuction(a).settleDelivery();

        vm.warp(block.timestamp + 46 days);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: not in escrow"));
        EnglishAuction(a).claimTimeoutRefund();
    }

    /// T4｜未铸造（tokenId == 0）⇒ 拒
    function testT4_settleDeliveryBeforeMintReverts() public {
        address a = _settledAuction("t4", 10e18, 12e18);
        vm.expectRevert(bytes("EA: not minted"));
        EnglishAuction(a).settleDelivery();
    }

    /// T5｜NFT 在无关第三方手里 ⇒ 拒（交割对象必须是治理方托管）
    function testT5_settleDeliveryWhenThirdPartyHoldsReverts() public {
        address a = _settledAuction("t5", 10e18, 12e18);
        _claimTo(CAROL, "t5");
        vm.expectRevert(bytes("EA: not gov-held"));
        EnglishAuction(a).settleDelivery();
    }

    /// T6｜无权限：任意地址（非赢家、非治理方）均可触发
    function testT6_settleDeliveryIsPermissionless() public {
        address a = _settledAuction("t6", 10e18, 12e18);
        vm.prank(MULTISIG);
        uint256 tid = jns.claim("t6");
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.setApprovalForAll(a, true);

        vm.prank(CAROL);                                 // 无关第三方调用
        EnglishAuction(a).settleDelivery();
        require(jns.ownerOf(tid) == BOB, "T6: NFT to winner");
        require(uint256(EnglishAuction(a).escrow()) == 2, "T6: Released");
        require(_trap() == 0, "trap");
    }
}

contract TestDvP_R is Base {

    /// R1｜正常路径不回归：铸给赢家 ⇒ releaseToDAO 放款成功
    function testR1_releaseToWinnerStillWorks() public {
        address a = _settledAuction("r1", 10e18, 12e18);
        _claimTo(BOB, "r1");
        uint256 dao0 = wj.balanceOf(DAO);
        EnglishAuction(a).releaseToDAO();
        require(wj.balanceOf(DAO) == dao0 + 12e18, "R1: payout");
        require(uint256(EnglishAuction(a).escrow()) == 2, "R1: Released");
        require(_trap() == 0, "trap");
    }

    /// R2｜硬化生效：铸给治理方 ⇒ releaseToDAO 拒付，escrow 停 Held
    function testR2_releaseWhenGovernanceHoldsReverts() public {
        address a = _settledAuction("r2", 10e18, 12e18);
        vm.prank(MULTISIG);
        jns.claim("r2");
        vm.expectRevert(bytes("EA: unexpected owner"));
        EnglishAuction(a).releaseToDAO();
        require(uint256(EnglishAuction(a).escrow()) == 1, "R2: must stay Held");
    }

    /// R3｜退款分支① 未铸造 + 窗口到 ⇒ 放行退款
    function testR3_refundWhenNotMintedPasses() public {
        address a = _settledAuction("r3", 10e18, 12e18);
        vm.warp(block.timestamp + 46 days);
        uint256 b0 = wj.balanceOf(BOB);
        vm.prank(BOB);
        EnglishAuction(a).claimTimeoutRefund();
        require(wj.balanceOf(BOB) == b0 + 12e18, "R3: refund");
        require(uint256(EnglishAuction(a).escrow()) == 3, "R3: Refunded");
        require(_trap() == 0, "trap");
    }

    /// R4｜退款分支④ 治理方托管（NFT 压在多签，多签不转）⇒ 超时放行退款（R9-b 封死）
    function testR4_refundWhenGovernanceHoldsPasses() public {
        address a = _settledAuction("r4", 10e18, 12e18);
        vm.prank(MULTISIG);
        jns.claim("r4");                              // 铸给多签，多签一直不转
        vm.warp(block.timestamp + 46 days);
        uint256 b0 = wj.balanceOf(BOB);
        vm.prank(BOB);
        EnglishAuction(a).claimTimeoutRefund();       // 放行退款
        require(wj.balanceOf(BOB) == b0 + 12e18, "R4: refund");
        require(uint256(EnglishAuction(a).escrow()) == 3, "R4: Refunded");
        require(_trap() == 0, "trap");
    }

    /// R5｜退款分支③ 赢家持有（= NFT 已铸给赢家且未转卖，此为「赢家持有」分支）⇒ 拒退（应走 releaseToDAO）
    function testR5_refundWhenWinnerHoldsReverts() public {
        address a = _settledAuction("r5", 10e18, 12e18);
        _claimTo(BOB, "r5");
        vm.warp(block.timestamp + 46 days);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: use releaseToDAO"));
        EnglishAuction(a).claimTimeoutRefund();
    }

    /// R6｜退款分支④ 无关第三方持有 ⇒ 放行退款（续期安全阀，防永久锁死）
    function testR6_refundWhenThirdPartyHoldsPasses() public {
        address a = _settledAuction("r6", 10e18, 12e18);
        _claimTo(CAROL, "r6");
        vm.warp(block.timestamp + 46 days);
        uint256 b0 = wj.balanceOf(BOB);
        vm.prank(BOB);
        EnglishAuction(a).claimTimeoutRefund();
        require(wj.balanceOf(BOB) == b0 + 12e18, "R6: safety-valve refund");
        require(uint256(EnglishAuction(a).escrow()) == 3, "R6: Refunded");
        require(_trap() == 0, "trap");
    }

    /// R7｜行6 残余双花（已知风险，非缺陷）：赢家先持有 NFT 再转卖第三方 ⇒ 超时退款放行（第三方分支）
    function testR7_refundAfterWinnerResoldPasses() public {
        address a = _settledAuction("r7", 10e18, 12e18);
        uint256 tid = _claimTo(BOB, "r7");            // 铸给赢家
        vm.prank(BOB);
        jns.unbind(tid);                              // 解绑
        vm.prank(BOB);
        jns.transferFrom(BOB, CAROL, tid);            // 赢家转卖给第三方
        require(jns.ownerOf(tid) == CAROL, "R7 pre: third party holds");

        vm.warp(block.timestamp + 46 days);
        uint256 b0 = wj.balanceOf(BOB);
        vm.prank(BOB);
        EnglishAuction(a).claimTimeoutRefund();       // 第三方分支 ⇒ 放行退款
        require(wj.balanceOf(BOB) == b0 + 12e18, "R7: refund after resell");
        require(uint256(EnglishAuction(a).escrow()) == 3, "R7: Refunded");
        require(_trap() == 0, "trap");
    }

    /// R8｜NFT 误入本合约（cur == address(this)）⇒ 放行退款 + returnNftToGovernance 可取回（端到端）
    function testR8_refundWhenNftInContractThenReturn() public {
        address a = _settledAuction("r8", 10e18, 12e18);
        uint256 tid = _claimTo(MULTISIG, "r8");        // 铸给多签
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, a, tid);            // 误转入拍卖合约
        require(jns.ownerOf(tid) == a, "R8 pre: NFT in contract");

        vm.warp(block.timestamp + 46 days);
        uint256 b0 = wj.balanceOf(BOB);
        vm.prank(BOB);
        EnglishAuction(a).claimTimeoutRefund();        // 放行退款（不再因 NFT 误入而拒退）
        require(wj.balanceOf(BOB) == b0 + 12e18, "R8: winner refunded");
        require(uint256(EnglishAuction(a).escrow()) == 3, "R8: Refunded");

        EnglishAuction(a).returnNftToGovernance();      // 终态下取回误入 NFT
        require(jns.ownerOf(tid) == MULTISIG, "R8: NFT returned to governance");
        require(_trap() == 0, "trap");
    }

    /// R9｜无新双花：退款成功后 settleDelivery / releaseToDAO 均因 escrow 终态互斥而 revert
    function testR9_noDoubleSpendAfterRefund() public {
        address a = _settledAuction("r9", 10e18, 12e18);
        vm.prank(MULTISIG);
        uint256 tid = jns.claim("r9");                 // 铸给多签（治理方托管）
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.setApprovalForAll(a, true);

        vm.warp(block.timestamp + 46 days);
        vm.prank(BOB);
        EnglishAuction(a).claimTimeoutRefund();        // 先退款 → Refunded
        require(uint256(EnglishAuction(a).escrow()) == 3, "R9 pre: Refunded");

        vm.expectRevert(bytes("EA: not in escrow"));
        EnglishAuction(a).settleDelivery();
        vm.expectRevert(bytes("EA: not in escrow"));
        EnglishAuction(a).releaseToDAO();
        require(_trap() == 0, "trap");
    }
}

contract TestDvP_E is Base {

    /// E1｜Refunded 终态后 NFT 误入 ⇒ 任何人可退回治理方
    function testE1_returnNftAfterRefund() public {
        address a = _settledAuction("e1", 10e18, 12e18);
        vm.warp(block.timestamp + 46 days);
        vm.prank(BOB);
        EnglishAuction(a).claimTimeoutRefund();          // → Refunded
        require(uint256(EnglishAuction(a).escrow()) == 3, "E1 pre: Refunded");

        // 之后才铸造，并被误转入拍卖合约
        vm.prank(MULTISIG);
        uint256 tid = jns.claim("e1");
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, a, tid);
        require(jns.ownerOf(tid) == a, "E1 pre: NFT in contract");

        EnglishAuction(a).returnNftToGovernance();
        require(jns.ownerOf(tid) == MULTISIG, "E1: must return to governance");
        require(_trap() == 0, "trap");
    }

    /// E2｜Released 终态后赢家误转回 ⇒ 退回治理方
    function testE2_returnNftAfterRelease() public {
        address a = _settledAuction("e2", 10e18, 12e18);
        _claimTo(BOB, "e2");
        EnglishAuction(a).releaseToDAO();                // → Released
        uint256 tid = jns._nslookup("e2");

        vm.prank(BOB);
        jns.unbind(tid);
        vm.prank(BOB);
        jns.transferFrom(BOB, a, tid);                   // 误转回合约
        require(jns.ownerOf(tid) == a, "E2 pre: NFT in contract");

        EnglishAuction(a).returnNftToGovernance();
        require(jns.ownerOf(tid) == MULTISIG, "E2: must return to governance");
    }

    /// E3｜守卫：① 非终态拒；② 终态但合约未持有 ⇒ 拒
    function testE3_returnNftGuardsRevert() public {
        // ① Held（非终态）
        address a = _settledAuction("e3a", 10e18, 12e18);
        vm.expectRevert(bytes("EA: not terminal"));
        EnglishAuction(a).returnNftToGovernance();

        // ② 终态但 NFT 不在本合约
        address b = _settledAuction("e3b", 10e18, 12e18);
        _claimTo(BOB, "e3b");
        EnglishAuction(b).releaseToDAO();
        vm.expectRevert(bytes("EA: no NFT held"));
        EnglishAuction(b).returnNftToGovernance();
    }
}

contract TestDvP_Deployer is Base {

    /// D1｜漏调 setFactory ⇒ 工厂创建拍卖 revert（不得静默返回零地址）
    function testD1_missingSetFactoryReverts() public {
        EnglishAuctionDeployer dep = new EnglishAuctionDeployer();
        JNSAuctionFactory fac = new JNSAuctionFactory(DAO, DAO, address(dep));
        // 故意不调 dep.setFactory(address(fac))

        vm.prank(ALICE);
        uint256 rid = fac.submitRequest("d1", 10e18, keccak256(bytes("d1")));
        vm.prank(DAO);
        fac.setReviewer(DAO, true);
        vm.prank(DAO);
        fac.approveRequest(rid);
        vm.prank(ALICE);
        wj.approve(address(fac), 10e18);
        vm.prank(ALICE);
        vm.expectRevert(bytes("DEP: not factory"));
        fac.createAuctionFromRequest(rid, 168);
    }

    /// D2｜setFactory 二次调用 ⇒ revert（一次性语义）
    function testD2_setFactoryTwiceReverts() public {
        EnglishAuctionDeployer dep = new EnglishAuctionDeployer();
        dep.setFactory(address(0xBEEF));
        vm.expectRevert(bytes("DEP: already set"));
        dep.setFactory(address(0xCAFE));
    }

    /// D3｜deploy() onlyFactory：非 factory 调用被拒
    function testD3_deployOnlyFactoryRejectsNonFactory() public {
        EnglishAuctionDeployer dep = new EnglishAuctionDeployer();
        JNSAuctionFactory fac = new JNSAuctionFactory(DAO, DAO, address(dep));
        dep.setFactory(address(fac));

        vm.prank(BOB);
        vm.expectRevert(bytes("DEP: not factory"));
        dep.deploy("d3", 168, 10e18, ALICE, DAO, bytes32(0), address(this));
    }
}
