// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

/**
 * @title  Deps —— 本批合约的最小自包含依赖 + JNS 接口 + developer 角色
 *
 * 说明：以下组件与 OpenZeppelin 同名组件【接口一致、行为等价】，自带是为了让本批交付
 *       【在离线环境也能直接编译】，并与链上既有合约的 solc 0.8.0 / evmVersion=istanbul 对齐。
 *       若目标仓库已安装 openzeppelin-contracts 4.x，可把下面 4 个组件的实现整体替换为
 *       OZ 同名文件，两个业务合约源码【无需改动】（API 完全一致）。
 */

// ─────────────────────────────────────────────────────────────
// 1. IERC20
// ─────────────────────────────────────────────────────────────
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// ─────────────────────────────────────────────────────────────
// 2. SafeERC20
// ─────────────────────────────────────────────────────────────
library SafeERC20 {
    /// @dev 标准语义（失败即 revert）。批量扣费场景需另用「不 revert」变体，见 NotificationService（第 4 批）。
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /// @dev 【不 revert】变体：供批量结算逐笔 try/catch 使用（失败不整批回滚）。
    /// @return ok 调用成功且（若返回数据）解码为 true
    function trySafeTransferFrom(IERC20 token, address from, address to, uint256 value) internal returns (bool ok) {
        (bool callOk, bytes memory ret) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, value)
        );
        if (!callOk) { return false; }
        if (ret.length == 0) { return true; }
        if (ret.length < 32) { return false; }
        return abi.decode(ret, (bool));
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool ok, bytes memory ret) = address(token).call(data);
        require(ok, "SafeERC20: low-level call failed");
        if (ret.length > 0) {
            require(ret.length >= 32 && abi.decode(ret, (bool)), "SafeERC20: ERC20 op failed");
        }
    }
}

// ─────────────────────────────────────────────────────────────
// 3. Ownable
// ─────────────────────────────────────────────────────────────
abstract contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _owner = msg.sender;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function _transferOwnership(address newOwner) internal {
        require(newOwner != address(0), "Ownable: new owner is zero");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        _transferOwnership(newOwner);
    }

    /// @dev 【P2-4 裁定·全局覆写禁用】拍卖系统需持续治理：owner 一旦弃权，
    ///      费率/收款方/审核人/超时窗口等参数将【永久不可调】，且合约不可升级 ⇒ 无法补救。
    ///      若将来确需「冻结」，请把 owner 转给黑洞地址（如 0x…dEaD），
    ///      以保留“可审计地转移”这一可控路径，而不是直接弃权。
    function renounceOwnership() public view onlyOwner {
        revert("Ownable: renounce disabled");
    }
}

// ─────────────────────────────────────────────────────────────
// 4. ReentrancyGuard
// ─────────────────────────────────────────────────────────────
abstract contract ReentrancyGuard {
    uint256 private _status = 1;

    modifier nonReentrant() {
        require(_status == 1, "ReentrancyGuard: reentrant call");
        _status = 2;
        _;
        _status = 1;
    }
}

// ─────────────────────────────────────────────────────────────
// 5. IJNS —— 只读接口（用于 releaseToDAO 的链上铸造校验）
//    选择器已实测：_nslookup(string)=0x54cf09e1、ownerOf(uint256)=0x6352211e
// ─────────────────────────────────────────────────────────────
interface IJNS {
    /// @dev JNS 内为 `mapping(string => uint256) public _nslookup`，其自动 getter。
    ///      实测：不存在的 name 返回 0（**不 revert**）；tokenId 从 1 起算，0 永不出现。
    function _nslookup(string calldata name) external view returns (uint256);

    function ownerOf(uint256 tokenId) external view returns (address);

    /// @dev JNS 自身 owner（链上实测为 3/2 多签 0x4eF5…C1B3），选择器 0x8da5cb5b
    function owner() external view returns (address);
}

