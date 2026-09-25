# JNS 拍卖 EnglishAuction 盲审测试（永久保留目录）

- 本目录 `audit-tests/` 为仓库内的独立 Foundry 工程（自带 `foundry.toml`），**永久保留**。
- 被测合约 `../contracts/EnglishAuction.sol` **零改动**（`contracts` 为指向 `../contracts` 的只读符号链接）。
- 两个 mock（`test/mocks/MockWJ.sol`、`test/mocks/MockJNS.sol`）为本盲审独立编写，
  经 `vm.etch` 挂到被测合约内硬编码的 WJ / JNS 常量地址，不侵入被测仓库。
- 复刻的链上关键语义：WJ 陷阱（to==0 或 WJ 自身 ⇒ 烧毁+困住原生 J）、
  JNS `_nslookup` 不存在返回 0 不 revert、tokenId 从 1 起、claim 仅 owner、CSBT 绑定不可转。

## 运行

```bash
cd audit-tests && forge test -vvv
```

## 测试 ↔ 审计发现对照

| 测试 | 发现（对应风险清单条目） | 断言的 revert 串 |
|---|---|---|
| `testA1_winnerDumpsNftThenTimeoutRefund` | **R9-d 双花面**：多签违规直转 NFT 给赢家（绕过 `settleDelivery`），赢家 `transferFrom` 甩给第二钱包后，`curOwner != highestBidder` ⇒ 恰 45 天 `claimTimeoutRefund` 放行退款。赢家拿回全部货款、NFT 留在第二钱包、DAO 分文未得。需「多签违规 + 赢家恶意」双条件同时成立 | `EA: unexpected owner`（DAO 出口被白名单挡死）／`EA: timeout window not reached`（差 1 秒仍挡）／`EA: not in escrow`（退款后 DAO 出口关死） |
| `testA2_misroutedNftEmergencyCancelNeverTerminal` | **误入 NFT + settle 前 emergencyCancel ⇒ escrow 永停 None（终态不可达）**：settle 被 `cancelled` 永久挡死，其余出口全部 `not in escrow`；资金可 pull 退款、NFT 却无任何出口 ⇒ 资金/资产可恢复性不对称 | `EA: not terminal`（returnNftToGovernance 被挡）＋ 佐证串：`EA: cancelled`／`EA: not in escrow` ×3 |
| `testA3_foreignNameNftPermanentlyLocked` | **非本场 name 的 NFT 误入 ⇒ 无任何出口、永久锁死**：合约只能按本场 name 查 tokenId，外名 NFT 既不满足「已铸本场名」也不满足「本场 NFT 在本合约」 | `EA: not minted`（本场名未铸，Refunded 终态）／`EA: no NFT held`（本场名已铸在赢家手，Released 终态）＋ 佐证串：`MockJNS: not authorized`（治理方无授权也拉不走） |

## 关键技术点

- `vm.etch` 不执行构造函数 ⇒ `MockJNS.initialize()` 补 `gov` / `nextId = 1`。
- 拍卖用直建方式（`new EnglishAuction(...)` + 手工 `wj.transfer` 复刻工厂同 tx 拉起拍价），
  与工厂路径账面等价，且不依赖工厂合约。
- 所有 WJ 出口断言 `trappedAmount() == 0`：WJ 陷阱防护（`_wjSafeTransfer`）不得失效。
- revert 串均为 `vm.expectRevert(bytes(...))` **精确匹配**（区别于 `expectRevert()` 泛匹配）。

## 结果（2026-09-26）

```
Ran 3 test suites: 11 passed / 0 failed / 0 skipped
  · AuditBlind（A1/A2/A3）       3 passed
  · RescueNft（A2/A3 修复验证）  6 passed
  · Invariant（INV-1/2/3b/4/5）  2 passed
```
