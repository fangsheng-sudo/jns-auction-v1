// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "../../contracts/deps/Deps.sol";

interface ITransferReceiver {
    function onTokenTransfer(address from, uint256 value, bytes calldata data) external returns (bool);
}

interface IApprovalReceiver {
    function onTokenApproval(address from, uint256 value, bytes calldata data) external returns (bool);
}

/**
 * @title MockWJ —— 复刻 WJ 的【陷阱】+【ERC-677 回调】行为，供 Foundry 测试断言防护是否生效
 * @notice 测试用 mock，不部署上链。
 *
 * 复刻要点（均对照【链上查明】WJ.sol 与主网字节码实测）：
 *  ① 【陷阱】transfer/transferFrom 的 to == address(0) 或 to == WJ 自身 ⇒ 不转账，burn + trappedAmount 记账
 *  ② 【ERC-677 回调】主网 WJ 字节码实测存在以下选择器：
 *       transferAndCall(address,uint256,bytes) 0x4000aea0  ✓（出现 2 次）
 *       approveAndCall(address,uint256,bytes)  0xcae9ca51  ✓（出现 1 次）
 *       depositToAndCall(address,bytes)        0x5ddb7d7e  ✓（出现 1 次）
 *       onTokenTransfer(address,uint256,bytes) 0xa4c0ed36  ✓（出现 2 次，被调方接口）
 *       onTokenApproval(address,uint256,bytes) 0x00ba451f  ✗（字节码 0 次；文档称有，此处按实测不实现）
 *     ⇒ 向【合约】走 transferAndCall/approveAndCall 时，会主动回调接收方；
 *       接收方未实现对应接口 ⇒ 整笔 revert（这是真实链上行为）。
 *  ③ 回调语义：与 OZ ERC677 一致 —— 先完成转账/授权，再回调，回调失败则整笔 revert。
 */
contract MockWJ {
    string public name = "Wrapped Joule";
    string public symbol = "WJ";
    uint8  public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev 模拟「退还给 msg.sender 的原生 J」——被陷阱吞掉的金额
    uint256 public trappedAmount;

    /// @dev 回调被触发次数（测试用，验证回调路径确实走到）
    uint256 public callbackCount;
    /// @dev 最近一次回调的调用方/接收方（测试用）
    address public lastCallbackFrom;
    address public lastCallbackTo;
    uint256 public lastCallbackValue;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Trapped(address indexed from, uint256 amount, uint256 ts);
    event CallbackFired(address indexed to, address indexed from, uint256 value, bytes data);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, value);
        _transfer(from, to, value);
        return true;
    }

    // ═══════════ ERC-677 回调路径（复刻真实 WJ）═══════════

    /// @dev transferAndCall：转账成功后再回调 to.onTokenTransfer；回调返回 false 或 revert ⇒ 整笔 revert
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool) {
        _transfer(msg.sender, to, value);
        _callbackTransfer(msg.sender, to, value, data);
        return true;
    }

    /// @dev depositToAndCall：本 mock 无原生 J，故仅按 msg.value 记账后再回调（签名与真实一致）
    function depositToAndCall(address to, bytes calldata data) external payable returns (bool) {
        totalSupply += msg.value;
        balanceOf[to] += msg.value;
        emit Transfer(address(0), to, msg.value);
        _callbackTransfer(msg.sender, to, msg.value, data);
        return true;
    }

    /// @dev approveAndCall：先授权，再回调 to.onTokenApproval
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        _callbackApproval(msg.sender, spender, value, data);
        return true;
    }

    function _callbackTransfer(address from, address to, uint256 value, bytes calldata data) internal {
        if (to.code.length > 0) {
            callbackCount += 1;
            lastCallbackFrom = from;
            lastCallbackTo = to;
            lastCallbackValue = value;
            emit CallbackFired(to, from, value, data);
            require(
                ITransferReceiver(to).onTokenTransfer(from, value, data),
                "MockWJ: onTokenTransfer failed"
            );
        }
    }

    function _callbackApproval(address from, address to, uint256 value, bytes calldata data) internal {
        if (to.code.length > 0) {
            callbackCount += 1;
            lastCallbackFrom = from;
            lastCallbackTo = to;
            lastCallbackValue = value;
            emit CallbackFired(to, from, value, data);
            require(
                IApprovalReceiver(to).onTokenApproval(from, value, data),
                "MockWJ: onTokenApproval failed"
            );
        }
    }

    // ═══════════ 内部：授权与转账（含陷阱）═══════════

    function _spendAllowance(address from, uint256 value) internal {
        if (from == msg.sender) { return; }
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= value, "MockWJ: allowance");
            allowance[from][msg.sender] -= value;
        }
    }

    /// @dev 【陷阱复刻】to == 0 或 to == 本合约 ⇒ 不转账，burn + trappedAmount 记账
    function _transfer(address from, address to, uint256 value) internal {
        require(balanceOf[from] >= value, "MockWJ: balance");
        balanceOf[from] -= value;

        if (to == address(0) || to == address(this)) {
            totalSupply -= value;          // burn
            trappedAmount += value;        // 模拟「退给 msg.sender 的原生 J」被困
            emit Transfer(from, address(0), value);
            emit Trapped(from, value, block.timestamp);
            return;
        }

        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
