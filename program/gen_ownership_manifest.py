#!/usr/bin/env python3
# gen_ownership_manifest.py — DETERMINISTIC owner-slot StateUpgrade manifest generator
# for the FULL Lux-mainnet (96369) DEX ownership migration -> DAO Safe.
#
# Supersedes the earlier gen_ownership_manifest.sh (which only covered the 0xce15 subset).
# The live DEX ownable set is owned by THREE non-Safe keys — all migrated the same way:
#   0xce15d0ac… (lost key)      : V3Factory + 3x V2Factory + 6 mock USDT/USDC
#   0xbe7a89f4… (unknown EOA)   : the 11 real bridge tokens (LETH/LBTC/LUSD/LZOO/LSOL/
#                                 LBNB/LPOL/LCELO/LFTM/LTON + LAVAX)
#   0x086f4aa1… (unknown EOA)   : 2 empty orphan dup tokens (LTON/LSOL)
#
# SAFETY MODEL (byte-identical across validators): the manifest is a PURE function of
# observed pre-fork state. For each target we (1) read the getter (owner()/feeToSetter())
# and require it to equal the recorded current owner, (2) locate the EXACT 20-byte window
# holding that owner inside its 32-byte slot, (3) replace ONLY that window with the DAO Safe
# — preserving every co-packed byte (e.g. the mock tokens pack decimals=0x12 in byte 31).
# The new word is a constant; every validator applies the same constant at the same fork
# block => identical root. Fail-closed if a getter != recorded owner or the owner is not
# found in the scanned slots.
#
# Usage: RPC=<c-chain-rpc> SAFE=<0xDaoSafe> OUT=<path> python3 gen_ownership_manifest.py
import json, os, sys, urllib.request

RPC  = os.environ.get("RPC", "http://127.0.0.1:19630/ext/bc/C/rpc")
SAFE = os.environ.get("SAFE", "0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2").lower().replace("0x","")
OUT  = os.environ.get("OUT", os.path.join(os.path.dirname(__file__), "..", "manifests",
                                          "96369-ownership.stateupgrade.json"))
SCAN = 16
SEL  = {"owner":"0x8da5cb5b", "feeToSetter":"0x094b7415"}
CE15 = "ce15d0ac1dd7f0da84d65aaa40717e0c60d9fe36"
BE   = "be7a89f41fa7371b856b9685dd025d0bcc6c7a25"
OF   = "086f4aa1a49b193d49e5bbb462e1554cfb419040"

# Fresh-chain re-run (2026-07 RLP re-import): Path A already rewrote every target's owner
# to the OLD DAO Safe 0x51284dc2 pre-snapshot; on the re-import that Safe is codeless, so we
# re-own to the NEW deterministic Safe. EXPECT overrides the historical lost-key owners with
# the single current owner (0x51284dc2) so the manifest rewrites 0x51284dc2 -> SAFE.
_EXP = os.environ.get("EXPECT", "").lower().replace("0x", "")
if _EXP:
    assert len(_EXP) == 40, "EXPECT must be a 20-byte address"
    CE15 = BE = OF = _EXP

