//+------------------------------------------------------------------+
//|  AMD Strategy — Accumulation · Manipulation · Distribution       |
//|  Playbook by Tanja Trade (ChartFanatics AMD Method)             |
//|                                                                   |
//|  SETUP SEQUENCE                                                   |
//|  Rule 1  — Accumulation: N bars tight range                      |
//|             Range height < InpAccumATRMult × ATR(14)            |
//|             StdDev(close) < InpAccumStdDevMult × ATR(14)        |
//|  Rule 2  — Direction via VWAP (InpVWAPMode)                     |
//|             Default: price < VWAP = LONG | > VWAP = SHORT       |
//|  Rule 3  — Entry at accumulation midpoint                       |
//|             LONG : ask ≤ midpoint  |  SHORT: bid ≥ midpoint     |
//|  Rule 4  — SL beyond range boundary + InpSLPips buffer          |
//|  Rule 5  — TP: R:R ratio or fixed pips                          |
//|  Rule 6  — Counter-trade after InpCounterMovePts move           |
//|             Opposite direction, TP = X/2, SL = X/4              |
//|  Rule 7  — Period filter: 48 × 30-min UTC slots                 |
//|  Rule 8  — ICT Session filter                                   |
//|  Rule 9  — Max trades per period per day                        |
//|  Rule 10 — Day quality: news-day filter (CPI/NFP/FOMC/GDP/PPI)  |
//|                                                                   |
//|  Chart drawing marks EVERY detected accumulation for backtesting |
//|                                                                   |
//|─────────────────── VERSION HISTORY ─────────────────────────────|
//|  v1.10  2026-04-30  — VWAP direction + midpoint entry           |
//|    · Accumulation detection rebuilt from v1.00 parameters       |
//|    · StdDev(close) tightness filter (InpAccumStdDevMult=1.5)    |
//|    · Direction: VWAP-based, 5 modes via InpVWAPMode             |
//|    · Entry: ask/bid vs midpoint (lower/upper half of range)     |
//|    · Counter-trade: opposite dir after InpCounterMovePts move   |
//|      TP=X/2  SL=X/4  (default $80 trigger / $40 TP / $20 SL)   |
//|    · Draws ALL detected accumulations for backtesting           |
//|  v1.02  2026-04-30  — NFP/FOMC/GDP/PPI calendar                 |
//|  v1.01  2026-04-27  — CPI calendar auto-detection               |
//|  v1.00  2026-04-26  — Initial release                            |
//+------------------------------------------------------------------+
#property copyright "AMD Strategy EA  v1.10"
#property version   "1.10"
#property description "AMD — Accumulation · Manipulation · Distribution  v1.10"
#property strict

#include <Trade\Trade.mqh>

//── VWAP mode enum ───────────────────────────────────────────────────────────

enum ENUM_VWAP_MODE
{
    VWAP_DEFAULT    = 0,  // Below VWAP = LONG, Above VWAP = SHORT (default)
    VWAP_INVERTED   = 1,  // Above VWAP = LONG, Below VWAP = SHORT
    VWAP_LONG_ONLY  = 2,  // Always LONG (VWAP not used for direction)
    VWAP_SHORT_ONLY = 3,  // Always SHORT (VWAP not used for direction)
    VWAP_DISABLED   = 4,  // Both directions allowed, no VWAP filter
};

//── Inputs ──────────────────────────────────────────────────────────────────

input group "=== Rule 10 — Day Quality & Execution Mode ==="
input bool          InpUseCPICalendar  = false; // Gate on news days: CPI/NFP/FOMC/GDP/PPI
input bool          InpHighProbDay     = false; // Manual override (both false = run every day)
input bool          InpManualConfirm   = true;  // true = Alert only | false = Auto-execute

input group "=== Risk Management ==="
input double InpRiskPercent        = 1.0;    // Risk per trade (% of balance)
input double InpMinRR              = 1.5;    // Minimum R:R ratio (0 = disabled)
input double InpMaxLots            = 5.0;    // Hard cap on position size
input double InpManualLots         = 0.0;    // Override lot size (0 = auto)

input group "=== Rule 4-5 — SL / TP Settings ==="
input bool   InpUsePipSL           = false;  // false = range boundary + buffer | true = fixed pips
input double InpManualSLPips       = 20.0;   // Fixed SL in pips (when InpUsePipSL=true)
input double InpSLPips             = 10.0;   // Buffer beyond range boundary
input bool   InpUsePipTP           = false;  // false = R:R ratio | true = fixed pips
input double InpTPPips             = 20.0;   // Fixed TP in pips (when InpUsePipTP=true)
input double InpRiskReward         = 2.0;    // TP = entry ± risk × this
input double InpTPBufferPips       = 5.0;    // Extra buffer beyond range (fallback TP)

input group "=== Rule 1 — Accumulation Detection ==="
input int    InpAccumBars          = 20;     // Lookback bars for accumulation
input double InpAccumATRMult       = 1.5;    // Range height < mult × ATR(14)
input double InpAccumStdDevMult    = 1.5;    // StdDev(close) < mult × ATR(14) — tightness gate
input int    InpCandleCount        = 60;     // Bars to fetch per scan

