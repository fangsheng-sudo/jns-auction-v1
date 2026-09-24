// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "../contracts/EnglishAuction.sol";
import "../contracts/EnglishAuctionDeployer.sol";
import "../contracts/JNSAuctionFactory.sol";
import "../contracts/SecondaryMarket.sol";
import "../contracts/ClaimRegistry.sol";
import "../contracts/SubnameRegistry.sol";
import "../contracts/NotificationService.sol";
import "./mocks/MockWJ.sol";
import "./mocks/MockJNS.sol";

interface Vm {
    function warp(uint256) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert() external;
    function expectRevert(bytes calldata) external;
    function deal(address, uint256) external;
    function getDeployedCode(string calldata) external returns (bytes memory);
    function etch(address, bytes calldata) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

struct Log {
    bytes32[] topics;
    bytes data;
    address emitter;
}

/// @dev 公共装置：etch 两个 mock 到合约硬编码的常量地址，部署四批合约
abstract contract Base {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant DAO      = address(0xD0A0);
    address constant DEVEL    = address(0xDE7E1);
    address constant MULTISIG = address(0x3C3C);
    address constant ALICE    = address(0xA11CE);
    address constant BOB      = address(0xB0B);
    address constant CAROL    = address(0xCAC0);

    address constant WJ_ADDR  = 0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD;
    address constant JNS_ADDR = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;

    MockWJ  wj;
    MockJNS jns;
    JNSAuctionFactory factory;
    SecondaryMarket   market;
    ClaimRegistry     registry;
    SubnameRegistry   subnames;
    NotificationService notify;

    function setUp() public virtual {
        vm.warp(1_000_000);

        // WJ/JNS 在合约内是【硬编码常量地址】⇒ mock 必须落同址，否则调用全部落空。
        // 本版 forge 无 deployCodeTo ⇒ 用 getDeployedCode + etch；etch 不跑构造函数，
        // 故 MockJNS 需 initialize() 补 nextId=1 等内联初值。
        vm.etch(WJ_ADDR,  vm.getDeployedCode("MockWJ.sol:MockWJ"));
        wj = MockWJ(WJ_ADDR);
        vm.etch(JNS_ADDR, vm.getDeployedCode("MockJNS.sol:MockJNS"));
        jns = MockJNS(JNS_ADDR);
        jns.initialize(MULTISIG);              // 真实 JNS 的 owner = 3/2 多签

        EnglishAuctionDeployer dep = new EnglishAuctionDeployer();
        factory  = new JNSAuctionFactory(DAO, DAO, address(dep));
        dep.setFactory(address(factory));
        market   = new SecondaryMarket(DAO, DAO);
        registry = new ClaimRegistry(DAO);
        subnames = new SubnameRegistry(DAO, DAO);
        notify   = new NotificationService(DAO, DEVEL, DAO);   // owner=DAO, developer=DEVEL

        wj.mint(ALICE, 1_000_000e18);
        wj.mint(BOB,   1_000_000e18);
        wj.mint(CAROL, 1_000_000e18);
    }

    // ──────────── helpers ────────────
    function _claimTo(address to, string memory n) internal returns (uint256) {
        vm.prank(MULTISIG);
        return jns.claimTo(n, to);
    }

    /// @dev 走完整链路建一场拍卖（申请→审核→开拍），起拍价由申请人 ALICE 出资
    function _newAuction(string memory n, uint256 sp, uint256 hrs) internal returns (address a) {
        vm.prank(ALICE);
        uint256 rid = factory.submitRequest(n, sp, keccak256(bytes(n)));
        vm.prank(DAO);
        factory.setReviewer(DAO, true);
        vm.prank(DAO);
        factory.approveRequest(rid);
        vm.prank(ALICE);
        wj.approve(address(factory), sp);
        vm.prank(ALICE);
        a = factory.createAuctionFromRequest(rid, hrs);
    }

    /// @dev 直接部署（绕开工厂），并手工复刻「同 tx 拉起拍价」使账面与真实一致
    function _directAuction(string memory n, uint256 sp, uint256 hrs) internal returns (EnglishAuction a) {
        a = new EnglishAuction(n, hrs, sp, ALICE, DAO, bytes32(0), address(this));
        vm.prank(ALICE);
        wj.transfer(address(a), sp);
    }

    function _trap() internal view returns (uint256) { return wj.trappedAmount(); }

    /// @dev 建仓 → BOB 加价 → 到点 settle（进入 Held）
    function _settledAuction(string memory n, uint256 sp, uint256 bidAmt)
        internal returns (address a)
    {
        a = _newAuction(n, sp, 168);
        if (bidAmt > 0) {
            vm.prank(BOB);
            wj.approve(a, bidAmt);
            vm.prank(BOB);
            EnglishAuction(a).bid(bidAmt);
        }
        vm.warp(block.timestamp + 169 hours);
        EnglishAuction(a).settle();
    }
}