// ─────────────────────────────────────────────────────────────
// 5b. IERC721 —— 只声明「无返回值」形态（OZ 4.x）。若目标 JNS 为 OZ 3.x（返回 bool），
//     多余返回数据会被忽略，同样安全；反向声明才会 decode 失败。
// ─────────────────────────────────────────────────────────────
interface IERC721 {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function getApproved(uint256 tokenId) external view returns (address);
}

// ─────────────────────────────────────────────────────────────
// 5c. IERC721Receiver + ERC721Core（第三批 SubnameRegistry 用）
//     与 OZ 4.x 同名组件【接口一致、行为等价】的最小实现；若仓库已装 OZ，可整体替换。
// ─────────────────────────────────────────────────────────────
interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external returns (bytes4);
}

abstract contract ERC721Core {
    string public name;
    string public symbol;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function ownerOf(uint256 tokenId) public view virtual returns (address) {
        address o = _owners[tokenId];
        require(o != address(0), "ERC721: nonexistent token");
        return o;
    }

    function balanceOf(address acc) public view returns (uint256) {
        require(acc != address(0), "ERC721: zero address");
        return _balances[acc];
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        require(_owners[tokenId] != address(0), "ERC721: nonexistent token");
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address acc, address operator) public view returns (bool) {
        return _operatorApprovals[acc][operator];
    }

    function approve(address to, uint256 tokenId) public {
        address o = ownerOf(tokenId);
        require(msg.sender == o || _operatorApprovals[o][msg.sender], "ERC721: not authorized");
        _tokenApprovals[tokenId] = to;
        emit Approval(o, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) public {
        require(operator != msg.sender, "ERC721: self approval");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public virtual {
        require(_isApprovedOrOwner(msg.sender, tokenId), "ERC721: not authorized");
        require(_owners[tokenId] == from, "ERC721: wrong from");
        _beforeTokenTransfer(from, to, tokenId);
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public virtual {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) public virtual {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, data);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address o = ownerOf(tokenId);
        return spender == o || spender == _tokenApprovals[tokenId] || _operatorApprovals[o][spender];
    }

    function _mint(address to, uint256 tokenId) internal {
        require(to != address(0), "ERC721: mint to zero");
        require(_owners[tokenId] == address(0), "ERC721: token exists");
        _beforeTokenTransfer(address(0), to, tokenId);
        _balances[to] += 1;
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function _safeMint(address to, uint256 tokenId, bytes memory data) internal {
        _mint(to, tokenId);
        _checkOnERC721Received(address(0), to, tokenId, data);
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        require(_owners[tokenId] == from, "ERC721: wrong from");
        require(to != address(0), "ERC721: transfer to zero");
        delete _tokenApprovals[tokenId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) private {
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 ret) {
                require(ret == IERC721Receiver.onERC721Received.selector, "ERC721: bad receiver");
            } catch {
                revert("ERC721: transfer to non receiver");
            }
        }
    }

    /// @dev 子类钩子：父控传输限制在此拦截
    function _beforeTokenTransfer(address, address, uint256) internal view virtual {}
}

// ─────────────────────────────────────────────────────────────
// 6. DeveloperRole —— 【J-53 裁定】developer 变更权【仅当前 developer 自转让】
//
//   语义：**沉默 = 否决**（而非“沉默 = 同意”）。
//   · owner/多签【无法发起】更换（proposeDeveloper 恒 revert）
//   · 唯一入口 = 当前 developer 自调 transferDeveloperRole
//   · Timelock 语义为【未确认即不生效】：到期未由被提名人主动确认 ⇒ 【作废】
//     （绝不“到期自动生效”）；且延迟期内原 developer 可 cancelDeveloperTransfer
// ─────────────────────────────────────────────────────────────
abstract contract DeveloperRole is Ownable {
    address public developer;
    address public pendingDeveloper;
    uint256 public developerEffectiveAt;   // 最早可确认时间
    uint256 public developerExpiryAt;      // 确认窗口截止（逾期作废）

    /// @dev 发起→可确认 的最短延迟（J-53 反悔窗口）
    uint256 public constant DEVELOPER_DELAY = 7 days;
    /// @dev 可确认窗口长度。到期未确认 ⇒ 转让【自动作废】
    uint256 public constant DEVELOPER_CONFIRM_WINDOW = 7 days;

    event DeveloperTransferProposed(
        address indexed current,
        address indexed candidate,
        uint256 effectiveAt,
        uint256 expiryAt,
        uint256 ts
    );
    event DeveloperTransferCancelled(address indexed current, address indexed candidate, uint256 ts);
    event DeveloperChanged(address indexed oldDev, address indexed newDev, uint256 ts);

    modifier onlyDeveloper() {
        require(msg.sender == developer, "Not developer");
        _;
    }

    /// @dev 【已停用】原 owner 可发起通道 ⇒ 现恒 revert。
    ///      保留函数体仅为让“多签试图更换 developer”得到一个【明确、可测】的拒绝，
    ///      避免静默失败或误以为可走旧路径。
    function proposeDeveloper(address) external pure {
        revert("DEV: owner cannot change developer");
    }

    /// @dev 【已停用】旧 veto 通道（新语义下无需否决：未确认即不生效）。
    function vetoDeveloper() external pure {
        revert("DEV: use cancelDeveloperTransfer");
    }

    /// @dev 【已停用】旧 accept 通道（改名以避免与自转让流程混淆）。
    function acceptDeveloper() external pure {
        revert("DEV: use acceptDeveloperRole");
    }

    /**
     * @dev 【唯一入口】当前 developer 主动自转让。两步确认：
     *      ① 本函数（当前 developer 的肯定性动作）
     *      ② 延迟满后由【被提名人】主动 acceptDeveloperRole（第二重确认）
     *      任一缺失 ⇒ 不生效。
     */
    function transferDeveloperRole(address newDeveloper) external onlyDeveloper {
        require(newDeveloper != address(0), "DEV: zero candidate");
        require(newDeveloper != developer, "DEV: already developer");
        pendingDeveloper = newDeveloper;
        developerEffectiveAt = block.timestamp + DEVELOPER_DELAY;
        developerExpiryAt = developerEffectiveAt + DEVELOPER_CONFIRM_WINDOW;
        emit DeveloperTransferProposed(
            developer, newDeveloper, developerEffectiveAt, developerExpiryAt, block.timestamp
        );
    }

    /// @dev 仅当前 developer：延迟期内（或到期后）撤回转让 ⇒ 到期【不生效】。
    function cancelDeveloperTransfer() external onlyDeveloper {
        require(pendingDeveloper != address(0), "DEV: nothing pending");
        emit DeveloperTransferCancelled(developer, pendingDeveloper, block.timestamp);
        _clearPending();
    }

    /// @dev 仅被提名人，且须落在 [effectiveAt, expiryAt] 窗口内；越窗 ⇒ revert（不作废重试）。
    function acceptDeveloperRole() external {
        require(msg.sender == pendingDeveloper, "DEV: not nominee");
        require(developerEffectiveAt != 0 && block.timestamp >= developerEffectiveAt, "DEV: timelock");
        require(block.timestamp <= developerExpiryAt, "DEV: transfer expired");
        emit DeveloperChanged(developer, pendingDeveloper, block.timestamp);
        developer = pendingDeveloper;
        _clearPending();
    }

    /// @dev 待转让是否仍在有效窗口内（只读，便于链下监控与告警）。
    function pendingTransferActive() external view returns (bool) {
        return pendingDeveloper != address(0)
            && developerEffectiveAt != 0
            && block.timestamp <= developerExpiryAt;
    }

    function _clearPending() internal {
        pendingDeveloper = address(0);
        developerEffectiveAt = 0;
        developerExpiryAt = 0;
    }

    /// @dev 仅供子类构造函数初始化首位 developer。
    function _initDeveloper(address dev_) internal {
        developer = dev_;
        emit DeveloperChanged(address(0), dev_, block.timestamp);
    }
}
