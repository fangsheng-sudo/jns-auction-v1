// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Base.sol";

// ═══════════════════ E 组：二级市场 ═══════════════════
contract TestE is Base {
    /// 卖家：自行 unbind + 授权，再 list ⇒ 挂拍即托管
    function _listBy(address seller, string memory n, uint256 startPrice, uint256 hrs)
        internal returns (uint256 tokenId, uint256 listingId)
    {
        tokenId = _claimTo(seller, n);                 // 铸给卖家（默认已 bind）
        vm.startPrank(seller);
        jns.unbind(tokenId);                           // CSBT：须先 unbind
        jns.setApprovalForAll(address(market), true);
        listingId = market.list(tokenId, startPrice, hrs);
        vm.stopPrank();
    }

    /// 挂拍即托管：NFT 立即进合约
    function testE1_listEscrowsNft() public {
        (uint256 tokenId, ) = _listBy(ALICE, "e1", 100e18, 168);
        require(jns.ownerOf(tokenId) == address(market), "nft not escrowed");
        require(market.tokenLocked(tokenId), "not locked");
        require(_trap() == 0, "trap");
    }

    /// 未 unbind 直接 list → JNS 侧 requireUnbound 拒绝
    function testE2_listWithoutUnbindReverts() public {
        uint256 tokenId = _claimTo(ALICE, "e2");
        vm.startPrank(ALICE);
        jns.setApprovalForAll(address(market), true);
        vm.expectRevert(bytes("JNS: token is bound"));
        market.list(tokenId, 100e18, 168);
        vm.stopPrank();
    }

    /// 1000 WJ 分账：fee 15 / 卖家 985 / NFT 归赢家
    function testE3_settleSplit() public {
        (uint256 tokenId, uint256 lid) = _listBy(ALICE, "e3", 1000e18, 168);
        // 买家 BOB 出价 1000 WJ（首笔 = 起拍价）
        vm.startPrank(BOB);
        wj.approve(address(market), 1000e18);
        market.bid(lid, 1000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 169 hours);
        uint256 sellerBefore = wj.balanceOf(ALICE);
        uint256 daoBefore    = wj.balanceOf(DAO);

        market.settle(lid);

        require(wj.balanceOf(DAO) == daoBefore + 15e18, "fee must be 15");
        require(wj.balanceOf(ALICE) == sellerBefore + 985e18, "proceeds must be 985");
        require(jns.ownerOf(tokenId) == BOB, "nft must go to winner");
        require(_trap() == 0, "trap");
    }

    /// 无人出价：NFT 退卖家、金额 0、无 WJ 转账、不 revert
    function testE4_noBidSettleReturnsNftZeroTransfer() public {
        (uint256 tokenId, uint256 lid) = _listBy(ALICE, "e4", 100e18, 168);
        vm.warp(block.timestamp + 169 hours);

        uint256 mktBefore   = wj.balanceOf(address(market));
        uint256 sellerBefore = wj.balanceOf(ALICE);
        uint256 daoBefore    = wj.balanceOf(DAO);

        market.settle(lid);

        require(jns.ownerOf(tokenId) == ALICE, "nft must return to seller");
        require(wj.balanceOf(address(market)) == mktBefore, "market balance must not change");
        require(wj.balanceOf(ALICE) == sellerBefore, "seller must get 0");
        require(wj.balanceOf(DAO) == daoBefore, "dao must get 0");
        require(market.tokenLocked(tokenId) == false, "must be unlocked");
        require(_trap() == 0, "trap");
    }

    /// 有出价不能撤单
    function testE5_cancelWithBidReverts() public {
        (, uint256 lid) = _listBy(ALICE, "e5", 100e18, 168);
        vm.startPrank(BOB);
        wj.approve(address(market), 100e18);
        market.bid(lid, 100e18);
        vm.stopPrank();

        vm.prank(ALICE);
        vm.expectRevert(bytes("SM: has bids, wait settle"));
        market.cancelListing(lid);
    }

    /// 无出价可撤单，NFT 退回
    function testE6_cancelWithoutBidReturnsNft() public {
        (uint256 tokenId, uint256 lid) = _listBy(ALICE, "e6", 100e18, 168);
        vm.prank(ALICE);
        market.cancelListing(lid);
        require(jns.ownerOf(tokenId) == ALICE, "nft not returned");
        require(!market.tokenLocked(tokenId), "still locked");
        require(_trap() == 0, "trap");
    }

    /// 费率 6% → revert（超 500 bps 硬上限）
    function testE7_feeRateAboveCapReverts() public {
        vm.prank(DAO);
        vm.expectRevert(bytes("SM: rate above cap"));
        market.setTradeFeeRate(600);          // 6%
        vm.prank(DAO);
        market.setTradeFeeRate(500);          // 5% 允许
        require(market.tradeFeeRate() == 500, "cap set failed");
    }

    /// 同一 NFT 重复挂拍 → revert
    function testE8_doubleListReverts() public {
        (uint256 tokenId, ) = _listBy(ALICE, "e8", 100e18, 168);
        vm.prank(ALICE);
        vm.expectRevert(bytes("SM: token already listed"));
        market.list(tokenId, 100e18, 168);
    }
}

