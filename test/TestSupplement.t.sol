// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Base.sol";
import "./mocks/MockWJ.sol";

/// @dev 实现 onTokenTransfer 且返回 true 的接收方
contract HookReceiver is ITransferReceiver {
    uint256 public hits;
    bool public nestedOk;
    EnglishAuction public target;

    function setTarget(address a) external { target = EnglishAuction(a); }

    function onTokenTransfer(address, uint256, bytes calldata) external override returns (bool) {
        hits++;
        // 回调内嵌套调用拍卖合约，验证不会造成状态错乱
        if (address(target) != address(0) && target.pendingReturns(address(this)) > 0) {
            target.withdrawRefund();
            nestedOk = true;
        }
        return true;
    }
}

/// @dev 返回 false 的接收方（应导致整笔 revert）
contract FalseReceiver is ITransferReceiver {
    function onTokenTransfer(address, uint256, bytes calldata) external pure override returns (bool) {
        return false;
    }
}

/// @dev 无 onTokenTransfer 的合约（调用应 revert）
contract NoHookContract { }

/// @title 上线前补测 1~6
contract TestSupplement is Base {
    // ═════════════════ 补测 1｜重名域名申请 ═════════════════
    function testS1_submitRequestForMintedNameReverts() public {
        _claimTo(ALICE, "taken1");                    // 已铸造
        require(jns._nslookup("taken1") != 0, "precondition: minted");

        vm.prank(BOB);
        vm.expectRevert(bytes("FAC: name already minted"));
        factory.submitRequest("taken1", 10e18, bytes32(0));
    }

    function testS1_freshNameStillSubmittable() public {
        _claimTo(ALICE, "taken2");
        vm.prank(BOB);
        uint256 rid = factory.submitRequest("fresh1", 10e18, bytes32(0));
        require(rid == 0, "request not created");
        require(factory.requestCount() == 1, "count wrong");
    }

    /// @dev 【X-3 必修后更新】未铸造的同名【不可】重复提交（原断言「允许」已废）
    function testS1_duplicatePendingNameNowRejected() public {
        vm.prank(ALICE);
        factory.submitRequest("dup1", 10e18, bytes32(0));
        vm.prank(BOB);
        vm.expectRevert(bytes("FAC: name has live request"));
        factory.submitRequest("dup1", 20e18, bytes32(0));
        require(factory.requestCount() == 1, "only one live request allowed");
    }

    // ═════════════════ 补测 2｜WJ ERC-677 回调 ═════════════════
    function testS2_normalTransferPathUnaffected() public {
        uint256 b0 = wj.balanceOf(BOB);
        vm.prank(ALICE);
        wj.transfer(BOB, 100e18);
        require(wj.balanceOf(BOB) == b0 + 100e18, "transfer broken");
        require(wj.callbackCount() == 0, "callback should not fire on plain transfer");

        vm.prank(BOB);
        wj.approve(CAROL, 50e18);
        vm.prank(CAROL);
        wj.transferFrom(BOB, CAROL, 50e18);
        require(wj.callbackCount() == 0, "callback should not fire on transferFrom");
        require(_trap() == 0, "trap");
    }

    function testS2_transferAndCallToEoaIsPlainTransfer() public {
        uint256 b0 = wj.balanceOf(CAROL);
        vm.prank(ALICE);
        wj.transferAndCall(CAROL, 30e18, "");
        require(wj.balanceOf(CAROL) == b0 + 30e18, "eoa transferAndCall broken");
        require(wj.callbackCount() == 0, "no code => no callback");
    }

    function testS2_transferAndCallToAuctionRevertsAtomically() public {
        address a = _newAuction("hook1", 10e18, 168);
        uint256 before = wj.balanceOf(a);
        vm.prank(ALICE);
        vm.expectRevert();   // 拍卖合约未实现 onTokenTransfer
        wj.transferAndCall(a, 5e18, "");
        require(wj.balanceOf(a) == before, "must roll back atomically");
        require(_trap() == 0, "trap");
    }

    function testS2_approveAndCallToAuctionReverts() public {
        address a = _newAuction("hook2", 10e18, 168);
        vm.prank(ALICE);
        vm.expectRevert();
        wj.approveAndCall(a, 5e18, "");
    }

    function testS2_depositToAndCallRejectsNonHookContract() public {
        NoHookContract c = new NoHookContract();
        vm.deal(ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert();
        wj.depositToAndCall{value: 1 ether}(address(c), "");
    }

    function testS2_receiverReturningFalseReverts() public {
        FalseReceiver f = new FalseReceiver();
        vm.prank(ALICE);
        vm.expectRevert(bytes("MockWJ: onTokenTransfer failed"));
        wj.transferAndCall(address(f), 1e18, "");
    }

    function testS2_goodReceiverGetsCallback() public {
        HookReceiver r = new HookReceiver();
        vm.prank(ALICE);
        wj.transferAndCall(address(r), 7e18, "");
        require(r.hits() == 1, "callback not delivered");
        require(wj.balanceOf(address(r)) == 7e18, "funds not delivered");
    }

    /// @dev 回调内嵌套调用拍卖合约 → 状态一致、无资金错乱
    function testS2_nestedCallDuringCallbackIsConsistent() public {
        address a = _newAuction("hook3", 10e18, 168);
        HookReceiver r = new HookReceiver();
        r.setTarget(a);

        // 先给接收方制造 pendingReturns：它出价后被超越
        vm.prank(BOB);
        wj.approve(a, 20e18);
        vm.prank(BOB);
        EnglishAuction(a).bid(20e18);          // BOB 出价 20（>10+1）

        // 让接收方也出价并随后被超越 → pendingReturns 挂账
        uint256 need = EnglishAuction(a).nextMinimumBid();
        wj.mint(address(r), need);
        vm.prank(address(r));
        wj.approve(a, need);
        vm.prank(address(r));
        EnglishAuction(a).bid(need);

        uint256 need2 = EnglishAuction(a).nextMinimumBid();
        vm.prank(CAROL);
        wj.approve(a, need2);
        vm.prank(CAROL);
        EnglishAuction(a).bid(need2);          // 接收方被超越 → pendingReturns[r] = need

        require(EnglishAuction(a).pendingReturns(address(r)) == need, "pending not set");

        // 触发回调 → 回调内 r 调 withdrawRefund()
        wj.mint(ALICE, 1e18);
        vm.prank(ALICE);
        wj.transferAndCall(address(r), 1e18, "");

        require(r.nestedOk(), "nested call did not run");
        require(EnglishAuction(a).pendingReturns(address(r)) == 0, "pending not cleared");
        require(_trap() == 0, "trap");
    }

    /// @dev 全流程只用 transferFrom ⇒ 全程零回调、零陷阱
    function testS2_fullFlowNeverTriggersCallback() public {
        address a = _settledAuction("hook4", 10e18, 12e18);
        _claimTo(BOB, "hook4");
        EnglishAuction(a).releaseToDAO();

        vm.prank(ALICE);
        EnglishAuction(a).withdrawRefund();

        require(wj.callbackCount() == 0, "no *AndCall should be used internally");
        require(_trap() == 0, "trap");
        require(wj.balanceOf(a) == 0, "auction must be drained");
    }

    // ═════════════════ 补测 3｜192h 硬顶 ═════════════════
    function testS3_extensionCapsAt192h() public {
        address a = _newAuction("cap1", 1e18, 168);
        uint256 start = EnglishAuction(a).startTime();
        uint256 cap = start + 192 hours;

        vm.prank(BOB);   wj.approve(a, type(uint256).max);
        vm.prank(CAROL); wj.approve(a, type(uint256).max);

        // 反复在末 10 分钟内出价，每次 +10min；144 次 = 24h ⇒ 恰好触顶
        for (uint256 i = 0; i < 144; i++) {
            uint256 t = EnglishAuction(a).endTime();
            vm.warp(t - 60);
            uint256 amt = EnglishAuction(a).nextMinimumBid();
            address bidder = (i % 2 == 0) ? BOB : CAROL;
            vm.prank(bidder);
            EnglishAuction(a).bid(amt);
        }
        require(EnglishAuction(a).endTime() == cap, "should reach exactly 192h");

        // 再出价：不得越过硬顶
        uint256 t2 = EnglishAuction(a).endTime();
        vm.warp(t2 - 60);
        uint256 amt2 = EnglishAuction(a).nextMinimumBid();
        vm.prank(BOB);
        EnglishAuction(a).bid(amt2);
        require(EnglishAuction(a).endTime() == cap, "must not extend past 192h");
        require(EnglishAuction(a).endTime() > start + 168 hours, "extension must have happened");

        // 到点可正常 settle
        vm.warp(cap);
        EnglishAuction(a).settle();
        require(uint256(EnglishAuction(a).escrow()) == 1, "not Held");
        require(_trap() == 0, "trap");
    }

    // ═════════════════ 补测 4｜emergencyCancel 无出价 ═════════════════
    function testS4_emergencyCancelWithoutBidsRefundsApplicant() public {
        address a = _newAuction("cancel1", 10e18, 168);
        require(wj.balanceOf(a) == 10e18, "precondition: starting price pulled");

        uint256 bal0 = wj.balanceOf(ALICE);
        vm.prank(DAO);   // emergencyCancelAuction 经工厂转发，仅 owner(DAO) 可调
        factory.emergencyCancelAuction(a, "test cancel");
        require(EnglishAuction(a).cancelled(), "not cancelled");
        require(EnglishAuction(a).highestBid() == 0, "highestBid not zeroed");
        require(EnglishAuction(a).pendingReturns(ALICE) == 10e18, "applicant refund not queued");

        vm.prank(ALICE);
        EnglishAuction(a).withdrawRefund();
        require(wj.balanceOf(ALICE) == bal0 + 10e18, "applicant not refunded");
        require(wj.balanceOf(a) == 0, "auction not drained");
        require(_trap() == 0, "trap");
    }

    function testS4_cannotSettleAfterCancel() public {
        address a = _newAuction("cancel2", 10e18, 168);
        vm.prank(DAO);
        factory.emergencyCancelAuction(a, "x");
        vm.warp(block.timestamp + 169 hours);
        vm.expectRevert(bytes("EA: cancelled"));
        EnglishAuction(a).settle();
    }

    // ═════════════════ 补测 5｜申请人兜底中标 + pull 退款 ═════════════════
    function testS5_applicantWinsWhenNoBidderAndEntersHeld() public {
        address a = _newAuction("solo1", 10e18, 168);
        vm.warp(block.timestamp + 169 hours);
        EnglishAuction(a).settle();

        require(EnglishAuction(a).highestBidder() == ALICE, "applicant should win");
        require(uint256(EnglishAuction(a).escrow()) == 1, "not Held");
        require(EnglishAuction(a).highestBid() == 10e18, "amount wrong");
        require(wj.balanceOf(a) == 10e18, "funds must stay in escrow");
        require(_trap() == 0, "trap");
    }

    function testS5_applicantRefundedAfterBeingOutbid_andReleaseOnlyTakesHighestBid() public {
        address a = _newAuction("solo2", 10e18, 168);
        vm.prank(BOB);
        wj.approve(a, 12e18);
        vm.prank(BOB);
        EnglishAuction(a).bid(12e18);                  // ALICE 被超越

        require(EnglishAuction(a).pendingReturns(ALICE) == 10e18, "applicant pending not set");

        vm.warp(block.timestamp + 169 hours);
        EnglishAuction(a).settle();
        _claimTo(BOB, "solo2");

        uint256 dao0 = wj.balanceOf(DAO);
        EnglishAuction(a).releaseToDAO();

        // 只转 highestBid(=12)，不动 pendingReturns(=10)
        require(wj.balanceOf(DAO) == dao0 + 12e18, "release must transfer exactly highestBid");
        require(EnglishAuction(a).pendingReturns(ALICE) == 10e18, "pendingReturns must be untouched");
        require(wj.balanceOf(a) == 10e18, "10 must remain for applicant refund");

        // 申请人 pull 领回
        vm.prank(ALICE);
        EnglishAuction(a).withdrawRefund();
        require(wj.balanceOf(a) == 0, "everything must be drained");
        require(_trap() == 0, "trap");
    }

    // ═════════════════ 补测 6｜中途态备案（多签铸而不转）═════════════════
    function testS6_mintedToMultisigNotYetTransferred() public {
        address a = _newAuction("mid1", 10e18, 168);
        vm.prank(BOB);
        wj.approve(a, 12e18);
        vm.prank(BOB);
        EnglishAuction(a).bid(12e18);
        vm.warp(block.timestamp + 169 hours);
        EnglishAuction(a).settle();

        // 多签 claim 铸造（真实链路 claim 为 _safeMint(msg.sender)）
        vm.prank(MULTISIG);
        jns.claim("mid1");                             // 铸给 MULTISIG
        uint256 tid = jns._nslookup("mid1");
        require(tid != 0, "not minted");
        require(jns.ownerOf(tid) == MULTISIG, "should be multisig-owned");

        // ① claimTimeoutRefund 被拒（_nslookup != 0，此时仍在 Held）
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: already minted, use releaseToDAO"));
        EnglishAuction(a).claimTimeoutRefund();

        // ② releaseToDAO 通过（ownerOf == JNS.owner()）
        uint256 dao0 = wj.balanceOf(DAO);
        EnglishAuction(a).releaseToDAO();
        require(wj.balanceOf(DAO) == dao0 + 12e18, "release should pass and pay");
        require(uint256(EnglishAuction(a).escrow()) == 2, "not Released");
    }

    /// @dev 反向：settle 后【未铸造】时 releaseToDAO 必须 revert、超时退款须满足窗口
    function testS6_releaseBeforeMintReverts() public {
        address a = _settledAuction("mid2", 10e18, 12e18);
        vm.expectRevert(bytes("EA: name not minted yet"));
        EnglishAuction(a).releaseToDAO();

        // 窗口未到 → 退款 revert
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: timeout window not reached"));
        EnglishAuction(a).claimTimeoutRefund();

        // 45 天后 → 退款成立
        vm.warp(block.timestamp + 46 days);
        vm.prank(BOB);
        EnglishAuction(a).claimTimeoutRefund();
        require(uint256(EnglishAuction(a).escrow()) == 3, "not Refunded");
        require(_trap() == 0, "trap");
    }

    // ═════════════════ X-3 必修：新增用例 ⑪⑫⑬ ═════════════════

    /// ⑪ 已铸造的 name 再次 submitRequest → revert
    function testX3_11_submitMintedNameReverts() public {
        _claimTo(ALICE, "x3a");
        vm.prank(BOB);
        vm.expectRevert(bytes("FAC: name already minted"));
        factory.submitRequest("x3a", 10e18, bytes32(0));
    }

    /// ⑫ 未铸造但有存活申请，再提交 → revert
    function testX3_12_submitNameWithLiveRequestReverts() public {
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("x3b", 10e18, bytes32(0));
        require(factory.requestOfName("x3b") == rid + 1, "name not reserved");

        vm.prank(BOB);
        vm.expectRevert(bytes("FAC: name has live request"));
        factory.submitRequest("x3b", 20e18, bytes32(0));
    }

    /// ⑫附 rejectRequest / cancelRequest 释放占用后，可重新提交
    function testX3_12b_rejectReleasesNameReservation() public {
        vm.prank(DAO);
        factory.setReviewer(DAO, true);
        vm.prank(ALICE);
        factory.submitRequest("x3c", 10e18, bytes32(0));
        vm.prank(DAO);
        factory.rejectRequest(0, "nope");
        require(factory.requestOfName("x3c") == 0, "not released after reject");

        vm.prank(BOB);
        factory.submitRequest("x3c", 20e18, bytes32(0));
        require(factory.requestCount() == 2, "resubmit failed");
    }

    function testX3_12c_cancelReleasesNameReservation() public {
        vm.prank(ALICE);
        factory.submitRequest("x3d", 10e18, bytes32(0));
        vm.prank(ALICE);
        factory.cancelRequest(0);
        require(factory.requestOfName("x3d") == 0, "not released after cancel");

        vm.prank(BOB);
        factory.submitRequest("x3d", 20e18, bytes32(0));
        require(factory.requestCount() == 2, "resubmit failed");
    }

    /// ⑬ 同一 name 两场拍卖（历史/边界数据）：铸给 A 后，B 在 45 天后可退款（安全阀生效）
    function testX3_13_safetyValveAllowsLoserRefundAfterMintedToOther() public {
        string memory n = "x3dual";

        // 两场同 name 拍卖（绕开工厂，模拟历史遗留/工厂外实例）
        EnglishAuction a1 = _directAuction(n, 10e18, 168);
        EnglishAuction a2 = new EnglishAuction(n, 168, 10e18, ALICE, DAO, bytes32(0), address(this));
        vm.prank(ALICE);
        wj.transfer(address(a2), 10e18);

        // a1 赢家 = CAROL，a2 赢家 = BOB
        vm.prank(CAROL);
        wj.approve(address(a1), 12e18);
        vm.prank(CAROL);
        a1.bid(12e18);

        vm.prank(BOB);
        wj.approve(address(a2), 12e18);
        vm.prank(BOB);
        a2.bid(12e18);

        vm.warp(block.timestamp + 169 hours);
        a1.settle();
        a2.settle();

        // 域名铸给 CAROL（= a1 赢家）
        _claimTo(CAROL, n);
        uint256 tid = jns._nslookup(n);
        require(tid != 0 && jns.ownerOf(tid) == CAROL, "precondition: minted to CAROL");

        // a1：releaseToDAO 通过（ownerOf == winner）
        uint256 dao0 = wj.balanceOf(DAO);
        a1.releaseToDAO();
        require(wj.balanceOf(DAO) == dao0 + 12e18, "a1 release failed");

        // a2：releaseToDAO 必 revert（铸给了无关第三方 CAROL，BOB != CAROL、CAROL != JNS.owner）
        vm.expectRevert(bytes("EA: minted to unexpected address"));
        a2.releaseToDAO();

        // a2：45 天后安全阀放行退款（旧逻辑此处会永久锁死）
        vm.warp(block.timestamp + 46 days);
        uint256 bob0 = wj.balanceOf(BOB);
        vm.prank(BOB);
        a2.claimTimeoutRefund();
        require(wj.balanceOf(BOB) == bob0 + 12e18, "safety valve refund failed");
        require(uint256(a2.escrow()) == 3, "a2 not Refunded");
        require(_trap() == 0, "trap");
    }

    /// ⑬附 安全阀不得放行「本可正常放款」的情形（铸给赢家/多签时仍 revert）
    function testX3_13b_safetyValveDoesNotBypassNormalPaths() public {
        address a = _settledAuction("x3safe", 10e18, 12e18);
        _claimTo(BOB, "x3safe");                 // 铸给赢家本人
        vm.warp(block.timestamp + 46 days);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: already minted, use releaseToDAO"));
        EnglishAuction(a).claimTimeoutRefund();
    }
}
