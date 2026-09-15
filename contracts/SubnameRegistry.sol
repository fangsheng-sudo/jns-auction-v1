// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./deps/Deps.sol";

/**
 * @title  SubnameRegistry —— JNS 子域名注册表（ERC-721 · 层级递归）
 * @notice 第三批交付 · 2026-09-14 · 只读核查版（未部署、未上链、未 commit）
 *
 * ── 关键设计 ─────────────────────────────────────────────────────
 *  独立部署的 ERC-721（不改 JNS 主合约；主域名仍由 JNS 持有）。
 *  层级：`label.parent` 递归 —— 父持有者可为自己的域名铸子域名；子域名持有者
 *        是否可再铸子子域名，由【父的 setCanMintSub 开关】决定。深度上限可配置。
 *  mintFee 1 WJ/个 → mintFeeRecipient，【即时型：每次读当前值，不快照】（【J-53 裁定】）。
 *  父控开关：setTransferable / setCanMintSub / renounceParentControl（v1 不设收回权）。
 *  父域名卖出后：子域名 NFT 独立存在，不受影响（本合约不联动主域名所有权）。
 */
contract SubnameRegistry is ReentrancyGuard, Ownable, ERC721Core {

    // ⚠️ 两常量尾部相似，务必区分：WJ …24203c6AD（小写 c）｜JNS …2035b89
    address public constant WJ_ADDRESS  = 0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD;
    address public constant JNS_ADDRESS = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;

    uint256 public constant ONE_WJ = 1e18;
    /// @dev 【J-53 裁定】label 改为【纯数字】。长度上限 19（可安全转 uint64；靓号价值在短号）
    uint256 public constant DIGITS_MAX_LEN = 19;
    uint256 public constant MAX_DEPTH_CEILING = 5;      // 深度硬上限（【J-53 裁定】8 → 5）
    uint256 public constant REASON_MAX_LEN = 200;

    /// @dev mintFee：1 WJ。【J-53 裁定】即时型，每次读当前值（不写快照）
    uint256 public mintFee = 1e18;
    /// @dev 费率上限保护（M2 同款思路）：上限 100 WJ
    uint256 public constant MINT_FEE_CAP = 100e18;
    address public mintFeeRecipient;
    /// @dev 深度上限（可配置，≤ MAX_DEPTH_CEILING）
    uint256 public maxDepth = MAX_DEPTH_CEILING;

    // ═══════════ 层级与父控 ═══════════
    struct Node {
        uint256 parentId;      // 父节点 tokenId；0 = 顶级子域名（父为主域名）
        string  label;         // 本段标签（不含父）
        string  fullName;      // 完整名称（留痕，便于链上校验/展示）
        uint8   depth;         // 层级深度（顶级子域名 = 1）
        address mainOwner;     // 主域名持有者快照（仅留痕）
        bool    transferable;  // 父控：是否可转让（默认 true）
        bool    canMintSub;    // 父控：是否允许其持有者再铸子子域名（默认 true）
        bool    parentControlled; // 是否仍受父控（renounceParentControl 后 = false）
        uint256 reserved;      // 【扩展位】为将来租期/到期字段预留（v1 恒为 0）
    }

    mapping(uint256 => Node) public nodes;
    /// @dev fullName hash → tokenId+1（0 = 未注册），防重复
    mapping(bytes32 => uint256) private _idOfName;
    uint256 public nextTokenId = 1;

    // ═══════════ 事件 ═══════════
    event SubnameMinted(uint256 indexed tokenId, uint256 indexed parentId, string label, string fullName, address indexed owner, uint8 depth, uint256 fee, uint256 ts);
    event MintFeeChanged(uint256 oldFee, uint256 newFee, uint256 ts);
    event MintFeeRecipientChanged(address indexed oldAddr, address indexed newAddr, uint256 ts);
    event MaxDepthChanged(uint256 oldD, uint256 newD, uint256 ts);
    event TransferableSet(uint256 indexed tokenId, bool ok, uint256 ts);
    event CanMintSubSet(uint256 indexed tokenId, bool ok, uint256 ts);
    event ParentControlRenounced(uint256 indexed tokenId, uint256 ts);

    constructor(address owner_, address mintFeeRecipient_) {
        require(mintFeeRecipient_ != address(0) && mintFeeRecipient_ != WJ_ADDRESS, "SR: bad fee recipient");
        mintFeeRecipient = mintFeeRecipient_;
        name = "JNS Subname";
        symbol = "JNSSUB";
        _transferOwnership(owner_);
    }

    // ═══════════ WJ 陷阱防护（唯一出口）═══════════
    function _wjSafeTransfer(address to, uint256 value) internal {
        require(to != address(0) && to != WJ_ADDRESS, "WJ trap: recipient must not be 0 or WJ");
        if (value == 0) { return; }
        SafeERC20.safeTransfer(IERC20(WJ_ADDRESS), to, value);
    }

    // ═══════════ 父控：传输限制钩子 ═══════════
    /// @dev transferable == false 即禁止转让（父控核心开关）
    function _beforeTokenTransfer(address from, address, uint256 tokenId) internal view override {
        if (from != address(0) && nodes[tokenId].parentControlled) {
            require(nodes[tokenId].transferable, "SR: parent control: not transferable");
        }
    }

    // ═══════════ 铸造（层级递归 + 权限校验）═══════════
    /**
     * @dev 权限矩阵：
     *      · parentId == 0（顶级子域名）⇒ 仅【主域名持有者】可铸（JNS.ownerOf(主域名tokenId) == msg.sender）
     *      · parentId != 0（子子域名）⇒ 仅【父节点持有者】可铸，且父节点 canMintSub == true
     *      全路径 depth ≤ maxDepth；label 合法（1..19 位【纯数字】，禁前导零；"0" 本身允许）。
     *      费用：即时型 mintFee（每次读当前值）→ mintFeeRecipient。
     */
    function mintSubname(
        uint256 mainTokenId,
        uint256 parentId,
        string calldata label,
        string calldata parentFullName
    ) external nonReentrant returns (uint256 tokenId) {
        require(_validLabel(label), "SR: bad label");

        uint8 depth;
        string memory fullName;

        if (parentId == 0) {
            // 顶级子域名：铸者必须是【主域名持有者】
            require(IJNS(JNS_ADDRESS).ownerOf(mainTokenId) == msg.sender, "SR: not main domain owner");
            // 【必修·防伪造】父全名必须真实挂在该 mainTokenId 上，否则可用自有 tokenId 配任意前缀
            //            铸出 a.google.j 之类看似属于他人的子域名，污染命名空间
            require(
                IJNS(JNS_ADDRESS)._nslookup(parentFullName) == mainTokenId,
                "SR: parentFullName does not match mainTokenId"
            );
            depth = 1;
            fullName = _join(label, parentFullName);
        } else {
            require(parentId < nextTokenId && nodes[parentId].depth > 0, "SR: no such parent");
            require(ownerOf(parentId) == msg.sender, "SR: not parent owner");       // 父持有者限定
            require(nodes[parentId].canMintSub, "SR: parent disallows sub minting"); // 父控开关
            depth = nodes[parentId].depth + 1;
            fullName = _join(label, nodes[parentId].fullName);
        }
        require(depth <= maxDepth, "SR: depth exceeds max");

        bytes32 key = keccak256(bytes(fullName));
        require(_idOfName[key] == 0, "SR: name already registered");

        uint256 fee = mintFee;   // 【即时型】读当前值，不快照
        tokenId = nextTokenId;
        nextTokenId = tokenId + 1;

        _idOfName[key] = tokenId + 1;
        nodes[tokenId] = Node({
            parentId: parentId,
            label: label,
            fullName: fullName,
            depth: depth,
            mainOwner: msg.sender,
            transferable: true,
            canMintSub: true,
            parentControlled: true,
            reserved: 0
        });

        _mint(msg.sender, tokenId);

        // 【铸造费收取】即时型：fee → mintFeeRecipient（经 WJ 陷阱防护）
        if (fee > 0) {
            SafeERC20.safeTransferFrom(IERC20(WJ_ADDRESS), msg.sender, address(this), fee);
            _wjSafeTransfer(mintFeeRecipient, fee);
        }

        emit SubnameMinted(tokenId, parentId, label, fullName, msg.sender, depth, fee, block.timestamp);
    }

    // ═══════════ 标签校验（【J-53 裁定】纯数字）═══════════
    /**
     * @dev 【J-53 裁定·安全第一】label 收窄为【纯数字】，与 JEEP-7「纯数字 = 免审查」对齐：
     *      ① 字符集仅 0x30-0x39（禁字母、禁连字符、禁空串）
     *      ② 禁前导零（"01"/"001" 非法），但 "0" 本身允许
     *         ← 关键：否则 "1"/"01"/"001" 是三个不同 NFT 而显示相似 ⇒ 钓鱼混淆风险
     *      ③ 长度 ≤ 19（可安全转 uint64）；靓号价值在短号
     *      ④ 由 ② 保证每个数值有唯一规范形式（数字 ↔ label 一一对应）
     *      原「敏感词风险由父持有者自担」声明随之移除（纯数字后风险源头消除）。
     */
    function _validLabel(string calldata label) internal pure returns (bool) {
        bytes calldata b = bytes(label);
        if (b.length == 0 || b.length > DIGITS_MAX_LEN) { return false; }
        if (b[0] == 0x30 && b.length > 1) { return false; }   // ② 禁前导零（"0" 本身允许）
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c < 0x30 || c > 0x39) { return false; }       // ① 仅 0-9
        }
        return true;                                          // ③④ 唯一规范形式
    }

    function _join(string calldata label, string memory parentFull) internal pure returns (string memory) {
        if (bytes(parentFull).length == 0) { return label; }
        return string(abi.encodePacked(label, ".", parentFull));
    }

    // ═══════════ 父控开关（仅该 token 持有者）═══════════
    function setTransferable(uint256 tokenId, bool ok) external {
        require(ownerOf(tokenId) == msg.sender, "SR: not owner");
        nodes[tokenId].transferable = ok;
        emit TransferableSet(tokenId, ok, block.timestamp);
    }

    function setCanMintSub(uint256 tokenId, bool ok) external {
        require(ownerOf(tokenId) == msg.sender, "SR: not owner");
        nodes[tokenId].canMintSub = ok;
        emit CanMintSubSet(tokenId, ok, block.timestamp);
    }

    /// @dev 永久放弃父控（此后该 token 不再受 transferable 限制）。v1 不设收回权。
    ///      【Q-B 裁定】自动置 transferable = true（父控解除即恢复自由转让，无需再手动开）。
    function renounceParentControl(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "SR: not owner");
        nodes[tokenId].parentControlled = false;
        nodes[tokenId].transferable = true;   // 父控解除 ⇒ 自动恢复可转让
        emit ParentControlRenounced(tokenId, block.timestamp);
    }

    // ═══════════ 治理（owner）═══════════
    function setMintFee(uint256 newFee) external onlyOwner {
        require(newFee <= MINT_FEE_CAP, "SR: fee above cap");
        emit MintFeeChanged(mintFee, newFee, block.timestamp);
        mintFee = newFee;
    }

    function setMintFeeRecipient(address newAddr) external onlyOwner {
        require(newAddr != address(0) && newAddr != WJ_ADDRESS, "SR: bad recipient");
        emit MintFeeRecipientChanged(mintFeeRecipient, newAddr, block.timestamp);
        mintFeeRecipient = newAddr;
    }

    function setMaxDepth(uint256 newDepth) external onlyOwner {
        require(newDepth >= 1 && newDepth <= MAX_DEPTH_CEILING, "SR: bad depth");
        emit MaxDepthChanged(maxDepth, newDepth, block.timestamp);
        maxDepth = newDepth;
    }

    // ═══════════ 只读 ═══════════
    /// @dev 按完整名称反查 tokenId（0 = 不存在）
    function tokenIdOfName(string calldata fullName) external view returns (uint256) {
        uint256 v = _idOfName[keccak256(bytes(fullName))];
        return v == 0 ? 0 : v - 1;
    }

    function fullNameOf(uint256 tokenId) external view returns (string memory) { return nodes[tokenId].fullName; }
    function depthOf(uint256 tokenId) external view returns (uint8) { return nodes[tokenId].depth; }
}
