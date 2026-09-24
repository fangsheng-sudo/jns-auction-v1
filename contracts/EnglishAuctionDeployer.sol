// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./EnglishAuction.sol";

interface IAuctionDeployer {
    function deploy(
        string calldata name_,
        uint256 durationHours_,
        uint256 startingPrice_,
        address applicant_,
        address beneficiary_,
        bytes32 reviewRef_,
        address owner_
    ) external returns (address);
}

/**
 * @title  EnglishAuctionDeployer —— 一级拍卖实例独立部署器
 * @notice 第一批交付 · 2026-09-24 · 只读核查版（未部署、未上链、未 commit）
 *
 * 目的：把 `new EnglishAuction(...)` 的创建码从 JNSAuctionFactory 剥离，
 *      使工厂 runtime 回到 EIP-170 上限（24,576 B）以内。
 *      工厂通过本部署器 `deploy(...)` 创建实例；创建码只在本合约内嵌一次。
 *
 * 权限：deploy() 仅工厂（onlyFactory）可调；factory 由部署方一次性 setFactory 绑定。
 * 实现：EnglishAuction 不改；不引入 delegatecall / assembly。
 */
contract EnglishAuctionDeployer is IAuctionDeployer {

    /// @dev 部署本部署器者（一次性 setFactory 的调用方）
    address public immutable owner;

    /// @dev 唯一可调用 deploy() 的工厂地址，一次性绑定
    address public factory;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwnerDeploy() {
        require(msg.sender == owner, "DEP: not owner");
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "DEP: not factory");
        _;
    }

    /// @dev 一次性绑定工厂地址；仅 owner 可调，且只可绑一次。
    function setFactory(address factory_) external onlyOwnerDeploy {
        require(factory == address(0), "DEP: already set");
        require(factory_ != address(0), "DEP: zero factory");
        factory = factory_;
    }

    /// @dev 部署并返回一个新的 EnglishAuction 实例；参数原样透传工厂。
    function deploy(
        string calldata name_,
        uint256 durationHours_,
        uint256 startingPrice_,
        address applicant_,
        address beneficiary_,
        bytes32 reviewRef_,
        address owner_
    ) external override onlyFactory returns (address) {
        EnglishAuction ea = new EnglishAuction(
            name_,
            durationHours_,
            startingPrice_,
            applicant_,
            beneficiary_,
            reviewRef_,
            owner_
        );
        return address(ea);
    }
}
