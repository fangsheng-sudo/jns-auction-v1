// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

/**
 * @title MockJNS —— 盲审独立 mock：最小 ERC-721 + _nslookup + owner() + CSBT 绑定
 * @notice 仅测试用，不上链。复刻被测合约依赖的链上事实：
 *           ① `_nslookup(string)`：不存在的 name 返回 0（不 revert）；tokenId 从 1 起，0 为哨兵
 *           ② `claim(name)`：仅 owner（治理多签）可调，铸给 msg.sender 且默认绑定（CSBT bound）
 *           ③ 绑定中的 token 不可 transferFrom，须持有人先 unbind
 *           ④ `owner()` 返回治理地址（真实链上为 3/2 多签）
 *         vm.etch 不执行构造函数 ⇒ 内联初值全部丢失，须先 initialize() 补齐。
 */
contract MockJNS {
    string public name = "J Name Service";
    string public symbol = "JNS";

    address public gov;      // JNS.owner()（initialize 补设）
    uint256 public nextId;   // etch 后为 0，initialize 补 1

    mapping(string => uint256) public _nslookup;   // name → tokenId（缺失返回 0）
    mapping(uint256 => address) private _owners;
    mapping(uint256 => bool) public bound;          // CSBT 绑定标志
    mapping(uint256 => address) private _approvals;
    mapping(address => mapping(address => bool)) private _operators;

    function initialize(address gov_) external {
        require(gov == address(0), "MockJNS: already initialized");
        require(gov_ != address(0), "MockJNS: zero gov");
        gov = gov_;
        nextId = 1;
    }

    function owner() external view returns (address) { return gov; }

    function ownerOf(uint256 tid) public view returns (address) {
        address o = _owners[tid];
        require(o != address(0), "ERC721: nonexistent token");
        return o;
    }

    /// @dev 仅治理（多签）可铸；铸给 msg.sender 且默认绑定
    function claim(string calldata n) external returns (uint256 tid) {
        require(msg.sender == gov, "MockJNS: not owner");
        require(_nslookup[n] == 0, "MockJNS: name taken");
        tid = nextId;
        nextId = tid + 1;
        _nslookup[n] = tid;
        _owners[tid] = msg.sender;
        bound[tid] = true;
    }

    function unbind(uint256 tid) external {
        require(_owners[tid] == msg.sender, "MockJNS: not owner");
        bound[tid] = false;
    }

    function isApprovedForAll(address o, address op) external view returns (bool) {
        return _operators[o][op];
    }

    function setApprovalForAll(address op, bool ok) external {
        _operators[msg.sender][op] = ok;
    }

    function transferFrom(address from, address to, uint256 tid) external {
        require(_owners[tid] == from, "MockJNS: wrong from");
        require(to != address(0), "MockJNS: zero to");
        require(
            msg.sender == from || _approvals[tid] == msg.sender || _operators[from][msg.sender],
            "MockJNS: not authorized"
        );
        require(!bound[tid], "MockJNS: token is bound");
        _owners[tid] = to;
        delete _approvals[tid];
    }
}
