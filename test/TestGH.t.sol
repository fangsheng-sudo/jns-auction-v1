// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Base.sol";

// ═══════════════════ G 组：提醒服务 ═══════════════════
contract TestG is Base {
    uint256 constant PERIOD_START = 900_000;
    uint256 constant PERIOD_END   = 999_000;

    /// @dev 【J-53 裁定·2026-09-15】v1 默认 perUseFee = 0（提醒服务休眠）⇒
    ///      计费相关用例需在此显式设费，否则金额恒为 0 而被逐笔跳过。
    function setUp() public override {
        super.setUp();
        vm.prank(DEVEL);
        notify.setPerUseFee(0.05e18);
    }

    function _users1(address u) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = u;
    }
    function _counts1(uint256 c) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = c;
    }

    /// 未授权 → 跳过，不扣款
    function testG1_unauthorizedSkipped() public {
        uint256 before = wj.balanceOf(BOB);
        vm.prank(DEVEL);
        notify.settleBatch(PERIOD_START, PERIOD_END, _users1(BOB), _counts1(10), keccak256("h"));

        require(wj.balanceOf(BOB) == before, "must not charge unauthorized");
        require(notify.chargesOf(BOB) == 0, "charges must stay 0");
        require(notify.batchCount() == 0, "no batch should be recorded for skipped user");
        require(_trap() == 0, "trap");
    }

    /// 授权后正常拉取：10 次 × 0.05 = 0.5 WJ
    function testG2_authorizedPulls() public {
        vm.prank(BOB);
        notify.authorizeForPulling();
        vm.prank(BOB);
        wj.approve(address(notify), 100e18);

        uint256 daoBefore = wj.balanceOf(DAO);
        vm.prank(DEVEL);
        notify.settleBatch(PERIOD_START, PERIOD_END, _users1(BOB), _counts1(10), keccak256("h"));

        require(wj.balanceOf(DAO) == daoBefore + 0.5e18, "fee must be 0.5 WJ");
        require(notify.chargesOf(BOB) == 0.5e18, "charges wrong");
        require(notify.batchCount() == 1, "batch not recorded");
        require(_trap() == 0, "trap");
    }

    /// revoke 后跳过
    function testG3_revokedSkipped() public {
        vm.prank(BOB);
        notify.authorizeForPulling();
        vm.prank(BOB);
        notify.revokeAuthorization();

        uint256 before = wj.balanceOf(BOB);
        vm.prank(DEVEL);
        notify.settleBatch(PERIOD_START, PERIOD_END, _users1(BOB), _counts1(10), keccak256("h"));
        require(wj.balanceOf(BOB) == before, "must not charge after revoke");
        require(_trap() == 0, "trap");
    }

    /// 单笔封顶 5 WJ：200 次 × 0.05 = 10 WJ ⇒ 封到 5 WJ
    function testG4_singleBatchCappedAt5WJ() public {
        vm.prank(BOB);
        notify.authorizeForPulling();
        vm.prank(BOB);
        wj.approve(address(notify), 100e18);

        vm.prank(DEVEL);
        notify.settleBatch(PERIOD_START, PERIOD_END, _users1(BOB), _counts1(200), keccak256("h"));

        require(notify.chargesOf(BOB) == 5e18, "must cap at 5 WJ");
        (,,,,,,,, bool capped) = notify.getBatch(0);
        require(capped, "capped flag must be true");
        require(_trap() == 0, "trap");
    }

    /// 累计欠费达 5 WJ → 跳过（此后不再计费）
    function testG5_arrearsCappedSkips() public {
        vm.prank(CAROL);
        notify.authorizeForPulling();
        // 故意不授权 WJ（或余额不足）⇒ 拉取失败 ⇒ 计入欠费
        vm.prank(DEVEL);
        notify.settleBatch(PERIOD_START, PERIOD_END, _users1(CAROL), _counts1(200), keccak256("h1"));
        require(notify.arrearsOf(CAROL) == 5e18, "arrears must be 5 WJ");

        uint256 batchesBefore = notify.batchCount();
        vm.prank(DEVEL);
        notify.settleBatch(PERIOD_END, PERIOD_END + 1000, _users1(CAROL), _counts1(1), keccak256("h2"));
        require(notify.batchCount() == batchesBefore, "must skip when arrears at cap");
        require(_trap() == 0, "trap");
    }

    /// 【P1-3 后】同周期二次结算 → 逐笔【跳过】（不再是整批 revert）
    function testG6_sameperiodSkippedNotRevert() public {
        vm.prank(BOB);
        notify.authorizeForPulling();
        vm.prank(BOB);
        wj.approve(address(notify), 100e18);

        vm.prank(DEVEL);
        notify.settleBatch(PERIOD_START, PERIOD_END, _users1(BOB), _counts1(1), keccak256("h"));
        uint256 b1 = notify.batchCount();
        uint256 charged1 = notify.chargesOf(BOB);

        // 同周期再来：不 revert，而是跳过、不新增 batch、不重复扣费
        vm.prank(DEVEL);
        notify.settleBatch(PERIOD_START, PERIOD_END, _users1(BOB), _counts1(1), keccak256("h"));
        require(notify.batchCount() == b1, "must not add batch");
        require(notify.chargesOf(BOB) == charged1, "must not double charge");
        require(_trap() == 0, "trap");
    }

    /// owner 改 serviceFeeRecipient → revert（仅 developer）
    function testG7_ownerCannotSetRecipient() public {
        vm.prank(DAO);
        vm.expectRevert(bytes("Not developer"));
        notify.setServiceFeeRecipient(CAROL);

        vm.prank(DEVEL);
        notify.setServiceFeeRecipient(CAROL);
        require(notify.serviceFeeRecipient() == CAROL, "developer change failed");
    }

    /// feeCap < 0.01 WJ → revert
    function testG8_feeCapBelowFloorReverts() public {
        vm.prank(DAO);
        vm.expectRevert(bytes("NS: feeCap below floor"));
        notify.setFeeCap(0.005e18);
    }

    /// periodEnd 在未来 → revert
    function testG9_futurePeriodReverts() public {
        vm.prank(DEVEL);
        vm.expectRevert(bytes("NS: future period"));
        notify.settleBatch(block.timestamp, block.timestamp + 1 days, _users1(BOB), _counts1(1), keccak256("h"));
    }

    /// 预存余额可无条件提回
    function testG10_withdrawBalanceUnconditional() public {
        vm.startPrank(BOB);
        wj.approve(address(notify), 10e18);
        notify.deposit(10e18);
        vm.stopPrank();
        require(notify.balanceOf(BOB) == 10e18, "deposit failed");

        uint256 before = wj.balanceOf(BOB);
        vm.prank(BOB);
        notify.withdrawBalance();
        require(wj.balanceOf(BOB) == before + 10e18, "withdraw failed");
        require(_trap() == 0, "trap");
    }
}