input group "=== Rule 2 — VWAP Direction ==="
input ENUM_VWAP_MODE InpVWAPMode   = VWAP_DEFAULT; // Direction mode (see enum)

input group "=== Rule 6 — Counter-Trade ==="
input bool   InpCounterEnable      = true;   // Enable concurrent counter-trade
input double InpCounterMovePts     = 80.0;   // Price move to trigger counter (e.g. 80 = $80 for XAUUSD)
                                              // TP = X/2 = 40pts | SL = X/4 = 20pts

input group "=== Rule 7 — Period Filter (48 × 30-min UTC Slots) ==="
input bool   InpUsePeriodFilter    = false;
input string InpAllowedPeriods     = "ALL";  // ALL or comma-separated 0-47
input int    InpMaxTradesPerPeriod = 2;

input group "=== Rule 8 — ICT Session Filter ==="
input bool   InpUseSessionFilter   = false;
input int    InpGMTOffset          = 0;
input int    InpAsianStartH        = 23;
input int    InpAsianEndH          = 9;
input int    InpLondonStartH       = 7;
input int    InpLondonEndH         = 16;
input int    InpNYStartH           = 12;
input int    InpNYEndH             = 21;

input group "=== Chart Display ==="
input bool   InpDrawObjects        = true;
input color  InpAccumColor         = clrSteelBlue;
input color  InpMidpointColor      = clrGold;
input color  InpCounterColor       = clrOrange;

input group "=== Trade Settings ==="
input int    InpMagicNumber        = 20260501;
input int    InpSlippage           = 20;

input group "=== Diagnostics ==="
input bool   InpDiagnostic         = false;

//── Globals ──────────────────────────────────────────────────────────────────

CTrade Trade;

bool     g_periodAllowed[48];
int      g_periodTrades[48];
datetime g_lastResetDay  = 0;
datetime g_lastBar       = 0;
double   g_pipSize       = 0.0;

// Primary trade
string   g_primarySfx    = "";
ulong    g_primaryTicket = 0;
double   g_primaryEntry  = 0.0;
bool     g_primaryIsLong = false;

// Counter-trade
ulong    g_counterTicket = 0;
bool     g_counterDone   = false;

const datetime FAR_FUTURE = D'2099.12.31 00:00';


//── CPI release calendar (UTC) ───────────────────────────────────────────────

const datetime CPI_DATES[] =
{
    //── 2022 ─────────────────────────────────────────────────────────────────
    D'2022.02.10 13:30',  // Jan-22  EST
    D'2022.03.10 13:30',  // Feb-22  EST
    D'2022.04.12 12:30',  // Mar-22  EDT
    D'2022.05.11 12:30',  // Apr-22  EDT
    D'2022.06.10 12:30',  // May-22  EDT
    D'2022.07.13 12:30',  // Jun-22  EDT
    D'2022.08.10 12:30',  // Jul-22  EDT
    D'2022.09.13 12:30',  // Aug-22  EDT
    D'2022.10.13 12:30',  // Sep-22  EDT
    D'2022.11.10 13:30',  // Oct-22  EST
    D'2022.12.13 13:30',  // Nov-22  EST
    //── 2023 ─────────────────────────────────────────────────────────────────
    D'2023.01.12 13:30',  // Dec-22  EST
    D'2023.02.14 13:30',  // Jan-23  EST
    D'2023.03.14 12:30',  // Feb-23  EDT
    D'2023.04.12 12:30',  // Mar-23  EDT
    D'2023.05.10 12:30',  // Apr-23  EDT
    D'2023.06.13 12:30',  // May-23  EDT
    D'2023.07.12 12:30',  // Jun-23  EDT
    D'2023.08.10 12:30',  // Jul-23  EDT
    D'2023.09.13 12:30',  // Aug-23  EDT
    D'2023.10.12 12:30',  // Sep-23  EDT
    D'2023.11.14 13:30',  // Oct-23  EST
    D'2023.12.12 13:30',  // Nov-23  EST
    //── 2024 ─────────────────────────────────────────────────────────────────
    D'2024.01.11 13:30',  // Dec-23  EST
    D'2024.02.13 13:30',  // Jan-24  EST
    D'2024.03.12 12:30',  // Feb-24  EDT
    D'2024.04.10 12:30',  // Mar-24  EDT
    D'2024.05.15 12:30',  // Apr-24  EDT
    D'2024.06.12 12:30',  // May-24  EDT
    D'2024.07.11 12:30',  // Jun-24  EDT
    D'2024.08.14 12:30',  // Jul-24  EDT
    D'2024.09.11 12:30',  // Aug-24  EDT
    D'2024.10.10 12:30',  // Sep-24  EDT
    D'2024.11.13 13:30',  // Oct-24  EST
    D'2024.12.11 13:30',  // Nov-24  EST
    //── 2025 ─────────────────────────────────────────────────────────────────
    D'2025.01.15 13:30',  // Dec-24  EST
    D'2025.02.12 13:30',  // Jan-25  EST
    D'2025.03.12 12:30',  // Feb-25  EDT
    D'2025.04.10 12:30',  // Mar-25  EDT
    D'2025.05.13 12:30',  // Apr-25  EDT
    D'2025.06.11 12:30',  // May-25  EDT
    D'2025.07.15 12:30',  // Jun-25  EDT
    D'2025.08.12 12:30',  // Jul-25  EDT
    D'2025.09.11 12:30',  // Aug-25  EDT
    D'2025.10.24 12:30',  // Sep-25  EDT
    D'2025.11.13 13:30',  // Oct-25  EST
    D'2025.12.18 13:30',  // Nov-25  EST
    //── 2026 ─────────────────────────────────────────────────────────────────
    D'2026.01.13 13:30',  // Dec-25  EST
    D'2026.02.13 13:30',  // Jan-26  EST
    D'2026.03.11 12:30',  // Feb-26  EDT
    D'2026.04.10 12:30',  // Mar-26  EDT
    D'2026.05.12 12:30',  // Apr-26  EDT
    D'2026.06.10 12:30',  // May-26  EDT
    D'2026.07.14 12:30',  // Jun-26  EDT
    D'2026.08.12 12:30',  // Jul-26  EDT
    D'2026.09.11 12:30',  // Aug-26  EDT
    D'2026.10.14 12:30',  // Sep-26  EDT
    D'2026.11.10 13:30',  // Oct-26  EST
    D'2026.12.10 13:30'   // Nov-26  EST
};

