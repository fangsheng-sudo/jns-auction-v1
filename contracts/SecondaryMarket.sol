// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./deps/Deps.sol";

/**
 * @title  SecondaryMarket —— JNS 二级市场（挂拍即托管 · 英式竞价）
 * @notice 第二批交付 · 2026-09-14 · 只读核查版（未部署、未上链、未 commit）
 *
 * ── 关键设计 ─────────────────────────────────────────────────────
 *  挂拍即托管：`list()` 在本 tx 内 `JNS.transferFrom(卖家 → 本合约)`，NFT 立即入托管。
 *    ⚠️ 【链上查明】JNS 的 transferFrom/safeTransferFrom 带 requireUnbound，且 unbind 只有
 *       ownerOf 本人可调（合约不能代调）⇒ 卖家必须先自行发 1 笔 `JNS.unbind(tokenId)`，
 *       再调 `list()` 由本合约拉取 NFT。链上必然是【两笔交易】，两笔之间存在「抢转窗口」。
 *  成交即分账：`settle()` 从本合约【直接转 NFT 给赢家】，卖家无需再参与。
 *  费率：成交时读当前 `tradeFeeRate`（【J-53 裁定】采纳甲案，不快照）。
 *  不改 JNS 合约；所有对外 WJ 转账必经 `_wjSafeTransfer`。
 */
