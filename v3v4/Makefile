# Lux mainnet V3 -> V4 liquidity migration (DEX LP move; NOT the Quasar network migration).
# One entrypoint. Everything derives from live chain state. DRY_RUN by default.
#
#   make snapshot     # read all treasury V3 positions from live 96369
#   make plan         # classify + accounting table -> tools/plan.json
#   make test         # foundry unit + fuzz tests for LiquidityDeployer
#   make build        # canonical deployable artifacts (via_ir)
#   make migrate      # DRY-RUN staged executor (no broadcast)  [DRY_RUN=1 default]
#   make migrate DRY_RUN=0   # BROADCAST to all 5 validators (needs LUX_PRIVATE_KEY)
#   make investigate  # full NPM ownership map (who owns what; LETH resolution)
#
# Config (override on the command line): KCTX, KNS, GAS_PRICE_GWEI, SLIPPAGE_BPS, ORACLE
SHELL := /bin/bash
TOOLS := tools
CONTRACTS := contracts
KCTX ?= do-sfo3-lux-k8s
KNS ?= lux-mainnet
GAS_PRICE_GWEI ?= 250
SLIPPAGE_BPS ?= 100
DRY_RUN ?= 1
ORACLE ?= $(TOOLS)/oracle.json
ORACLE_TICK_BAND ?= 2000                     # max |oracleTick - expected_tick| for a one-sided bid
ONESIDED_MAX_WLUX ?= 5000000000000000000000000  # 5,000,000e18 hard cap per one-sided pool
FINALIZE ?= 0                                # 1 => zero LD approvals + transferOwnership LD->DAO Safe
export FOUNDRY_DISABLE_NIGHTLY_WARNING := 1

.PHONY: setup snapshot plan investigate test build migrate clean
EXECUTE := $(if $(filter 0,$(DRY_RUN)),1,0)

setup: ## clone pinned v4-core deps if missing (deterministic build inputs)
	@bash scripts/setup.sh

snapshot: ## enumerate treasury V3 positions from live chain
	cd $(TOOLS) && TRANSPORT=kubectl KCTX=$(KCTX) KNS=$(KNS) python3 snapshot.py

investigate: ## full NPM ownership map (all 149 NFTs) + LETH resolution
	cd $(TOOLS) && KCTX=$(KCTX) KNS=$(KNS) python3 investigate_all.py

plan: ## classification + accounting table -> plan.json
	cd $(TOOLS) && python3 build_plan.py

test: ## foundry unit + fuzz tests (fast profile)
	cd $(CONTRACTS) && FOUNDRY_PROFILE=test forge test -vv

build: ## canonical deployable artifacts (via_ir, optimizer 44444444, bytecode_hash=none)
	cd $(CONTRACTS) && forge build src/LiquidityDeployer.sol

migrate: ## staged executor. DRY_RUN=1 (default) simulates; DRY_RUN=0 broadcasts.
	cd $(TOOLS) && EXECUTE=$(EXECUTE) KCTX=$(KCTX) KNS=$(KNS) \
	  GAS_PRICE_GWEI=$(GAS_PRICE_GWEI) SLIPPAGE_BPS=$(SLIPPAGE_BPS) \
	  ORACLE_TICK_BAND=$(ORACLE_TICK_BAND) ONESIDED_MAX_WLUX=$(ONESIDED_MAX_WLUX) \
	  FINALIZE=$(FINALIZE) ORACLE=$(notdir $(ORACLE)) python3 execute.py

clean:
	rm -f $(TOOLS)/state.json
