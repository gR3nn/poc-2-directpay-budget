// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/* ---------------------------------------------------------------------------
   Standalone audit harness for the Morpheus/Lumerin inference diamond on Base.
   No external dependencies: minimal Vm cheatcode interface + minimal ABI.

   Target : 0x6aBE1d282f72B474E54527D93b979A4f64d3030a  (EIP-2535 diamond)
   Fork   : Base mainnet, block 56140891 (pinned in setUp)
   Actors : attacker-controlled EOAs only (vm.prank on self-derived keys).
            No prank is ever applied to owner / admin / multisig.
   --------------------------------------------------------------------------- */

interface Vm {
    struct Log { bytes32[] topics; bytes data; address emitter; }
    function createSelectFork(string calldata url, uint256 blockNumber) external returns (uint256);
    function deal(address who, uint256 amount) external;
    function warp(uint256 newTimestamp) external;
    function roll(uint256 newHeight) external;
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function expectRevert() external;
    function expectRevert(bytes calldata revertData) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function store(address target, bytes32 slot, bytes32 value) external;
    function load(address target, bytes32 slot) external view returns (bytes32);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external returns (address);
    function label(address account, string calldata newLabel) external;
    function envOr(string calldata name, string calldata defaultValue) external returns (string memory);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IDiamond {
    struct Pool { uint256 initialReward; uint256 rewardDecrease; uint128 payoutStart; uint128 decreaseInterval; }
    struct Bid { address provider; bytes32 modelId; uint256 pricePerSecond; uint256 nonce; uint128 createdAt; uint128 deletedAt; }
    struct Provider { string endpoint; uint256 stake; uint128 createdAt; uint128 limitPeriodEnd; uint256 limitPeriodEarned; bool isDeleted; }
    struct Model {
        bytes32 ipfsCID; uint256 fee; uint256 stake; address owner;
        string name; string[] tags; uint128 createdAt; bool isDeleted;
    }
    struct Session {
        address user; bytes32 bidId; uint256 stake; bytes closeoutReceipt; uint256 closeoutType;
        uint256 providerWithdrawnAmount; uint128 openedAt; uint128 endsAt; uint128 closedAt;
        bool isActive; bool isDirectPaymentFromUser;
    }

    // views
    function getToken() external view returns (address);
    function getFundingAccount() external view returns (address);
    function getProviderMinimumStake() external view returns (uint256);
    function getModelMinimumStake() external view returns (uint256);
    function getBidFee() external view returns (uint256);
    function getMinMaxBidPricePerSecond() external view returns (uint256, uint256);
    function getMaxSessionDuration() external view returns (uint128);
    function getProvidersTotalClaimed() external view returns (uint256);
    function getFeeBalance() external view returns (uint256);
    function getComputeBalance(uint128) external view returns (uint256);
    function totalMORSupply(uint128) external view returns (uint256);
    function stakeToStipend(uint256, uint128) external view returns (uint256);
    function stipendToStake(uint256, uint128) external view returns (uint256);
    function startOfTheDay(uint128) external pure returns (uint128);
    function getBid(bytes32) external view returns (Bid memory);
    function getProvider(address) external view returns (Provider memory);
    function getModel(bytes32) external view returns (Model memory);
    function getSession(bytes32) external view returns (Session memory);
    function isBidActive(bytes32) external view returns (bool);
    function getModelId(address, bytes32) external pure returns (bytes32);
    function getBidId(address, bytes32, uint256) external pure returns (bytes32);
    function getSessionId(address, address, bytes32, uint256) external pure returns (bytes32);
    function getUserStakesOnHold(address, uint8) external view returns (uint256, uint256);
    function getTotalSessions(address) external view returns (uint256);
    function owner() external view returns (address);

    // state changing
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function providerDeregister(address provider_) external;
    function modelRegister(address, bytes32, bytes32, uint256, uint256, string calldata, string[] calldata) external;
    function modelDeregister(bytes32) external;
    function postModelBid(address, bytes32, uint256) external returns (bytes32);
    function deleteModelBid(bytes32) external;
    function openSession(address, uint256, bool, bytes calldata, bytes calldata) external returns (bytes32);
    function closeSession(bytes calldata, bytes calldata) external;
    function claimForProvider(bytes32) external;
    function withdrawUserStakes(address, uint8) external;

    // admin (must be unreachable for an unprivileged EOA)
    function setPoolConfig(uint256, Pool calldata) external;
    function setMaxSessionDuration(uint128) external;
    function withdrawFee(address, uint256) external;
    function setMarketplaceBidFee(uint256) external;
    function setMinMaxBidPricePerSecond(uint256, uint256) external;
    function providerSetMinStake(uint256) external;
    function modelSetMinStake(uint256) external;
    function setRegistry(address) external;
    function __Marketplace_init(address, uint256, uint256) external;
    function __ProviderRegistry_init() external;
    function __ModelRegistry_init() external;
    function __Delegation_init(address) external;
    function __SessionRouter_init(address, uint128, Pool[] calldata) external;
    function __LumerinDiamond_init() external;
    function diamondCut(bytes calldata) external;
}

contract DiamondAuditBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    uint256 internal constant FORK_BLOCK = 56140891;