// ═══════════════════ H 组：全局（WJ 零陷阱 + 越权 + 对账）═══════════════════
contract TestH is Base {
    /// 覆盖全场景后，MockWJ 陷阱计数必须为 0
    function testH1_noTrapAcrossAllFlows() public {
        // 1) 一级：出价 → settle → releaseToDAO
        address a = _settledAuction("h1a", 10e18, 12e18);
        _claimTo(BOB, "h1a");
        EnglishAuction(a).releaseToDAO();

        // 2) 一级：超时退款
        address b = _settledAuction("h1b", 10e18, 12e18);
        vm.warp(block.timestamp + 46 days);
        vm.prank(BOB);
        EnglishAuction(b).claimTimeoutRefund();

        // 3) 二级：挂拍 → 成交分账
        uint256 tid = _claimTo(ALICE, "h1c");
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

        // 4) 子域名铸造费
        vm.prank(DAO);
        subnames.setMintFee(1e18);
        uint256 mid = _claimTo(ALICE, "h1d");
        vm.startPrank(ALICE);
        wj.approve(address(subnames), 1e18);
        subnames.mintSubname(mid, 0, "1", "h1d");
        vm.stopPrank();

        // 5) 提醒服务批量拉取
        vm.prank(BOB);
        notify.authorizeForPulling();
        vm.prank(BOB);
        wj.approve(address(notify), 10e18);
        address[] memory us = new address[](1);
        us[0] = BOB;
        uint256[] memory cs = new uint256[](1);
        cs[0] = 4;
        vm.prank(DEVEL);
        notify.settleBatch(900_000, 999_000, us, cs, keccak256("hh"));

        // 核心断言：全过程一滴 WJ 都没被陷阱吞掉
        require(_trap() == 0, "WJ trap triggered somewhere!");
    }

    /// 越权调用一律 revert
    function testH2_unauthorizedCallsRevert() public {
        // 非 owner 调 owner-only
        vm.prank(BOB);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        factory.setSignersRequired(2);

        vm.prank(BOB);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        market.setTradeFeeRate(100);

        vm.prank(BOB);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        subnames.setMintFee(1e18);

        vm.prank(BOB);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        notify.setFeeCap(1e18);

        // 非 developer 调 settleBatch
        vm.prank(BOB);
        vm.expectRevert(bytes("Not developer"));
        address[] memory us = new address[](1);
        us[0] = BOB;
        uint256[] memory cs = new uint256[](1);
        cs[0] = 1;
        notify.settleBatch(900_000, 999_000, us, cs, bytes32(0));

        // 非审批人创建拍卖（先由 ALICE 真实提交，否则先撞边界检查）
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("h2", 10e18, bytes32(0));
        vm.prank(BOB);
        vm.expectRevert(bytes("FAC: not allowed"));
        factory.createAuctionFromRequest(rid, 168);

        require(_trap() == 0, "trap");
    }

    /// 防自审硬约束
    function testH3_selfReviewForbidden() public {
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("h3", 10e18, bytes32(0));
        vm.prank(DAO);
        factory.setReviewer(ALICE, true);            // 把自己设为审核人
        vm.prank(ALICE);
        vm.expectRevert(bytes("FAC: reviewer cannot be applicant"));
        factory.approveRequest(rid);
    }

    /// 未审核不得创建拍卖
    function testH4_createWithoutApprovalReverts() public {
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("h4", 10e18, bytes32(0));
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: request not approved"));
        factory.createAuctionFromRequest(rid, 168);
    }
}