//── NFP release dates (UTC) ──────────────────────────────────────────────────
const datetime NFP_DATES[] =
{
    D'2026.01.09 13:30',  D'2026.02.06 13:30',  D'2026.03.06 13:30',
    D'2026.04.03 12:30',  D'2026.05.08 12:30',  D'2026.06.05 12:30',
    D'2026.07.10 12:30',  D'2026.08.07 12:30',  D'2026.09.04 12:30',
    D'2026.10.02 12:30',  D'2026.11.06 13:30',  D'2026.12.04 13:30',
};

//── FOMC rate decision dates (UTC) ───────────────────────────────────────────
const datetime FOMC_DATES[] =
{
    D'2026.01.28 19:00',  D'2026.03.18 18:00',  D'2026.04.29 18:00',
    D'2026.06.17 18:00',  D'2026.07.29 18:00',  D'2026.09.16 18:00',
    D'2026.10.28 18:00',  D'2026.12.09 19:00',
};

//── GDP Advance release dates (UTC) ──────────────────────────────────────────
const datetime GDP_DATES[] =
{
    D'2026.04.30 12:30',  D'2026.07.30 12:30',  D'2026.10.29 12:30',
};

//── PPI release dates (UTC) ──────────────────────────────────────────────────
const datetime PPI_DATES[] =
{
    D'2026.01.14 13:30',  D'2026.02.12 13:30',  D'2026.03.18 12:30',
    D'2026.04.14 12:30',  D'2026.05.13 12:30',  D'2026.06.11 12:30',
    D'2026.07.14 12:30',  D'2026.08.12 12:30',  D'2026.09.10 12:30',
    D'2026.10.13 12:30',  D'2026.11.10 13:30',  D'2026.12.10 13:30',
};

bool IsDateInArray(const datetime &arr[], datetime now)
{
    MqlDateTime today; TimeToStruct(now, today);
    for(int i = 0; i < ArraySize(arr); i++)
    {
        MqlDateTime d; TimeToStruct(arr[i], d);
        if(d.year == today.year && d.mon == today.mon && d.day == today.day) return true;
    }
    return false;
}
bool IsCPIDay()  { return IsDateInArray(CPI_DATES,  TimeCurrent()); }
bool IsNFPDay()  { return IsDateInArray(NFP_DATES,  TimeCurrent()); }
bool IsFOMCDay() { return IsDateInArray(FOMC_DATES, TimeCurrent()); }
bool IsGDPDay()  { return IsDateInArray(GDP_DATES,  TimeCurrent()); }
bool IsPPIDay()  { return IsDateInArray(PPI_DATES,  TimeCurrent()); }
bool IsNewsDay() { return IsCPIDay() || IsNFPDay() || IsFOMCDay() || IsGDPDay() || IsPPIDay(); }


//── Utility ──────────────────────────────────────────────────────────────────

double GetPipSize()
{
    int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
    double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    return (digits == 3 || digits == 5) ? point * 10.0 : point;
}

bool InWindow(int h, int start, int end)
{
    if(start > end) return (h >= start || h < end);
    return (h >= start && h < end);
}

bool IsAllowedSession()
{
    if(!InpUseSessionFilter) return true;
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    int h = (dt.hour + InpGMTOffset + 24) % 24;
    return (InpAsianStartH  != InpAsianEndH  && InWindow(h, InpAsianStartH,  InpAsianEndH))  ||
           (InpLondonStartH != InpLondonEndH && InWindow(h, InpLondonStartH, InpLondonEndH)) ||
           (InpNYStartH     != InpNYEndH     && InWindow(h, InpNYStartH,     InpNYEndH));
}

int GetCurrentPeriod()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    return dt.hour * 2 + (dt.min >= 30 ? 1 : 0);
}

