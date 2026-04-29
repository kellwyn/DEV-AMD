//+------------------------------------------------------------------+
//|  AMD Strategy — Accumulation · Manipulation · Distribution       |
//|  Playbook by Tanja Trade (ChartFanatics AMD Method)             |
//|                                                                   |
//|  SETUP SEQUENCE                                                   |
//|  Rule 1  — Accumulation: N bars of tight range-bound price      |
//|             Range height < InpAccumATRMult × ATR(14)            |
//|  Rule 2  — Entry at midpoint of accumulation range              |
//|             LONG  if ask ≤ midpoint (price in lower half)        |
//|             SHORT if bid ≥ midpoint (price in upper half)        |
//|  Rule 3  — SL beyond range boundary + InpSLPips buffer          |
//|  Rule 4  — TP: R:R ratio or fixed pips                          |
//|  Rule 5  — Period filter: 48 × 30-min UTC slots (multi-select)  |
//|  Rule 6  — ICT Session filter: Asian / London / NY              |
//|  Rule 7  — Max trades per period per day                        |
//|  Rule 8  — Day quality flag: trade only high-probability days   |
//|                                                                   |
//|  HIGH-PROBABILITY DAYS: CPI, NFP, FOMC, GDP, PPI                |
//|  → Check economic calendar before enabling InpHighProbDay=true  |
//|  → For market correlation analysis use /financial-analyst-master |
//|                                                                   |
//|─────────────────── VERSION HISTORY ─────────────────────────────|
//|  v1.02  2026-04-27  — midpoint entry, accumulation only          |
//|    · Replaced FVG + sweep detection with midpoint entry rule     |
//|    · LONG if ask ≤ midpoint | SHORT if bid ≥ midpoint            |
//|    · SL placed beyond range boundary (not manip extreme)         |
//|    · Removed Rules 2-4 (manip sweep, FVG, retrace)               |
//|  v1.02  2026-04-30  — NFP/FOMC/GDP/PPI calendar auto-detection  |
//|    · Added NFP, FOMC, GDP Advance, PPI date arrays (2026, UTC)  |
//|    · IsNewsDay() combines all five events; replaces IsCPIDay()  |
//|    · InpUseCPICalendar now gates on any news day (all five)     |
//|    · InpHighProbDay retains manual override capability          |
//|  v1.01  2026-04-27  — CPI calendar auto-detection               |
//|    · Hard-coded CPI release dates 2022–2026 (59 dates, UTC)     |
//|    · EST dates → 13:30 UTC | EDT dates → 12:30 UTC              |
//|    · IsCPIDay() auto-enables Rule 10 on CPI release days        |
//|    · InpHighProbDay repurposed: override for NFP/FOMC/GDP/PPI   |
//|  v1.00  2026-04-26  — Initial release                            |
//|    · Full AMD playbook implementation (Rules 1–10)               |
//|    · FVG detection + retrace entry logic                         |
//|    · 48-slot period filter with comma-separated string config    |
//|    · ICT session filter (Asian / London / NY)                    |
//|    · Max trades per 30-min period per day                        |
//|    · Risk-based lot sizing with max lot cap                       |
//|    · SL in pips + TP by R:R ratio or fixed pips                  |
//|    · Chart drawing: accumulation zone, FVG zone, SL/TP lines    |
//|    · Alert (manual) or auto-execute mode                         |
//+------------------------------------------------------------------+
#property copyright "AMD Strategy EA  v1.02"
#property version   "1.02"
#property description "AMD — Accumulation · Manipulation · Distribution  v1.02"
#property strict

#include <Trade\Trade.mqh>

//── Inputs ──────────────────────────────────────────────────────────────────

input group "=== Day Filter & Execution Mode ==="
input bool   InpUseCPICalendar     = false;  // Restrict to news days: CPI/NFP/FOMC/GDP/PPI (set true for news-day filter)
input bool   InpHighProbDay        = false;  // Manual override for specific news days (NFP/FOMC/GDP/PPI)
                                              // Both false = run every day (default for this EA)
input bool   InpManualConfirm      = true;   // true = Alert only | false = Auto-execute

input group "=== Risk Management ==="
input double InpRiskPercent        = 1.0;    // Risk per trade (% of account balance)
input double InpMinRR              = 1.5;    // Minimum risk:reward ratio (0 = disabled)
input double InpMaxLots            = 5.0;    // Hard cap on position size
input double InpManualLots         = 0.0;    // Manual position size override (0 = auto risk-based)

input group "=== Rule 3-4 — SL / TP Settings ==="
input bool   InpUsePipSL           = false;  // false = range boundary + buffer  |  true = fixed pip SL
input double InpManualSLPips       = 20.0;   // SL distance from entry in pips (when InpUsePipSL = true)
input double InpSLPips             = 10.0;   // SL buffer beyond range boundary (when InpUsePipSL = false)
input bool   InpUsePipTP           = false;  // false = R:R ratio  |  true = fixed pip TP
input double InpTPPips             = 20.0;   // TP in pips (when InpUsePipTP = true)
input double InpRiskReward         = 2.0;    // TP = entry ± risk × this (when not pip-based)
input double InpTPBufferPips       = 5.0;    // Extra pip buffer beyond range extreme (fallback)

