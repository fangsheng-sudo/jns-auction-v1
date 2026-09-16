// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "../contracts/JNSAuctionFactory.sol";
import "../contracts/SecondaryMarket.sol";
import "../contracts/ClaimRegistry.sol";
import "../contracts/SubnameRegistry.sol";
import "../contracts/NotificationService.sol";

interface VmDeploy {
    function startBroadcast(address who) external;
    function stopBroadcast() external;
    function envOr(string calldata name, address defaultValue) external returns (address);
}

/**
 * @title  Deploy —— 【仅部署】脚本（Part 1 / 2）
 * @notice 只读核查版 · 2026-09-14 · 【不执行广播】
 *
 * ── 部署广播方（必修1 已改正）──────────────────────────────────
 *  ① 部署交易用【普通 EOA】广播即可 —— 部署【不需要 owner 权限】；
 *     constructor 的 owner 参数【硬编码填多签】0x4eF599...C1B3。
 *  ② 所有 owner-only setter 由【多签 2/3 流程】自行发交易执行；
 *     本脚本【只部署、不调 setter】，calldata 由 SetterCalldata.s.sol 产出。
 *  ③ 【常见误解·必读】干跑时若看到 "Ownable: caller is not the owner"，
 *     成因是【调用 setter 的那个地址】不是 owner（多签），
 *     【与「谁部署」完全无关】—— 部署者是谁都不影响 setter 的权限判定。
 *     正因如此，setter 必须由多签发起，不能在本脚本里代劳。
 *  ④ 多签 0x4eF599...C1B3 是【合约地址、无私钥】，
 *     绝不可作为 --broadcast 的发送者（主网无法签名，必然失败）；
 *     但这【不是】setter 失败的原因。
 *
 * 运行（本地干跑，不广播、不发送交易）：
 *   forge script script/Deploy.s.sol:Deploy
 * 真部署（需人工二次确认）：
 *   DEPLOYER_ADDR=<持有私钥的EOA> forge script script/Deploy.s.sol:Deploy --broadcast --rpc-url $JNS_DAO_RPC_URL
 *
 * ⚠️ 本链【无测试网】（chainId 3666），四批合约【均不可升级】⇒ 参数须事前逐项核对。
 */
contract Deploy {
    VmDeploy constant vm = VmDeploy(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @dev JNS DAO 多签（3 人 2/3）。【链上查明】5860B 合约、required()==2、JNS.owner()
    address public constant DAO_MULTISIG = 0x4eF599b6E39D950D6Ddbd830fF5f95e06770C1B3;

    /// @dev 【J-53 裁定·2026-09-15 已确认采用】提醒服务 developer = J-53 本人地址
    ///      （core-contributors.md L90；EOA 实测；≠ 多签 ⇒ 权限隔离成立）
    ///      v1：perUseFee = 0 ⇒ 提醒服务休眠（单次封顶 1 WJ / 月费封顶 30 WJ 均为常量）。
    ///      ⚠️ developer 变更权【仅其本人】（transferDeveloperRole 自转让）；owner 无法发起。
    address public constant DEVELOPER = 0x8b4846d72d1530df755D9B5146A3e627a0A7147F;

    event Deployed(string what, address addr);

    function run() external {
        // ① 部署者 = 持有私钥的普通 EOA（部署不需要 owner 权限）
        address deployer = vm.envOr("DEPLOYER_ADDR", msg.sender);
        require(deployer != DAO_MULTISIG, "DEPLOYER must be an EOA with a private key");

        address owner        = DAO_MULTISIG;   // constructor owner 一律硬编码为多签
        address beneficiary  = DAO_MULTISIG;   // ① 一级拍卖受益
        address tradeFeeTo   = DAO_MULTISIG;   // ② 二级市场手续费
        address mintFeeTo    = DAO_MULTISIG;   // ③ 子域名铸造费
        address serviceFeeTo = DAO_MULTISIG;   // ④ 提醒服务费

        vm.startBroadcast(deployer);

        JNSAuctionFactory factory = new JNSAuctionFactory(owner, beneficiary);
        emit Deployed("JNSAuctionFactory", address(factory));

        SecondaryMarket market = new SecondaryMarket(owner, tradeFeeTo);
        emit Deployed("SecondaryMarket", address(market));

        ClaimRegistry registry = new ClaimRegistry(owner);
        emit Deployed("ClaimRegistry", address(registry));

        SubnameRegistry subnames = new SubnameRegistry(owner, mintFeeTo);
        emit Deployed("SubnameRegistry", address(subnames));

        NotificationService notify = new NotificationService(owner, DEVELOPER, serviceFeeTo);
        emit Deployed("NotificationService", address(notify));

        vm.stopBroadcast();

        // 【本脚本到此为止】不调用任何 setter。
        // 后续两步见：
        //   · 多签待执行 calldata → script/SetterCalldata.s.sol
        //   · developer 就位路径   → 部署与多签执行清单.md §3c
    }
}
