// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "../contracts/EnglishAuction.sol";
import "../contracts/JNSAuctionFactory.sol";
import "../contracts/SecondaryMarket.sol";
import "../contracts/ClaimRegistry.sol";
import "../contracts/SubnameRegistry.sol";
import "../contracts/NotificationService.sol";
import "./mocks/MockWJ.sol";
import "./mocks/MockJNS.sol";

/// @dev 极简 cheatcode 接口（避免 forge-std 的网络依赖）
interface Vm {
    function warp(uint256) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes calldata) external;
    function deal(address, uint256) external;
    function roll(uint256) external;
    function getCode(string calldata what) external returns (bytes memory);
    function getDeployedCode(string calldata what) external returns (bytes memory);
    function etch(address where, bytes calldata code) external;
    function store(address where, bytes32 slot, bytes32 value) external;
}

/**
 * @title SmokeTest —— 阶段 A 冒烟：四批合约 + 两 mock 全部署
 * @notice 主流程：申请 → 审核 → 开拍 → 出价 → 到点 → settle → 暂存(Held)
 *         最终断言 MockWJ.trappedAmount() == 0（WJ 陷阱未被触发）
 */
contract SmokeTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MockWJ  wj;
    MockJNS jns;
    JNSAuctionFactory factory;
    SecondaryMarket   market;
    ClaimRegistry     registry;
    SubnameRegistry   subnames;
    NotificationService notify;

    address constant DAO  = address(0xD0A0);
    address constant MULTISIG = address(0x3C3C);
    address constant ALICE = address(0xA11CE);
    address constant BOB   = address(0xB0B);

    // 合约内硬编码的常量地址（mock 必须落在同址，否则调用落空）
    address constant WJ_ADDR  = 0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD;
    address constant JNS_ADDR = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;

    function setUp() public {
        // 合约内 WJ/JNS 是【硬编码常量地址】⇒ mock 必须落在同址，否则调用全部落空。
        // 本版 forge 无 deployCodeTo，改用 getDeployedCode + etch（etch 不跑构造函数，
        // 故 MockJNS 需额外 initialize 设置 owner）。
        vm.etch(WJ_ADDR,  vm.getDeployedCode("MockWJ.sol:MockWJ"));
        wj = MockWJ(WJ_ADDR);
        vm.etch(JNS_ADDR, vm.getDeployedCode("MockJNS.sol:MockJNS"));
        jns = MockJNS(JNS_ADDR);
        jns.initialize(MULTISIG);          // 真实 JNS 的 owner 为 3/2 多签

        factory  = new JNSAuctionFactory(DAO, DAO);     // owner=DAO, auctionBeneficiary=DAO
        market   = new SecondaryMarket(DAO, DAO);
        registry = new ClaimRegistry(DAO);
        subnames = new SubnameRegistry(DAO, DAO);
        notify   = new NotificationService(DAO, DAO, DAO);  // owner, developer, serviceFeeRecipient

        // 资金
        wj.mint(ALICE, 100_000e18);
        wj.mint(BOB,   100_000e18);
    }

    /// @dev 经 Vm cheatcode 把指定 artifact 的运行时码 + 构造部署到固定地址

    function testSmoke_DeployAll() public view {
        require(address(wj) != address(0) && address(factory) != address(0), "deploy failed");
        require(wj.trappedAmount() == 0, "trap triggered at deploy");
    }

    function testSmoke_FullAuctionFlow() public {
        // ── 申请 ──
        vm.prank(ALICE);
        uint256 requestId = factory.submitRequest("bit", 10e18, keccak256("payload"));

        // ── 审核（owner 代审，防自审：审核人 != 申请人）──
        vm.prank(DAO);
        factory.setReviewer(DAO, true);
        vm.prank(DAO);
        factory.approveRequest(requestId);

        // ── 开拍：ALICE 授权工厂拉起拍价，由 ALICE 自己触发 ──
        vm.prank(ALICE);
        wj.approve(address(factory), 10e18);
        vm.prank(ALICE);
        address auction = factory.createAuctionFromRequest(requestId, 168);

        // 起拍价即 ALICE 的首笔出价 ⇒ 拍卖合约已持有 10 WJ
        require(wj.balanceOf(auction) == 10e18, "startPrice not escrowed");

        // ── 出价：BOB 出 12 WJ ──
        vm.prank(BOB);
        wj.approve(auction, 12e18);
        vm.prank(BOB);
        EnglishAuction(auction).bid(12e18);

        // ── 到点结算（暂存 Held，不放款）──
        vm.warp(block.timestamp + 169 hours);
        EnglishAuction(auction).settle();

        require(uint256(EnglishAuction(auction).escrow()) == 1, "not Held");   // EscrowState.Held == 1
        require(wj.balanceOf(auction) == 22e18, "escrow balance wrong");

        // ── 核心断言：WJ 陷阱全程未被触发 ──
        require(wj.trappedAmount() == 0, "WJ trap was triggered!");
    }
}
