# program/ — operating a live fleet

Scripts for changing a running Lux validator fleet without breaking it. Each is
one concern; they compose.

| Script | Does |
|---|---|
| `fleet.sh` | Sourced helpers: per-pod RPC, in-place restart, stranded-node heal. Not run directly. |
| `fleet_verify.sh` | Is the fleet converged? Answers with evidence. Exit 0 iff yes. |
| `fleet_heal.sh` | Rejoin stranded validators, one at a time. |
| `state_upgrade.sh` | Stage a C-Chain StateUpgrade into the GitOps source, with guards. |

Every fleet is addressable through the same env vars, so nothing is
lux-mainnet-specific:

```sh
./fleet_verify.sh                                             # lux mainnet
NS=lux-testnet ./fleet_verify.sh
NS=zoo-mainnet STS=zood-mv CTX=do-sfo3-zoo-k8s ./fleet_verify.sh
```

## The five things that cost real time

**1. The ConfigMap is not writable.** `luxd-startup` is owned by hanzo-cd
(annotation `apps.hanzo.ai/installation-id`). `kubectl patch` works until the
reconciler notices, then silently reverts. The source of truth is a Helm values
file: `luxfi/universe` → `deploy/<fleet>/luxd.yaml` →
`configMaps[0].data['cchain-upgrade.json']`.

**2. Push to GitHub, not to git.hanzo.ai.** hanzo-cd *reads* from
`git.hanzo.ai/luxfi/universe`, but that repo is a read-only pull mirror —
pushing returns `Mirror Repository luxfi/universe is read-only`. Push to
`github.com/luxfi/universe`; the mirror pulls within a minute or two.

**3. Auto-sync is off, and syncing recreates ALL pods at once.** The app only
moves when you trigger it. The StatefulSet carries a config checksum, so any
ConfigMap change rolls the whole fleet simultaneously rather than one at a time.
Budget an outage window (~2 min observed on 2026-08-05, recovered to 5/5).

**4. `kubectl delete pod` is the wrong restart.** DO's kubelet TTL-caches
ConfigMaps, so a recreated pod can boot on the stale mount. `restart_in_place`
kills the luxd child; `startup.sh` re-copies the current mount on boot.

**5. A restart can strand a validator, silently.** Under the default
`--skip-bootstrap=true`, a node that misses one gossiped block never re-fetches
it and freezes forever — while still logging `quorum: CERT assembled … sentToPeers=4`.
Consensus liveness says nothing about whether its EVM moved. At 4-of-5 the chain
still finalizes, so it looks healthy from outside with zero margin left.
`fleet_heal.sh` writes the `.allow-bootstrap` opt-in and restarts.

## Verifying anything

Two rules, both learned by getting them wrong:

- **Direction, not inequality.** A height that differs from a peer is ambiguous
  (different read instants). A height that does not *move* while the fleet
  advances is proof. Compare `stateRoot` at a common height for "no fork".
- **Read through the contract, not the slot.** Verifying a StateUpgrade by
  reading the slot back and comparing it to what you wrote passes *by
  construction*. Ask `owner()` and `decimals()`, and keep an untouched account
  as a control so you can tell "my write was wrong" from "my probe was wrong".

That second rule is not hypothetical: a plain left-padded address written into a
*packed* slot (address + `uint8` sharing one word) shifted six tokens' owner one
byte onto an address nobody controls and set `decimals` to 189. Slot readback
was green throughout. See `manifests/96369-packed-slot5-repair.applied.json`.
