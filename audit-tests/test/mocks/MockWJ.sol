// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

/**
 * @title MockWJ —— 盲审独立 mock：最小 ERC-20 + 复刻 WJ 陷阱语义
 * @notice 仅测试用，不上链。行为对照被测合约注释中【链上查明】的 WJ.sol：
 *          transfer/transferFrom 的 to == 0 或 to == WJ 自身 ⇒ 不转账、烧毁并记账
 *          （对应「原生 J 退给 msg.sender 被困」）。被测合约的 _wjSafeTransfer
 *          防护不得失效 ⇒ 全部用例断言 trappedAmount() == 0。
 */
contract MockWJ {
    string  public name = "Wrapped Joule";
    string  public symbol = "WJ";
    uint8   public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev 落入陷阱的金额（正常应恒为 0）
    uint256 public trappedAmount;

    function mint(address to, uint256 v) external {
        totalSupply += v;
        balanceOf[to] += v;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        _transfer(msg.sender, to, v);
        return true;
    }

    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        if (f != msg.sender) {
            uint256 a = allowance[f][msg.sender];
            require(a >= v, "MockWJ: allowance");
            if (a != type(uint256).max) { allowance[f][msg.sender] = a - v; }
        }
        _transfer(f, to, v);
        return true;
    }

    function _transfer(address f, address to, uint256 v) internal {
        require(balanceOf[f] >= v, "MockWJ: balance");
        balanceOf[f] -= v;
        if (to == address(0) || to == address(this)) {
            totalSupply -= v;      // 烧毁
            trappedAmount += v;    // 对应被困的原生 J
            return;
        }
        balanceOf[to] += v;
    }
}
