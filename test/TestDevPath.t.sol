// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Base.sol";

/**
 * @dev 【J-53 裁定·2026-09-15】developer 变更权改造后的用例
 *
 *  语义：**沉默 = 否决**（不是「沉默 = 同意」）
 *   · owner/多签【无法发起】更换（proposeDeveloper 恒 revert）
 *   · 唯一入口 = 当前 developer 自调 transferDeveloperRole
 *   · Timelock = 【未确认即不生效】（窗口内无被提名人主动确认 ⇒ 作废）
 *
 *  Base 装置：notify 的 developer = DEVEL（address(0xDE7E1)）
 */
contract TestDevPath is Base {

    /// @dev 【J-53 裁定】提醒服务 developer = J-53 本人地址（core-contributors.md L90，EOA）
    address constant DEVELOPER_J53 = 0x8b4846d72d1530df755D9B5146A3e627a0A7147F;

    // ═══════════ ① 自转让成功（延迟后生效）═══════════
    function test_devTransfer_happyPath() public {
        require(notify.developer() == DEVEL, "precondition");

        // 当前 developer 发起自转让
        vm.prank(DEVEL);
        notify.transferDeveloperRole(BOB);
        require(notify.pendingDeveloper() == BOB, "pending not set");
        uint256 eff = notify.developerEffectiveAt();

        // 未满 7 天：被提名人确认 → revert
        vm.prank(BOB);
        vm.expectRevert(bytes("DEV: timelock"));
        notify.acceptDeveloperRole();

        // 满 7 天后：被提名人确认 → 生效
        vm.warp(eff);
        vm.prank(BOB);
        notify.acceptDeveloperRole();
        require(notify.developer() == BOB, "dev not transferred");
        require(notify.pendingDeveloper() == address(0), "pending not cleared");
    }

    // ═══════════ ② 非 developer（含 owner/多签）不能发起转让 ═══════════
    function test_devTransfer_onlyCurrentDeveloperCanTransfer() public {
        // owner / 多签
        vm.prank(DAO);
        vm.expectRevert(bytes("Not developer"));
        notify.transferDeveloperRole(DAO);

        vm.prank(MULTISIG);
        vm.expectRevert(bytes("Not developer"));
        notify.transferDeveloperRole(MULTISIG);

        // 普通用户
        vm.prank(ALICE);
        vm.expectRevert(bytes("Not developer"));
        notify.transferDeveloperRole(ALICE);

        require(notify.pendingDeveloper() == address(0), "no pending should exist");
    }

    // ═══════════ ③ 延迟期内 cancelTransfer 生效 ═══════════
    function test_devTransfer_cancelWithinWindow() public {
        vm.prank(DEVEL);
        notify.transferDeveloperRole(BOB);
        uint256 eff = notify.developerEffectiveAt();

        // 原 developer 撤回（仍在其掌控窗口内）
        vm.prank(DEVEL);
        notify.cancelDeveloperTransfer();
        require(notify.pendingDeveloper() == address(0), "pending should be cleared");
        require(notify.developerEffectiveAt() == 0, "eff should be cleared");

        // 到期后被提名人再确认 → 已无 pending ⇒ 拒绝
        vm.warp(eff + 1);
        vm.prank(BOB);
        vm.expectRevert(bytes("DEV: not nominee"));
        notify.acceptDeveloperRole();

        require(notify.developer() == DEVEL, "developer must remain DEVEL");
    }

    // ═══════════ ④ 转让后：新地址有权、旧地址失去 ═══════════
    function test_devTransfer_newGainsOldLoses() public {
        vm.prank(DEVEL);
        notify.transferDeveloperRole(BOB);
        vm.warp(notify.developerEffectiveAt());
        vm.prank(BOB);
        notify.acceptDeveloperRole();

        // 新 developer：可设费率 / 收款方
        vm.prank(BOB);
        notify.setPerUseFee(5e16);
        require(notify.perUseFee() == 5e16, "new dev cannot set fee");

        vm.prank(BOB);
        notify.setServiceFeeRecipient(CAROL);
        require(notify.serviceFeeRecipient() == CAROL, "new dev cannot set recipient");

        // 旧 developer：失去设置权
        vm.prank(DEVEL);
        vm.expectRevert(bytes("Not developer"));
        notify.setPerUseFee(1e18);

        vm.prank(DEVEL);
        vm.expectRevert(bytes("Not developer"));
        notify.setServiceFeeRecipient(MULTISIG);
    }

    // ═══════════ ⑤ owner/多签 调 proposeDeveloper → revert（沉默=否决）═══════════
    function test_ownerCannotProposeDeveloper() public {
        vm.prank(DAO);
        vm.expectRevert(bytes("DEV: owner cannot change developer"));
        notify.proposeDeveloper(ALICE);

        // 多签地址同样被拒
        vm.prank(MULTISIG);
        vm.expectRevert(bytes("DEV: owner cannot change developer"));
        notify.proposeDeveloper(MULTISIG);

        require(notify.developer() == DEVEL, "developer must be unchanged");
        require(notify.pendingDeveloper() == address(0), "no pending");
    }

    // ═══════════ ⑥ 到期未确认 ⇒ 【不生效】（证明非「到期自动生效」）═══════════
    function test_devTransfer_expiryMeansNoEffect() public {
        vm.prank(DEVEL);
        notify.transferDeveloperRole(BOB);
        uint256 expiry = notify.developerExpiryAt();
        require(expiry > 0, "expiry must be set");

        // 越过确认窗口
        vm.warp(expiry + 1);
        require(!notify.pendingTransferActive(), "must be inactive after expiry");

        vm.prank(BOB);
        vm.expectRevert(bytes("DEV: transfer expired"));
        notify.acceptDeveloperRole();

        // 关键断言：developer 仍为原值 —— 沉默/拖延都不会导致变更生效
        require(notify.developer() == DEVEL, "SILENCE MUST NOT CHANGE DEVELOPER");
    }

    // ═══════════ ⑦ 旧入口已停用（防误走老路径）═══════════
    function test_legacyDeveloperEntrypointsDisabled() public {
        vm.prank(DEVEL);
        vm.expectRevert(bytes("DEV: use cancelDeveloperTransfer"));
        notify.vetoDeveloper();

        vm.prank(DEVEL);
        vm.expectRevert(bytes("DEV: use acceptDeveloperRole"));
        notify.acceptDeveloper();

        // owner 走旧入口同样被拒
        vm.prank(DAO);
        vm.expectRevert(bytes("DEV: owner cannot change developer"));
        notify.proposeDeveloper(BOB);
    }

    // ═══════════ ⑧ 自转让目标校验 ═══════════
    function test_devTransfer_rejectsBadCandidate() public {
        vm.prank(DEVEL);
        vm.expectRevert(bytes("DEV: zero candidate"));
        notify.transferDeveloperRole(address(0));

        vm.prank(DEVEL);
        vm.expectRevert(bytes("DEV: already developer"));
        notify.transferDeveloperRole(DEVEL);

        // 无 pending 时取消 → revert
        vm.prank(DEVEL);
        vm.expectRevert(bytes("DEV: nothing pending"));
        notify.cancelDeveloperTransfer();
    }

    // ═══════════ ⑨ serviceFeeRecipient 现状确认：仅 developer（J-53 沉默即不可改）═══════════
    function test_serviceFeeRecipientOnlyDeveloper() public {
        vm.prank(DAO);
        vm.expectRevert(bytes("Not developer"));
        notify.setServiceFeeRecipient(CAROL);

        vm.prank(MULTISIG);
        vm.expectRevert(bytes("Not developer"));
        notify.setServiceFeeRecipient(CAROL);

        vm.prank(ALICE);
        vm.expectRevert(bytes("Not developer"));
        notify.setServiceFeeRecipient(CAROL);

        // 仅 developer 可改
        vm.prank(DEVEL);
        notify.setServiceFeeRecipient(CAROL);
        require(notify.serviceFeeRecipient() == CAROL, "developer change failed");
    }

    // ═══════════ ⑩ v1 休眠：perUseFee = 0、monthlyEnabled = false ═══════════
    function test_v1DormantDefaults() public {
        NotificationService n = new NotificationService(DAO, DEVELOPER_J53, DAO);
        require(n.developer() == DEVELOPER_J53, "developer must be J-53");
        require(n.perUseFee() == 0, "v1 perUseFee must be 0");
        require(!n.monthlyEnabled(), "v1 monthly must be disabled");
        require(n.unitFee() == 0, "unitFee must be 0 while dormant");

        // 休眠下结算：金额为 0 ⇒ 逐笔跳过，不扣款
        address[] memory us = new address[](1);
        us[0] = ALICE;
        uint256[] memory cs = new uint256[](1);
        cs[0] = 1;
        vm.prank(DEVELOPER_J53);
        n.settleBatch(1000, 2000, us, cs, bytes32(0));
        require(n.chargesOf(ALICE) == 0, "must not charge while dormant");
        require(n.batchCount() == 0, "no batch recorded for zero amount");
    }

    // ═══════════ ⑪ J-53 私钥丢失 ⇒ 角色锁死（可预期代价）═══════════
    function test_devRoleLockedIfKeyLost() public {
        // 模拟「J-53 沉默」：无人发起转让 ⇒ 角色永不变化
        vm.warp(block.timestamp + 3650 days);
        require(notify.developer() == DEVEL, "role must be unchanged without action");

        // 即便 owner/多签想换，也无路径
        vm.prank(DAO);
        vm.expectRevert(bytes("DEV: owner cannot change developer"));
        notify.proposeDeveloper(ALICE);

        // 但 v1 提醒服务休眠（perUseFee=0）⇒ 影响为 0；其余模块与 developer 无关
        require(notify.perUseFee() == 0, "dormant");
    }

    // ═══════════ ⑫ 零 developer 时其他模块不受影响（回归保留）═══════════
    function test_otherModulesUnaffectedByDeveloper() public {
        NotificationService n = new NotificationService(DAO, address(0), DAO);
        require(address(n) != address(0), "deploy failed");

        // 一级拍卖全套照常
        address a = _settledAuction("devzero", 10e18, 12e18);
        _claimTo(BOB, "devzero");
        EnglishAuction(a).releaseToDAO();
        require(wj.balanceOf(DAO) > 0, "auction unaffected");

        // 二级市场照常
        uint256 tid = _claimTo(ALICE, "dz2");
        vm.startPrank(ALICE);
        jns.unbind(tid);
        jns.setApprovalForAll(address(market), true);
        uint256 lid = market.list(tid, 100e18, 168);
        vm.stopPrank();
        vm.startPrank(CAROL);
        wj.approve(address(market), 100e18);
        market.bid(lid, 100e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 169 hours);
        market.settle(lid);

        require(_trap() == 0, "trap");
    }
}