# (address, getter, label, expected_current_owner)
TARGETS = [
  ("0x80bBc7C4C7a59C899D1B37BC14539A22D5830a84","owner","V3Factory (gen1 LIVE)",CE15),
  ("0xD173926A10A0C4eCd3A51B1422270b65Df0551c1","feeToSetter","V2Factory gen1 (LIVE)",CE15),
  ("0xeac0a50112b5ee20cc18e42ba4d37777012afd0d","feeToSetter","V2Factory gen2 (orphan)",CE15),
  ("0xaa6a41cacb18bed5b98059a5fa30f9dbabe0cc64","feeToSetter","V2Factory gen3 (orphan)",CE15),
  ("0xdf1de693c31e2a5eb869c329529623556b20abf3","owner","MockUSDT gen1",CE15),
  ("0x8031e9b0d02a792cfefaa2bdca6e1289d385426f","owner","MockUSDC gen1",CE15),
  ("0x79608e442d046ea6d3125931a33ce971ad99c6f9","owner","MockUSDT gen2",CE15),
  ("0xa85eb8e163f4d70bfc43a4f3fcc9a8dfc42b1ae4","owner","MockUSDC gen2",CE15),
  ("0x724f4ef0400386fc8c1011788af733bd367ac00f","owner","MockUSDT gen3",CE15),
  ("0x3569c06a80c148d7b4b67f8a06125f6d59774243","owner","MockUSDC gen3",CE15),
  ("0x60E0a8167FC13dE89348978860466C9ceC24B9ba","owner","LETH (ZETH)",BE),
  ("0x1E48D32a4F5e9f08DB9aE4959163300FaF8A6C8e","owner","LBTC (ZBTC)",BE),
  ("0x848Cff46eb323f323b6Bbe1Df274E40793d7f2c2","owner","LUSD (ZUSD)",BE),
  ("0x5E5290f350352768bD2bfC59c2DA15DD04A7cB88","owner","LZOO (ZLUX)",BE),
  ("0x26B40f650156C7EbF9e087Dd0dca181Fe87625B7","owner","LSOL (ZSOL)",BE),
  ("0x6EdcF3645DeF09DB45050638c41157D8B9FEa1cf","owner","LBNB (ZBNB)",BE),
  ("0x28BfC5DD4B7E15659e41190983e5fE3df1132bB9","owner","LPOL (ZPOL)",BE),
  ("0x3078847F879A33994cDa2Ec1540ca52b5E0eE2e5","owner","LCELO (ZCELO)",BE),
  ("0x8B982132d639527E8a0eAAD385f97719af8f5e04","owner","LFTM (ZFTM)",BE),
  ("0x3141b94b89691009b950c96e97Bff48e0C543E3C","owner","LTON (ZTON)",BE),
  ("0x0e4bd0dd67c15DECFbBBDBbE07Fc9d51D737693D","owner","LAVAX",BE),
  ("0xf5a313885832d4fc71d1ef80115197c4479b58c8","owner","LTON dup (empty)",OF),
  ("0x1af00a2590a834d14f4a8a26d1b03ebba8cf7961","owner","LSOL dup (empty)",OF),
]

def rpc_batch(calls):
    req = urllib.request.Request(RPC, data=json.dumps(calls).encode(),
                                 headers={"content-type":"application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read())

assert len(SAFE) == 40, "SAFE must be a 20-byte address"

# 1) confirm getters
gres = {r["id"]:r for r in rpc_batch(
    [{"jsonrpc":"2.0","id":i,"method":"eth_call","params":[{"to":a,"data":SEL[g]},"latest"]}
     for i,(a,g,l,e) in enumerate(TARGETS)])}
# 2) scan slots
scalls=[]; smap=[]
for i,(a,g,l,e) in enumerate(TARGETS):
    for s in range(SCAN):
        smap.append((i,s))
        scalls.append({"jsonrpc":"2.0","id":len(smap)-1,"method":"eth_getStorageAt","params":[a,hex(s),"latest"]})
sres = {r["id"]:r for r in rpc_batch(scalls)}

accts={}; errors=[]; rows=[]
for i,(addr,getter,label,exp) in enumerate(TARGETS):
    gv=(gres[i].get("result","") or "")[-40:].lower()
    if gv != exp:
        errors.append(f"{addr} {label}: {getter}()={gv} != recorded {exp} — REFUSE"); continue
    slots={s: (sres[cid].get("result","0x"+"0"*64)[2:].lower().rjust(64,"0"))
           for cid,(ti,s) in enumerate(smap) if ti==i}
    hit=None
    for s in range(SCAN):
        w=slots.get(s,"0"*64)
        if exp in w:
            hit=(s, "0x"+w, "0x"+w.replace(exp,SAFE)); break
    if not hit:
        errors.append(f"{addr} {label}: owner {exp} not in slots 0..{SCAN-1} — REFUSE"); continue
    s,old,new=hit
    accts[addr]={"storage":{"0x"+format(s,"064x"): new}}
    rows.append((addr,s,label,exp,old,new))

for addr,s,label,exp,old,new in rows:
    print(f"{addr}  slot={s:<2} [{label}] owner={exp[:8]}..")
    print(f"    old={old}\n    new={new}")
if errors:
    print("\n=== REFUSALS (fail-closed) ===")
    for e in errors: print("  "+e)
    sys.exit(1)

frag=[{"blockTimestamp":"__OWNERSHIP_MIGRATION_TS__","accounts":accts}]
os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT,"w").write(json.dumps(frag,indent=2)+"\n")
print(f"\nOK: wrote {len(accts)} contracts -> {OUT}")
