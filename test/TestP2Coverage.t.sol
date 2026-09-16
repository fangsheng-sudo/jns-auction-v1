// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Base.sol";

/// @title P2-5：补齐此前「有实现无测试」的函数用例
/// @dev 不含 ClaimRegistry（其归属待 J-25 结果，见 P1-1，本轮不修不测）
contract TestP2Coverage is Base {

    // ═════════ EnglishAuction 未覆盖函数 ═════════

    function testCov_ea_isEnded() public {
        address a = _newAuction("cov1", 10e18, 168);
        require(!EnglishAuction(a).isEnded(), "should not be ended");
        vm.warp(block.timestamp + 169 hours);
        require(EnglishAuction(a).isEnded(), "should be ended");
    }

    function testCov_ea_minIncrement() public {
        address a = _newAuction("cov2", 10e18, 168);
        // highestBid = 10 WJ ⇒ 5% = 0.5 WJ ⇒ ceil 到 1 WJ
        require(EnglishAuction(a).minIncrement() == 1e18, "ceil to 1 WJ");
        // 21 WJ ⇒ 5% = 1.05 ⇒ ceil 到 2
        address b = _newAuction("cov2b", 21e18, 168);
        require(EnglishAuction(b).minIncrement() == 2e18, "ceil to 2 WJ");
    }

    // ═════════ JNSAuctionFactory 未覆盖函数 ═════════

    function testCov_fac_viewsAndBatch() public {
        address a = _newAuction("cov3", 10e18, 168);
        require(factory.auctionCount() == 1, "count");
        require(factory.allAuctions()[0] == a, "allAuctions");
        require(factory.requestCount() == 1, "requestCount");
        require(factory.reviewersOf(0).length == 1, "reviewersOf");

        (address ap, string memory nm, uint256 sp, , , JNSAuctionFactory.Status st, ) = factory.getRequest(0);
        require(ap == ALICE && sp == 10e18 && uint256(st) == 3, "getRequest fields");
        require(keccak256(bytes(nm)) == keccak256(bytes("cov3")), "name");
    }

    function testCov_fac_createBatch() public {
        // 准备 5 个已审核请求
        uint256[] memory rids = new uint256[](5);
        vm.startPrank(DAO);
        factory.setReviewer(DAO, true);
        vm.stopPrank();
        for (uint256 i = 0; i < 5; i++) {
            string memory n = string(abi.encodePacked("batch", i));
            vm.prank(ALICE);
            rids[i] = factory.submitRequest(n, 1e18, bytes32(0));
            vm.prank(DAO);
            factory.approveRequest(rids[i]);
        }
        vm.prank(ALICE);
        wj.approve(address(factory), type(uint256).max);
        vm.prank(DAO);
        address[] memory created = factory.createBatch(rids, 168);
        require(created.length == 5, "batch size");
        require(factory.auctionCount() == 5, "5 auctions");
        require(factory.batchCount() == 1, "batch counted");
        for (uint256 i = 0; i < 5; i++) {
            require(EnglishAuction(created[i]).highestBid() == 1e18, "starting price pulled");
        }
    }

    function testCov_fac_setAuctionBeneficiary() public {
        vm.prank(DAO);
        factory.setAuctionBeneficiary(MULTISIG);
        require(factory.auctionBeneficiary() == MULTISIG, "set failed");

        // 非法值
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: bad beneficiary"));
        factory.setAuctionBeneficiary(address(0));
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: bad beneficiary"));
        factory.setAuctionBeneficiary(0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD); // WJ 自身
    }

    function testCov_fac_setSignersRequiredAndReject() public {
        vm.prank(DAO);
        factory.setSignersRequired(2);
        require(factory.signersRequired() == 2, "set failed");
        vm.prank(DAO);
        vm.expectRevert(bytes("FAC: must be >=1"));
        factory.setSignersRequired(0);

        // 会签：需 2 人
        vm.startPrank(DAO);
        factory.setReviewer(DAO, true);
        factory.setReviewer(MULTISIG, true);
        vm.stopPrank();
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest("cov4", 10e18, bytes32(0));
        vm.prank(DAO);
        factory.approveRequest(rid);
        (, , , , , JNSAuctionFactory.Status st1, ) = factory.getRequest(rid);
        require(uint256(st1) == 1, "still pending after 1 sig");
        vm.prank(MULTISIG);
        factory.approveRequest(rid);
        (, , , , , JNSAuctionFactory.Status st2, ) = factory.getRequest(rid);
        require(uint256(st2) == 2, "approved after 2 sigs");
    }

    // ═════════ NotificationService 未覆盖函数 ═════════

    function testCov_ns_developerFeeSettersAndUnitFee() public {
        // 【J-53 裁定】v1 休眠：默认为 0
        require(notify.unitFee() == 0, "v1 dormant default");

        vm.prank(DEVEL);
        notify.setPerUseFee(0.02e18);
        require(notify.unitFee() == 0.02e18, "per-use applied");

        // 【J-53 裁定·2026-09-16】单次封顶 1 WJ（常量）
        vm.prank(DEVEL);
        notify.setPerUseFee(1e18);
        require(notify.unitFee() == 1e18, "1 WJ allowed");

        vm.prank(DEVEL);
        vm.expectRevert(bytes("NS: above per-use cap"));
        notify.setPerUseFee(1e18 + 1);
    }

    function testCov_ns_batchesOf() public {
        vm.prank(DEVEL);
        notify.setPerUseFee(0.05e18);   // v1 默认 0 ⇒ 显式设费
        vm.prank(BOB);
        notify.authorizeForPulling();
        vm.prank(BOB);
        wj.approve(address(notify), 100e18);

        address[] memory us = new address[](1); us[0] = BOB;
        uint256[] memory cs = new uint256[](1); cs[0] = 2;
        vm.prank(DEVEL);
        notify.settleBatch(1000, 2000, us, cs, bytes32(0));

        uint256[] memory mine = notify.batchesOf(BOB);
        require(mine.length == 1 && mine[0] == 0, "batchesOf");
        require(notify.batchCount() == 1, "batchCount");
        (address u, uint256 cnt, , uint256 coll, , , , , ) = notify.getBatch(0);
        require(u == BOB && cnt == 2 && coll == 0.1e18, "batch fields");
    }

    // ═════════ SecondaryMarket 未覆盖函数 ═════════

    function testCov_sm_setTradeFeeRecipientAndViews() public {
        vm.prank(DAO);
        market.setTradeFeeRecipient(MULTISIG);
        require(market.tradeFeeRecipient() == MULTISIG, "recipient set");

        vm.prank(DAO);
        vm.expectRevert(bytes("SM: bad recipient"));
        market.setTradeFeeRecipient(address(0));

        uint256 tid = _claimTo(ALICE, "cov5");
        vm.startPrank(ALICE);
        jns.unbind(tid);
        jns.setApprovalForAll(address(market), true);
        uint256 lid = market.list(tid, 100e18, 168);
        vm.stopPrank();
        require(market.listingCount() == 1, "listingCount");
        require(market.minIncrementOf(lid) == 1e18, "minIncrement at 0 bid floors to 1 WJ");
        require(market.nextMinimumBid(lid) == 100e18, "first bid = startPrice");
    }

    // ═════════ SubnameRegistry 未覆盖函数 ═════════

    function testCov_sr_setMintFeeRecipientAndTokenIdOfName() public {
        vm.prank(DAO);
        subnames.setMintFeeRecipient(MULTISIG);
        require(subnames.mintFeeRecipient() == MULTISIG, "recipient set");

        vm.prank(DAO);
        vm.expectRevert(bytes("SR: bad recipient"));
        subnames.setMintFeeRecipient(address(0));

        _claimTo(ALICE, "covmain");
        uint256 mid = jns._nslookup("covmain");
        vm.startPrank(ALICE);
        wj.approve(address(subnames), 10e18);
        uint256 tid = subnames.mintSubname(mid, 0, "1", "covmain");
        vm.stopPrank();

        require(subnames.tokenIdOfName("1.covmain") == tid, "tokenIdOfName");
        require(subnames.tokenIdOfName("9.covmain") == 0, "missing returns 0");
    }

    /// setMintFee 上限保护
    function testCov_sr_mintFeeCap() public {
        vm.prank(DAO);
        vm.expectRevert(bytes("SR: fee above cap"));
        subnames.setMintFee(101e18);
        vm.prank(DAO);
        subnames.setMintFee(0);
        require(subnames.mintFee() == 0, "zero fee allowed");
    }
}
