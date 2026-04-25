@../../Dev-RZY/AGENT.md

## Strategy: AMD — Accumulation · Manipulation · Distribution

Playbook by Tanja Trade (ChartFanatics). Markets cycle through three phases:
- **Accumulation**: price ranges sideways, liquidity builds
- **Manipulation**: stop sweep beyond range (traps traders)
- **Distribution**: real directional move after the sweep — entry on retrace into FVG

Best setups: high-impact news days (CPI, NFP, FOMC, GDP, PPI).  
For fundamental analysis and market correlation → `/financial-analyst-master TICKER`

## Repo Structure

```
amd-mq5-ea/          MQL5 EA — manual backtesting + alert mode
amd-python-bot/      Python bot — auto-executes AMD setups via MT5 API
amd-signal-lab/      Historical backtesting + period/FVG analysis
```

## Critical Rules

- `MANUAL_CONFIRM=true` until strategy is validated on demo
- Validate new parameters in signal lab on ≥3M data before enabling in live bot
- Mirror EA rules 1-for-1 in the Python bot — same rule numbers
- Credentials in `keyring`, non-sensitive config in `.env` (gitignored)

## Commands

```bash
# Run bot
python amd-python-bot/main.py
python amd-python-bot/main.py --profile metaquotes
python amd-python-bot/main.py --symbol XAUUSDp

# Signal lab
python amd-signal-lab/main.py
python amd-signal-lab/main.py XAUUSD 3M

# Fundamental check (before news trades)
# Use /financial-analyst-master skill for market correlation and catalyst analysis

# Lint
flake8 amd-python-bot/bot/ --max-line-length=100
```

## Verification

| Change | How to verify |
|---|---|
| Python bot edit | Run one-shot diagnostic scan; confirm no errors |
| EA (.mq5) edit | Compile in MetaTrader (0 errors, 0 warnings); run `/deploy-ea` |
| New filter/rule | Signal lab on ≥3M data; check win rate delta |
| Credential change | `python -c "import keyring; print(keyring.get_password('mt5','<key>'))"` |

## AMD-Specific Notes

- FVG (Fair Value Gap): bearish = `bar[i].high < bar[i-2].low`; bullish = `bar[i].low > bar[i-2].high`
- Manipulation: bar swept beyond range boundary AND closed back inside range
- Accumulation tightness: range height < `accum_atr_mult × ATR(14)`
- High-prob days trade around macro windows: NY 09:50–10:10 ET and 10:50–11:10 ET
- After news spike (manipulation), wait for FVG to form — never enter during the spike
- For market correlations (e.g. NASDAQ + S&P alignment): use `/financial-analyst-master`
- Period indices: 26=13:00 UTC (NY open), 27=13:30, 28=14:00, 29=14:30, 30=15:00 UTC

## Subagents

| Task | Command |
|---|---|
| Review changed code | `use the code-reviewer subagent` |
| Security scan | `use the security-reviewer subagent` |
| Check if bot is live | `use the bot-health-check subagent` |
| Deploy EA to MetaTrader | `use the ea-deployer subagent` |
| Commit and push | `use the git-push subagent` |
