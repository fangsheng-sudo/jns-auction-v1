// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Base.sol";

// ═══════════════════ A 组：一级主流程 ═══════════════════
contract TestA is Base {
    function testA1_bidImmediatePayAndPullRefund() public {
        address a = _newAuction("a1", 10e18, 168);
        vm.prank(BOB);
        wj.approve(a, 12e18);
        vm.prank(BOB);
        EnglishAuction(a).bid(12e18);

        require(EnglishAuction(a).highestBid() == 12e18, "bid not recorded");
        require(EnglishAuction(a).pendingReturns(ALICE) == 10e18, "no pull refund for outbid");

        uint256 before = wj.balanceOf(ALICE);
        vm.prank(ALICE);
        EnglishAuction(a).withdrawRefund();
        require(wj.balanceOf(ALICE) == before + 10e18, "refund amount wrong");
        require(_trap() == 0, "trap");
    }

    function testA2_last10MinExtends() public {
        address a = _newAuction("a2", 10e18, 168);
        uint256 end = EnglishAuction(a).endTime();
        vm.warp(end - 5 minutes);
        vm.prank(BOB);
        wj.approve(a, 12e18);
        vm.prank(BOB);
        EnglishAuction(a).bid(12e18);
        require(EnglishAuction(a).endTime() == end + 10 minutes, "not extended");
        require(_trap() == 0, "trap");
    }

    function testA3_extensionCappedAt192h() public {
        EnglishAuction a = _directAuction("a3", 10e18, 192);   // 已在上限
        uint256 end = a.endTime();
        vm.warp(end - 5 minutes);
        vm.prank(BOB);
        wj.approve(address(a), 12e18);
        vm.prank(BOB);
        a.bid(12e18);
        require(a.endTime() == end, "must not exceed 192h cap");
        require(_trap() == 0, "trap");
    }

    function testA4_applicantWinsInDefault() public {
        address a = _newAuction("a4", 10e18, 168);
        vm.warp(block.timestamp + 169 hours);
        EnglishAuction(a).settle();
        require(EnglishAuction(a).highestBidder() == ALICE, "not applicant");
        require(uint256(EnglishAuction(a).escrow()) == 1, "not Held");
        require(_trap() == 0, "trap");
    }

    function testA5_bidAfterEndReverts() public {
        address a = _newAuction("a5", 10e18, 168);
        vm.warp(block.timestamp + 169 hours);
        vm.prank(BOB);
        wj.approve(a, 12e18);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: auction ended"));
        EnglishAuction(a).bid(12e18);
        require(_trap() == 0, "trap");
    }
}

// ═══════════════════ B 组：整数与 ceil ═══════════════════
contract TestB is Base {
    function testB1_oneToTwo() public {
        EnglishAuction a = _directAuction("b1", 1e18, 168);
        vm.prank(BOB);
        wj.approve(address(a), 10e18);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: below minimum"));
        a.bid(1e18);
        vm.prank(BOB);
        a.bid(2e18);                       // 1 → 2 pass
        require(a.highestBid() == 2e18, "no");
    }

    function testB2_twentyToTwentyOne() public {
        EnglishAuction a = _directAuction("b2", 20e18, 168);
        vm.prank(BOB);
        wj.approve(address(a), 100e18);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: below minimum"));
        a.bid(20e18);
        vm.prank(BOB);
        a.bid(21e18);                      // 20 → 21 pass
        require(a.highestBid() == 21e18, "no");
    }

    function testB3_twentyOneToTwentyTwoReverts_TwentyThreePasses() public {
        EnglishAuction a = _directAuction("b3", 21e18, 168);
        vm.prank(BOB);
        wj.approve(address(a), 100e18);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: below minimum"));
        a.bid(22e18);                      // 21 → 22 revert（ceil(5%)=2）
        vm.prank(BOB);
        a.bid(23e18);                      // 21 → 23 pass
        require(a.highestBid() == 23e18, "no");
    }

    function testB4_hundredToHundredFourReverts_FivePasses() public {
        EnglishAuction a = _directAuction("b4", 100e18, 168);
        vm.prank(BOB);
        wj.approve(address(a), 1000e18);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: below minimum"));
        a.bid(104e18);                     // 100 → 104 revert（ceil=5）
        vm.prank(BOB);
        a.bid(105e18);                     // 100 → 105 pass
        require(a.highestBid() == 105e18, "no");
    }

    function testB5_nonIntegerBidReverts() public {
        EnglishAuction a = _directAuction("b5", 10e18, 168);
        vm.prank(BOB);
        wj.approve(address(a), 100e18);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: amount must be integer WJ"));
        a.bid(10.5e18);
    }

    function testB6_nonIntegerStartPriceReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("FAC: startingPrice must be integer >=1 WJ"));
        factory.submitRequest("b6", 1.5e18, bytes32(0));

        vm.expectRevert(bytes("EA: startingPrice must be integer >=1 WJ"));
        _directAuction("b6", 1.5e18, 168);
    }
}
