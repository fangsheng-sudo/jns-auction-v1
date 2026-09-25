// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Base.sol";

/**
 * @title TestBranchCoverage —— 分支覆盖率补测（只为 ① 可达未覆盖分支）
 *
 * 依据：`forge coverage`（jns-auction 161 用例）实测，三上链合约未覆盖分支分类如下。
 *
 *  ① 可达但未覆盖（真缺口）—— 本文件逐个补测，每个测试注释写明覆盖的分支（文件:行）。
 *  ② 不可达 / 防御性分支 —— 如实保留未覆盖，清单与理由如下（同步写入复审包 §10/§11）：
 *     - EnglishAuction.sol L129  `_wjSafeTransfer` require(to!=0 && to!=WJ)：WJ 陷阱防护，
 *       所有调用点 to 恒为已校验的 beneficiary / bidder / msg.sender，公入口无法触发。
 *     - EnglishAuction.sol L130  `if (value == 0) return`：所有转账 value 恒 > 0（≥1 WJ 起拍、
 *       withdrawRefund require amount>0），死分支。
 *     - EnglishAuction.sol L144  `if (inc < ONE_WJ)`：highestBid ≥ 1 WJ ⇒ ceil 后 inc 恒 ≥ 1 WJ，
 *       下限分支不可达。
 *     - EnglishAuction.sol L199  `_notifyReleaseName` if(!ended)：两处调用点均已在调用前置终态，
 *       !ended 恒假。
 *     - EnglishAuction.sol L203  `_notifyReleaseName` if(f.code.length==0)：owner 恒为工厂/测试合约
 *       （有代码），EOA-owner 场景不在本架构。
 *     - JNSAuctionFactory.sol L304 `releaseNameReservation` require(name match)：requestOfName[name_]
 *       恒指向 name==name_ 的 request（submitRequest 唯一写入点），恒真，不可达。
 */
