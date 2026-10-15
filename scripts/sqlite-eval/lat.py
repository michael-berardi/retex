import os, statistics, subprocess, sys, time, json
S=os.path.dirname(os.path.abspath(__file__)); BIN=os.path.expanduser("~/dev/retex-sqlite-eval/.build/release/retex")
vault=os.path.join(S,"clones",sys.argv[1]); N=int(sys.argv[2]) if len(sys.argv)>2 else 5
Q=[["search","acme"],["search","cloudflare deploy"],["search","stripe invoice","--ranked"],["search","ai"],
   ["recall","how do we deploy acme to cloudflare","--budget","12000"],["recall","stripe invoice for acme","--budget","12000"],
   ["recall","deploy","--type","memory","--budget","4000"],["query","--type","memory","--limit","100"],["count"],["list"]]
def t(q,ix):
    env=dict(os.environ,RETEX_INDEX_DIR=os.path.join(S,"idx")); env.pop("RETEX_INDEX",None); env.pop("RETEX_INDEX_TRACE",None)
    if ix: env["RETEX_INDEX"]="sqlite"
    xs=[]
    for _ in range(N):
        a=time.perf_counter(); subprocess.run([BIN]+q+["--vault",vault,"--lean"],env=env,capture_output=True,check=True); xs.append(time.perf_counter()-a)
    return statistics.median(xs)
rows=[]
for q in Q:
    a=t(q,False); b=t(q,True); rows.append((" ".join(q[:2]) + (" "+q[2] if len(q)>2 and q[2].startswith("--r") else ""),a,b))
    print(f"{rows[-1][0][:45]:45s} md {a*1000:7.0f} ms  sqlite {b*1000:7.0f} ms  x{a/b:5.2f}",flush=True)
json.dump(rows,open(os.path.join(S,f"lat-{sys.argv[1]}.json"),"w"))