input group "=== Rule 1-2 — Accumulation & Entry ==="
input int    InpAccumBars          = 20;     // Rule 1: Accumulation lookback bars
input double InpAccumATRMult       = 1.5;    // Rule 1: Accum range < mult × ATR(14) of prior bars
input double InpOverbought         = 70.0;   // Rule 2: Price position % in range ≥ this → SHORT
input double InpOversold           = 30.0;   // Rule 2: Price position % in range ≤ this → LONG
                                              //   Position % = (close - rangeLow) / rangeHeight × 100
                                              //   70/30 = top/bottom 30% of range triggers entry
input int    InpCandleCount        = 60;     // Total bars to fetch per scan

input group "=== Rule 7 — Period Filter (48 × 30-min UTC Slots) ==="
input bool   InpUsePeriodFilter    = false;  // Only trade in selected UTC periods
input string InpAllowedPeriods     = "ALL";  // Periods: ALL or comma-separated indices 0-47
                                              // Index guide: 0=00:00  13=06:30  24=12:00
                                              //   26=13:00 (NY open)  27=13:30  34=17:00
                                              // Example NY morning: "26,27,28,29,30,31"
input int    InpMaxTradesPerPeriod = 2;       // Rule 9: Max executions per slot per day

input group "=== Rule 8 — ICT Session Filter ==="
input bool   InpUseSessionFilter   = false;  // Restrict to ICT sessions (set true to filter by session)
input int    InpGMTOffset          = 0;       // Broker server offset from GMT
input int    InpAsianStartH        = 23;      // Asian session start (UTC incl. 1hr pre-market)
input int    InpAsianEndH          = 9;       // Asian session end (UTC)
input int    InpLondonStartH       = 7;       // London start (UTC, 1hr pre-market)
input int    InpLondonEndH         = 16;      // London end (UTC)
input int    InpNYStartH           = 12;      // NY start (UTC, 1hr pre-market)
input int    InpNYEndH             = 21;      // NY end (UTC)

input group "=== Chart Display ==="
input bool   InpDrawObjects        = true;           // Draw accumulation zone and levels on chart
input color  InpAccumColor         = clrSteelBlue;   // Accumulation range fill
input color  InpMidpointColor      = clrGold;        // Midpoint line

input group "=== Trade Settings ==="
input int    InpMagicNumber        = 20260501;
input int    InpSlippage           = 20;

input group "=== Diagnostics ==="
input bool   InpDiagnostic         = false;   // Print rule-by-rule blocking reason each bar

//── Globals ──────────────────────────────────────────────────────────────────

CTrade Trade;

bool    g_periodAllowed[48];    // which 30-min UTC slots are allowed
int     g_periodTrades[48];     // trade count per slot today
datetime g_lastResetDay = 0;    // last UTC date we reset g_periodTrades

datetime g_lastBar = 0;         // gate: only run on new bar

double g_pipSize = 0.0;

string   g_openSfx    = "";    // drawing suffix of the currently open trade
ulong    g_openTicket = 0;     // ticket of the currently open trade

const datetime FAR_FUTURE = D'2099.12.31 00:00'; // sentinel right-edge; snapped to close time on exit


//── CPI release calendar (UTC) ───────────────────────────────────────────────
//  All releases at 08:30 ET.
//  EST months (Jan, Feb, Nov, Dec + Mar pre-DST) → 13:30 UTC  (UTC+5)
//  EDT months (Apr–Oct + Mar post-DST)            → 12:30 UTC  (UTC+4)
//  DST starts: 2nd Sunday March | DST ends: 1st Sunday November