// ═══════════════════ F 组：子域名 ═══════════════════
contract TestF is Base {
    /// 所有铸造都要拉 1 WJ 铸造费 ⇒ 先给 Registry 授权
    function setUp() public override {
        super.setUp();
        vm.prank(ALICE);
        wj.approve(address(subnames), 10_000e18);
        vm.prank(BOB);
        wj.approve(address(subnames), 10_000e18);
    }

    /// 顶级子域名铸造成功（父为主域名）
    function testF1_mintTopLevel() public {
        uint256 mainId = _claimTo(ALICE, "f1j");           // ALICE 持主域名
        vm.prank(ALICE);
        uint256 sub = subnames.mintSubname(mainId, 0, "1", "f1j");
        require(subnames.ownerOf(sub) == ALICE, "not minted");
        require(keccak256(bytes(subnames.fullNameOf(sub))) == keccak256(bytes("1.f1j")), "fullName wrong");
        require(subnames.depthOf(sub) == 1, "depth wrong");
        require(_trap() == 0, "trap");
    }

    /// 非主域名持有者 → revert
    function testF2_nonMainOwnerReverts() public {
        uint256 mainId = _claimTo(ALICE, "f2j");
        vm.prank(BOB);
        vm.expectRevert(bytes("SR: not main domain owner"));
        subnames.mintSubname(mainId, 0, "1", "f2j");
    }

    /// 【伪造用例】parentFullName 与 mainTokenId 不匹配 → revert
    function testF3_forgedParentFullNameReverts() public {
        uint256 goodId = _claimTo(BOB, "good.j");          // BOB 持 good.j = 某 tokenId
        // BOB 拿自己的 tokenId 配他人主域名前缀 "google.j" 试图伪造
        _claimTo(CAROL, "google.j");
        vm.prank(BOB);
        vm.expectRevert(bytes("SR: parentFullName does not match mainTokenId"));
        subnames.mintSubname(goodId, 0, "1", "google.j");
    }

    /// 匹配的真名 → 成功且拼接正确
    function testF4_matchingNameSucceeds() public {
        uint256 id = _claimTo(BOB, "acme.j");
        vm.prank(BOB);
        uint256 sub = subnames.mintSubname(id, 0, "1", "acme.j");
        require(keccak256(bytes(subnames.fullNameOf(sub))) == keccak256(bytes("1.acme.j")), "join wrong");
    }

    /// canMintSub = false → 其持有者不能铸子子域名
    function testF5_canMintSubFalseReverts() public {
        uint256 mainId = _claimTo(ALICE, "f5j");
        vm.prank(ALICE);
        uint256 sub = subnames.mintSubname(mainId, 0, "1", "f5j");

        vm.prank(ALICE);
        subnames.setCanMintSub(sub, false);

        vm.prank(ALICE);
        vm.expectRevert(bytes("SR: parent disallows sub minting"));
        subnames.mintSubname(0, sub, "2", "");
    }

    /// 层级递归：子子域名成功
    function testF6_recursiveDepth() public {
        uint256 mainId = _claimTo(ALICE, "f6j");
        vm.prank(ALICE);
        uint256 l1 = subnames.mintSubname(mainId, 0, "1", "f6j");
        vm.prank(ALICE);
        uint256 l2 = subnames.mintSubname(0, l1, "2", "");
        require(subnames.depthOf(l2) == 2, "depth wrong");
        require(keccak256(bytes(subnames.fullNameOf(l2))) == keccak256(bytes("2.1.f6j")), "join wrong");
    }

    /// 超 maxDepth → revert
    function testF7_exceedMaxDepthReverts() public {
        vm.prank(DAO);
        subnames.setMaxDepth(2);
        uint256 mainId = _claimTo(ALICE, "f7j");
        vm.prank(ALICE);
        uint256 l1 = subnames.mintSubname(mainId, 0, "1", "f7j");
        vm.prank(ALICE);
        uint256 l2 = subnames.mintSubname(0, l1, "2", "");
        vm.prank(ALICE);
        vm.expectRevert(bytes("SR: depth exceeds max"));
        subnames.mintSubname(0, l2, "3", "");
    }

    /// 非法 label → revert
    function testF8_badLabelReverts() public {
        uint256 mainId = _claimTo(ALICE, "f8j");
        vm.startPrank(ALICE);
        vm.expectRevert(bytes("SR: bad label"));
        subnames.mintSubname(mainId, 0, "", "f8j");
        vm.expectRevert(bytes("SR: bad label"));
        subnames.mintSubname(mainId, 0, "-abc", "f8j");
        vm.expectRevert(bytes("SR: bad label"));
        subnames.mintSubname(mainId, 0, "ABC", "f8j");
        vm.stopPrank();
    }

    /// 重复注册同一 fullName → revert
    function testF9_duplicateNameReverts() public {
        uint256 mainId = _claimTo(ALICE, "f9j");
        vm.startPrank(ALICE);
        subnames.mintSubname(mainId, 0, "7", "f9j");
        vm.expectRevert(bytes("SR: name already registered"));
        subnames.mintSubname(mainId, 0, "7", "f9j");
        vm.stopPrank();
    }

    /// transferable=false 转让 revert；renounce 后可转让
    function testF10_transferableAndRenounce() public {
        uint256 mainId = _claimTo(ALICE, "f10j");
        vm.prank(ALICE);
        uint256 sub = subnames.mintSubname(mainId, 0, "1", "f10j");

        vm.prank(ALICE);
        subnames.setTransferable(sub, false);
        vm.prank(ALICE);
        vm.expectRevert(bytes("SR: parent control: not transferable"));
        subnames.transferFrom(ALICE, BOB, sub);

        vm.prank(ALICE);
        subnames.renounceParentControl(sub);
        vm.prank(ALICE);
        subnames.transferFrom(ALICE, BOB, sub);            // 现在可转
        require(subnames.ownerOf(sub) == BOB, "transfer failed");
    }

    /// mintFee = 1 WJ；改后立即生效（即时型，不快照）
    function testF11_mintFeeImmediate() public {
        vm.prank(DAO);
        subnames.setMintFee(1e18);
        uint256 mainId = _claimTo(ALICE, "f11j");

        uint256 daoBefore = wj.balanceOf(DAO);
        vm.startPrank(ALICE);
        wj.approve(address(subnames), 1e18);
        subnames.mintSubname(mainId, 0, "1", "f11j");
        vm.stopPrank();
        require(wj.balanceOf(DAO) == daoBefore + 1e18, "fee must be 1 WJ");

        // 改费 → 下一笔立即按新值
        vm.prank(DAO);
        subnames.setMintFee(3e18);
        uint256 daoMid = wj.balanceOf(DAO);
        vm.startPrank(ALICE);
        wj.approve(address(subnames), 3e18);
        subnames.mintSubname(mainId, 0, "2", "f11j");
        vm.stopPrank();
        require(wj.balanceOf(DAO) == daoMid + 3e18, "fee change must apply immediately");
        require(_trap() == 0, "trap");
    }

    /// 父域名在 JNS 卖出后，子域名 NFT 独立存在
    function testF12_subIndependentAfterParentSold() public {
        uint256 mainId = _claimTo(ALICE, "f12j");
        vm.prank(ALICE);
        uint256 sub = subnames.mintSubname(mainId, 0, "5", "f12j");

        // ALICE 把主域名转给 CAROL（主域名由多签铸出，已 bind ⇒ 先 unbind）
        vm.startPrank(ALICE);
        jns.unbind(mainId);
        jns.transferFrom(ALICE, CAROL, mainId);
        vm.stopPrank();

        require(jns.ownerOf(mainId) == CAROL, "main not sold");
        require(subnames.ownerOf(sub) == ALICE, "subname must be independent");
    }

    // ═══════ 【J-53 裁定】纯数字 label 补测（6 条）═══════

    /// 补测①：合法纯数字 "1" / "0" / "888" 全部通过
    function testF13_digitsValid() public {
        uint256 mainId = _claimTo(ALICE, "f13j");
        vm.startPrank(ALICE);
        uint256 s1 = subnames.mintSubname(mainId, 0, "1", "f13j");
        uint256 s0 = subnames.mintSubname(mainId, 0, "0", "f13j");    // "0" 本身允许
        uint256 s888 = subnames.mintSubname(mainId, 0, "888", "f13j");
        vm.stopPrank();
        require(subnames.ownerOf(s1) == ALICE && subnames.ownerOf(s0) == ALICE && subnames.ownerOf(s888) == ALICE, "digits must pass");
        require(keccak256(bytes(subnames.fullNameOf(s0))) == keccak256(bytes("0.f13j")), "0 join wrong");
        require(keccak256(bytes(subnames.fullNameOf(s888))) == keccak256(bytes("888.f13j")), "888 join wrong");
    }

    /// 补测②：非纯数字 "abc" / "1-2" / "a1" → revert
    function testF14_nonDigitsRevert() public {
        uint256 mainId = _claimTo(ALICE, "f14j");
        vm.startPrank(ALICE);
        vm.expectRevert(bytes("SR: bad label"));
        subnames.mintSubname(mainId, 0, "abc", "f14j");
        vm.expectRevert(bytes("SR: bad label"));
        subnames.mintSubname(mainId, 0, "1-2", "f14j");          // 连字符已禁
        vm.expectRevert(bytes("SR: bad label"));
        subnames.mintSubname(mainId, 0, "a1", "f14j");
        vm.stopPrank();
    }

    /// 补测③：前导零 "01" / "001" → revert（防 "1"/"01"/"001" 三 NFT 混淆）
    function testF15_leadingZeroReverts() public {
        uint256 mainId = _claimTo(ALICE, "f15j");
        vm.startPrank(ALICE);
        vm.expectRevert(bytes("SR: bad label"));
        subnames.mintSubname(mainId, 0, "01", "f15j");
        vm.expectRevert(bytes("SR: bad label"));
        subnames.mintSubname(mainId, 0, "001", "f15j");
        vm.stopPrank();
    }

    /// 补测④：空串 → revert
    function testF16_emptyReverts() public {
        uint256 mainId = _claimTo(ALICE, "f16j");
        vm.prank(ALICE);
        vm.expectRevert(bytes("SR: bad label"));
        subnames.mintSubname(mainId, 0, "", "f16j");
    }

    /// 补测⑤：20 位数字 → revert（超 19 上限）
    function testF17_tooLongReverts() public {
        uint256 mainId = _claimTo(ALICE, "f17j");
        vm.startPrank(ALICE);
        subnames.mintSubname(mainId, 0, "1234567890123456789", "f17j");   // 19 位：恰好合法
        vm.expectRevert(bytes("SR: bad label"));
        subnames.mintSubname(mainId, 0, "12345678901234567890", "f17j");  // 20 位：超长
        vm.stopPrank();
    }

    /// 补测⑥：同一数字重复注册 → revert（唯一性）
    function testF18_duplicateDigitsRevert() public {
        uint256 mainId = _claimTo(ALICE, "f18j");
        vm.startPrank(ALICE);
        subnames.mintSubname(mainId, 0, "888", "f18j");
        vm.expectRevert(bytes("SR: name already registered"));
        subnames.mintSubname(mainId, 0, "888", "f18j");
        vm.stopPrank();
    }

    /// 补测⑦（附）："1" 与 "01" 不构成同一数字的两种形式 —— "01" 被拒 ⇒ 无混淆面对
    function testF19_noAmbiguousForms() public {
        uint256 mainId = _claimTo(ALICE, "f19j");
        vm.startPrank(ALICE);
        uint256 s1 = subnames.mintSubname(mainId, 0, "1", "f19j");
        vm.expectRevert(bytes("SR: bad label"));
        subnames.mintSubname(mainId, 0, "01", "f19j");
        vm.stopPrank();
        require(subnames.tokenIdOfName("1.f19j") == s1, "canonical form only");
        require(subnames.tokenIdOfName("01.f19j") == 0, "ambiguous form must not exist");
    }

    // ═══════ 【J-53 裁定】maxDepth 8 → 5 边界用例 ═══════

    /// 补测⑧：默认深度上限 = 5；递归至第 5 层成功，第 6 层 revert
    function testF20_maxDepthFiveBoundary() public {
        require(subnames.maxDepth() == 5, "default maxDepth must be 5");
        uint256 mainId = _claimTo(ALICE, "f20j");
        vm.startPrank(ALICE);
        uint256 cur = subnames.mintSubname(mainId, 0, "1", "f20j");   // depth 1
        for (uint256 d = 2; d <= 5; d++) {
            cur = subnames.mintSubname(0, cur, _digit(d), "");         // depth 2..5
        }
        require(subnames.depthOf(cur) == 5, "depth 5 must succeed");
        vm.expectRevert(bytes("SR: depth exceeds max"));
        subnames.mintSubname(0, cur, "6", "");                        // depth 6 ⇒ revert
        vm.stopPrank();
    }

    /// 补测⑨：setMaxDepth 上限保护（>5 拒绝）
    function testF21_setMaxDepthCeiling() public {
        vm.prank(DAO);
        vm.expectRevert(bytes("SR: bad depth"));
        subnames.setMaxDepth(6);
        vm.prank(DAO);
        subnames.setMaxDepth(5);
        require(subnames.maxDepth() == 5, "5 allowed");
        vm.prank(DAO);
        vm.expectRevert(bytes("SR: bad depth"));
        subnames.setMaxDepth(0);
    }

    /// @dev 数字标签助手（1..19 位纯数字，无前导零）
    function _digit(uint256 n) internal pure returns (string memory) {
        if (n == 0) { return "0"; }
        uint256 len;
        uint256 t = n;
        while (t != 0) { len++; t /= 10; }
        bytes memory b = new bytes(len);
        uint256 i = len;
        while (i != 0) { i--; b[i] = bytes1(uint8(0x30 + (n % 10))); n /= 10; }
        return string(b);
    }
}