void ResetDailyCounters()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    dt.hour = 0; dt.min = 0; dt.sec = 0;
    datetime today = StructToTime(dt);
    if(today != g_lastResetDay) { ArrayFill(g_periodTrades, 0, 48, 0); g_lastResetDay = today; }
}

bool ParsePeriods(string periods)
{
    if(periods == "ALL" || periods == "") { ArrayFill(g_periodAllowed, 0, 48, true); return true; }
    ArrayFill(g_periodAllowed, 0, 48, false);
    string parts[];
    int cnt = StringSplit(periods, ',', parts);
    for(int i = 0; i < cnt; i++)
    {
        StringTrimLeft(parts[i]); StringTrimRight(parts[i]);
        int idx = (int)StringToInteger(parts[i]);
        if(idx >= 0 && idx < 48) g_periodAllowed[idx] = true;
    }
    return true;
}

double CalcATR(const double &high[], const double &low[], const double &close[],
               int period, int offset)
{
    double sum = 0.0; int count = 0;
    for(int i = offset; i < offset + period && i + 1 < ArraySize(high); i++)
    {
        double tr = MathMax(high[i] - low[i],
                   MathMax(MathAbs(high[i] - close[i+1]),
                           MathAbs(low[i]  - close[i+1])));
        sum += tr; count++;
    }
    return count > 0 ? sum / count : 0.001;
}

double CalcStdDev(const double &arr[], int count, int offset)
{
    if(count < 2 || offset + count > ArraySize(arr)) return 0.0;
    double mean = 0.0;
    for(int i = offset; i < offset + count; i++) mean += arr[i];
    mean /= count;
    double var = 0.0;
    for(int i = offset; i < offset + count; i++) var += (arr[i] - mean) * (arr[i] - mean);
    return MathSqrt(var / count);
}

double CalcLots(double entryPrice, double slPrice)
{
    double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmt   = balance * InpRiskPercent / 100.0;
    double slDist    = MathAbs(entryPrice - slPrice);
    double tickSize  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
    double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
    double volMin    = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
    double volMax    = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
    double volStep   = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
    if(slDist == 0 || tickSize == 0 || tickValue == 0) return volMin;
    double valPerPt  = tickValue / tickSize;
    double lot       = riskAmt / (slDist * valPerPt);
    double maxLot    = MathMin(volMax, InpMaxLots);
    lot = MathMax(volMin, MathMin(maxLot, lot));
    if(volStep > 0) lot = MathFloor(lot / volStep) * volStep;
    return NormalizeDouble(lot, 2);
}

void ValidateLevels(double entry, double &sl, double &tp, bool isShort)
{
    long   stopsLvl = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
    double minDist  = stopsLvl * SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    if(minDist <= 0) return;
    if(isShort)
    {
        if(sl < entry + minDist) { PrintFormat("AMD WARN: SL clamped %.5f", entry + minDist); sl = entry + minDist; }
        if(tp > entry - minDist) { PrintFormat("AMD WARN: TP clamped %.5f", entry - minDist); tp = entry - minDist; }
    }
    else
    {
        if(sl > entry - minDist) { PrintFormat("AMD WARN: SL clamped %.5f", entry - minDist); sl = entry - minDist; }
        if(tp < entry + minDist) { PrintFormat("AMD WARN: TP clamped %.5f", entry + minDist); tp = entry + minDist; }
    }
}


//── VWAP (session, daily from midnight UTC) ──────────────────────────────────

double CalcVWAP()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    dt.hour = 0; dt.min = 0; dt.sec = 0;
    datetime dayStart = StructToTime(dt);

    int barsBack = MathMax(2, (int)((TimeCurrent() - dayStart) / PeriodSeconds()) + 2);

    double h[], l[], c[]; long v[]; datetime t[];
    ArraySetAsSeries(h, true); ArraySetAsSeries(l, true);
    ArraySetAsSeries(c, true); ArraySetAsSeries(v, true);
    ArraySetAsSeries(t, true);

    int n = CopyHigh(Symbol(), Period(), 1, barsBack, h);
    if(n < 1) return 0.0;
    CopyLow(Symbol(), Period(), 1, barsBack, l);
    CopyClose(Symbol(), Period(), 1, barsBack, c);
    CopyTickVolume(Symbol(), Period(), 1, barsBack, v);
    CopyTime(Symbol(), Period(), 1, barsBack, t);

    double cumTPV = 0.0, cumVol = 0.0;
    for(int i = n - 1; i >= 0; i--)
    {
        if(t[i] < dayStart) continue;
        double vol = (v[i] > 0) ? (double)v[i] : 1.0;
        cumTPV += ((h[i] + l[i] + c[i]) / 3.0) * vol;
        cumVol += vol;
    }
    return (cumVol > 0) ? cumTPV / cumVol : 0.0;
}


//── Accumulation detection ───────────────────────────────────────────────────
//
//  Checks that the most recent InpAccumBars bars form a tight range.
//  ATR is measured from the InpAccumBars bars BEFORE the window (external ref).
//  Two gates: rHeight < InpAccumATRMult × ATR  AND  StdDev(close) < InpAccumStdDevMult × ATR