const datetime CPI_DATES[] =
{
    //── 2022 ─────────────────────────────────────────────────────────────────
    D'2022.02.10 13:30',  // Jan-22  EST
    D'2022.03.10 13:30',  // Feb-22  EST  (DST starts Mar 13)
    D'2022.04.12 12:30',  // Mar-22  EDT
    D'2022.05.11 12:30',  // Apr-22  EDT
    D'2022.06.10 12:30',  // May-22  EDT
    D'2022.07.13 12:30',  // Jun-22  EDT
    D'2022.08.10 12:30',  // Jul-22  EDT
    D'2022.09.13 12:30',  // Aug-22  EDT
    D'2022.10.13 12:30',  // Sep-22  EDT
    D'2022.11.10 13:30',  // Oct-22  EST  (DST ends Nov 6)
    D'2022.12.13 13:30',  // Nov-22  EST
    //── 2023 ─────────────────────────────────────────────────────────────────
    D'2023.01.12 13:30',  // Dec-22  EST
    D'2023.02.14 13:30',  // Jan-23  EST
    D'2023.03.14 12:30',  // Feb-23  EDT  (DST starts Mar 12)
    D'2023.04.12 12:30',  // Mar-23  EDT
    D'2023.05.10 12:30',  // Apr-23  EDT
    D'2023.06.13 12:30',  // May-23  EDT
    D'2023.07.12 12:30',  // Jun-23  EDT
    D'2023.08.10 12:30',  // Jul-23  EDT
    D'2023.09.13 12:30',  // Aug-23  EDT
    D'2023.10.12 12:30',  // Sep-23  EDT
    D'2023.11.14 13:30',  // Oct-23  EST  (DST ends Nov 5)
    D'2023.12.12 13:30',  // Nov-23  EST
    //── 2024 ─────────────────────────────────────────────────────────────────
    D'2024.01.11 13:30',  // Dec-23  EST
    D'2024.02.13 13:30',  // Jan-24  EST
    D'2024.03.12 12:30',  // Feb-24  EDT  (DST starts Mar 10)
    D'2024.04.10 12:30',  // Mar-24  EDT
    D'2024.05.15 12:30',  // Apr-24  EDT
    D'2024.06.12 12:30',  // May-24  EDT
    D'2024.07.11 12:30',  // Jun-24  EDT
    D'2024.08.14 12:30',  // Jul-24  EDT
    D'2024.09.11 12:30',  // Aug-24  EDT
    D'2024.10.10 12:30',  // Sep-24  EDT
    D'2024.11.13 13:30',  // Oct-24  EST  (DST ends Nov 3)
    D'2024.12.11 13:30',  // Nov-24  EST
    //── 2025 ─────────────────────────────────────────────────────────────────
    D'2025.01.15 13:30',  // Dec-24  EST
    D'2025.02.12 13:30',  // Jan-25  EST
    D'2025.03.12 12:30',  // Feb-25  EDT  (DST starts Mar 9)
    D'2025.04.10 12:30',  // Mar-25  EDT
    D'2025.05.13 12:30',  // Apr-25  EDT
    D'2025.06.11 12:30',  // May-25  EDT
    D'2025.07.15 12:30',  // Jun-25  EDT
    D'2025.08.12 12:30',  // Jul-25  EDT
    D'2025.09.11 12:30',  // Aug-25  EDT
    D'2025.10.24 12:30',  // Sep-25  EDT
    D'2025.11.13 13:30',  // Oct-25  EST  (DST ends Nov 2)
    D'2025.12.18 13:30',  // Nov-25  EST
    //── 2026 ─────────────────────────────────────────────────────────────────
    D'2026.01.13 13:30',  // Dec-25  EST
    D'2026.02.13 13:30',  // Jan-26  EST
    D'2026.03.11 12:30',  // Feb-26  EDT  (DST starts Mar 8)
    D'2026.04.10 12:30',  // Mar-26  EDT
    D'2026.05.12 12:30',  // Apr-26  EDT
    D'2026.06.10 12:30',  // May-26  EDT
    D'2026.07.14 12:30',  // Jun-26  EDT
    D'2026.08.12 12:30',  // Jul-26  EDT
    D'2026.09.11 12:30',  // Aug-26  EDT
    D'2026.10.14 12:30',  // Sep-26  EDT
    D'2026.11.10 13:30',  // Oct-26  EST  (DST ends Nov 1)
    D'2026.12.10 13:30'   // Nov-26  EST
};

bool IsCPIDay()
{
    MqlDateTime today;
    TimeToStruct(TimeCurrent(), today);
    for(int i = 0; i < ArraySize(CPI_DATES); i++)
    {
        MqlDateTime d;
        TimeToStruct(CPI_DATES[i], d);
        if(d.year == today.year && d.mon == today.mon && d.day == today.day)
            return true;
    }
    return false;
}

//── NFP release dates (UTC) ──────────────────────────────────────────────────
//  First Friday of each month at 08:30 ET (US holiday-adjusted).
//  EST → 13:30 UTC | EDT → 12:30 UTC
//  DST 2026: starts Mar 8 | ends Nov 1
const datetime NFP_DATES[] =
{
    //── 2026 ───
    D'2026.01.09 13:30',  // Jan NFP  EST  (Jan 2 skipped – day after NYE)
    D'2026.02.06 13:30',  // Feb NFP  EST
    D'2026.03.06 13:30',  // Mar NFP  EST  ✓ confirmed
    D'2026.04.03 12:30',  // Apr NFP  EDT  ✓ confirmed
    D'2026.05.08 12:30',  // May NFP  EDT  ✓ confirmed (May 1 skipped)
    D'2026.06.05 12:30',  // Jun NFP  EDT
    D'2026.07.10 12:30',  // Jul NFP  EDT  (Jul 3 = observed Independence Day)
    D'2026.08.07 12:30',  // Aug NFP  EDT
    D'2026.09.04 12:30',  // Sep NFP  EDT
    D'2026.10.02 12:30',  // Oct NFP  EDT
    D'2026.11.06 13:30',  // Nov NFP  EST  (post-DST)
    D'2026.12.04 13:30',  // Dec NFP  EST
};

//── FOMC rate decision dates (UTC) ───────────────────────────────────────────
//  Statement 14:00 ET | press conference 14:30 ET.
//  EST → 19:00 UTC | EDT → 18:00 UTC  — all 8 confirmed federalreserve.gov
const datetime FOMC_DATES[] =
{
    //── 2026 ───
    D'2026.01.28 19:00',  // Jan FOMC  EST
    D'2026.03.18 18:00',  // Mar FOMC  EDT
    D'2026.04.29 18:00',  // Apr FOMC  EDT
    D'2026.06.17 18:00',  // Jun FOMC  EDT
    D'2026.07.29 18:00',  // Jul FOMC  EDT
    D'2026.09.16 18:00',  // Sep FOMC  EDT
    D'2026.10.28 18:00',  // Oct FOMC  EDT
    D'2026.12.09 19:00',  // Dec FOMC  EST
};

//── GDP Advance release dates (UTC) ──────────────────────────────────────────
//  First estimate only — 08:30 ET.  All confirmed bea.gov.
//  All three fall in EDT → 12:30 UTC
const datetime GDP_DATES[] =
{
    //── 2026 ───
    D'2026.04.30 12:30',  // Q1 GDP Advance  EDT
    D'2026.07.30 12:30',  // Q2 GDP Advance  EDT
    D'2026.10.29 12:30',  // Q3 GDP Advance  EDT
};