contract TestBranchCoverage is Base {

    // ═══════════════════════════════════════════════════════════════
    // EnglishAuction 构造器守卫（L96 / L98 / L100 / L101）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 EnglishAuction.sol L96：require(bytes(name__).length > 0)
    function testEA_constructorEmptyName() public {
        vm.expectRevert(bytes("EA: empty name"));
        new EnglishAuction("", 168, 10e18, ALICE, DAO, bytes32(0), address(this));
    }

    /// 覆盖 EnglishAuction.sol L98：require(applicant_ != address(0))
    function testEA_constructorZeroApplicant() public {
        vm.expectRevert(bytes("EA: zero applicant"));
        new EnglishAuction("ea-ctor-app", 168, 10e18, address(0), DAO, bytes32(0), address(this));
    }

    /// 覆盖 EnglishAuction.sol L100：require(beneficiary_ != address(0))（零地址分支）
    function testEA_constructorZeroBeneficiary() public {
        vm.expectRevert(bytes("EA: bad beneficiary"));
        new EnglishAuction("ea-ctor-ben0", 168, 10e18, ALICE, address(0), bytes32(0), address(this));
    }

    /// 覆盖 EnglishAuction.sol L100：require(beneficiary_ != WJ_ADDRESS)（WJ 陷阱分支）
    function testEA_constructorWjBeneficiary() public {
        vm.expectRevert(bytes("EA: bad beneficiary"));
        new EnglishAuction("ea-ctor-benwj", 168, 10e18, ALICE, WJ_ADDR, bytes32(0), address(this));
    }

    /// 覆盖 EnglishAuction.sol L101：require(durationHours_ > 0)
    function testEA_constructorZeroDuration() public {
        vm.expectRevert(bytes("EA: bad duration"));
        new EnglishAuction("ea-ctor-dur0", 0, 10e18, ALICE, DAO, bytes32(0), address(this));
    }

    /// 覆盖 EnglishAuction.sol L101：require(durationHours_*1h <= MAX_DURATION)（192h 上限分支）
    function testEA_constructorDurationOverMax() public {
        vm.expectRevert(bytes("EA: bad duration"));
        new EnglishAuction("ea-ctor-durmax", 200, 10e18, ALICE, DAO, bytes32(0), address(this));
    }

    // ═══════════════════════════════════════════════════════════════
    // EnglishAuction bid 守卫（L155 / L156）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 EnglishAuction.sol L155：bid 的 require(!cancelled)（cancel 后出价）
    function testEA_bidAfterCancel() public {
        EnglishAuction a = _directAuction("ea-bid-cancel", 10e18, 168);
        a.emergencyCancel("cancel before bid");
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: cancelled"));
        a.bid(12e18);
    }

    /// 覆盖 EnglishAuction.sol L156：bid 的 require(!settled)（settle 后出价）
    function testEA_bidAfterSettle() public {
        EnglishAuction a = _directAuction("ea-bid-settled", 10e18, 168);
        vm.warp(block.timestamp + 169 hours);
        a.settle();
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: settled"));
        a.bid(12e18);
    }

    // ═══════════════════════════════════════════════════════════════
    // EnglishAuction withdrawRefund（L211）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 EnglishAuction.sol L211：require(amount > 0)（无待退台账）
    function testEA_withdrawNothingToRefund() public {
        EnglishAuction a = _directAuction("ea-wd-none", 10e18, 168);
        vm.prank(CAROL);
        vm.expectRevert(bytes("EA: nothing to refund"));
        a.withdrawRefund();
    }

    // ═══════════════════════════════════════════════════════════════
    // EnglishAuction settle 守卫（L220 / L221）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 EnglishAuction.sol L220：settle 的 require(!settled)（重复 settle）
    function testEA_settleTwice() public {
        EnglishAuction a = _directAuction("ea-settle-2x", 10e18, 168);
        vm.warp(block.timestamp + 169 hours);
        a.settle();
        vm.expectRevert(bytes("EA: already settled"));
        a.settle();
    }

    /// 覆盖 EnglishAuction.sol L221：settle 的 require(ts >= endTime)（未到点 settle）
    function testEA_settleBeforeEnd() public {
        EnglishAuction a = _directAuction("ea-settle-early", 10e18, 168);
        vm.expectRevert(bytes("EA: auction not ended"));
        a.settle();
    }

    // ═══════════════════════════════════════════════════════════════
    // EnglishAuction returnNftToGovernance（L310）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 EnglishAuction.sol L310：require(tokenId != 0)（终态但未铸）
    function testEA_returnNftNotMinted() public {
        EnglishAuction a = _directAuction("ea-ret-nomint", 10e18, 168);
        vm.warp(block.timestamp + 169 hours);
        a.settle();
        vm.warp(a.requestedAt() + 46 days);   // 未铸，赢家 ALICE 超时退款 → Refunded
        vm.prank(ALICE);
        a.claimTimeoutRefund();
        vm.expectRevert(bytes("EA: not minted"));
        a.returnNftToGovernance();
    }

    // ═══════════════════════════════════════════════════════════════
    // EnglishAuction rescueStuckNft（L337 / L339 / L341 / L343）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 EnglishAuction.sol L337：require(msg.sender == gov)（非治理方）
    function testEA_rescueNotGov() public {
        EnglishAuction a = _directAuction("ea-rs-nogov", 10e18, 168);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: not gov"));
        a.rescueStuckNft(JNS_ADDR, 1);
    }

    /// 覆盖 EnglishAuction.sol L339：require(ownerOf(tokenId) == address(this))（未持有）
    function testEA_rescueNotHeld() public {
        EnglishAuction a = _directAuction("ea-rs-nohold", 10e18, 168);
        vm.prank(MULTISIG);
        uint256 tid = jns.claimTo("ea-rs-nohold", MULTISIG);   // 铸给治理方，未转入合约
        vm.prank(MULTISIG);
        vm.expectRevert(bytes("EA: no NFT held"));
        a.rescueStuckNft(JNS_ADDR, tid);
    }

    /// 覆盖 EnglishAuction.sol L341(true) + L343(true)：托管保护（Held + 本场在途 NFT 不可提走）
    function testEA_rescueInEscrowGuard() public {
        EnglishAuction a = _directAuction("ea-rs-escrow", 10e18, 168);
        vm.warp(block.timestamp + 169 hours);
        a.settle();                                   // escrow = Held
        vm.prank(MULTISIG);
        uint256 tid = jns.claimTo("ea-rs-escrow", MULTISIG);
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, address(a), tid);  // 本场 NFT 误入合约
        require(jns.ownerOf(tid) == address(a), "pre: auction holds own NFT");
        vm.prank(MULTISIG);
        vm.expectRevert(bytes("EA: in escrow"));
        a.rescueStuckNft(JNS_ADDR, tid);
    }

    /// 覆盖 EnglishAuction.sol L341(false)：跨合约 ERC721（token != JNS）可救回
    function testEA_rescueForeignErc721() public {
        EnglishAuction a = _directAuction("ea-rs-foreign", 10e18, 168);
        address FOREIGN = 0x1111111111111111111111111111111111111111;
        vm.etch(FOREIGN, vm.getDeployedCode("MockJNS.sol:MockJNS"));
        MockJNS f = MockJNS(FOREIGN);
        f.initialize(MULTISIG);
        vm.prank(MULTISIG);
        uint256 fid = f.claimTo("ea-rs-foreign-name", MULTISIG);
        vm.prank(MULTISIG);
        f.unbind(fid);
        vm.prank(MULTISIG);
        f.transferFrom(MULTISIG, address(a), fid);    // 跨合约 NFT 误入
        require(f.ownerOf(fid) == address(a), "pre: foreign NFT misrouted");
        vm.prank(MULTISIG);
        a.rescueStuckNft(FOREIGN, fid);               // token != JNS ⇒ 不受托管保护
        require(f.ownerOf(fid) == MULTISIG, "foreign NFT must return to gov");
    }

    /// 覆盖 EnglishAuction.sol L343(false)：JNS 本场 tokenId 在终态（非 Held）可救回
    function testEA_rescueOwnTokenTerminal() public {
        EnglishAuction a = _directAuction("ea-rs-terminal", 10e18, 168);
        vm.warp(block.timestamp + 169 hours);
        a.settle();                                   // Held
        vm.prank(MULTISIG);
        uint256 tid = jns.claimTo("ea-rs-terminal", MULTISIG);
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, address(a), tid);  // 误入
        vm.warp(a.requestedAt() + 46 days);
        vm.prank(ALICE);
        a.claimTimeoutRefund();                       // Refunded（终态，非 Held）
        vm.prank(MULTISIG);
        a.rescueStuckNft(JNS_ADDR, tid);              // 终态可救回
        require(jns.ownerOf(tid) == MULTISIG, "own NFT must return to gov");
    }

    // ═══════════════════════════════════════════════════════════════
    // EnglishAuction emergencyCancel（L391 / L392）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 EnglishAuction.sol L391：require(!cancelled)（重复 cancel）
    function testEA_cancelTwice() public {
        EnglishAuction a = _directAuction("ea-cancel-2x", 10e18, 168);
        a.emergencyCancel("first");
        vm.expectRevert(bytes("EA: already cancelled"));
        a.emergencyCancel("second");
    }

    /// 覆盖 EnglishAuction.sol L392：require(reason.length <= 200)
    function testEA_cancelReasonTooLong() public {
        EnglishAuction a = _directAuction("ea-cancel-long", 10e18, 168);
        string memory longReason = string(new bytes(201));
        vm.expectRevert(bytes("EA: reason too long"));
        a.emergencyCancel(longReason);
    }

    // ═══════════════════════════════════════════════════════════════
    // EnglishAuction extendTimeoutWindow（L408 / L409 / L410）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 EnglishAuction.sol L408：require(escrow == Held)（未结算时延长）
    function testEA_extendNotInEscrow() public {
        EnglishAuction a = _directAuction("ea-ext-none", 10e18, 168);
        vm.expectRevert(bytes("EA: not in escrow"));
        a.extendTimeoutWindow(1 days, "r");
    }

    /// 覆盖 EnglishAuction.sol L409：require(timeoutExtends < 3)（第 4 次延长）
    function testEA_extendLimit() public {
        EnglishAuction a = _directAuction("ea-ext-limit", 10e18, 168);
        vm.warp(block.timestamp + 169 hours);
        a.settle();
        a.extendTimeoutWindow(1 days, "r1");
        a.extendTimeoutWindow(1 days, "r2");
        a.extendTimeoutWindow(1 days, "r3");          // timeoutExtends = 3
        vm.expectRevert(bytes("EA: extend limit"));
        a.extendTimeoutWindow(1 days, "r4");
    }

    /// 覆盖 EnglishAuction.sol L410：require(extra > 0 && extra <= 45d)（extra=0）
    function testEA_extendOutOfRange() public {
        EnglishAuction a = _directAuction("ea-ext-range", 10e18, 168);
        vm.warp(block.timestamp + 169 hours);
        a.settle();
        vm.expectRevert(bytes("EA: extra out of range"));
        a.extendTimeoutWindow(0, "r");
    }

    // ═══════════════════════════════════════════════════════════════
    // EnglishAuctionDeployer setFactory（L42 / L54）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 EnglishAuctionDeployer.sol L42：require(msg.sender == owner)（非 owner）
    function testDEP_setFactoryNotOwner() public {
        EnglishAuctionDeployer dep = new EnglishAuctionDeployer();   // owner = 本测试合约
        vm.prank(BOB);
        vm.expectRevert(bytes("DEP: not owner"));
        dep.setFactory(address(0xdead));
    }

    /// 覆盖 EnglishAuctionDeployer.sol L54：require(factory_ != address(0))
    function testDEP_setFactoryZero() public {
        EnglishAuctionDeployer dep = new EnglishAuctionDeployer();
        vm.expectRevert(bytes("DEP: zero factory"));
        dep.setFactory(address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    // JNSAuctionFactory 构造器守卫（L98 / L99）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 JNSAuctionFactory.sol L98：require(auctionBeneficiary_ != address(0))
    function testFAC_constructorZeroBeneficiary() public {
        vm.expectRevert(bytes("FAC: bad beneficiary"));
        new JNSAuctionFactory(DAO, address(0), address(0xdead));
    }

    /// 覆盖 JNSAuctionFactory.sol L98：require(auctionBeneficiary_ != WJ_ADDRESS)
    function testFAC_constructorWjBeneficiary() public {
        vm.expectRevert(bytes("FAC: bad beneficiary"));
        new JNSAuctionFactory(DAO, WJ_ADDR, address(0xdead));
    }

    /// 覆盖 JNSAuctionFactory.sol L99：require(deployer_ != address(0))
    function testFAC_constructorZeroDeployer() public {
        vm.expectRevert(bytes("FAC: zero deployer"));
        new JNSAuctionFactory(DAO, DAO, address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    // JNSAuctionFactory submitRequest（L112）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 JNSAuctionFactory.sol L112：require(bytes(name_).length > 0)
    function testFAC_submitEmptyName() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("FAC: empty name"));
        factory.submitRequest("", 10e18, bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════
    // JNSAuctionFactory cancelRequest（L140 / L142 / L143）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 JNSAuctionFactory.sol L140：require(requestId < requests.length)
    function testFAC_cancelNoSuchRequest() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("FAC: no such request"));
        factory.cancelRequest(999);
    }

    /// 覆盖 JNSAuctionFactory.sol L142：require(msg.sender == r.applicant)
    function testFAC_cancelOnlyApplicant() public {
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("fac-cancel-app", 10e18, bytes32(0));
        vm.prank(BOB);
        vm.expectRevert(bytes("FAC: only applicant"));
        factory.cancelRequest(rid);
    }

    /// 覆盖 JNSAuctionFactory.sol L143：require(status in Pending/Approved)（已 Created 不可撤）
    function testFAC_cancelCannotCancel() public {
        _newAuction("fac-cancel-created", 10e18, 168);   // 已开拍 → Created
        uint256 rid = factory.requestCount() - 1;
        vm.prank(ALICE);
        vm.expectRevert(bytes("FAC: cannot cancel"));
        factory.cancelRequest(rid);
    }

    // ═══════════════════════════════════════════════════════════════
    // JNSAuctionFactory approveRequest（L155 / L157 / L160）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 JNSAuctionFactory.sol L155：require(isReviewer[msg.sender])
    function testFAC_approveNotReviewer() public {
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("fac-app-norev", 10e18, bytes32(0));
        vm.prank(CAROL);
        vm.expectRevert(bytes("FAC: not reviewer"));
        factory.approveRequest(rid);
    }

    /// 覆盖 JNSAuctionFactory.sol L157：require(status == Pending)（已 Approved 再 approve）
    function testFAC_approveNotPending() public {
        vm.prank(DAO);
        factory.setReviewer(DAO, true);
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("fac-app-pending", 10e18, bytes32(0));
        vm.prank(DAO);
        factory.approveRequest(rid);            // signersRequired=1 → Approved
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: not pending"));
        factory.approveRequest(rid);
    }

    /// 覆盖 JNSAuctionFactory.sol L160：require(!approvedBy)（同一审核人重复签）
    function testFAC_approveAlreadyApproved() public {
        vm.prank(DAO);
        factory.setSignersRequired(2);
        vm.prank(DAO);
        factory.setReviewer(DAO, true);
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("fac-app-dup", 10e18, bytes32(0));
        vm.prank(DAO);
        factory.approveRequest(rid);            // 仍 Pending（1/2）
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: already approved"));
        factory.approveRequest(rid);
    }

    // ═══════════════════════════════════════════════════════════════
    // JNSAuctionFactory rejectRequest（L174 / L176 / L177 / L178）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 JNSAuctionFactory.sol L174：require(isReviewer[msg.sender])
    function testFAC_rejectNotReviewer() public {
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("fac-rej-norev", 10e18, bytes32(0));
        vm.prank(CAROL);
        vm.expectRevert(bytes("FAC: not reviewer"));
        factory.rejectRequest(rid, "r");
    }

    /// 覆盖 JNSAuctionFactory.sol L176：require(status == Pending)
    function testFAC_rejectNotPending() public {
        vm.prank(DAO);
        factory.setReviewer(DAO, true);
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("fac-rej-pending", 10e18, bytes32(0));
        vm.prank(DAO);
        factory.approveRequest(rid);            // → Approved
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: not pending"));
        factory.rejectRequest(rid, "r");
    }

    /// 覆盖 JNSAuctionFactory.sol L177：require(msg.sender != r.applicant)
    function testFAC_rejectReviewerIsApplicant() public {
        vm.prank(DAO);
        factory.setReviewer(ALICE, true);       // ALICE 既是申请人又是审核人
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("fac-rej-self", 10e18, bytes32(0));
        vm.prank(ALICE);
        vm.expectRevert(bytes("FAC: reviewer cannot be applicant"));
        factory.rejectRequest(rid, "r");
    }

    /// 覆盖 JNSAuctionFactory.sol L178：require(reason.length <= 200)
    function testFAC_rejectReasonTooLong() public {
        vm.prank(DAO);
        factory.setReviewer(DAO, true);
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("fac-rej-long", 10e18, bytes32(0));
        string memory longReason = string(new bytes(201));
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: reason too long"));
        factory.rejectRequest(rid, longReason);
    }

    // ═══════════════════════════════════════════════════════════════
    // JNSAuctionFactory canCreate / createBatch（L188 / L207 / L106）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 JNSAuctionFactory.sol L188：require(requestId < requests.length)（canCreate）
    function testFAC_createNoSuchRequest() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("FAC: no such request"));
        factory.createAuctionFromRequest(999, 168);
    }

    /// 覆盖 JNSAuctionFactory.sol L207：require(requestIds.length == BATCH_SIZE)
    function testFAC_createBatchWrongSize() public {
        uint256[] memory ids = new uint256[](1);
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: batch size must be 5"));
        factory.createBatch(ids, 168);
    }

    /// 覆盖 JNSAuctionFactory.sol L106：onlyApproved（非 owner 且非 reviewer 调 createBatch）
    function testFAC_createBatchNotApproved() public {
        uint256[] memory ids = new uint256[](5);
        vm.prank(CAROL);
        vm.expectRevert(bytes("FAC: not approved"));
        factory.createBatch(ids, 168);
    }

    // ═══════════════════════════════════════════════════════════════
    // JNSAuctionFactory setReviewer（L247）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 JNSAuctionFactory.sol L247：require(reviewer != address(0))
    function testFAC_setReviewerZero() public {
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: zero reviewer"));
        factory.setReviewer(address(0), true);
    }

    // ═══════════════════════════════════════════════════════════════
    // JNSAuctionFactory 转发口（L266 / L283 / L284）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 JNSAuctionFactory.sol L266：emergencyCancelAuction 的 require(isAuction)
    function testFAC_emergencyCancelUnknownAuction() public {
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: unknown auction"));
        factory.emergencyCancelAuction(address(0xdead), "r");
    }

    /// 覆盖 JNSAuctionFactory.sol L283：extendTimeoutWindowAuction 的 require(isAuction)
    function testFAC_extendTimeoutUnknownAuction() public {
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: unknown auction"));
        factory.extendTimeoutWindowAuction(address(0xdead), 1 days, "r");
    }

    /// 覆盖 JNSAuctionFactory.sol L284：require(newOwner != address(0))
    function testFAC_transferOwnershipZero() public {
        address a = _newAuction("fac-tx-owner0", 10e18, 168);
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: zero new owner"));
        factory.transferAuctionOwnership(a, address(0));
    }

    /// 覆盖 JNSAuctionFactory.sol L283：transferAuctionOwnership 的 require(isAuction)（未知拍卖）
    function testFAC_transferOwnershipUnknownAuction() public {
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: unknown auction"));
        factory.transferAuctionOwnership(address(0xdead), DAO);
    }

    // ═══════════════════════════════════════════════════════════════
    // JNSAuctionFactory releaseNameReservation（L300 / L301 / L305）
    // （L304 name mismatch 恒真不可达，归 ② 类，见文件头注释）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 JNSAuctionFactory.sol L300：if (v == 0) return（无占用的幂等返回）
    function testFAC_releaseReservationIdempotent() public {
        factory.releaseNameReservation("fac-rel-none");   // 无占用 → 幂等返回，不 revert
    }

    /// 覆盖 JNSAuctionFactory.sol L301：require(isAuction[msg.sender])（非拍卖实例调用）
    function testFAC_releaseReservationNotAuction() public {
        vm.prank(ALICE);
        factory.submitRequest("fac-rel-reserved", 10e18, bytes32(0));   // 产生占用
        vm.prank(CAROL);
        vm.expectRevert(bytes("FAC: not auction"));
        factory.releaseNameReservation("fac-rel-reserved");
    }

    /// 覆盖 JNSAuctionFactory.sol L305：require(_nslookup(name_) == 0)（占用仍存但已铸造）
    function testFAC_releaseReservationAlreadyMinted() public {
        vm.prank(ALICE);
        factory.submitRequest("fac-rel-minted", 10e18, bytes32(0));     // 占用
        vm.prank(MULTISIG);
        jns.claimTo("fac-rel-minted", MULTISIG);                        // 铸造该名
        address a = _newAuction("fac-rel-other", 10e18, 168);           // 任一拍卖实例
        vm.prank(a);
        vm.expectRevert(bytes("FAC: already minted"));
        factory.releaseNameReservation("fac-rel-minted");
    }

    // ═══════════════════════════════════════════════════════════════
    // JNSAuctionFactory releaseName（L312）
    // ═══════════════════════════════════════════════════════════════

    /// 覆盖 JNSAuctionFactory.sol L312：require(requestId < requests.length)
    function testFAC_releaseNameNoSuchRequest() public {
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: no such request"));
        factory.releaseName(999);
    }
}