bool DetectAccum(
    const double &high[], const double &low[], const double &close[], const datetime &times[],
    int totalBars,
    double &outRangeHigh, double &outRangeLow, double &outMidpoint,
    datetime &outAccumT1, datetime &outAccumT2
)
{
    if(InpAccumBars + 16 >= totalBars) return false;

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

    // StdDev tightness gate
    double stddev = CalcStdDev(close, InpAccumBars, 0);
    if(stddev > InpAccumStdDevMult * atr) return false;

    outRangeHigh = rHigh;
    outRangeLow  = rLow;
    outMidpoint  = (rHigh + rLow) / 2.0;
    outAccumT1   = times[InpAccumBars - 1];
    outAccumT2   = times[0];
    return true;
}


//── Chart drawing helpers ────────────────────────────────────────────────────

void DrawZone(string name, datetime t1, double price1,
              datetime t2, double price2, color clr)
{
    if(!InpDrawObjects) return;
    if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
    ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, price1, t2, price2);
    ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
    ObjectSetInteger(0, name, OBJPROP_FILL,       true);
    ObjectSetInteger(0, name, OBJPROP_BACK,       true);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void DrawHLine(string name, datetime t1, datetime t2, double price, color clr,
               int width = 1, ENUM_LINE_STYLE style = STYLE_DASH)
{
    if(!InpDrawObjects) return;
    if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
    ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
    ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
    ObjectSetInteger(0, name, OBJPROP_WIDTH,      width);
    ObjectSetInteger(0, name, OBJPROP_STYLE,      style);
    ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT,  false);
    ObjectSetInteger(0, name, OBJPROP_RAY_LEFT,   false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void DrawSetupLines(string sfx, datetime t1, datetime t2, double entry, double sl, double tp)
{
    if(!InpDrawObjects) return;
    DrawHLine("AMD_Entry_" + sfx, t1, t2, entry, clrDodgerBlue, 2, STYLE_SOLID);
    DrawHLine("AMD_SL_"    + sfx, t1, t2, sl,    clrRed,        1, STYLE_DASH);
    DrawHLine("AMD_TP_"    + sfx, t1, t2, tp,    clrLime,       1, STYLE_DASH);
}

void DrawLabel(string name, datetime t, double price, string text, color clr)
{
    if(!InpDrawObjects) return;
    if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
    ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
    ObjectSetString(0,  name, OBJPROP_TEXT,      text);
    ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  8);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
}

void FinalizeSetupDrawings(string sfx, datetime closeTime)
{
    string names[] = {"AMD_Midpt_", "AMD_Entry_", "AMD_SL_", "AMD_TP_",
                      "AMD_CTR_Entry_", "AMD_CTR_SL_", "AMD_CTR_TP_"};
    for(int i = 0; i < ArraySize(names); i++)
    {
        string name = names[i] + sfx;
        if(ObjectFind(0, name) >= 0)
            ObjectSetInteger(0, name, OBJPROP_TIME, 1, (long)closeTime);
    }
}


//── Counter-trade (called every tick while primary is open) ──────────────────

void CheckCounterTrade()
{
    if(!InpCounterEnable)                    return;
    if(g_primaryTicket == 0)                 return;
    if(g_counterDone)                        return;
    if(!PositionSelectByTicket(g_primaryTicket)) return;

    double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    datetime now = TimeCurrent();

    bool triggered = false;
    bool ctrIsShort = false;

    if(g_primaryIsLong  && bid - g_primaryEntry >= InpCounterMovePts)
        { triggered = true; ctrIsShort = true; }
    else if(!g_primaryIsLong && g_primaryEntry - ask >= InpCounterMovePts)
        { triggered = true; ctrIsShort = false; }

    if(!triggered) return;

    g_counterDone = true;   // mark before execution to prevent re-entry on same tick

    double entry, sl, tp;
    if(ctrIsShort)
    {
        entry = bid;
        sl    = entry + InpCounterMovePts / 4.0;
        tp    = entry - InpCounterMovePts / 2.0;
        ValidateLevels(entry, sl, tp, true);
    }
    else
    {
        entry = ask;
        sl    = entry - InpCounterMovePts / 4.0;
        tp    = entry + InpCounterMovePts / 2.0;
        ValidateLevels(entry, sl, tp, false);
    }

    double lots = (InpManualLots > 0) ? InpManualLots : CalcLots(entry, sl);
    string sfx  = g_primarySfx;

    string alertMsg = StringFormat(
        "AMD COUNTER-%s  %s\n"
        "Trigger      : primary moved %.1f pts\n"
        "Entry        : %.5f\n"
        "Stop Loss    : %.5f  (%.1f pts)\n"
        "Take Profit  : %.5f  (%.1f pts)\n"
        "Lots         : %.2f",
        ctrIsShort ? "SHORT" : "LONG", Symbol(),
        InpCounterMovePts,
        entry,
        sl, MathAbs(sl - entry),
        tp, MathAbs(tp - entry),
        lots);

    if(InpManualConfirm)
    {
        Alert(alertMsg);
        Print("AMD COUNTER ALERT:\n" + alertMsg);
        return;
    }

    if(ctrIsShort)
    {
        if(Trade.Sell(lots, Symbol(), bid, sl, tp, "AMD_CTR"))
        {
            g_counterTicket = Trade.ResultOrder();
            DrawHLine("AMD_CTR_Entry_" + sfx, now, FAR_FUTURE, entry, InpCounterColor, 2, STYLE_SOLID);
            DrawHLine("AMD_CTR_SL_"    + sfx, now, FAR_FUTURE, sl,    clrRed,          1, STYLE_DOT);
            DrawHLine("AMD_CTR_TP_"    + sfx, now, FAR_FUTURE, tp,    clrLime,         1, STYLE_DOT);
            DrawLabel("AMD_CTR_Lbl_"   + sfx, now, entry,
                      StringFormat("CTR SHORT  TP:%.2f  SL:%.2f", InpCounterMovePts/2, InpCounterMovePts/4),
                      InpCounterColor);
            Print("AMD COUNTER SHORT  ticket=", g_counterTicket, "  entry=", entry, "  sl=", sl, "  tp=", tp);
        }
        else
            Print("AMD COUNTER SELL FAILED  retcode=", Trade.ResultRetcode(), "  ", Trade.ResultComment());
    }
    else
    {
        if(Trade.Buy(lots, Symbol(), ask, sl, tp, "AMD_CTR"))
        {
            g_counterTicket = Trade.ResultOrder();
            DrawHLine("AMD_CTR_Entry_" + sfx, now, FAR_FUTURE, entry, InpCounterColor, 2, STYLE_SOLID);
            DrawHLine("AMD_CTR_SL_"    + sfx, now, FAR_FUTURE, sl,    clrRed,          1, STYLE_DOT);
            DrawHLine("AMD_CTR_TP_"    + sfx, now, FAR_FUTURE, tp,    clrLime,         1, STYLE_DOT);
            DrawLabel("AMD_CTR_Lbl_"   + sfx, now, entry,
                      StringFormat("CTR LONG  TP:%.2f  SL:%.2f", InpCounterMovePts/2, InpCounterMovePts/4),
                      InpCounterColor);
            Print("AMD COUNTER LONG  ticket=", g_counterTicket, "  entry=", entry, "  sl=", sl, "  tp=", tp);
        }
        else
            Print("AMD COUNTER BUY FAILED  retcode=", Trade.ResultRetcode(), "  ", Trade.ResultComment());
    }
}