//── PPI release dates (UTC) ──────────────────────────────────────────────────
//  08:30 ET.  EST → 13:30 UTC | EDT → 12:30 UTC
//  Mar–May confirmed TradingEconomics; remainder estimated from BLS pattern.
const datetime PPI_DATES[] =
{
    //── 2026 ───
    D'2026.01.14 13:30',  // Jan PPI  EST  (estimated)
    D'2026.02.12 13:30',  // Feb PPI  EST  (estimated)
    D'2026.03.18 12:30',  // Mar PPI  EDT  ✓ confirmed
    D'2026.04.14 12:30',  // Apr PPI  EDT  ✓ confirmed
    D'2026.05.13 12:30',  // May PPI  EDT  ✓ confirmed
    D'2026.06.11 12:30',  // Jun PPI  EDT  (estimated)
    D'2026.07.14 12:30',  // Jul PPI  EDT  (estimated)
    D'2026.08.12 12:30',  // Aug PPI  EDT  (estimated)
    D'2026.09.10 12:30',  // Sep PPI  EDT  (estimated)
    D'2026.10.13 12:30',  // Oct PPI  EDT  (estimated)
    D'2026.11.10 13:30',  // Nov PPI  EST  (estimated)
    D'2026.12.10 13:30',  // Dec PPI  EST  (estimated)
};

bool IsNFPDay()
{
    MqlDateTime today;
    TimeToStruct(TimeCurrent(), today);
    for(int i = 0; i < ArraySize(NFP_DATES); i++)
    {
        MqlDateTime d;
        TimeToStruct(NFP_DATES[i], d);
        if(d.year == today.year && d.mon == today.mon && d.day == today.day)
            return true;
    }
    return false;
}

bool IsFOMCDay()
{
    MqlDateTime today;
    TimeToStruct(TimeCurrent(), today);
    for(int i = 0; i < ArraySize(FOMC_DATES); i++)
    {
        MqlDateTime d;
        TimeToStruct(FOMC_DATES[i], d);
        if(d.year == today.year && d.mon == today.mon && d.day == today.day)
            return true;
    }
    return false;
}

bool IsGDPDay()
{
    MqlDateTime today;
    TimeToStruct(TimeCurrent(), today);
    for(int i = 0; i < ArraySize(GDP_DATES); i++)
    {
        MqlDateTime d;
        TimeToStruct(GDP_DATES[i], d);
        if(d.year == today.year && d.mon == today.mon && d.day == today.day)
            return true;
    }
    return false;
}

bool IsPPIDay()
{
    MqlDateTime today;
    TimeToStruct(TimeCurrent(), today);
    for(int i = 0; i < ArraySize(PPI_DATES); i++)
    {
        MqlDateTime d;
        TimeToStruct(PPI_DATES[i], d);
        if(d.year == today.year && d.mon == today.mon && d.day == today.day)
            return true;
    }
    return false;
}

bool IsNewsDay()
{
    return IsCPIDay() || IsNFPDay() || IsFOMCDay() || IsGDPDay() || IsPPIDay();
}


//── Utility functions ────────────────────────────────────────────────────────

double GetPipSize()
{
    int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
    double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    return (digits == 3 || digits == 5) ? point * 10.0 : point;
}

bool InWindow(int h, int start, int end)
{
    // Handles midnight-spanning windows (start > end)
    if(start > end)
        return (h >= start || h < end);
    return (h >= start && h < end);
}

bool IsAllowedSession()
{
    if(!InpUseSessionFilter) return true;
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int h = (dt.hour + InpGMTOffset + 24) % 24;
    return (InpAsianStartH  != InpAsianEndH  && InWindow(h, InpAsianStartH,  InpAsianEndH))  ||
           (InpLondonStartH != InpLondonEndH && InWindow(h, InpLondonStartH, InpLondonEndH)) ||
           (InpNYStartH     != InpNYEndH     && InWindow(h, InpNYStartH,     InpNYEndH));
}

int GetCurrentPeriod()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    return dt.hour * 2 + (dt.min >= 30 ? 1 : 0);
}

void ResetDailyCounters()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    dt.hour = 0; dt.min = 0; dt.sec = 0;
    datetime today = StructToTime(dt);
    if(today != g_lastResetDay)
    {
        ArrayFill(g_periodTrades, 0, 48, 0);
        g_lastResetDay = today;
    }
}

bool ParsePeriods(string periods)
{
    if(periods == "ALL" || periods == "")
    {
        ArrayFill(g_periodAllowed, 0, 48, true);
        return true;
    }
    ArrayFill(g_periodAllowed, 0, 48, false);
    string parts[];
    int cnt = StringSplit(periods, ',', parts);
    for(int i = 0; i < cnt; i++)
    {
        StringTrimLeft(parts[i]);
        StringTrimRight(parts[i]);
        string p = parts[i];
        int idx = (int)StringToInteger(p);
        if(idx >= 0 && idx < 48)
            g_periodAllowed[idx] = true;
    }
    return true;
}

double CalcATR(const double &high[], const double &low[], const double &close[],
               int period, int offset)
{
    // Arrays are AsSeries=true: index 0 = most recent
    double sum = 0.0;
    int    count = 0;
    for(int i = offset; i < offset + period && i + 1 < ArraySize(high); i++)
    {
        double tr = MathMax(high[i] - low[i],
                   MathMax(MathAbs(high[i] - close[i+1]),
                           MathAbs(low[i]  - close[i+1])));
        sum += tr;
        count++;
    }
    return count > 0 ? sum / count : 0.001;
}