contract SecondaryMarket is ReentrancyGuard, Ownable {

    // ⚠️ 两常量尾部相似，务必区分：WJ …24203c6AD（小写 c）｜JNS …2035b89
    address public constant WJ_ADDRESS  = 0x7fba9BB966189Db8C4fE33B7bf67Bfa24203c6AD;
    address public constant JNS_ADDRESS = 0xf8AbF36Bb2dc525b1E566d6B42F6Fd1BB2035b89;

    uint256 public constant ONE_WJ = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEFAULT_TRADE_FEE_BPS = 150;      // 1.5%
    uint256 public constant MAX_TRADE_FEE_BPS = 500;          // 硬上限 5%

    uint256 public constant DEFAULT_DURATION = 168 hours;
    uint256 public constant MAX_DURATION = 192 hours;
    uint256 public constant EXTEND_WINDOW = 10 minutes;
    uint256 public constant EXTEND_STEP = 10 minutes;
    uint256 public constant REASON_MAX_LEN = 200;

    /// @dev 成交手续费费率（bps）。【J-53 裁定】成交时取当前值（不快照）
    uint256 public tradeFeeRate = DEFAULT_TRADE_FEE_BPS;
    /// @dev 手续费收款方（DAO 侧）
    address public tradeFeeRecipient;

    enum ListingState { None, Active, Settled, Cancelled }

    struct Listing {
        uint256 tokenId;
        address seller;
        uint256 startPrice;      // 单位 WJ
        uint256 startTime;
        uint256 endTime;
        address highestBidder;
        uint256 highestBid;
        ListingState state;
        uint256 feePaid;         // 结算时实际扣除的手续费（留痕）
    }

    Listing[] public listings;
    mapping(uint256 => mapping(address => uint256)) public pendingReturns;
    mapping(uint256 => bool) public tokenLocked;   // 防同一 NFT 重复挂拍

    event Listed(uint256 indexed listingId, uint256 indexed tokenId, address indexed seller, uint256 startPrice, uint256 endTime, uint256 ts);
    event BidPlaced(uint256 indexed listingId, address indexed bidder, uint256 amount, uint256 newEndTime, uint256 ts);
    event Outbid(uint256 indexed listingId, address indexed outbidder, uint256 refundAmount, uint256 ts);
    event Extended(uint256 indexed listingId, uint256 newEndTime, uint256 ts);
    event RefundWithdrawn(uint256 indexed listingId, address indexed user, uint256 amount, uint256 ts);
    event Settled(uint256 indexed listingId, address indexed winner, uint256 amount, uint256 fee, address indexed feeRecipient, uint256 sellerProceeds, uint256 ts);
    event ListingCancelled(uint256 indexed listingId, address indexed seller, uint256 ts);
    event TradeFeeRateChanged(uint256 oldBps, uint256 newBps, uint256 ts);
    event TradeFeeRecipientChanged(address indexed oldAddr, address indexed newAddr, uint256 ts);
    event NftReturnedToSeller(uint256 indexed listingId, uint256 indexed tokenId, address indexed seller, uint256 ts);

    constructor(address owner_, address tradeFeeRecipient_) {
        require(tradeFeeRecipient_ != address(0) && tradeFeeRecipient_ != WJ_ADDRESS, "SM: bad fee recipient");
        tradeFeeRecipient = tradeFeeRecipient_;
        _transferOwnership(owner_);
    }

    // ═══════════ WJ 陷阱防护（唯一出口）═══════════
    /// @dev WJ.transfer 的 to==0 或 to==WJ ⇒ 烧 WJ + 退 J 给 msg.sender（本合约）⇒ 永久损失
    function _wjSafeTransfer(address to, uint256 value) internal {
        require(to != address(0) && to != WJ_ADDRESS, "WJ trap: recipient must not be 0 or WJ");
        if (value == 0) { return; }
        SafeERC20.safeTransfer(IERC20(WJ_ADDRESS), to, value);
    }

    // ═══════════ 整数规则 + ceil 最小加价（与一级市场同规则）═══════════
    function _minIncrement(uint256 highestBid_) internal pure returns (uint256) {
        uint256 inc = highestBid_ * 5 / 100;
        uint256 r = inc % ONE_WJ;
        if (r != 0) { inc = (inc / ONE_WJ + 1) * ONE_WJ; }
        if (inc < ONE_WJ) { inc = ONE_WJ; }
        return inc;
    }

    function minIncrementOf(uint256 listingId) external view returns (uint256) {
        return _minIncrement(listings[listingId].highestBid);
    }

    /// @dev 首笔出价的下限 = 起拍价；已有出价时 = 当前最高价 + ceil(5%)
    function nextMinimumBid(uint256 listingId) public view returns (uint256) {
        Listing storage L = listings[listingId];
        if (L.highestBid == 0) { return L.startPrice; }
        return L.highestBid + _minIncrement(L.highestBid);
    }

    // ═══════════ 挂拍（同 tx 托管 NFT）═══════════
    /**
     * @dev 前置：卖家已自行 `JNS.unbind(tokenId)`，并授权本合约（setApprovalForAll 或 approve）。
     *      本 tx 内把 NFT 从卖家拉入本合约托管 ⇒ 「挂拍即托管」。
     */
    function list(uint256 tokenId, uint256 startPrice, uint256 durationHours) external nonReentrant returns (uint256 listingId) {
        require(!tokenLocked[tokenId], "SM: token already listed");
        require(startPrice >= ONE_WJ && startPrice % ONE_WJ == 0, "SM: startPrice must be integer >=1 WJ");
        require(durationHours > 0 && durationHours * 1 hours <= MAX_DURATION, "SM: bad duration");

        // 【挂拍即托管】NFT 必须无绑定（requireUnbound 由 JNS 侧强制）+ 拉入本合约
        IERC721(JNS_ADDRESS).transferFrom(msg.sender, address(this), tokenId);
        require(IERC721(JNS_ADDRESS).ownerOf(tokenId) == address(this), "SM: escrow failed");

        listings.push(Listing({
            tokenId: tokenId,
            seller: msg.sender,
            startPrice: startPrice,
            startTime: block.timestamp,
            endTime: block.timestamp + durationHours * 1 hours,
            highestBidder: address(0),   // 【必修】不得预置为卖家/起拍价：卖家挂拍未存钱
            highestBid: 0,               // 【必修】0 = 无人出价哨兵，settle 走「无人出价分支」
            state: ListingState.Active,
            feePaid: 0
        }));
        listingId = listings.length - 1;
        tokenLocked[tokenId] = true;

        emit Listed(listingId, tokenId, msg.sender, startPrice, listings[listingId].endTime, block.timestamp);
    }

    // ═══════════ 出价 ═══════════
    function bid(uint256 listingId, uint256 amount) external nonReentrant {
        Listing storage L = listings[listingId];
        require(L.state == ListingState.Active, "SM: not active");
        require(block.timestamp < L.endTime, "SM: ended");
        require(amount % ONE_WJ == 0, "SM: amount must be integer WJ");
        // 首笔出价下限 = 起拍价（highestBid==0 为哨兵，无需另加 minIncrement）
        require(amount >= nextMinimumBid(listingId), "SM: below minimum");

        SafeERC20.safeTransferFrom(IERC20(WJ_ADDRESS), msg.sender, address(this), amount);

        if (L.highestBidder != address(0) && L.highestBid > 0) {
            pendingReturns[listingId][L.highestBidder] += L.highestBid;
            emit Outbid(listingId, L.highestBidder, L.highestBid, block.timestamp);
        }
        L.highestBidder = msg.sender;
        L.highestBid = amount;

        if (L.endTime - block.timestamp <= EXTEND_WINDOW) {
            uint256 newEnd = L.endTime + EXTEND_STEP;
            uint256 cap = L.startTime + MAX_DURATION;
            if (newEnd > cap) { newEnd = cap; }
            if (newEnd > L.endTime) {
                L.endTime = newEnd;
                emit Extended(listingId, newEnd, block.timestamp);
            }
        }
        emit BidPlaced(listingId, msg.sender, amount, L.endTime, block.timestamp);
    }

    // ═══════════ 成交分账（任何人可触发）═══════════
    /**
     * @dev 分账顺序（CEI：先更状态、后转账）：
     *      ① fee = floor(highestBid × tradeFeeRate / 10000)  ← 【裁定】成交时读当前费率
     *      ② sellerProceeds = highestBid − fee
     *      ③ NFT：本合约 → highestBidder（卖家无需参与）
     *      ④ WJ：fee → tradeFeeRecipient；sellerProceeds → seller（均经 _wjSafeTransfer）
     */
    function settle(uint256 listingId) external nonReentrant {
        Listing storage L = listings[listingId];
        require(L.state == ListingState.Active, "SM: not active");
        require(block.timestamp >= L.endTime, "SM: not ended");

        // 【必修】无人出价分支：绝不进入分账逻辑，避免动用不存在/他人资金（幽灵资金）
        if (L.highestBid == 0) {
            L.state = ListingState.Settled;
            tokenLocked[L.tokenId] = false;
            IERC721(JNS_ADDRESS).transferFrom(address(this), L.seller, L.tokenId);
            emit Settled(listingId, L.seller, 0, 0, tradeFeeRecipient, 0, block.timestamp);
            return;
        }

        uint256 amount = L.highestBid;
        uint256 fee = amount * tradeFeeRate / BPS_DENOMINATOR;      // 成交时取当前费率
        uint256 proceeds = amount - fee;

        L.state = ListingState.Settled;
        L.feePaid = fee;
        tokenLocked[L.tokenId] = false;

        // ② NFT 直转赢家
        address winner = L.highestBidder;
        IERC721(JNS_ADDRESS).transferFrom(address(this), winner, L.tokenId);

        // ③ 分账
        _wjSafeTransfer(tradeFeeRecipient, fee);
        _wjSafeTransfer(L.seller, proceeds);

        emit Settled(listingId, winner, amount, fee, tradeFeeRecipient, proceeds, block.timestamp);
    }

    // ═══════════ 下架（卖家，仅无人加价时）═══════════
    /// @dev 已有加价 ⇒ 须等 settle；无加价 ⇒ 卖家可撤回 NFT，出价全部走 pull 退款
    function cancelListing(uint256 listingId) external nonReentrant {
        Listing storage L = listings[listingId];
        require(L.state == ListingState.Active, "SM: not active");
        require(msg.sender == L.seller, "SM: only seller");
        require(L.highestBidder == address(0), "SM: has bids, wait settle");

        L.state = ListingState.Cancelled;
        tokenLocked[L.tokenId] = false;

        IERC721(JNS_ADDRESS).transferFrom(address(this), L.seller, L.tokenId);
        emit NftReturnedToSeller(listingId, L.tokenId, L.seller, block.timestamp);
        emit ListingCancelled(listingId, L.seller, block.timestamp);
    }

    // ═══════════ 退款（pull）═══════════
    function withdrawRefund(uint256 listingId) external nonReentrant {
        uint256 amount = pendingReturns[listingId][msg.sender];
        require(amount > 0, "SM: nothing to refund");
        pendingReturns[listingId][msg.sender] = 0;
        _wjSafeTransfer(msg.sender, amount);
        emit RefundWithdrawn(listingId, msg.sender, amount, block.timestamp);
    }

    // ═══════════ 治理（owner）═══════════
    function setTradeFeeRate(uint256 newBps) external onlyOwner {
        require(newBps <= MAX_TRADE_FEE_BPS, "SM: rate above cap");
        emit TradeFeeRateChanged(tradeFeeRate, newBps, block.timestamp);
        tradeFeeRate = newBps;
    }

    function setTradeFeeRecipient(address newAddr) external onlyOwner {
        require(newAddr != address(0) && newAddr != WJ_ADDRESS, "SM: bad recipient");
        emit TradeFeeRecipientChanged(tradeFeeRecipient, newAddr, block.timestamp);
        tradeFeeRecipient = newAddr;
    }

    // ═══════════ 只读 ═══════════
    function listingCount() external view returns (uint256) { return listings.length; }
}
