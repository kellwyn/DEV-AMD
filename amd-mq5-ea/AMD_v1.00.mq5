//+------------------------------------------------------------------+
//|  AMD Strategy — Accumulation · Manipulation · Distribution       |
//|  Playbook by Tanja Trade (ChartFanatics AMD Method)             |
//|                                                                   |
//|  SETUP SEQUENCE                                                   |
//|  Rule 1  — Accumulation: N bars of tight range-bound price      |
//|             Range height < InpAccumATRMult × ATR(14)            |
//|  Rule 2  — Manipulation: bar sweeps stops beyond range boundary  |
//|             High/Low > range boundary by InpManipPips,           |
//|             close returns inside range (failed breakout = trap)  |
//|  Rule 3  — Displacement: strong impulsive bar leaving an FVG    |
//|             Bearish FVG: bar[i].high < bar[i+2].low (AsSeries)  |
//|             Bullish FVG: bar[i].low  > bar[i+2].high            |
//|  Rule 4  — Distribution entry: price retraces into FVG zone     |
//|  Rule 5  — SL above/below manipulation extreme + InpSLPips      |
//|  Rule 6  — TP: R:R ratio or fixed pips                          |
//|  Rule 7  — Period filter: 48 × 30-min UTC slots (multi-select)  |
//|  Rule 8  — ICT Session filter: Asian / London / NY              |
//|  Rule 9  — Max trades per period per day                        |
//|  Rule 10 — Day quality flag: trade only high-probability days   |
//|                                                                   |
//|  HIGH-PROBABILITY DAYS: CPI, NFP, FOMC, GDP, PPI                |
//|  → Check economic calendar before enabling InpHighProbDay=true  |
//|  → For market correlation analysis use /financial-analyst-master |
//|                                                                   |
//|─────────────────── VERSION HISTORY ─────────────────────────────|
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
#property copyright "AMD Strategy EA  v1.00"
#property version   "1.00"
#property description "AMD — Accumulation · Manipulation · Distribution  v1.00"
#property strict

#include <Trade\Trade.mqh>

//── Inputs ──────────────────────────────────────────────────────────────────

input group "=== Rule 10 — Day Quality & Execution Mode ==="
input bool   InpHighProbDay        = true;   // HIGH-PROB DAY: CPI/NFP/FOMC/GDP/PPI
                                              // Set FALSE to sit out low-quality days
input bool   InpManualConfirm      = true;   // true = Alert only | false = Auto-execute
                                              // Keep TRUE until strategy is validated on demo

input group "=== Risk Management ==="
input double InpRiskPercent        = 1.0;    // Risk per trade (% of account balance)
input double InpMinRR              = 1.5;    // Minimum risk:reward ratio (0 = disabled)
input double InpMaxLots            = 5.0;    // Hard cap on position size

input group "=== Rule 5-6 — SL / TP Settings ==="
input double InpSLPips             = 10.0;   // SL buffer above/below manipulation extreme (pips)
input bool   InpUsePipTP           = false;  // false = R:R ratio  |  true = fixed pip TP
input double InpTPPips             = 20.0;   // TP in pips (when InpUsePipTP = true)
input double InpRiskReward         = 2.0;    // TP = entry ± risk × this (when not pip-based)
input double InpTPBufferPips       = 5.0;    // Extra pip buffer beyond range extreme (fallback)

input group "=== Rule 1-3 — AMD Detection ==="
input int    InpAccumBars          = 20;     // Rule 1: Accumulation lookback bars
input double InpAccumATRMult       = 1.5;    // Rule 1: Range < InpAccumATRMult × ATR(14)
input double InpManipPips          = 5.0;    // Rule 2: Min sweep beyond range boundary (pips)
input int    InpManipLookback      = 10;     // Rule 2: Bars before FVG to search for sweep
input int    InpFVGLookback        = 8;      // Rule 3: Bars to search for Fair Value Gap
input int    InpCandleCount        = 60;     // Total bars to fetch per scan

input group "=== Rule 7 — Period Filter (48 × 30-min UTC Slots) ==="
input bool   InpUsePeriodFilter    = false;  // Only trade in selected UTC periods
input string InpAllowedPeriods     = "ALL";  // Periods: ALL or comma-separated indices 0-47
                                              // Index guide: 0=00:00  13=06:30  24=12:00
                                              //   26=13:00 (NY open)  27=13:30  34=17:00
                                              // Example NY morning: "26,27,28,29,30,31"
