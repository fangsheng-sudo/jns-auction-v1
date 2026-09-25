![CI](https://github.com/fangsheng-sudo/jns-auction-v1/actions/workflows/ci.yml/badge.svg)
# JNS 域名链上自动拍卖系统

> **一句话定位**：把 JNS 主域名发放，从「人工夜拍专场」升级为 **链上无人主持、自动竞价、自动结算、全程留痕** 的公开系统。

> **提交 J-25 审查用**｜提交人：J-53（@fangsheng-sudo）

## ⚠️ 声明

**本项目仅提交审查，尚未部署；合约不可升级，审查通过前不部署。**

**硬前提**：本系统假设 WJ 为标准 ERC20（18 位整数、无转账税、无 rebasing、无回调）；WJ 若变更特性，须重新审计。

## 文档导航

| 你想了解 | 看这里 |
|---|---|
| **审查入口（自包含，先看这个）** | [`审查材料-J25.md`](审查材料-J25.md)（§0~§9） |
| 这是什么 / 当前状态 | 本页 → [这是什么](#这是什么) · [当前状态](#当前状态) |
| 设计、权限矩阵、状态机 | [`设计说明.md`](设计说明.md) · [`docs/架构说明.md`](docs/架构说明.md) |
| 部署步骤与多签动作 | [`部署与多签执行清单.md`](部署与多签执行清单.md) · [`docs/部署说明.md`](docs/部署说明.md) |
| 风险与安全 | [`风险清单.md`](风险清单.md) · [`域名系统安全自查报告.md`](域名系统安全自查报告.md) · [`docs/安全自查摘要.md`](docs/安全自查摘要.md) |
| 费用 / gas 实测 | [`gas表.md`](gas表.md) |
| 试点（主网小规模预演） | [`金丝雀试点方案.md`](金丝雀试点方案.md) · [`金丝雀试点执行手册.md`](金丝雀试点执行手册.md) |
| 中止与回退 | [`中止预案.md`](中止预案.md) |
| 依赖来源与可复现构建 | [`docs/依赖与可复现构建.md`](docs/依赖与可复现构建.md) |
| 全部文档索引 | [`docs/README.md`](docs/README.md) |

> **阅读顺序建议**：先读 [`审查材料-J25.md`](审查材料-J25.md)（自包含，§0~§9），再按需要下钻本页「目录」列出的各专项文档。

## 这是什么

把 JNS（Jouleverse Name Service）主域名发放，从「**人工夜拍专场**」升级为
**链上无人主持、自动竞拍、自动结算**；审核留痕由 GitHub 升级为链上。

四个模块：

| 模块 | 合约 | 说明 |
|---|---|---|
| ① 一级拍卖 | `EnglishAuction` + `JNSAuctionFactory` | 申请 → 链上审核 → 自动拍卖(168h) → 结算 → 多签铸造 |
| ② 二级市场 | `SecondaryMarket` | NFT 挂单 → 竞价 → 成交(1.5% 手续费) |
| ③ 子域名 | `SubnameRegistry` | ERC-721；**纯数字 label**（禁前导零、≤19 位）；深度上限 **5**；1 WJ 铸造费 |
| ④ 提醒服务 | `NotificationService` | **v1 不启用**（`perUseFee = 0`，休眠），为将来预留 |

## 当前状态

- **测试：18 suites / 211 passed / 0 failed**（原 161 + 分支补测新增 50）
- **合约数：7**（EnglishAuction / EnglishAuctionDeployer / JNSAuctionFactory / SecondaryMarket / SubnameRegistry / ClaimRegistry / NotificationService，`deps/Deps.sol` 为依赖层）
- **体积：** EnglishAuction 11,827 / EnglishAuctionDeployer 14,783 / JNSAuctionFactory 12,220
- **编译：solc 0.8.0 / istanbul / optimizer 200 ⇒ 0 warning / 0 error / 0 stack-too-deep**
- **链：** chainId 3666（Jouleverse 主网）；须 `--evm-version istanbul`（PUSH0 不可用）
- **计价：** 全系统 WJ，J 仅作 gas
- **权限：** 五处 owner 均为 JNS DAO 多签 `0x4eF599b6E39D950D6Ddbd830fF5f95e06770C1B3`（2/3）
- **部署者：** 仅承担 gas，**不获得任何权限**（owner 由 constructor 硬编码为多签，**不经 EOA 移交**）
- **developer：** v1 休眠；变更权仅其本人（`transferDeveloperRole` 自转让 ⇒ 沉默 = 否决）

## 目录

```
contracts/        四批合约 + Deps（依赖层）
script/           Deploy.s.sol（部署）/ SetterCalldata.s.sol（calldata 生成）
test/             18 suites（含 mock：MockWJ / MockJNS）
审查材料-J25.md    ← 主交付物（§0~§9，自包含）
设计说明.md        设计说明 + 权限矩阵 + 状态机
风险清单.md        残余风险与缓解
gas表.md           gas 实测（含口径更正说明）
部署与多签执行清单.md   部署步骤与多签动作
多签执行calldata.txt   多签 calldata 包
金丝雀试点方案.md / 金丝雀试点执行手册.md   试点方案
中止预案.md        中止与回退预案
提交正文-Issue.md  Issue 提交正文
docs/              展开版文档（架构 / 部署 / 安全摘要 / 依赖与可复现构建）
```

## 环境

- Foundry（`forge`）；`solc 0.8.0`（`auto_detect_solc = false`）
- 无测试网 ⇒ 仅本地 EVM 验证；JNS DAO 官方 RPC（授权端点，部署时配置）
- 部署时通过 `--rpc-url` 指定 Jouleverse 主网 RPC（chainId **3666**）
- 命令示例中的 `$JNS_DAO_RPC_URL` 为环境变量占位，部署时按授权端点填入

## 运行测试

```bash
# ① 主套件（含分支补测 TestBranchCoverage.t.sol）：211 passed / 0 failed（18 suites）
forge test

# ② 审计测试（不变量 + A1/A2/A3 + rescueStuckNft 交叉验证，独立 Foundry 工程）
cd audit-tests && forge test
```

> `audit-tests/` 为独立工程（自带 `foundry.toml`，`contracts` 为指向 `../contracts` 的只读符号链接），与主套件互不干扰。

## 许可

MIT