    // MOR (18 decimals) balances mapping lives in storage slot 5 (probed on-chain)
    uint256 internal constant MOR_BALANCE_SLOT = 5;

    uint256 internal constant ATTACKER_PK = 0xA11CE;
    address internal attacker;

    IDiamond internal d;
    IERC20 internal mor;
    address internal funding;

    uint256 internal providerMinStake;
    uint256 internal modelMinStake;
    uint256 internal bidFee;
    uint256 internal minPps;
    uint256 internal maxPps;
    uint128 internal maxSessionDuration;

    bytes32 internal constant BASE_MODEL_ID = keccak256("audit-base-model");
    bytes32 internal modelId;

    function setUp() public virtual {
        string memory rpc = vm.envOr("RPC_URL", "https://mainnet.base.org");
        vm.createSelectFork(rpc, FORK_BLOCK);

        d = IDiamond(DIAMOND);
        attacker = vm.addr(ATTACKER_PK);
        vm.label(attacker, "attacker");
        vm.deal(attacker, 100 ether);

        mor = IERC20(d.getToken());
        funding = d.getFundingAccount();
        providerMinStake = d.getProviderMinimumStake();
        modelMinStake = d.getModelMinimumStake();
        bidFee = d.getBidFee();
        (minPps, maxPps) = d.getMinMaxBidPricePerSecond();
        maxSessionDuration = d.getMaxSessionDuration();

        // working capital (simulated lender / whale), netted out of every P&L assertion
        _setMOR(attacker, 5_000_000e18);
        vm.prank(attacker);
        mor.approve(DIAMOND, type(uint256).max);
    }

    /* ---------------------------- helpers ---------------------------- */

    function _setMOR(address who, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(who, MOR_BALANCE_SLOT));
        vm.store(address(mor), slot, bytes32(amount));
        require(mor.balanceOf(who) == amount, "balance slot mismatch");
    }

    function _ethSigned(bytes memory payload) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(payload)));
    }

    function _sign(uint256 pk, bytes memory payload) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _ethSigned(payload));
        return abi.encodePacked(r, s, v);
    }

    function _registerProvider(uint256 amount) internal {
        vm.prank(attacker);
        d.providerRegister(attacker, amount, "audit.local:1");
    }

    function _registerModel() internal returns (bytes32) {
        modelId = d.getModelId(attacker, BASE_MODEL_ID);
        string[] memory tags = new string[](1);
        tags[0] = "audit";
        vm.prank(attacker);
        d.modelRegister(attacker, BASE_MODEL_ID, keccak256("cid"), 0, modelMinStake, "audit-model", tags);
        return modelId;
    }

    function _postBid(uint256 pps) internal returns (bytes32) {
        vm.prank(attacker);
        return d.postModelBid(attacker, modelId, pps);
    }

    /// @dev provider-signed, single-use approval blob; the on-chain decoder ignores field #3
    function _approval(bytes32 bidId) internal returns (bytes memory payload, bytes memory sig) {
        payload = abi.encode(bidId, block.chainid, attacker, uint128(block.timestamp));
        sig = _sign(ATTACKER_PK, payload);
    }

    function _open(bytes32 bidId, uint256 stake, bool direct) internal returns (bytes32 sessionId) {
        (bytes memory payload, bytes memory sig) = _approval(bidId);
        vm.prank(attacker);
        sessionId = d.openSession(attacker, stake, direct, payload, sig);
    }

    function _receipt(bytes32 sessionId, uint32 tps, uint32 ttft)
        internal
        returns (bytes memory payload, bytes memory sig)
    {
        payload = abi.encode(sessionId, block.chainid, uint128(block.timestamp), tps, ttft);
        sig = _sign(ATTACKER_PK, payload);
    }

    function _close(bytes32 sessionId, uint32 tps, uint32 ttft) internal {
        (bytes memory payload, bytes memory sig) = _receipt(sessionId, tps, ttft);
        vm.prank(attacker);
        d.closeSession(payload, sig);
    }

    function _claim(bytes32 sessionId) internal {
        vm.prank(attacker);
        d.claimForProvider(sessionId);
    }

    function _withdrawStakes(uint8 iterations) internal {
        vm.prank(attacker);
        d.withdrawUserStakes(attacker, iterations);
    }

    function _nextDayStart() internal view returns (uint256) {
        return (block.timestamp / 1 days + 1) * 1 days;
    }

    function _dayStart(uint256 t) internal pure returns (uint256) {
        return t - (t % 1 days);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}