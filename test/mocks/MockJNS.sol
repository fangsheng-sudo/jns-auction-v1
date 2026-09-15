// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "../../contracts/deps/Deps.sol";

/**
 * @title MockJNS —— 复刻 JNS 关键行为（ERC721 + _nslookup + claim + CSBT bind/unbind）
 * @notice 测试用 mock，不部署上链。
 *
 * 复刻要点（均对照链上实测）：
 *  · `_nslookup(string)` 为 `mapping(string=>uint256) public` 的自动 getter ⇒ 不存在的 name 返回 0、不 revert
 *  · `claim(name)` 仅 owner，`_safeMint(msg.sender)`，tokenId 从 1 递增
 *  · CSBT：已绑定（bound）的 token 不可 transfer ⇒ transferFrom 带 requireUnbound
 *  · `owner()` 返回合约 owner（真实 JNS 为 3/2 多签）
 */
contract MockJNS is ERC721Core, Ownable {

    mapping(string => uint256) public _nslookup;      // name → tokenId（缺失返回 0）
    mapping(uint256 => bool) public bound;            // CSBT 绑定标志
    mapping(uint256 => string) private _nameOf;
    uint256 public nextId = 1;

    event Claimed(string name, uint256 tokenId, address to);
    event Bound(uint256 tokenId);
    event Unbound(uint256 tokenId);

    constructor(address owner_) {
        name = "J Name Service";
        symbol = "JNS";
        _transferOwnership(owner_);
    }

    /// @dev etch 部署不跑构造函数 ⇒ 内联初始值全部丢失，必须在此补齐
    function initialize(address owner_) external {
        require(owner() == address(0), "JNS: already init");
        name = "J Name Service";
        symbol = "JNS";
        nextId = 1;                       // 关键：tokenId 从 1 起，0 保留为哨兵
        _transferOwnership(owner_);
    }

    /// @dev claim：仅 owner（真实 JNS 为多签），_safeMint(msg.sender)，tokenId 从 1 起
    function claim(string calldata n) external onlyOwner returns (uint256 tokenId) {
        require(_nslookup[n] == 0, "JNS: name taken");
        tokenId = nextId;
        nextId = tokenId + 1;
        _nslookup[n] = tokenId;
        _nameOf[tokenId] = n;
        _safeMint(msg.sender, tokenId, "");
        bound[tokenId] = true;                        // 先铸给多签并绑定
        emit Claimed(n, tokenId, msg.sender);
    }

    /// @dev 便捷重载：owner 铸给任意地址（测试用）
    function claimTo(string calldata n, address to) external onlyOwner returns (uint256 tokenId) {
        require(_nslookup[n] == 0, "JNS: name taken");
        tokenId = nextId;
        nextId = tokenId + 1;
        _nslookup[n] = tokenId;
        _nameOf[tokenId] = n;
        _safeMint(to, tokenId, "");
        bound[tokenId] = true;
        emit Claimed(n, tokenId, to);
    }

    function bind(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "JNS: not owner");
        bound[tokenId] = true;
        emit Bound(tokenId);
    }

    /// @dev unbind：仅 ownerOf 本人可调（合约不能代调）——真实 JNS 硬约束
    function unbind(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "JNS: not owner");
        bound[tokenId] = false;
        emit Unbound(tokenId);
    }

    /// @dev CSBT：已绑定不可转让
    function _beforeTokenTransfer(address from, address, uint256 tokenId) internal view override {
        if (from != address(0)) {
            require(!bound[tokenId], "JNS: token is bound");
        }
    }

    function tokenName(uint256 tokenId) external view returns (string memory) { return _nameOf[tokenId]; }
}
