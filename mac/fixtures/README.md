# Usage endpoint test answers

Shapes of `GET https://api.anthropic.com/api/oauth/usage` answers for the
account types Claude Buddy handles. The shapes follow what
[Clawdmeter](https://github.com/HermannBjorgvin/Clawdmeter) documents. To print
the line the device would get for one:

```sh
"../dist/Claude Buddy.app/Contents/MacOS/ClaudeBuddy" --parse-usage <file> [ISO time]
./test.sh   # all of them, compared with expected.txt
```

| File | Account |
| --- | --- |
| `pro.json` | Pro / Max / Team: a running 5-hour window and the weekly one |
| `pro-window-not-started.json` | the same with no 5-hour window running |
| `pro-idle-with-extra-usage.json` | extra usage switched on: still a subscription, not a spend cap |
| `weekly-only.json` | `"five_hour": null`: plans with only a weekly limit |
| `enterprise-spend-limits.json` | spend-capped Enterprise, cap in `limits` |
| `enterprise-spend-top-level.json` | spend-capped Enterprise, cap only in `spend` / `extra_usage` |
| `enterprise-spend-reached.json` | the same at its cap |
| `uncapped.json` | spend on but no cap: nothing to show |
