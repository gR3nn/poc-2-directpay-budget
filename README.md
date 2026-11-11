# poc-2-directpay-budget — SessionRouter direct-payment compute-budget destruction

Base mainnet fork, pinned block **56140891**. Self-contained Foundry bundle. Fork-only: no broadcast,
no privileged pranks (only self-derived attacker EOAs), loss asserted with real assertions.

## Target
- LumerinDiamond (proxy): `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`
- SessionRouter facet (deployed, source-verified): `0x3a3952F0e57B343F00B31f7da039Ef16389B7260`
- Funding account: `0x5160C0311A95E0A1072FA85Df23712A7BA1cD4b1`
- Root cause: `_claimForProvider`, `SessionRouter.sol:392` (`providersTotalClaimed += amount_`) runs before the
  `isDirectPaymentFromUser` branch (`:394-402`). Direct claims pay from the user's stake (`:395`), not the
  treasury, but still inflate the global claimed counter.

## Mechanism
`getComputeBalance = periodReward - providersTotalClaimed` (`:497`), where `periodReward` is cumulative since
`payoutStart` (LDID.getPeriodReward). `providersTotalClaimed` is cumulative and never decremented. A user-funded
direct claim raises the counter with zero funding outflow, so the compute budget is permanently depressed and
`totalMORSupply` (`:526`) permanently inflated. Honest `stakeToStipend` (`:408-415`) falls permanently.

## Run
```
cd poc-2-directpay-budget
RPC_URL=https://mainnet.base.org forge test -vvvv
```
Config: solc 0.8.24, optimizer 200, via_ir=true, evm_version=paris. Block pinned in the harness.
(On the audit node: `PATH=/data/morpheus-audit/bin:$PATH forge test -vvvv` inside
`/data/morpheus-audit/poc-directpay-approval`, the identical tested bundle.)

## Tests (4 passed / 0 failed, forge exit 0)
- `test_directPayment_selfClaim_destroysComputeBudget` — 3,000,000 MOR stake, maxPps=1e16, 7-day cap:
  PTC +6048 MOR, computeBalance -6048 MOR, funding delta 0, totalMORSupply +6048 MOR,
  honest stakeToStipend(1M) 2922.810 -> 2915.243 MOR, attacker net 0, impact $4,536 (@ $0.75/MOR).
- `test_directPayment_repeatable_cumulative` — 2 sessions destroy 12,096 MOR ($9,072).
- `test_directPayment_closeConservesFunds_noTreasuryDrain` — REFUTATION: direct close pays exactly the stake,
  funding outflow 0 (no overpay).
- `test_directPayment_midnightSpan_noTreasuryDrain` — REFUTATION: a midnight-spanning DIRECT session has
  treasury outflow 0 (the under-lock only refunds the attacker's own stake early).

## Impact class (honest)
Capital-preserving griefing, not theft. Attacker net 0; needs large refundable capital (~3M MOR max case,
~227k MOR to clear $500), rate-limited ~1 max session/UTC day per capital unit. The harm is a permanent adverse
shift in stake-to-stipend pricing that reduces honest stakers' yield. Clears the program's "griefing without
permanent loss" exclusion (the budget loss is permanent); fits the Medium "griefing with a measurable cost borne
by others" clause. Severity is the program's call.

## Fix
Move `providersTotalClaimed += amount_` (SessionRouter.sol:392) into the `else` (treasury-funded) branch so only
stipend claims count against the compute budget.

## Gate status
Clean-clone gate `verify_poc.sh poc-directpay-approval` RESULT: PASS (pinned fork, attacker-only pranks,
real-loss asserts, no broadcast). Lead re-run at block 56140891: forge exit 0, 4/4.