input int    InpMaxTradesPerPeriod = 2;       // Rule 9: Max executions per slot per day

input group "=== Rule 8 — ICT Session Filter ==="
input bool   InpUseSessionFilter   = true;   // Only trade during active ICT sessions
input int    InpGMTOffset          = 0;       // Broker server offset from GMT
input int    InpAsianStartH        = 23;      // Asian session start (UTC incl. 1hr pre-market)
input int    InpAsianEndH          = 9;       // Asian session end (UTC)
input int    InpLondonStartH       = 7;       // London start (UTC, 1hr pre-market)
input int    InpLondonEndH         = 16;      // London end (UTC)
input int    InpNYStartH           = 12;      // NY start (UTC, 1hr pre-market)
input int    InpNYEndH             = 21;      // NY end (UTC)

input group "=== Chart Display ==="
input bool   InpDrawObjects        = true;    // Draw accumulation zone, FVG, levels on chart
input color  InpAccumColor         = clrSteelBlue;   // Accumulation range fill
input color  InpFVGBullColor       = clrLimeGreen;   // Bullish FVG fill
input color  InpFVGBearColor       = clrOrangeRed;   // Bearish FVG fill
input color  InpManipColor         = clrMagenta;     // Manipulation level line

input group "=== Trade Settings ==="
input int    InpMagicNumber        = 20260501;
input int    InpSlippage           = 20;

//── Globals ──────────────────────────────────────────────────────────────────

CTrade Trade;

bool    g_periodAllowed[48];    // which 30-min UTC slots are allowed
int     g_periodTrades[48];     // trade count per slot today
datetime g_lastResetDay = 0;    // last UTC date we reset g_periodTrades

datetime g_lastBar = 0;         // gate: only run on new bar

double g_pipSize = 0.0;


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
        string p = StringTrimLeft(StringTrimRight(parts[i]));
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
    ObjectSetInteger(0, name, OBJPROP_TRANSPARENCY, alpha);
    ObjectSetInteger(0, name, OBJPROP_BACK,         true);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE,   false);
}

