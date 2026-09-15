// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Base.sol";

// ═══════════════════ C 组：异常与救济 ═══════════════════
contract TestC is Base {
    /// 不是 owner 不能紧急叫停
    function testC1_emergencyCancelOnlyOwner() public {
        address a = _newAuction("c1", 10e18, 168);
        vm.prank(BOB);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        EnglishAuction(a).emergencyCancel("nope");
        require(_trap() == 0, "trap");
    }

    /// 紧急取消：出价挂 pull 退款，且取消后可领回
    function testC2_emergencyCancel_and_refund() public {
        address a = _newAuction("c2", 10e18, 168);
        vm.prank(BOB);
        wj.approve(a, 12e18);
        vm.prank(BOB);
        EnglishAuction(a).bid(12e18);

        // 工厂是拍卖实例的 owner ⇒ 经工厂转发叫停
        vm.prank(DAO);
        factory.emergencyCancelAuction(a, "governance halt");

        require(EnglishAuction(a).cancelled(), "not cancelled");
        // 最高价 12 WJ 挂到 BOB 的 pull 台账；ALICE 的 10 WJ 属「曾出资」亦须可领
        uint256 bBefore = wj.balanceOf(BOB);
        vm.prank(BOB);
        EnglishAuction(a).withdrawRefund();
        require(wj.balanceOf(BOB) == bBefore + 12e18, "bob refund wrong");
        require(_trap() == 0, "trap");
    }

    /// settled 后不可取消
    function testC3_cancelAfterSettledReverts() public {
        address a = _settledAuction("c3", 10e18, 12e18);
        vm.prank(DAO);
        vm.expectRevert(bytes("EA: settled"));
        factory.emergencyCancelAuction(a, "too late");
    }

    /// 45 天超时退款：未铸造 + 仅赢家可调
    function testC4_timeoutRefundAfter45Days() public {
        address a = _settledAuction("c4", 10e18, 12e18);   // BOB 中标 12 WJ
        // 未满 45 天 → revert
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: timeout window not reached"));
        EnglishAuction(a).claimTimeoutRefund();

        vm.warp(block.timestamp + 46 days);
        uint256 before = wj.balanceOf(BOB);
        vm.prank(BOB);
        EnglishAuction(a).claimTimeoutRefund();
        require(wj.balanceOf(BOB) == before + 12e18, "refund wrong");
        require(uint256(EnglishAuction(a).escrow()) == 3, "not Refunded");
        require(_trap() == 0, "trap");
    }

    /// 非赢家调退款 → revert
    function testC5_nonWinnerClaimReverts() public {
        address a = _settledAuction("c5", 10e18, 12e18);
        vm.warp(block.timestamp + 46 days);
        vm.prank(CAROL);
        vm.expectRevert(bytes("EA: only winner"));
        EnglishAuction(a).claimTimeoutRefund();
    }

    /// 已铸造后再走超时退款 → revert（两出口互斥）
    function testC6_refundAfterMintedReverts() public {
        address a = _settledAuction("c6", 10e18, 12e18);
        _claimTo(BOB, "c6");                      // 已铸造
        vm.warp(block.timestamp + 46 days);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: already minted, use releaseToDAO"));
        EnglishAuction(a).claimTimeoutRefund();
    }
}

// ═══════════════════ D 组：铸造放款 ═══════════════════
contract TestD is Base {
    /// 未铸造 → releaseToDAO revert
    function testD1_releaseBeforeMintReverts() public {
        address a = _settledAuction("d1", 10e18, 12e18);
        vm.expectRevert(bytes("EA: name not minted yet"));
        EnglishAuction(a).releaseToDAO();
        require(_trap() == 0, "trap");
    }

    /// 铸给 winner → 放款成功，且【只转 highestBid】，不动 pendingReturns
    function testD2_releaseToWinner_onlyTransfersHighestBid() public {
        address a = _settledAuction("d2", 10e18, 12e18);   // BOB 12 WJ；ALICE 挂账 10 WJ
        _claimTo(BOB, "d2");

        uint256 daoBefore = wj.balanceOf(DAO);
        uint256 alicePending = EnglishAuction(a).pendingReturns(ALICE);
        require(alicePending == 10e18, "precondition: alice pending");

        EnglishAuction(a).releaseToDAO();                  // 任何人可触发

        require(wj.balanceOf(DAO) == daoBefore + 12e18, "DAO must get exactly 12 WJ");
        require(
            EnglishAuction(a).pendingReturns(ALICE) == alicePending,
            "pendingReturns must NOT be touched"
        );
        // 合约仍留 ALICE 的 10 WJ 退款待领
        require(wj.balanceOf(a) == 10e18, "escrow residue wrong");
        require(uint256(EnglishAuction(a).escrow()) == 2, "not Released");
        require(_trap() == 0, "trap");
    }

    /// 铸给多签（claim 后未转出的中间态）→ 通过
    function testD3_releaseWhenMintedToMultisigPasses() public {
        address a = _settledAuction("d3", 10e18, 12e18);
        vm.prank(MULTISIG);
        jns.claim("d3");                    // 先铸给多签，中间态

        uint256 daoBefore = wj.balanceOf(DAO);
        EnglishAuction(a).releaseToDAO();
        require(wj.balanceOf(DAO) == daoBefore + 12e18, "DAO payout wrong");
        require(_trap() == 0, "trap");
    }

    /// 铸给第三方 → revert（等治理纠正）
    function testD4_releaseWhenMintedToThirdPartyReverts() public {
        address a = _settledAuction("d4", 10e18, 12e18);
        _claimTo(CAROL, "d4");              // 铸错人
        vm.expectRevert(bytes("EA: minted to unexpected address"));
        EnglishAuction(a).releaseToDAO();
    }

    /// 重复调用 → revert
    function testD5_doubleReleaseReverts() public {
        address a = _settledAuction("d5", 10e18, 12e18);
        _claimTo(BOB, "d5");
        EnglishAuction(a).releaseToDAO();
        vm.expectRevert(bytes("EA: not in escrow"));
        EnglishAuction(a).releaseToDAO();
    }

    /// 两出口互斥：先 release 再 claimTimeout → revert
    function testD6_exitsAreMutuallyExclusive() public {
        address a = _settledAuction("d6", 10e18, 12e18);
        _claimTo(BOB, "d6");
        EnglishAuction(a).releaseToDAO();
        vm.warp(block.timestamp + 46 days);
        vm.prank(BOB);
        vm.expectRevert(bytes("EA: not in escrow"));
        EnglishAuction(a).claimTimeoutRefund();
    }

    /// 全流程对账：合约余额 = 待领退款 + 待放款，无尘差
    function testD7_fullFlowReconciliation() public {
        address a = _settledAuction("d7", 10e18, 12e18);   // BOB 12；ALICE 挂账 10
        _claimTo(BOB, "d7");

        // 放款前：合约持 22 = 12(待放款) + 10(待领退款)
        require(wj.balanceOf(a) == 22e18, "pre-release balance");

        EnglishAuction(a).releaseToDAO();                  // 放 12
        require(wj.balanceOf(a) == 10e18, "post-release balance");

        vm.prank(ALICE);
        EnglishAuction(a).withdrawRefund();                // 领 10
        require(wj.balanceOf(a) == 0, "residue must be zero");

        require(_trap() == 0, "trap");
    }
}