double CalcLots(double entryPrice, double slPrice)
{
    double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmt    = balance * InpRiskPercent / 100.0;
    double slDist     = MathAbs(entryPrice - slPrice);
    double tickSize   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
    double tickValue  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
    double volMin     = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
    double volMax     = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
    double volStep    = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

    if(slDist == 0 || tickSize == 0 || tickValue == 0) return volMin;

    double valPerPt = tickValue / tickSize;
    double lot      = riskAmt / (slDist * valPerPt);
    double maxLot   = MathMin(volMax, InpMaxLots);
    lot = MathMax(volMin, MathMin(maxLot, lot));
    if(volStep > 0)
        lot = MathFloor(lot / volStep) * volStep;
    return NormalizeDouble(lot, 2);
}


//── Stops-level guard ────────────────────────────────────────────────────────
// Clamps SL and TP to the broker's minimum stop distance from entry.
// Logs a warning if either level had to be adjusted.
void ValidateLevels(double entry, double &sl, double &tp, bool isShort)
{
    long   stopsLvl = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
    double minDist  = stopsLvl * SymbolInfoDouble(Symbol(), SYMBOL_POINT);

    if(minDist <= 0) return;   // broker imposes no minimum

    if(isShort)
    {
        double minSL = entry + minDist;
        double maxTP = entry - minDist;
        if(sl < minSL)
        {
            PrintFormat("AMD WARN: SL %.5f too close (min dist %.5f pts) — clamped to %.5f",
                        sl, minDist, minSL);
            sl = minSL;
        }
        if(tp > maxTP)
        {
            PrintFormat("AMD WARN: TP %.5f too close (min dist %.5f pts) — clamped to %.5f",
                        tp, minDist, maxTP);
            tp = maxTP;
        }
    }
    else
    {
        double minSL = entry - minDist;
        double maxTP = entry + minDist;
        if(sl > minSL)
        {
            PrintFormat("AMD WARN: SL %.5f too close (min dist %.5f pts) — clamped to %.5f",
                        sl, minDist, minSL);
            sl = minSL;
        }
        if(tp < maxTP)
        {
            PrintFormat("AMD WARN: TP %.5f too close (min dist %.5f pts) — clamped to %.5f",
                        tp, minDist, maxTP);
            tp = maxTP;
        }
    }
}


//── Chart drawing helpers ────────────────────────────────────────────────────

void DeleteObjects(string prefix)
{
    int total = ObjectsTotal(0);
    for(int i = total - 1; i >= 0; i--)
    {
        string name = ObjectName(0, i);
        if(StringFind(name, prefix) == 0)
            ObjectDelete(0, name);
    }
}

void DrawZone(string name, datetime t1, double price1,
              datetime t2, double price2, color clr, int alpha = 80)
{
    if(!InpDrawObjects) return;
    if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
    ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, price1, t2, price2);
    ObjectSetInteger(0, name, OBJPROP_COLOR,        clr);
    ObjectSetInteger(0, name, OBJPROP_FILL,         true);
    ObjectSetInteger(0, name, OBJPROP_BACK,         true);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE,   false);
}

