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
 * @title  RescueNft —— A2/A3 + 跨合约修复验证：通用 NFT 救援出口
 * @notice 验证 rescueStuckNft(address token, uint256 tokenId)（gov-only + nonReentrant + CEI）：
 *          覆盖 A2（本场 tokenId、非终态）、A3（外名 tokenId）、跨合约 ERC721，
 *          且不丢「JNS 本场 Held 在途」托管保护。
 */
contract RescueNft {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant WJ_ADDR  = 0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD;
    address constant JNS_ADDR = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;
    // 另一 ERC721 合约（跨合约误入场景），用 MockJNS 代码 etch 到独立地址
    address constant FOREIGN_NFT = 0x1111111111111111111111111111111111111111;

    address constant DAO      = address(0xD0A0);
    address constant MULTISIG = address(0x3C3C);
    address constant ALICE    = address(0xA11CE);
    address constant BOB      = address(0xB0B);

    MockWJ  wj;
    MockJNS jns;
    MockJNS foreign;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(WJ_ADDR, vm.getDeployedCode("MockWJ.sol:MockWJ"));
        wj = MockWJ(WJ_ADDR);
        vm.etch(JNS_ADDR, vm.getDeployedCode("MockJNS.sol:MockJNS"));
        jns = MockJNS(JNS_ADDR);
        jns.initialize(MULTISIG);
        vm.etch(FOREIGN_NFT, vm.getDeployedCode("MockJNS.sol:MockJNS"));
        foreign = MockJNS(FOREIGN_NFT);
        foreign.initialize(MULTISIG);
        wj.mint(ALICE, 1_000_000e18);
        wj.mint(BOB,   1_000_000e18);
    }

    function _newAuction(string memory n) internal returns (EnglishAuction a) {
        a = new EnglishAuction(n, 168, 10e18, ALICE, DAO, bytes32(uint256(0x5155)), address(this));
        vm.prank(ALICE);
        wj.transfer(address(a), 10e18);
        vm.prank(BOB);
        wj.approve(address(a), 12e18);
        vm.prank(BOB);
        a.bid(12e18);
    }

    /// ① 跨合约 ERC721 NFT 误入 ⇒ 可救回
    function testCrossContract_rescueForeignErc721() public {
        EnglishAuction a = _newAuction("x1-name");
        vm.warp(block.timestamp + 169 hours);

        // 另一 ERC721 合约的 NFT 误入本场
        vm.prank(MULTISIG);
        uint256 fid = foreign.claim("foreign-name");
        vm.prank(MULTISIG);
        foreign.unbind(fid);
        vm.prank(MULTISIG);
        foreign.transferFrom(MULTISIG, address(a), fid);
        require(foreign.ownerOf(fid) == address(a), "pre: foreign NFT misrouted");

        // 救回（token = FOREIGN_NFT，非 JNS ⇒ 不受本场托管约束）
        vm.prank(MULTISIG);
        a.rescueStuckNft(FOREIGN_NFT, fid);
        require(foreign.ownerOf(fid) == MULTISIG, "cross: foreign NFT must return to gov");
    }

    /// ② token=JNS + 本场 tokenId + escrow=Held ⇒ revert EA: in escrow（保护未丢）
    function testGuard_heldOwnTokenNotRescuable() public {
        EnglishAuction a = _newAuction("x2-name");
        vm.warp(block.timestamp + 169 hours);
        a.settle();
        require(a.escrow() == EnglishAuction.EscrowState.Held, "pre: Held");

        vm.prank(MULTISIG);
        uint256 tid = jns.claim("x2-name");
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, address(a), tid);
        require(jns.ownerOf(tid) == address(a), "pre: own token held by contract");

        vm.prank(MULTISIG);
        vm.expectRevert(bytes("EA: in escrow"));
        a.rescueStuckNft(JNS_ADDR, tid);
        require(jns.ownerOf(tid) == address(a), "guard: NFT must stay");
    }

    /// ③ token=JNS + 外名 tokenId ⇒ 仍可救回（A3）
    function testA3_rescueForeignName() public {
        EnglishAuction a = _newAuction("x3-name");
        vm.warp(block.timestamp + 169 hours);

        vm.prank(MULTISIG);
        uint256 tid = jns.claim("x3-other");           // 外名
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, address(a), tid);
        require(jns.ownerOf(tid) == address(a), "pre: foreign-name NFT misrouted");

        vm.prank(MULTISIG);
        a.rescueStuckNft(JNS_ADDR, tid);
        require(jns.ownerOf(tid) == MULTISIG, "A3: foreign-name NFT must return to gov");
    }

    /// A2：本场 NFT settle 前 cancel（escrow=None）⇒ 可救回
    function testA2_rescueAfterEmergencyCancel() public {
        EnglishAuction a = _newAuction("x4-name");
        vm.warp(block.timestamp + 169 hours);

        vm.prank(MULTISIG);
        uint256 tid = jns.claim("x4-name");
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, address(a), tid);
        require(jns.ownerOf(tid) == address(a), "pre: own NFT misrouted");

        a.emergencyCancel("cancel before settle");
        require(a.escrow() == EnglishAuction.EscrowState.None, "pre: escrow None");

        vm.prank(MULTISIG);
        a.rescueStuckNft(JNS_ADDR, tid);
        require(jns.ownerOf(tid) == MULTISIG, "A2: NFT must return to gov");
    }

    /// ④ 非 gov ⇒ revert EA: not gov
    function testGuard_notGov() public {
        EnglishAuction a = _newAuction("x5-name");
        vm.warp(block.timestamp + 169 hours);
        vm.prank(MULTISIG);
        uint256 tid = jns.claim("x5-name");
        vm.prank(MULTISIG);
        jns.unbind(tid);
        vm.prank(MULTISIG);
        jns.transferFrom(MULTISIG, address(a), tid);

        vm.prank(BOB);
        vm.expectRevert(bytes("EA: not gov"));
        a.rescueStuckNft(JNS_ADDR, tid);
    }

    /// ⑤ 本合约未持有该 tokenId ⇒ revert EA: no NFT held
    function testGuard_notHeld() public {
        EnglishAuction a = _newAuction("x6-name");
        vm.warp(block.timestamp + 169 hours);
        vm.prank(MULTISIG);
        uint256 tid = jns.claim("x6-name");            // 仍由治理方持有

        vm.prank(MULTISIG);
        vm.expectRevert(bytes("EA: no NFT held"));
        a.rescueStuckNft(JNS_ADDR, tid);
    }
}