void DrawHLine(string name, double price, color clr, int width = 1,
               ENUM_LINE_STYLE style = STYLE_DASH)
{
    if(!InpDrawObjects) return;
    if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
    ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
    ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
    ObjectSetInteger(0, name, OBJPROP_WIDTH,     width);
    ObjectSetInteger(0, name, OBJPROP_STYLE,     style);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void DrawSetupLines(double entry, double sl, double tp)
{
    if(!InpDrawObjects) return;
    DrawHLine("AMD_Entry", entry, clrDodgerBlue, 2, STYLE_SOLID);
    DrawHLine("AMD_SL",    sl,    clrRed,        1, STYLE_DASH);
    DrawHLine("AMD_TP",    tp,    clrLime,       1, STYLE_DASH);
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


//── AMD Detection — SHORT ─────────────────────────────────────────────────────
//
//  AsSeries=true: index 0 = most recent completed bar, higher index = older.
//
//  SHORT timeline (index view):
//    higher index (older)  →  lower index (newer) → current
//    [ACCUMULATION bars]   [MANIP: high[m] > rangeHigh]
//    [FVG: high[f] < low[f+2]]  →  price retraces UP into FVG

bool DetectShort(
    const double &high[], const double &low[], const double &close[], const datetime &times[],
    int totalBars,
    double &outFVGUpper, double &outFVGLower, double &outManipHigh,
    double &outRangeHigh, double &outRangeLow,
    datetime &outAccumT1, datetime &outAccumT2,
    datetime &outFVGT1,   datetime &outFVGT2
)
{
    double atr = CalcATR(high, low, close, 14, 1);
    if(atr <= 0) return false;

    // Step 1: Find most recent bearish FVG within InpFVGLookback bars
    // Bearish FVG at bar i (AsSeries): high[i] < low[i+2]
    int    fvgBar = -1;
    double fvgUpper = 0, fvgLower = 0;

    for(int i = 0; i < InpFVGLookback; i++)
    {
        if(i + 2 >= totalBars) break;
        if(high[i] < low[i + 2])
        {
            fvgBar   = i;
            fvgUpper = low[i + 2];   // bar A (older) low
            fvgLower = high[i];      // bar C (newer) high
            break;
        }
    }
    if(fvgBar < 0 || (fvgUpper - fvgLower) < g_pipSize * 2) return false;

    // Step 2: Find manipulation sweep BEFORE the FVG
    // In AsSeries, before = higher index (older).
    // Search from fvgBar+1 up to fvgBar+InpManipLookback+2
    for(int m = fvgBar + 1; m <= fvgBar + InpManipLookback + 2; m++)
    {
        if(m + InpAccumBars >= totalBars) break;

        // Accumulation window: bars [m+1 .. m+InpAccumBars] (older than manipulation bar)
        double rHigh = -DBL_MAX, rLow = DBL_MAX;
        for(int a = m + 1; a <= m + InpAccumBars; a++)
        {
            if(a >= totalBars) break;
            if(high[a] > rHigh) rHigh = high[a];
            if(low[a]  < rLow)  rLow  = low[a];
        }
        double rHeight = rHigh - rLow;
        if(rHeight <= 0 || rHeight > InpAccumATRMult * atr) continue;

        // Check manipulation: high[m] swept above rangeHigh by >= InpManipPips
        double sweep = high[m] - rHigh;
        if(sweep < InpManipPips * g_pipSize) continue;

        // Close should return inside or near the range (failed breakout)
        if(close[m] > rHigh + rHeight * 0.5) continue;

        // Found!
        outFVGUpper   = fvgUpper;
        outFVGLower   = fvgLower;
        outManipHigh  = high[m];
        outRangeHigh  = rHigh;
        outRangeLow   = rLow;
        outAccumT1    = times[m + InpAccumBars];   // oldest accumulation bar
        outAccumT2    = times[m + 1];              // bar just before manipulation
        outFVGT1      = times[fvgBar + 2];         // bar A of FVG
        outFVGT2      = times[fvgBar];             // bar C of FVG (newest)
        return true;
    }
    return false;
}


//── AMD Detection — LONG ──────────────────────────────────────────────────────
//
//  LONG timeline (AsSeries, older = higher index):
//    [ACCUMULATION] [MANIP: low[m] < rangeLow]
//    [FVG: low[f] > high[f+2]]  →  price retraces DOWN into FVG

bool DetectLong(
    const double &high[], const double &low[], const double &close[], const datetime &times[],
    int totalBars,
    double &outFVGUpper, double &outFVGLower, double &outManipLow,
    double &outRangeHigh, double &outRangeLow,
    datetime &outAccumT1, datetime &outAccumT2,
    datetime &outFVGT1,   datetime &outFVGT2
)
{
    double atr = CalcATR(high, low, close, 14, 1);
    if(atr <= 0) return false;

    // Find bullish FVG: low[i] > high[i+2]
    int    fvgBar = -1;
    double fvgUpper = 0, fvgLower = 0;

    for(int i = 0; i < InpFVGLookback; i++)
    {
        if(i + 2 >= totalBars) break;
        if(low[i] > high[i + 2])
        {
            fvgBar   = i;
            fvgUpper = low[i];       // bar C (newer) low
            fvgLower = high[i + 2];  // bar A (older) high
            break;
        }
    }
    if(fvgBar < 0 || (fvgUpper - fvgLower) < g_pipSize * 2) return false;

    for(int m = fvgBar + 1; m <= fvgBar + InpManipLookback + 2; m++)
    {
        if(m + InpAccumBars >= totalBars) break;

        double rHigh = -DBL_MAX, rLow = DBL_MAX;
        for(int a = m + 1; a <= m + InpAccumBars; a++)
        {
            if(a >= totalBars) break;
            if(high[a] > rHigh) rHigh = high[a];
            if(low[a]  < rLow)  rLow  = low[a];
        }
        double rHeight = rHigh - rLow;
        if(rHeight <= 0 || rHeight > InpAccumATRMult * atr) continue;

        double sweep = rLow - low[m];
        if(sweep < InpManipPips * g_pipSize) continue;

        if(close[m] < rLow - rHeight * 0.5) continue;

        outFVGUpper   = fvgUpper;
        outFVGLower   = fvgLower;
        outManipLow   = low[m];
        outRangeHigh  = rHigh;
        outRangeLow   = rLow;
        outAccumT1    = times[m + InpAccumBars];
        outAccumT2    = times[m + 1];
        outFVGT1      = times[fvgBar + 2];
        outFVGT2      = times[fvgBar];
        return true;
    }
    return false;
}


//── Run strategy (called on each new bar) ────────────────────────────────────

void RunStrategy()
{
    // Rule 10: day quality
    if(!InpHighProbDay) return;

    // Rule 8: session filter
    if(!IsAllowedSession()) return;

    // Rule 7 + 9: period filter
    int curPeriod = GetCurrentPeriod();
    if(InpUsePeriodFilter)
    {
        if(!g_periodAllowed[curPeriod]) return;
        if(g_periodTrades[curPeriod] >= InpMaxTradesPerPeriod) return;
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

    int copied = CopyHigh (Symbol(), Period(), 1, needed, highArr);
    if(copied < InpAccumBars + InpFVGLookback + 6) return;
    CopyLow  (Symbol(), Period(), 1, needed, lowArr);
    CopyClose(Symbol(), Period(), 1, needed, closeArr);
    CopyTime (Symbol(), Period(), 1, needed, timeArr);

    int totalBars = copied;

    double fvgUpper, fvgLower, manipExtreme, rangeHigh, rangeLow;
    datetime accumT1, accumT2, fvgT1, fvgT2;

    double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    datetime now = TimeCurrent();

    // ── Try SHORT ────────────────────────────────────────────────────────────
    if(DetectShort(highArr, lowArr, closeArr, timeArr, totalBars,
                   fvgUpper, fvgLower, manipExtreme,
                   rangeHigh, rangeLow, accumT1, accumT2, fvgT1, fvgT2))
    {
        // Rule 4: bid must be inside the bearish FVG zone (retracing UP)
        if(bid >= fvgLower && bid <= fvgUpper)
        {
            double entry = bid;
            double sl    = manipExtreme + InpSLPips * g_pipSize;
            double tp;

            if(InpUsePipTP)
                tp = entry - InpTPPips * g_pipSize;
            else
            {
                double risk = sl - entry;
                tp = (risk > 0) ? entry - risk * InpRiskReward
                                : rangeLow - InpTPBufferPips * g_pipSize;
            }

            if(tp >= entry) return;   // TP must be below entry

            double risk   = sl - entry;
            double reward = entry - tp;
            double rr     = (risk > 0) ? reward / risk : 0.0;
            if(InpMinRR > 0 && rr < InpMinRR) return;

            double lots = CalcLots(entry, sl);

            // Draw objects
            DeleteObjects("AMD_");
            DrawZone("AMD_Accum",  accumT1, rangeHigh, accumT2, rangeLow, InpAccumColor);
            DrawHLine("AMD_Manip", manipExtreme, InpManipColor, 1, STYLE_DOT);
            DrawZone("AMD_FVG",    fvgT1, fvgUpper, fvgT2, fvgLower, InpFVGBearColor, 60);
            DrawSetupLines(entry, sl, tp);
            DrawLabel("AMD_Lbl", now, fvgUpper, StringFormat("SHORT  SL:%.5f  TP:%.5f  RR:1:%.1f", sl, tp, rr), clrOrangeRed);

            string alertMsg = StringFormat(
                "AMD SHORT  %s [%s]\n"
                "Accumulation : %.5f – %.5f\n"
                "Manipulation : %.5f (sweep high)\n"
                "FVG Zone     : %.5f – %.5f\n"
                "Entry        : %.5f\n"
                "Stop Loss    : %.5f  (%.1f pips)\n"
                "Take Profit  : %.5f  (%.1f pips)\n"
                "Risk:Reward  : 1:%.2f\n"
                "Lots         : %.2f",
                Symbol(), EnumToString(Period()),
                rangeLow, rangeHigh,
                manipExtreme,
                fvgLower, fvgUpper,
                entry, sl, (sl - entry) / g_pipSize,
                tp, (entry - tp) / g_pipSize,
                rr, lots
            );

            if(InpManualConfirm)
            {
                Alert(alertMsg);
                Print("AMD SHORT ALERT:\n" + alertMsg);
            }
            else
            {
                if(Trade.Sell(lots, Symbol(), bid, sl, tp, "AMD_v1.00"))
                {
                    g_periodTrades[curPeriod]++;
                    Print("AMD SHORT EXECUTED  ticket=", Trade.ResultOrder(),
                          "  lots=", lots, "  entry=", bid,
                          "  sl=", sl, "  tp=", tp);
                }
                else
                    Print("AMD SELL FAILED  retcode=", Trade.ResultRetcode(),
                          "  ", Trade.ResultComment());
            }
        }
    }

    // ── Try LONG ─────────────────────────────────────────────────────────────
    else if(DetectLong(highArr, lowArr, closeArr, timeArr, totalBars,
                       fvgUpper, fvgLower, manipExtreme,
                       rangeHigh, rangeLow, accumT1, accumT2, fvgT1, fvgT2))
    {
        // Rule 4: ask must be inside the bullish FVG zone (retracing DOWN)
        if(ask >= fvgLower && ask <= fvgUpper)
        {
            double entry = ask;
            double sl    = manipExtreme - InpSLPips * g_pipSize;
            double tp;

            if(InpUsePipTP)
                tp = entry + InpTPPips * g_pipSize;
            else
            {
                double risk = entry - sl;
                tp = (risk > 0) ? entry + risk * InpRiskReward
                                : rangeHigh + InpTPBufferPips * g_pipSize;
            }

            if(tp <= entry) return;

            double risk   = entry - sl;
            double reward = tp - entry;
            double rr     = (risk > 0) ? reward / risk : 0.0;
            if(InpMinRR > 0 && rr < InpMinRR) return;

            double lots = CalcLots(entry, sl);

            DeleteObjects("AMD_");
            DrawZone("AMD_Accum",  accumT1, rangeHigh, accumT2, rangeLow, InpAccumColor);
            DrawHLine("AMD_Manip", manipExtreme, InpManipColor, 1, STYLE_DOT);
            DrawZone("AMD_FVG",    fvgT1, fvgUpper, fvgT2, fvgLower, InpFVGBullColor, 60);
            DrawSetupLines(entry, sl, tp);
            DrawLabel("AMD_Lbl", now, fvgLower, StringFormat("LONG  SL:%.5f  TP:%.5f  RR:1:%.1f", sl, tp, rr), clrLimeGreen);

            string alertMsg = StringFormat(
                "AMD LONG  %s [%s]\n"
                "Accumulation : %.5f – %.5f\n"
                "Manipulation : %.5f (sweep low)\n"
                "FVG Zone     : %.5f – %.5f\n"
                "Entry        : %.5f\n"
                "Stop Loss    : %.5f  (%.1f pips)\n"
                "Take Profit  : %.5f  (%.1f pips)\n"
                "Risk:Reward  : 1:%.2f\n"
                "Lots         : %.2f",
                Symbol(), EnumToString(Period()),
                rangeLow, rangeHigh,
                manipExtreme,
                fvgLower, fvgUpper,
                entry, sl, (entry - sl) / g_pipSize,
                tp, (tp - entry) / g_pipSize,
                rr, lots
            );

            if(InpManualConfirm)
            {
                Alert(alertMsg);
                Print("AMD LONG ALERT:\n" + alertMsg);
            }
            else
            {
                if(Trade.Buy(lots, Symbol(), ask, sl, tp, "AMD_v1.00"))
                {
                    g_periodTrades[curPeriod]++;
                    Print("AMD LONG EXECUTED  ticket=", Trade.ResultOrder(),
                          "  lots=", lots, "  entry=", ask,
                          "  sl=", sl, "  tp=", tp);
                }
                else
                    Print("AMD BUY FAILED  retcode=", Trade.ResultRetcode(),
                          "  ", Trade.ResultComment());
            }
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

    Print("AMD Strategy EA  v1.00  initialized  |  ", Symbol(), " [", EnumToString(Period()), "]");
    Print("Pip size = ", DoubleToString(g_pipSize, _Digits));

    if(!InpHighProbDay)
        Print("  [PAUSED] InpHighProbDay=false — set true on CPI/NFP/FOMC/GDP/PPI days");
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

void OnDeinit(const int reason)
{
    if(InpDrawObjects)
        DeleteObjects("AMD_");
    Print("AMD Strategy EA  v1.00  removed.");
}