void DrawHLine(string name, datetime t1, datetime t2, double price, color clr,
               int width = 1, ENUM_LINE_STYLE style = STYLE_DASH)
{
    // OBJ_TREND used as a bounded horizontal segment (RAY_RIGHT=false)
    // t2 is set to FAR_FUTURE at draw time and snapped to close time on trade exit
    if(!InpDrawObjects) return;
    if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
    ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
    ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
    ObjectSetInteger(0, name, OBJPROP_WIDTH,     width);
    ObjectSetInteger(0, name, OBJPROP_STYLE,     style);
    ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
    ObjectSetInteger(0, name, OBJPROP_RAY_LEFT,  false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void DrawSetupLines(string sfx, datetime t1, datetime t2, double entry, double sl, double tp)
{
    if(!InpDrawObjects) return;
    DrawHLine("AMD_Entry_" + sfx, t1, t2, entry, clrDodgerBlue, 2, STYLE_SOLID);
    DrawHLine("AMD_SL_"    + sfx, t1, t2, sl,    clrRed,        1, STYLE_DASH);
    DrawHLine("AMD_TP_"    + sfx, t1, t2, tp,    clrLime,       1, STYLE_DASH);
}

void FinalizeSetupDrawings(string sfx, datetime closeTime)
{
    // Snap right edge of all bounded objects to the actual trade close bar
    string names[] = {"AMD_Midpt_", "AMD_Entry_", "AMD_SL_", "AMD_TP_"};
    for(int i = 0; i < ArraySize(names); i++)
    {
        string name = names[i] + sfx;
        if(ObjectFind(0, name) >= 0)
            ObjectSetInteger(0, name, OBJPROP_TIME, 1, (long)closeTime);
    }
}

void DrawLabel(string name, datetime t, double price, string text, color clr)
{
    if(!InpDrawObjects) return;
    if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
    ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
    ObjectSetString(0, name,  OBJPROP_TEXT,  text);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}


//── RSI calculation (Wilder smoothing, AsSeries arrays) ─────────────────────
double CalcRSI(const double &close[], int period, int offset)
{
    int needed = period + 1 + offset;
    if(ArraySize(close) < needed) return 50.0;   // neutral fallback

    double gain = 0.0, loss = 0.0;
    // Seed with simple average over first `period` changes
    for(int i = offset; i < offset + period; i++)
    {
        double change = close[i] - close[i + 1];
        if(change > 0) gain += change;
        else           loss -= change;
    }
    gain /= period;
    loss /= period;
    if(loss == 0) return 100.0;

    double rs = gain / loss;
    return 100.0 - 100.0 / (1.0 + rs);
}


//── Accumulation detection ───────────────────────────────────────────────────
//
//  Checks that the most recent InpAccumBars completed bars form a tight range.
//  ATR is measured from bars AFTER (older than) the accumulation window so it
//  reflects normal pre-accumulation volatility — not the tight range itself.
//  Condition: accumulation range < InpAccumATRMult × that external ATR.
//
//  Direction (Rule 2) is determined in RunStrategy via price position in range:
//    %K = (close - rangeLow) / rangeHeight × 100
//    %K ≥ InpOverbought → SHORT   (price in upper portion — overbought)
//    %K ≤ InpOversold   → LONG    (price in lower portion — oversold)

bool DetectAccum(
    const double &high[], const double &low[], const double &close[], const datetime &times[],
    int totalBars,
    double &outRangeHigh, double &outRangeLow, double &outMidpoint,
    datetime &outAccumT1, datetime &outAccumT2
)
{
    // Need accumulation bars + ATR reference bars (14) beyond them
    if(InpAccumBars + 16 >= totalBars) return false;

    // ATR from the 14 bars just before the accumulation window (external reference)
    double atr = CalcATR(high, low, close, 14, InpAccumBars);
    if(atr <= 0) return false;

    double rHigh = -DBL_MAX, rLow = DBL_MAX;
    for(int i = 0; i < InpAccumBars; i++)
    {
        if(high[i] > rHigh) rHigh = high[i];
        if(low[i]  < rLow)  rLow  = low[i];
    }

    double rHeight = rHigh - rLow;
    if(rHeight <= 0 || rHeight > InpAccumATRMult * atr) return false;

    outRangeHigh = rHigh;
    outRangeLow  = rLow;
    outMidpoint  = (rHigh + rLow) / 2.0;
    outAccumT1   = times[InpAccumBars - 1];   // oldest bar of the accumulation window
    outAccumT2   = times[0];                   // most recent completed bar
    return true;
}


//── Run strategy (called on each new bar) ────────────────────────────────────

void RunStrategy()
{
    // Rule 10: day quality — skipped entirely when both inputs are false (run all days)
    if(InpUseCPICalendar || InpHighProbDay)
    {
        bool highProbDay = (InpUseCPICalendar && IsNewsDay()) || InpHighProbDay;
        if(!highProbDay)
        {
            if(InpDiagnostic) Print("AMD DIAG [R10] BLOCKED — not a news day and InpHighProbDay=false");
            return;
        }
    }

    // Rule 8: session filter
    if(!IsAllowedSession())
    {
        if(InpDiagnostic) Print("AMD DIAG [R8] BLOCKED — outside allowed session");
        return;
    }

    // Rule 7 + 9: period filter
    int curPeriod = GetCurrentPeriod();
    if(InpUsePeriodFilter)
    {
        if(!g_periodAllowed[curPeriod])
        {
            if(InpDiagnostic) PrintFormat("AMD DIAG [R7] BLOCKED — period %d not in allowed list", curPeriod);
            return;
        }
        if(g_periodTrades[curPeriod] >= InpMaxTradesPerPeriod)
        {
            if(InpDiagnostic) PrintFormat("AMD DIAG [R9] BLOCKED — period %d trade limit reached (%d)", curPeriod, InpMaxTradesPerPeriod);
            return;
        }
    }

    // Already have a position for this EA?
    if(PositionsTotal() > 0)
    {
        for(int i = 0; i < PositionsTotal(); i++)
        {
            if(PositionGetTicket(i) > 0 &&
               PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
               PositionGetString(POSITION_SYMBOL) == Symbol())
                return;   // already in a trade — wait for it to close
        }
    }

    // Fetch bars (AsSeries=true, pos=1 skips forming bar)
    int    needed = InpCandleCount;
    double highArr[], lowArr[], closeArr[];
    datetime timeArr[];
    ArraySetAsSeries(highArr,  true);
    ArraySetAsSeries(lowArr,   true);
    ArraySetAsSeries(closeArr, true);
    ArraySetAsSeries(timeArr,  true);

    int copied = CopyHigh(Symbol(), Period(), 1, needed, highArr);
    if(copied < InpAccumBars + 18) return;   // accum + ATR reference window
    CopyLow  (Symbol(), Period(), 1, needed, lowArr);
    CopyClose(Symbol(), Period(), 1, needed, closeArr);
    CopyTime (Symbol(), Period(), 1, needed, timeArr);

    int totalBars = copied;

    double   rangeHigh, rangeLow, midpoint;
    datetime accumT1, accumT2;

    if(!DetectAccum(highArr, lowArr, closeArr, timeArr, totalBars,
                    rangeHigh, rangeLow, midpoint, accumT1, accumT2))
    {
        if(InpDiagnostic) PrintFormat("AMD DIAG [R1] no accum — range too wide or too few bars  bars=%d", totalBars);
        return;
    }

    double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    datetime now = TimeCurrent();
    string sfx = StringFormat("%d", (int)accumT1);

    // ── Rule 2: price position within accumulation range (stochastic %K) ───────
    double rHeight = rangeHigh - rangeLow;
    double pctK    = (rHeight > 0) ? (closeArr[0] - rangeLow) / rHeight * 100.0 : 50.0;

    // Always log — confirms detection is firing even without InpDiagnostic
    PrintFormat("AMD ACCUM DETECTED  high=%.5f  low=%.5f  mid=%.5f  %%K=%.1f  bid=%.5f  ask=%.5f",
                rangeHigh, rangeLow, midpoint, pctK, bid, ask);

    bool doShort = (pctK >= InpOverbought);   // price in upper portion → SHORT
    bool doLong  = (pctK <= InpOversold);     // price in lower portion → LONG

    if(!doShort && !doLong)
    {
        if(InpDiagnostic)
            PrintFormat("AMD DIAG [R2] %%K=%.1f neutral (need >= %.0f SHORT or <= %.0f LONG) — no entry",
                        pctK, InpOverbought, InpOversold);
        return;
    }

    if(doShort)
    {
        double entry = bid;
        double sl    = InpUsePipSL ? entry + InpManualSLPips * g_pipSize
                                   : rangeHigh + InpSLPips * g_pipSize;
        double tp;
        if(InpUsePipTP)
            tp = entry - InpTPPips * g_pipSize;
        else
        {
            double risk = sl - entry;
            tp = (risk > 0) ? entry - risk * InpRiskReward
                            : rangeLow - InpTPBufferPips * g_pipSize;
        }

        ValidateLevels(entry, sl, tp, true);

        if(tp >= entry)
        {
            if(InpDiagnostic) PrintFormat("AMD DIAG SHORT [R4] BLOCKED — TP %.5f >= entry %.5f", tp, entry);
            return;
        }

        double risk   = sl - entry;
        double reward = entry - tp;
        double rr     = (risk > 0) ? reward / risk : 0.0;
        if(InpMinRR > 0 && rr < InpMinRR)
        {
            if(InpDiagnostic) PrintFormat("AMD DIAG SHORT [R4] BLOCKED — RR %.2f < min %.2f", rr, InpMinRR);
            return;
        }

        double lots = (InpManualLots > 0) ? InpManualLots : CalcLots(entry, sl);

        DrawZone("AMD_Accum_"  + sfx, accumT1, rangeHigh, accumT2, rangeLow,  InpAccumColor);
        DrawHLine("AMD_Midpt_" + sfx, accumT1, FAR_FUTURE, midpoint, InpMidpointColor, 1, STYLE_DOT);
        DrawSetupLines(sfx, now, FAR_FUTURE, entry, sl, tp);
        DrawLabel("AMD_Lbl_"   + sfx, now, entry, StringFormat("SHORT  SL:%.5f  TP:%.5f  RR:1:%.1f", sl, tp, rr), clrOrangeRed);

        string alertMsg = StringFormat(
            "AMD SHORT  %s [%s]\n"
            "Accumulation : %.5f – %.5f  mid=%.5f\n"
            "Entry        : %.5f\n"
            "Stop Loss    : %.5f  (%.1f pips)\n"
            "Take Profit  : %.5f  (%.1f pips)\n"
            "Risk:Reward  : 1:%.2f\n"
            "Lots         : %.2f",
            Symbol(), EnumToString(Period()),
            rangeLow, rangeHigh, midpoint,
            entry, sl, (sl - entry) / g_pipSize,
            tp,    (entry - tp)  / g_pipSize,
            rr, lots);

        if(InpManualConfirm)
        {
            Alert(alertMsg);
            Print("AMD SHORT ALERT:\n" + alertMsg);
        }
        else
        {
            if(Trade.Sell(lots, Symbol(), bid, sl, tp, "AMD_v1.02"))
            {
                g_periodTrades[curPeriod]++;
                g_openTicket = Trade.ResultOrder();
                g_openSfx    = sfx;
                Print("AMD SHORT EXECUTED  ticket=", g_openTicket,
                      "  lots=", lots, "  entry=", bid, "  sl=", sl, "  tp=", tp);
            }
            else
                Print("AMD SELL FAILED  retcode=", Trade.ResultRetcode(), "  ", Trade.ResultComment());
        }
    }
    else // doLong
    {
        double entry = ask;
        double sl    = InpUsePipSL ? entry - InpManualSLPips * g_pipSize
                                   : rangeLow - InpSLPips * g_pipSize;
        double tp;
        if(InpUsePipTP)
            tp = entry + InpTPPips * g_pipSize;
        else
        {
            double risk = entry - sl;
            tp = (risk > 0) ? entry + risk * InpRiskReward
                            : rangeHigh + InpTPBufferPips * g_pipSize;
        }

        ValidateLevels(entry, sl, tp, false);

        if(tp <= entry)
        {
            if(InpDiagnostic) PrintFormat("AMD DIAG LONG [R4] BLOCKED — TP %.5f <= entry %.5f", tp, entry);
            return;
        }

        double risk   = entry - sl;
        double reward = tp - entry;
        double rr     = (risk > 0) ? reward / risk : 0.0;
        if(InpMinRR > 0 && rr < InpMinRR)
        {
            if(InpDiagnostic) PrintFormat("AMD DIAG LONG [R4] BLOCKED — RR %.2f < min %.2f", rr, InpMinRR);
            return;
        }

        double lots = (InpManualLots > 0) ? InpManualLots : CalcLots(entry, sl);

        DrawZone("AMD_Accum_"  + sfx, accumT1, rangeHigh, accumT2, rangeLow,  InpAccumColor);
        DrawHLine("AMD_Midpt_" + sfx, accumT1, FAR_FUTURE, midpoint, InpMidpointColor, 1, STYLE_DOT);
        DrawSetupLines(sfx, now, FAR_FUTURE, entry, sl, tp);
        DrawLabel("AMD_Lbl_"   + sfx, now, entry, StringFormat("LONG  SL:%.5f  TP:%.5f  RR:1:%.1f", sl, tp, rr), clrLimeGreen);

        string alertMsg = StringFormat(
            "AMD LONG  %s [%s]\n"
            "Accumulation : %.5f – %.5f  mid=%.5f\n"
            "Entry        : %.5f\n"
            "Stop Loss    : %.5f  (%.1f pips)\n"
            "Take Profit  : %.5f  (%.1f pips)\n"
            "Risk:Reward  : 1:%.2f\n"
            "Lots         : %.2f",
            Symbol(), EnumToString(Period()),
            rangeLow, rangeHigh, midpoint,
            entry, sl, (entry - sl) / g_pipSize,
            tp,    (tp - entry)    / g_pipSize,
            rr, lots);

        if(InpManualConfirm)
        {
            Alert(alertMsg);
            Print("AMD LONG ALERT:\n" + alertMsg);
        }
        else
        {
            if(Trade.Buy(lots, Symbol(), ask, sl, tp, "AMD_v1.02"))
            {
                g_periodTrades[curPeriod]++;
                g_openTicket = Trade.ResultOrder();
                g_openSfx    = sfx;
                Print("AMD LONG EXECUTED  ticket=", g_openTicket,
                      "  lots=", lots, "  entry=", ask, "  sl=", sl, "  tp=", tp);
            }
            else
                Print("AMD BUY FAILED  retcode=", Trade.ResultRetcode(), "  ", Trade.ResultComment());
        }
    }
}


//── Lifecycle ─────────────────────────────────────────────────────────────────

int OnInit()
{
    Trade.SetExpertMagicNumber(InpMagicNumber);
    Trade.SetDeviationInPoints(InpSlippage);
    Trade.SetTypeFilling(ORDER_FILLING_IOC);

    g_pipSize = GetPipSize();

    ParsePeriods(InpAllowedPeriods);
    ArrayFill(g_periodTrades, 0, 48, 0);
    ResetDailyCounters();

    long   stopsLvl  = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
    double minStopPt = stopsLvl * SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    Print("AMD Strategy EA  v1.02  initialized  |  ", Symbol(), " [", EnumToString(Period()), "]");
    PrintFormat("  Pip size        : %.5f  (SYMBOL_POINT=%.5f  DIGITS=%d)",
                g_pipSize, SymbolInfoDouble(Symbol(), SYMBOL_POINT), (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS));
    PrintFormat("  Min stop dist   : %d pts = %.5f price units",
                (int)stopsLvl, minStopPt);
    if(InpUsePipSL)
        PrintFormat("  Manual SL dist  : %.1f pips = %.5f price units  (%.5f needed)",
                    InpManualSLPips, InpManualSLPips * g_pipSize, minStopPt);
    if(InpUsePipTP)
        PrintFormat("  Manual TP dist  : %.1f pips = %.5f price units  (%.5f needed)",
                    InpTPPips, InpTPPips * g_pipSize, minStopPt);

    bool newsToday = IsNewsDay();
    PrintFormat("  News day today   : %s%s%s%s%s",
        newsToday ? "YES — " : "no  |  ",
        IsCPIDay()  ? "CPI "  : "",
        IsNFPDay()  ? "NFP "  : "",
        IsFOMCDay() ? "FOMC " : "",
        IsGDPDay()  ? "GDP "  : "");
    if(IsPPIDay() && newsToday) Print("                     PPI");
    if(!InpUseCPICalendar && !InpHighProbDay)
        Print("  [DAY FILTER OFF] Running all days — no news-day restriction");
    else if(!((InpUseCPICalendar && newsToday) || InpHighProbDay))
        Print("  [PAUSED] Not a news day — set InpHighProbDay=true to override");
    if(InpManualConfirm)
        Print("  [ALERT MODE] Auto-execute disabled — InpManualConfirm=true");

    return INIT_SUCCEEDED;
}

void OnTick()
{
    // Bar-open gate: only process on new completed bar
    datetime barTime = iTime(Symbol(), Period(), 1);
    if(barTime == g_lastBar) return;
    g_lastBar = barTime;

    ResetDailyCounters();
    RunStrategy();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest    &request,
                        const MqlTradeResult     &result)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

    ulong deal = trans.deal;
    if(!HistoryDealSelect(deal)) return;
    if(HistoryDealGetInteger(deal, DEAL_MAGIC)  != InpMagicNumber) return;
    if(HistoryDealGetString(deal,  DEAL_SYMBOL) != Symbol())       return;

    ENUM_DEAL_ENTRY de = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
    if(de != DEAL_ENTRY_OUT && de != DEAL_ENTRY_INOUT)             return;

    datetime closeTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
    if(g_openSfx != "")
        FinalizeSetupDrawings(g_openSfx, closeTime);

    g_openSfx    = "";
    g_openTicket = 0;
}

void OnDeinit(const int reason)
{
    Print("AMD Strategy EA  v1.02  removed.");
}