//── Run strategy (bar open) ───────────────────────────────────────────────────

void RunStrategy()
{
    // Rule 10: news-day gate
    if(InpUseCPICalendar || InpHighProbDay)
    {
        bool ok = (InpUseCPICalendar && IsNewsDay()) || InpHighProbDay;
        if(!ok) { if(InpDiagnostic) Print("AMD DIAG [R10] BLOCKED — not a news day"); return; }
    }

    // Rule 8: session
    if(!IsAllowedSession()) { if(InpDiagnostic) Print("AMD DIAG [R8] BLOCKED — outside session"); return; }

    // Rule 7 + 9: period
    int curPeriod = GetCurrentPeriod();
    if(InpUsePeriodFilter)
    {
        if(!g_periodAllowed[curPeriod])
        { if(InpDiagnostic) PrintFormat("AMD DIAG [R7] BLOCKED — period %d", curPeriod); return; }
        if(g_periodTrades[curPeriod] >= InpMaxTradesPerPeriod)
        { if(InpDiagnostic) PrintFormat("AMD DIAG [R9] BLOCKED — period %d limit", curPeriod); return; }
    }

    // Skip if primary already open
    if(g_primaryTicket != 0 && PositionSelectByTicket(g_primaryTicket)) return;

    // Fetch bars (AsSeries, skip forming bar at pos=0)
    double highArr[], lowArr[], closeArr[]; datetime timeArr[];
    ArraySetAsSeries(highArr, true); ArraySetAsSeries(lowArr,   true);
    ArraySetAsSeries(closeArr,true); ArraySetAsSeries(timeArr,  true);

    int copied = CopyHigh(Symbol(), Period(), 1, InpCandleCount, highArr);
    if(copied < InpAccumBars + 18) return;
    CopyLow  (Symbol(), Period(), 1, InpCandleCount, lowArr);
    CopyClose(Symbol(), Period(), 1, InpCandleCount, closeArr);
    CopyTime (Symbol(), Period(), 1, InpCandleCount, timeArr);

    double   rangeHigh, rangeLow, midpoint;
    datetime accumT1, accumT2;

    if(!DetectAccum(highArr, lowArr, closeArr, timeArr, copied,
                    rangeHigh, rangeLow, midpoint, accumT1, accumT2))
    {
        if(InpDiagnostic) PrintFormat("AMD DIAG [R1] no accum  bars=%d", copied);
        return;
    }

    string sfx = StringFormat("%d", (int)accumT1);

    // Draw accumulation zone for every detection (backtesting visibility)
    // ObjectFind prevents duplicate drawing of the same zone
    if(ObjectFind(0, "AMD_Accum_" + sfx) < 0)
    {
        DrawZone("AMD_Accum_" + sfx, accumT1, rangeHigh, accumT2, rangeLow, InpAccumColor);
        DrawHLine("AMD_Midpt_" + sfx, accumT1, accumT2 + PeriodSeconds(), midpoint,
                  InpMidpointColor, 1, STYLE_DOT);
        if(InpDiagnostic)
            PrintFormat("AMD ACCUM DRAWN  high=%.5f  low=%.5f  mid=%.5f  T1=%s",
                        rangeHigh, rangeLow, midpoint, TimeToString(accumT1));
    }

    double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    datetime now = TimeCurrent();

    // Rule 2: VWAP direction
    double vwap  = CalcVWAP();
    double price = (ask + bid) / 2.0;

    bool allowLong  = false;
    bool allowShort = false;

    switch(InpVWAPMode)
    {
        case VWAP_DEFAULT:
            allowLong  = (vwap > 0 && price < vwap);
            allowShort = (vwap > 0 && price > vwap);
            break;
        case VWAP_INVERTED:
            allowLong  = (vwap > 0 && price > vwap);
            allowShort = (vwap > 0 && price < vwap);
            break;
        case VWAP_LONG_ONLY:
            allowLong  = true;
            allowShort = false;
            break;
        case VWAP_SHORT_ONLY:
            allowLong  = false;
            allowShort = true;
            break;
        case VWAP_DISABLED:
        default:
            allowLong  = true;
            allowShort = true;
            break;
    }

    if(!allowLong && !allowShort)
    {
        if(InpDiagnostic)
            PrintFormat("AMD DIAG [R2] BLOCKED — VWAP=%.5f price=%.5f mode=%d", vwap, price, (int)InpVWAPMode);
        return;
    }

    // Rule 3: entry at midpoint — price must be in matching half of range
    bool doLong  = allowLong  && ask <= midpoint;   // price in lower half → BUY at ask
    bool doShort = allowShort && bid >= midpoint;    // price in upper half → SELL at bid

    if(!doLong && !doShort)
    {
        if(InpDiagnostic)
            PrintFormat("AMD DIAG [R3] waiting for midpoint  mid=%.5f  ask=%.5f  bid=%.5f",
                        midpoint, ask, bid);
        return;
    }

    // Prefer the VWAP-aligned direction if both somehow qualify
    if(doLong && doShort) doShort = false;

    // ── LONG entry ───────────────────────────────────────────────────────────
    if(doLong)
    {
        double entry = ask;
        double sl    = InpUsePipSL ? entry - InpManualSLPips * g_pipSize
                                   : rangeLow  - InpSLPips * g_pipSize;
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

        if(tp <= entry) { if(InpDiagnostic) Print("AMD DIAG LONG TP blocked"); return; }
        double risk = entry - sl, reward = tp - entry;
        double rr   = (risk > 0) ? reward / risk : 0.0;
        if(InpMinRR > 0 && rr < InpMinRR)
        { if(InpDiagnostic) PrintFormat("AMD DIAG LONG RR %.2f < %.2f", rr, InpMinRR); return; }

        double lots = (InpManualLots > 0) ? InpManualLots : CalcLots(entry, sl);

        DrawSetupLines(sfx, now, FAR_FUTURE, entry, sl, tp);
        DrawLabel("AMD_Lbl_" + sfx, now, entry,
                  StringFormat("LONG  mid=%.5f  SL:%.5f  TP:%.5f  RR:1:%.1f", midpoint, sl, tp, rr),
                  clrLimeGreen);

        string alertMsg = StringFormat(
            "AMD LONG  %s [%s]\n"
            "Accum range  : %.5f – %.5f  (mid=%.5f)\n"
            "VWAP         : %.5f\n"
            "Entry        : %.5f\n"
            "Stop Loss    : %.5f  (%.1f pips)\n"
            "Take Profit  : %.5f  (%.1f pips)\n"
            "Risk:Reward  : 1:%.2f\n"
            "Lots         : %.2f",
            Symbol(), EnumToString(Period()),
            rangeLow, rangeHigh, midpoint, vwap,
            entry, sl, (entry - sl) / g_pipSize,
            tp,    (tp - entry)    / g_pipSize,
            rr, lots);

        if(InpManualConfirm) { Alert(alertMsg); Print("AMD LONG ALERT:\n" + alertMsg); }
        else
        {
            if(Trade.Buy(lots, Symbol(), ask, sl, tp, "AMD_v1.10"))
            {
                g_periodTrades[curPeriod]++;
                g_primaryTicket  = Trade.ResultOrder();
                g_primarySfx     = sfx;
                g_primaryEntry   = ask;
                g_primaryIsLong  = true;
                g_counterDone    = false;
                g_counterTicket  = 0;
                Print("AMD LONG EXECUTED  ticket=", g_primaryTicket,
                      "  entry=", ask, "  sl=", sl, "  tp=", tp);
            }
            else
                Print("AMD BUY FAILED  retcode=", Trade.ResultRetcode(), "  ", Trade.ResultComment());
        }
    }
    // ── SHORT entry ──────────────────────────────────────────────────────────
    else
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

        if(tp >= entry) { if(InpDiagnostic) Print("AMD DIAG SHORT TP blocked"); return; }
        double risk = sl - entry, reward = entry - tp;
        double rr   = (risk > 0) ? reward / risk : 0.0;
        if(InpMinRR > 0 && rr < InpMinRR)
        { if(InpDiagnostic) PrintFormat("AMD DIAG SHORT RR %.2f < %.2f", rr, InpMinRR); return; }

        double lots = (InpManualLots > 0) ? InpManualLots : CalcLots(entry, sl);

        DrawSetupLines(sfx, now, FAR_FUTURE, entry, sl, tp);
        DrawLabel("AMD_Lbl_" + sfx, now, entry,
                  StringFormat("SHORT  mid=%.5f  SL:%.5f  TP:%.5f  RR:1:%.1f", midpoint, sl, tp, rr),
                  clrOrangeRed);

        string alertMsg = StringFormat(
            "AMD SHORT  %s [%s]\n"
            "Accum range  : %.5f – %.5f  (mid=%.5f)\n"
            "VWAP         : %.5f\n"
            "Entry        : %.5f\n"
            "Stop Loss    : %.5f  (%.1f pips)\n"
            "Take Profit  : %.5f  (%.1f pips)\n"
            "Risk:Reward  : 1:%.2f\n"
            "Lots         : %.2f",
            Symbol(), EnumToString(Period()),
            rangeLow, rangeHigh, midpoint, vwap,
            entry, sl, (sl - entry) / g_pipSize,
            tp,    (entry - tp)    / g_pipSize,
            rr, lots);

        if(InpManualConfirm) { Alert(alertMsg); Print("AMD SHORT ALERT:\n" + alertMsg); }
        else
        {
            if(Trade.Sell(lots, Symbol(), bid, sl, tp, "AMD_v1.10"))
            {
                g_periodTrades[curPeriod]++;
                g_primaryTicket  = Trade.ResultOrder();
                g_primarySfx     = sfx;
                g_primaryEntry   = bid;
                g_primaryIsLong  = false;
                g_counterDone    = false;
                g_counterTicket  = 0;
                Print("AMD SHORT EXECUTED  ticket=", g_primaryTicket,
                      "  entry=", bid, "  sl=", sl, "  tp=", tp);
            }
            else
                Print("AMD SELL FAILED  retcode=", Trade.ResultRetcode(), "  ", Trade.ResultComment());
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

    Print("AMD Strategy EA  v1.10  initialized  |  ", Symbol(), " [", EnumToString(Period()), "]");
    PrintFormat("  Pip size        : %.5f", g_pipSize);
    PrintFormat("  Min stop dist   : %d pts = %.5f", (int)stopsLvl, minStopPt);
    PrintFormat("  VWAP mode       : %s", EnumToString(InpVWAPMode));
    PrintFormat("  Counter-trade   : %s  trigger=%.1f pts  TP=%.1f  SL=%.1f",
                InpCounterEnable ? "ON" : "OFF",
                InpCounterMovePts, InpCounterMovePts/2, InpCounterMovePts/4);
    PrintFormat("  Accum filter    : %d bars  ATR×%.1f  StdDev×%.1f",
                InpAccumBars, InpAccumATRMult, InpAccumStdDevMult);

    bool newsToday = IsNewsDay();
    PrintFormat("  News day today  : %s%s%s%s%s",
        newsToday ? "YES — " : "no",
        IsCPIDay()  ? " CPI"  : "", IsNFPDay()  ? " NFP"  : "",
        IsFOMCDay() ? " FOMC" : "", IsGDPDay()  ? " GDP"  : "");
    if(IsPPIDay()) Print("                    PPI");
    if(!InpUseCPICalendar && !InpHighProbDay)
        Print("  [DAY FILTER OFF] Running all days");
    else if(!((InpUseCPICalendar && newsToday) || InpHighProbDay))
        Print("  [PAUSED] Not a news day — set InpHighProbDay=true to override");
    if(InpManualConfirm)
        Print("  [ALERT MODE] Auto-execute disabled — InpManualConfirm=true");

    return INIT_SUCCEEDED;
}

void OnTick()
{
    // Counter-trade check: every tick while primary is open
    CheckCounterTrade();

    // Strategy: bar-open gate
    datetime barTime = iTime(Symbol(), Period(), 1);
    if(barTime == g_lastBar) return;
    g_lastBar = barTime;

    ResetDailyCounters();
    RunStrategy();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
    ulong deal = trans.deal;
    if(!HistoryDealSelect(deal)) return;
    if(HistoryDealGetInteger(deal, DEAL_MAGIC)  != InpMagicNumber) return;
    if(HistoryDealGetString(deal,  DEAL_SYMBOL) != Symbol())       return;

    ENUM_DEAL_ENTRY de = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
    if(de != DEAL_ENTRY_OUT && de != DEAL_ENTRY_INOUT) return;

    datetime closeTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
    ulong    dealOrder = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);

    if(dealOrder == g_primaryTicket)
    {
        if(g_primarySfx != "") FinalizeSetupDrawings(g_primarySfx, closeTime);
        g_primaryTicket = 0; g_primarySfx = ""; g_primaryEntry = 0.0;
        g_counterDone   = false;
    }
    else if(dealOrder == g_counterTicket)
    {
        g_counterTicket = 0;
    }
}

void OnDeinit(const int reason)
{
    Print("AMD Strategy EA  v1.10  removed.");
}
