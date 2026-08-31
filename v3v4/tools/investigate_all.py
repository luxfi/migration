#!/usr/bin/env python3
"""Enumerate ALL NonfungiblePositionManager NFTs (not just treasury's), map
owner + pool + liquidity for each. Answer: who owns the WLUX/LETH liquidity, and
what treasury-controlled paths (0x9011 or DAO Safe 0x51284d) hold liquidity."""
import json, os, subprocess
from eth_abi import encode as abi_encode, decode as abi_decode
from eth_utils import keccak

NPM     = "0x7a4C48B9dae0b7c396569b34042fcA604150Ee28"
FACTORY = "0x80bBc7C4C7a59C899D1B37BC14539A22D5830a84"
OWNER   = "0x9011e888251ab053b7bd1cdb598db4f9ded94714"
SAFE    = "0x51284dc2133e8d3a8e213dca6a6fa768cfdfcce2"
WLUX    = "0x4888e4a2ee0f03051c72d2bd3acf755ed3498b3e"
LETH    = "0x60e0a8167fc13de89348978860466c9cec24b9ba"
KCTX = os.environ.get("KCTX", "do-sfo3-lux-k8s")
KNS  = os.environ.get("KNS", "lux-mainnet")
KPOD = os.environ.get("KPOD", "luxd-1")

def rpc(batch):
    body = json.dumps(batch).encode()
    p = subprocess.run(["kubectl","--context",KCTX,"-n",KNS,"exec","-i",KPOD,"--",
        "curl","-s","-X","POST","http://localhost:9630/v1/chain/C/rpc",
        "-H","content-type:application/json","-d","@-"], input=body, capture_output=True, timeout=180)
    return json.loads(p.stdout)

def sel(sig): return "0x"+keccak(text=sig).hex()[:8]
def enc(sig, types, args): return sel(sig)+abi_encode(types,args).hex()
_id=[0]
def call(to,data,frm=None):
    _id[0]+=1; p={"to":to,"data":data}
    if frm: p["from"]=frm
    return {"jsonrpc":"2.0","id":_id[0],"method":"eth_call","params":[p,"latest"]}
def batch(calls):
    reqs,km={},{}
    lst=[]
    for k,to,d in calls:
        r=call(to,d); km[r["id"]]=k; lst.append(r)
    out={}
    for i in range(0,len(lst),60):
        for resp in rpc(lst[i:i+60]):
            out[km[resp["id"]]]=resp.get("result")
    return out
def dec(types,raw): return abi_decode(types,bytes.fromhex(raw[2:]))

total=int(batch([("t",NPM,enc("totalSupply()",[],[]))])["t"],16)
print("NPM totalSupply:",total)

# tokenByIndex all
idx=batch([(f"i{i}",NPM,enc("tokenByIndex(uint256)",["uint256"],[i])) for i in range(total)])
ids=[int(idx[f"i{i}"],16) for i in range(total)]
# positions + owner
pos=batch([(f"p{t}",NPM,enc("positions(uint256)",["uint256"],[t])) for t in ids])
own=batch([(f"o{t}",NPM,enc("ownerOf(uint256)",["uint256"],[t])) for t in ids])
ptypes=["uint96","address","address","address","uint24","int24","int24","uint128","uint256","uint256","uint128","uint128"]

from collections import Counter, defaultdict
owner_count=Counter(); owner_liq=defaultdict(int)
leth_positions=[]
recs=[]
for t in ids:
    _,_,t0,t1,fee,tl,tu,liq,_,_,ow0,ow1=dec(ptypes,pos[f"p{t}"])
    owner="0x"+own[f"o{t}"][-40:]
    owner_count[owner.lower()]+=1
    owner_liq[owner.lower()]+=liq
    rec=dict(id=t,owner=owner.lower(),t0=t0.lower(),t1=t1.lower(),fee=fee,tl=tl,tu=tu,liq=liq,ow0=ow0,ow1=ow1)
    recs.append(rec)
    if {t0.lower(),t1.lower()}=={WLUX,LETH}:
        leth_positions.append(rec)

print("\n=== ownership histogram (address: #NFTs, sum rawLiquidity) ===")
for a,c in owner_count.most_common():
    tag=" <-- TREASURY 0x9011" if a==OWNER else (" <-- DAO SAFE" if a==SAFE else "")
    print(f"  {a}: {c} NFTs, liqSum={owner_liq[a]}{tag}")

print(f"\n=== ALL WLUX/LETH positions (pool token pair) : {len(leth_positions)} ===")
for r in sorted(leth_positions,key=lambda x:-x['liq']):
    tag=" TREASURY" if r['owner']==OWNER else (" DAO_SAFE" if r['owner']==SAFE else " EXTERNAL")
    print(f"  id={r['id']:<5} owner={r['owner']}{tag} liq={r['liq']} [{r['tl']},{r['tu']}] owed0={r['ow0']} owed1={r['ow1']}")

# DAO Safe: does it own ANY position with liquidity?
safe_liq=[r for r in recs if r['owner']==SAFE and r['liq']>0]
print(f"\n=== DAO Safe {SAFE} positions with liq>0: {len(safe_liq)} ===")
for r in safe_liq:
    print(f"  id={r['id']} pair=({r['t0']},{r['t1']}) liq={r['liq']} [{r['tl']},{r['tu']}]")

# treasury (0x9011) positions with liq>0 recap
tre_liq=[r for r in recs if r['owner']==OWNER and r['liq']>0]
print(f"\ntreasury 0x9011 positions with liq>0: {len(tre_liq)}  (ids={[r['id'] for r in tre_liq]})")

# LETH token supply + where it sits
sup=batch([("s",LETH,enc("totalSupply()",[],[])),
           ("pool",FACTORY,enc("getPool(address,address,uint24)",["address","address","uint24"],[WLUX,LETH,3000]))])
lethpool="0x"+sup["pool"][-40:]
bals=batch([("bp",LETH,enc("balanceOf(address)",["address"],[lethpool])),
            ("bo",LETH,enc("balanceOf(address)",["address"],[OWNER])),
            ("bs",LETH,enc("balanceOf(address)",["address"],[SAFE]))])
print(f"\nLETH totalSupply={int(sup['s'],16)/1e18} pool={lethpool} poolLETH={int(bals['bp'],16)/1e18} ownerLETH={int(bals['bo'],16)/1e18} safeLETH={int(bals['bs'],16)/1e18}")
json.dump({"total":total,"leth_positions":leth_positions,"owner_count":dict(owner_count)},
          open(os.path.join(os.path.dirname(__file__),"leth_investigation.json"),"w"),indent=2,default=str)
