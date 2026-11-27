"""Benchmarks LEO's OpenAI 'understanding' step exactly as the app sends it (same system prompt,
same settings). Accuracy = the plan contains every required step; speed = wall-clock per request."""
import json, re, sys, time, statistics, http.client

root = sys.argv[1]
runs = int(sys.argv[2]) if len(sys.argv) > 2 else 2
key = [re.match(r'\s*OPENAI_API_KEY\s*=\s*(\S+)', l).group(1) for l in open(root + '/lib/.env', encoding='utf-8')
       if re.match(r'\s*OPENAI_API_KEY\s*=', l)][0].strip('"\'')
src = open(root + '/lib/ai/sarvam_brain.dart', encoding='utf-8').read()
system = src.split("static const systemPrompt = '''", 1)[1].split("''';", 1)[0]

# (said, kind, checks) — kind 'plan': every regex must match some command (in order not required)
#                       kind 'answer': answer must match the regex
CASES = [
    ("open youtube and play lofi then set a timer for 20 minutes", 'plan', [r'youtube|lofi', r'lofi', r'timer.*20|20.*min']),
    ("mujhe kal subah 6 baje uthana aur amma ko message karo ki main late hoon", 'plan', [r'alarm.*6|6.*alarm|wake', r'(message|text|whatsapp).*amma|amma.*late']),
    ("whatsapp kholo aur rahul ko bolo main aa raha hoon", 'plan', [r'rahul']),
    ("turn on do not disturb and then call amma", 'plan', [r'do not disturb|dnd', r'call amma']),
    ("message rahul the meeting moved to 4 and also email the same to kiran", 'plan', [r'rahul.*4|meeting', r'email.*kiran|kiran.*email']),
    ("naale 7 gantege alarm idu", 'plan', [r'alarm.*7|7.*alarm']),
    ("start the stopwatch", 'plan', [r'stopwatch']),
    ("open claude and ask it to prepare a ppt about blood", 'plan', [r'claude', r'blood']),
    ("play arijit singh on spotify and turn the volume up", 'plan', [r'arijit', r'volume']),
    ("remind me to call the doctor tomorrow at 10 am", 'plan', [r'remind|alarm', r'doctor|10']),
    ("search amazon for wireless earbuds under 2000", 'plan', [r'amazon', r'earbuds']),
    ("send hi to amma on whatsapp and then open instagram", 'plan', [r'amma', r'instagram']),
    ("kal 5 baje kiran ke saath zoom meeting schedule karo", 'plan', [r'zoom|meeting', r'kiran', r'5']),
    ("take a selfie and share it with rahul on whatsapp", 'plan', [r'selfie|camera|photo', r'rahul']),
    ("turn off wifi and turn on bluetooth", 'plan', [r'wi-?fi', r'bluetooth']),
    ("who won the 2011 cricket world cup", 'answer', [r'india']),
    ("what is the capital of australia", 'answer', [r'canberra']),
    ("explain in one line how vaccines work", 'answer', [r'immun|antibod']),
    ("how many days are there in a leap year", 'answer', [r'366']),
    ("bharat ki rajdhani kya hai", 'answer', [r'delhi']),
]

def call(conn, said):
    body = {"model": "gpt-4o-mini", "messages": [{"role": "system", "content": system},
            {"role": "user", "content": f'User said: "{said}"'}],
            "temperature": 0.1, "max_completion_tokens": 300, "response_format": {"type": "json_object"},
            "store": False, "prompt_cache_key": "leo-understand-v1"}
    t = time.time()
    conn.request("POST", "/v1/chat/completions", json.dumps(body), {"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    r = json.loads(conn.getresponse().read())
    ms = (time.time() - t) * 1000
    if 'error' in r:
        raise SystemExit('API error: ' + str(r['error'].get('message')))
    u = r['usage']
    return r['choices'][0]['message']['content'], ms, u['prompt_tokens'], u['completion_tokens'], (u.get('prompt_tokens_details') or {}).get('cached_tokens', 0)

def grade(content, kind, checks):
    try:
        m = json.loads(content[content.index('{'):content.rindex('}') + 1])
    except Exception:
        return False, 'unparseable'
    cmds = [c for c in (m.get('commands') or []) if isinstance(c, str)]
    if kind == 'plan':
        text = ' || '.join(cmds).lower()
        miss = [c for c in checks if not re.search(c, text)]
        return (not miss and bool(cmds)), ' → '.join(cmds) or (m.get('answer') or m.get('clarify') or '')
    ans = (m.get('answer') or '') + ' ' + ' '.join(cmds)
    return all(re.search(c, ans.lower()) for c in checks), (m.get('answer') or str(cmds))[:90]

conn = http.client.HTTPSConnection("api.openai.com", timeout=30)
call(conn, "hello")  # open the TLS connection (the app keeps one open too)
rows, lat, tin, tout, tcache = [], [], 0, 0, 0
for said, kind, checks in CASES:
    for i in range(runs):
        content, ms, pi, po, pc = call(conn, said)
        ok, shown = grade(content, kind, checks)
        rows.append((said, kind, ok, ms, shown)); lat.append(ms); tin += pi; tout += po; tcache += pc
n = len(rows)
acc = sum(r[2] for r in rows) / n
acc_plan = [r[2] for r in rows if r[1] == 'plan']; acc_ans = [r[2] for r in rows if r[1] == 'answer']
lat.sort()
cost = ((tin - tcache) * 0.15 + tcache * 0.075 + tout * 0.6) / 1e6
summary = {"requests": n, "accuracy": round(acc, 3), "plan_accuracy": round(sum(acc_plan) / len(acc_plan), 3),
           "answer_accuracy": round(sum(acc_ans) / len(acc_ans), 3),
           "latency_ms_p50": round(statistics.median(lat)), "latency_ms_p90": round(lat[int(0.9 * (n - 1))]),
           "latency_ms_max": round(lat[-1]), "avg_tokens_in": round(tin / n), "avg_tokens_out": round(tout / n),
           "cached_share": round(tcache / max(tin, 1), 2), "cost_usd_total": round(cost, 5), "cost_usd_per_request": round(cost / n, 6)}
print(json.dumps(summary, indent=1))
for said, kind, ok, ms, shown in rows:
    if not ok:
        print(f"MISS [{kind}] {said!r} ({ms:.0f} ms): {shown}")
json.dump({"summary": summary, "rows": rows}, open(root + '/build/benchmark_openai.json', 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
