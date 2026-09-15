// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "../contracts/JNSAuctionFactory.sol";
import "../contracts/ClaimRegistry.sol";

/**
 * @title  SetterCalldata —— 【不部署、不发交易】只产出多签/developer 待执行 calldata（Part 2 / 2）
 * @notice 只读核查版 · 2026-09-14
 *
 * 用途：Part 1（Deploy.s.sol）只负责部署；本脚本【只计算 calldata】，
 *       供多签 2/3 与 developer 各自用【自己的钱包】发起交易。
 *
 * ⚠️ 本脚本【不调用】任何 setter —— 若在此调用，msg.sender 是部署者 EOA 而非多签/developer，
 *    必然 revert "Ownable: caller is not the owner" / "Not developer"。
 *    这正是要拆成两部分的根本原因。
 *
 * 运行（干跑）：
 *   forge script script/SetterCalldata.s.sol:SetterCalldata -vv
 *
 * 使用：把下方 emit 出来的 `data` 逐条填入多签工具（或 `cast send <target> <data>`，
 *       由多签钱包/多签 UI 发起）。
 */
contract SetterCalldata {
    address public constant DAO_MULTISIG = 0x4eF599b6E39D950D6Ddbd830fF5f95e06770C1B3;

    /// @dev 审核人 J-0 / Koant。【链上实测】eth_getCode()=="0x" ⇒ EOA；core-contributors.md L37
    address public constant REVIEWER_J0 = 0x5BF50F2931688F886F46f88D5CEEDE530bB92076;

    /// @dev 【J-53 裁定·2026-09-15 已确认采用】提醒服务 developer = J-53 本人地址
    ///      部署时 constructor 直接填入；无需 propose→accept 就位流程。
    address public constant DEV_ADDR = 0x8b4846d72d1530df755D9B5146A3e627a0A7147F;

    /// @dev 部署后把实际地址填进来（Deploy 输出的 Deployed 事件）
    address public factoryAddr = address(0);
    address public registryAddr = address(0);

    event MultisigCall(address indexed target, string fn, bytes data, string expectEmit);
    event DeveloperCall(address indexed target, string fn, bytes data, string expectEmit);

    function run() external {
        // ═══════════ A. 多签 2/3 待执行（仅 2 条）═══════════
        emit MultisigCall(
            factoryAddr,
            "setReviewer(address,bool)",
            abi.encodeWithSignature("setReviewer(address,bool)", REVIEWER_J0, true),
            "ReviewerSet(J0_EOA, true, ts)"
        );
        emit MultisigCall(
            registryAddr,
            "setRegistrar(address,bool)",
            abi.encodeWithSignature("setRegistrar(address,bool)", factoryAddr, true),
            "RegistrarSet(factory, true, ts)"
        );

        // ═══════════ B. developer 待执行（J-53 本人钱包）═══════════
        // 【J-53 裁定】v1 休眠：perUseFee = 0（constructor 已是 0），无需调 setPerUseFee。
        // 下方仅列【将来启用时】的 calldata，由 J-53 本人用自己钱包发起。
        emit DeveloperCall(
            address(0),   // notify 地址（Deploy 输出）
            "setPerUseFee(uint256)",
            abi.encodeWithSignature("setPerUseFee(uint256)", 5e16),   // 0.05 WJ（将来启用时）
            "PerUseFeeChanged(old, 5e16, ts)"
        );
        emit DeveloperCall(
            address(0),   // notify 地址
            "setServiceFeeRecipient(address)",
            abi.encodeWithSignature("setServiceFeeRecipient(address)", DAO_MULTISIG),
            "ServiceFeeRecipientChanged(old, DAO, ts)"
        );
    }

    // ═══════════ C. developer 变更（仅 J-53 本人；自转让）═══════════
    /// @dev 【J-53 裁定】语义：沉默 = 否决。
    ///      · owner/多签【无法发起】：proposeDeveloper 恒 revert
    ///      · 唯一入口 = 当前 developer 自调 transferDeveloperRole
    ///      · Timelock = 【未确认即不生效】（到期未由被提名人主动确认 ⇒ 作废）
    ///      ① transferDeveloperRole(<new>)          [仅当前 developer]
    ///      ② 等 7 天（DEVELOPER_DELAY）
    ///      ③ acceptDeveloperRole()                [仅被提名人；须在 +7 天窗口内]
    ///      （任一步缺失 ⇒ 不生效；另可用 cancelDeveloperTransfer 提前撤回）
    function developerTransferCalldata(address newDev)
        external
        pure
        returns (bytes memory transfer, bytes memory cancel, bytes memory accept)
    {
        transfer = abi.encodeWithSignature("transferDeveloperRole(address)", newDev);
        cancel   = abi.encodeWithSignature("cancelDeveloperTransfer()");
        accept   = abi.encodeWithSignature("acceptDeveloperRole()");
    }
}
