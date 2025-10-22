//+------------------------------------------------------------------+
//|                                            XAUUSD_ProfitBot.mq5  |
//|                      Trend-following XAUUSD bot with ATR guards  |
//|                                        (c) 2025, YourName/ChatGPT|
//+------------------------------------------------------------------+
#property copyright   "(c) 2025"
#property version     "1.00"
#property strict
#property description "Trend-following EA for XAUUSD with ATR SL/TP, breakeven, trailing and daily equity guard."

#include <Trade/Trade.mqh>

//============================== Inputs ==============================//
input string InpSymbol                = "";           // Symbol (empty = current chart)
input ENUM_TIMEFRAMES InpTF           = PERIOD_M5;    // Trading timeframe

// Trend filters
input ENUM_TIMEFRAMES InpHTF          = PERIOD_H1;    // Higher timeframe trend filter
input int   FastEMA                   = 21;           // Fast EMA (trade TF)
input int   SlowEMA                   = 50;           // Slow EMA (trade TF)
input int   HTF_EMA_Fast              = 50;           // Fast EMA (HTF)
input int   HTF_EMA_Slow              = 200;          // Slow EMA (HTF)
input int   ADX_Period                = 14;           // ADX period (trade TF)
input double Min_ADX                  = 18.0;         // Minimum ADX to consider trend

// Pullback/entry filters
input int   RSI_Period                = 14;           // RSI period (trade TF)
input int   RSI_Buy_Max               = 60;           // Max RSI to allow buys (pullback)
input int   RSI_Sell_Min              = 40;           // Min RSI to allow sells (pullback)

// Risk and position sizing
input double Risk_Per_Trade_Pct       = 1.0;          // % equity risked per trade
input int    ATR_Period               = 14;           // ATR period (trade TF)
input double SL_ATR_Mult              = 2.0;          // Stop Loss = ATR * multiplier
input double TP_ATR_Mult              = 1.5;          // Take Profit = ATR * multiplier
input double BE_Trigger_ATR           = 0.8;          // Move SL to breakeven after this ATR move
input double Trail_ATR_Mult           = 1.0;          // Trailing distance = ATR * multiplier

// Execution and filters
input int    Max_Spread_Points        = 2000;         // Maximum spread in points (looser default)
input int    Slippage_Points          = 50;           // Max deviation in points
input bool   Use_Session_Filter       = false;        // Restrict to trading session hours
input int    Session_Start_Hour       = 7;            // Start hour (server time)
input int    Session_End_Hour         = 22;           // End hour (server time)
input int    Max_Concurrent_Positions = 1;            // Max open positions for this symbol
input bool   One_Pos_Per_Direction    = true;         // Limit one per direction

// Daily guard
input double Daily_Loss_Limit_Pct     = 3.0;          // Disable trading after this daily loss
input double Daily_Profit_Target_Pct  = 3.0;          // Stop for the day after this profit
input int    Max_Daily_Trades         = 10;           // Max trades per day
input bool   Disable_Daily_Guard      = false;        // Disable daily guard (testing only)

// Misc
input long   Magic_Number             = 20251022;     // Magic number
input bool   Close_On_Opposite_Signal = true;         // Close when opposite signal appears
input bool   Debug_Mode               = true;         // Enable debug logs/comment

//=========================== Globals/State ==========================//
CTrade        trade;
string        g_symbol;
int           g_digits = 0;
double        g_point  = 0.0;
double        g_tickSize = 0.0;
double        g_tickValue = 0.0;

// Indicator handles (trade TF)
int hMAFast = INVALID_HANDLE;
int hMASlow = INVALID_HANDLE;
int hRSI    = INVALID_HANDLE;
int hADX    = INVALID_HANDLE;
int hATR    = INVALID_HANDLE;

// Indicator handles (HTF)
int hHTFFast = INVALID_HANDLE;
int hHTFSlow = INVALID_HANDLE;

// New bar detection
static datetime g_lastBarTime = 0;

// Daily guard state
static int     g_dayOfYear = -1;
static double  g_dayStartEquity = 0.0;
static int     g_tradesToday = 0;
static bool    g_disabledToday = false;

//============================== Utils ===============================//
bool SelectSymbol(const string sym)
{
   bool selected = SymbolSelect(sym, true);
   if(!selected)
      PrintFormat("[EA] Failed to select symbol %s", sym);
   return selected;
}

bool UpdateSymbolInfo()
{
   long digitsLong = 0;
   if(!SymbolInfoInteger(g_symbol, SYMBOL_DIGITS, digitsLong)) return false;
   g_digits = (int)digitsLong;
   if(!SymbolInfoDouble(g_symbol, SYMBOL_POINT, g_point)) return false;
   if(!SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE, g_tickSize)) return false;
   if(!SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE, g_tickValue)) return false;
   return true;
}

double NormalizeVolume(double lots)
{
   double minLot, maxLot, lotStep;
   if(!SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN, minLot)) minLot = 0.01;
   if(!SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX, maxLot)) maxLot = 100.0;
   if(!SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP, lotStep)) lotStep = 0.01;
   double stepped = MathFloor(lots/lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, stepped));
}

bool IsNewBar()
{
   datetime t0 = iTime(g_symbol, InpTF, 0);
   if(t0 != 0 && t0 != g_lastBarTime)
   {
      g_lastBarTime = t0;
      return true;
   }
   return false;
}

bool IsWithinSession()
{
   if(!Use_Session_Filter) return true;
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   int hour = (int)dt.hour;
   if(Session_Start_Hour <= Session_End_Hour)
      return (hour >= Session_Start_Hour && hour < Session_End_Hour);
   // Overnight window (e.g., 22 -> 6)
   return (hour >= Session_Start_Hour || hour < Session_End_Hour);
}

void DebugPrint(const string msg)
{
   if(!Debug_Mode) return;
   Print(msg);
}

bool IsSpreadAcceptable()
{
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return false;
   double spreadPts = (tick.ask - tick.bid) / g_point;
   return (spreadPts <= Max_Spread_Points);
}

void ResetDailyIfNeeded()
{
   datetime now = TimeCurrent();
   int doy = TimeDayOfYear(now);
   if(doy != g_dayOfYear)
   {
      g_dayOfYear      = doy;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_tradesToday    = 0;
      g_disabledToday  = false;
   }
}

bool DailyGuardAllowsTrading()
{
   if(Disable_Daily_Guard) return true;
   ResetDailyIfNeeded();
   if(g_disabledToday) return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_dayStartEquity <= 0.0) g_dayStartEquity = equity;

   double ddPct  = 100.0 * (g_dayStartEquity - equity) / g_dayStartEquity;
   double prPct  = 100.0 * (equity - g_dayStartEquity) / g_dayStartEquity;

   if(ddPct >= Daily_Loss_Limit_Pct)
   {
      g_disabledToday = true;
      PrintFormat("[Guard] Daily loss limit reached (%.2f%%). Disabling trading for today.", ddPct);
      return false;
   }
   if(prPct >= Daily_Profit_Target_Pct)
   {
      g_disabledToday = true;
      PrintFormat("[Guard] Daily profit target reached (%.2f%%). Stopping for today.", prPct);
      return false;
   }
   if(g_tradesToday >= Max_Daily_Trades)
   {
      Print("[Guard] Max daily trades reached.");
      return false;
   }
   return true;
}

// Calculate volume from risk percent and stop distance in price (not points)
// Returns 0 if cannot calculate
double CalculateRiskVolume(const double stopDistancePrice)
{
   if(stopDistancePrice <= 0.0 || g_tickSize <= 0.0 || g_tickValue <= 0.0)
      return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (Risk_Per_Trade_Pct/100.0);

   // Convert price distance to number of ticks
   double ticks = stopDistancePrice / g_tickSize;
   if(ticks <= 0.0) return 0.0;

   // Profit per tick for 1.0 lot is g_tickValue
   double lots = riskMoney / (ticks * g_tickValue);
   return NormalizeVolume(lots);
}

//=========================== Indicators ============================//
bool CreateIndicators()
{
   // Release old handles if any
   if(hMAFast != INVALID_HANDLE)  IndicatorRelease(hMAFast);
   if(hMASlow != INVALID_HANDLE)  IndicatorRelease(hMASlow);
   if(hRSI   != INVALID_HANDLE)   IndicatorRelease(hRSI);
   if(hADX   != INVALID_HANDLE)   IndicatorRelease(hADX);
   if(hATR   != INVALID_HANDLE)   IndicatorRelease(hATR);
   if(hHTFFast != INVALID_HANDLE) IndicatorRelease(hHTFFast);
   if(hHTFSlow != INVALID_HANDLE) IndicatorRelease(hHTFSlow);

   hMAFast  = iMA(g_symbol, InpTF, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hMASlow  = iMA(g_symbol, InpTF, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(g_symbol, InpTF, RSI_Period, PRICE_CLOSE);
   hADX     = iADX(g_symbol, InpTF, ADX_Period);
   hATR     = iATR(g_symbol, InpTF, ATR_Period);

   hHTFFast = iMA(g_symbol, InpHTF, HTF_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hHTFSlow = iMA(g_symbol, InpHTF, HTF_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   bool ok = (hMAFast>0 && hMASlow>0 && hRSI>0 && hADX>0 && hATR>0 && hHTFFast>0 && hHTFSlow>0);
   if(!ok) Print("[EA] Failed to create one or more indicators.");
   return ok;
}

bool GetBufferValue(const int handle, const int bufferIndex, const int shift, double &value)
{
   double data[];
   if(CopyBuffer(handle, bufferIndex, shift, 1, data) != 1)
      return false;
   value = data[0];
   return true;
}

//============================ Positions ============================//
int CountOpenPositions(const string sym, const long magic, int directionFilter = -1)
{
   int count = 0;
   for(int i=0;i<PositionsTotal();++i)
   {
      if(!PositionSelectByIndex(i)) continue;
      string psym; long pmagic; long ptype;
      PositionGetString(POSITION_SYMBOL, psym);
      PositionGetInteger(POSITION_MAGIC, pmagic);
      PositionGetInteger(POSITION_TYPE, ptype);
      if(psym==sym && pmagic==magic)
      {
         if(directionFilter==-1 || ptype==directionFilter)
            count++;
      }
   }
   return count;
}

bool HasOpenPositionInDirection(const string sym, const long magic, const int direction)
{
   return CountOpenPositions(sym, magic, direction) > 0;
}

//============================ Signals ==============================//
struct Signal
{
   bool   buy;
   bool   sell;
};

Signal GetSignal()
{
   Signal s; s.buy=false; s.sell=false;

   // Fetch needed values (shift 1 for confirmed bar where applicable)
   double emaFast0, emaFast1, emaSlow0, emaSlow1;
   double htfFast0, htfSlow0;
   double rsi1; double adx0;
   double close0, close1;

   if(!GetBufferValue(hMAFast, 0, 0, emaFast0)) return s;
   if(!GetBufferValue(hMAFast, 0, 1, emaFast1)) return s;
   if(!GetBufferValue(hMASlow, 0, 0, emaSlow0)) return s;
   if(!GetBufferValue(hMASlow, 0, 1, emaSlow1)) return s;
   if(!GetBufferValue(hHTFFast,0, 0, htfFast0)) return s;
   if(!GetBufferValue(hHTFSlow,0, 0, htfSlow0)) return s;
   if(!GetBufferValue(hRSI,   0, 1, rsi1))      return s;
   if(!GetBufferValue(hADX,   0, 0, adx0))      return s;

   double cbuf[];
   if(CopyClose(g_symbol, InpTF, 0, 2, cbuf)!=2) return s;
   close0 = cbuf[0];
   close1 = cbuf[1];

   // Trend filters
   bool trendUpHTF = (htfFast0 > htfSlow0);
   bool trendDnHTF = (htfFast0 < htfSlow0);

   bool trendUpTF  = (emaFast0 > emaSlow0);
   bool trendDnTF  = (emaFast0 < emaSlow0);

   bool adxOk      = (adx0 >= Min_ADX);

   // Pullback idea: cross back above fast EMA after a dip (for buys), vice versa for sells
   bool buyPullback = (close1 < emaFast1 && close0 > emaFast0 && rsi1 <= RSI_Buy_Max);
   bool sellPullback= (close1 > emaFast1 && close0 < emaFast0 && rsi1 >= RSI_Sell_Min);

   if(adxOk && trendUpHTF && trendUpTF && buyPullback)
      s.buy = true;
   if(adxOk && trendDnHTF && trendDnTF && sellPullback)
      s.sell = true;

   return s;
}

//=========================== Trade logic ===========================//
void ManageOpenPositions()
{
   // Trailing and breakeven per position
   for(int i=0;i<PositionsTotal();++i)
   {
      if(!PositionSelectByIndex(i)) continue;
      string psym; long pmagic; long ptype;
      double priceOpen, sl, tp;
      PositionGetString(POSITION_SYMBOL, psym);
      PositionGetInteger(POSITION_MAGIC, pmagic);
      PositionGetInteger(POSITION_TYPE, ptype);
      PositionGetDouble(POSITION_PRICE_OPEN, priceOpen);
      PositionGetDouble(POSITION_SL, sl);
      PositionGetDouble(POSITION_TP, tp);

      if(psym != g_symbol || pmagic != Magic_Number) continue;

      // Current ATR for trailing distance
      double atr0; if(!GetBufferValue(hATR, 0, 0, atr0)) continue;
      double trailDist = atr0 * Trail_ATR_Mult;

      MqlTick tick; if(!SymbolInfoTick(g_symbol, tick)) continue;

      // Breakeven logic
      double beTrigger = atr0 * BE_Trigger_ATR;
      if(ptype == POSITION_TYPE_BUY)
      {
         double move = tick.bid - priceOpen;
         // Move SL to breakeven once in profit
         if(move > beTrigger)
         {
            double minBufferPts = MathMax(1.0, (double)(Max_Spread_Points/2));
            double newSL = MathMax(sl, priceOpen + g_point * minBufferPts);
            newSL = NormalizeDouble(newSL, g_digits);
            if(newSL > sl)
               trade.PositionModify(g_symbol, newSL, tp);
         }
         // ATR trailing
         double desiredSL = NormalizeDouble(tick.bid - trailDist, g_digits);
         if(desiredSL > sl && tick.bid - desiredSL > g_point*5) // ensure min distance
            trade.PositionModify(g_symbol, desiredSL, tp);
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         double move = priceOpen - tick.ask;
         if(move > beTrigger)
         {
            double minBufferPts = MathMax(1.0, (double)(Max_Spread_Points/2));
            double newSL = MathMin(sl, priceOpen - g_point * minBufferPts);
            newSL = NormalizeDouble(newSL, g_digits);
            if(sl==0.0 || newSL < sl)
               trade.PositionModify(g_symbol, newSL, tp);
         }
         double desiredSL = NormalizeDouble(tick.ask + trailDist, g_digits);
         if((sl==0.0 || desiredSL < sl) && desiredSL - tick.ask > g_point*5)
            trade.PositionModify(g_symbol, desiredSL, tp);
      }
   }
}

void CloseOnOppositeIfNeeded(const Signal &s)
{
   if(!Close_On_Opposite_Signal) return;

   for(int i=0;i<PositionsTotal();++i)
   {
      if(!PositionSelectByIndex(i)) continue;
      string psym; long pmagic; long ptype;
      PositionGetString(POSITION_SYMBOL, psym);
      PositionGetInteger(POSITION_MAGIC, pmagic);
      PositionGetInteger(POSITION_TYPE, ptype);
      if(psym != g_symbol || pmagic != Magic_Number) continue;

      if(ptype==POSITION_TYPE_BUY && s.sell)
      {
         trade.PositionClose(psym);
      }
      else if(ptype==POSITION_TYPE_SELL && s.buy)
      {
         trade.PositionClose(psym);
      }
   }
}

bool OpenTrade(const bool isBuy)
{
   MqlTick tick; if(!SymbolInfoTick(g_symbol, tick)) return false;

   // ATR-based stops
   double atr0; if(!GetBufferValue(hATR, 0, 0, atr0)) return false;

   double sl=0.0, tp=0.0, entry=0.0;
   if(isBuy)
   {
      entry = tick.ask;
      sl = entry - atr0 * SL_ATR_Mult;
      tp = entry + atr0 * TP_ATR_Mult;
   }
   else
   {
      entry = tick.bid;
      sl = entry + atr0 * SL_ATR_Mult;
      tp = entry - atr0 * TP_ATR_Mult;
   }
   sl = NormalizeDouble(sl, g_digits);
   tp = NormalizeDouble(tp, g_digits);

   double stopDistance = MathAbs(entry - sl);
   double lots = CalculateRiskVolume(stopDistance);
   if(lots <= 0.0)
   {
      Print("[EA] Calculated lot size is zero. Aborting trade.");
      return false;
   }

   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(Slippage_Points);

   bool sent=false;
   if(isBuy)
      sent = trade.Buy(lots, g_symbol, entry, sl, tp, "XAU Buy");
   else
      sent = trade.Sell(lots, g_symbol, entry, sl, tp, "XAU Sell");

   if(sent)
   {
      g_tradesToday++;
      PrintFormat("[EA] Order sent: %s %.2f lots @ %.2f SL %.2f TP %.2f", (isBuy?"BUY":"SELL"), lots, entry, sl, tp);
   }
   else
   {
      PrintFormat("[EA] Order send failed: %s. Error %d", (isBuy?"BUY":"SELL"), GetLastError());
   }
   return sent;
}

void TryEnter(const Signal &s)
{
   if(!DailyGuardAllowsTrading()) { DebugPrint("[Skip] Daily guard active"); return; }
   if(!IsWithinSession())        { DebugPrint("[Skip] Outside session"); return; }
   if(!IsSpreadAcceptable())     { DebugPrint("[Skip] Spread too high"); return; }

   // Position limits
   int totalForSymbol = CountOpenPositions(g_symbol, Magic_Number, -1);
   if(totalForSymbol >= Max_Concurrent_Positions) { DebugPrint("[Skip] Max concurrent positions reached"); return; }

   if(s.buy)
   {
      if(One_Pos_Per_Direction && HasOpenPositionInDirection(g_symbol, Magic_Number, POSITION_TYPE_BUY))
      { DebugPrint("[Skip] Existing BUY position"); return; }
      OpenTrade(true);
   }
   if(s.sell)
   {
      if(One_Pos_Per_Direction && HasOpenPositionInDirection(g_symbol, Magic_Number, POSITION_TYPE_SELL))
      { DebugPrint("[Skip] Existing SELL position"); return; }
      OpenTrade(false);
   }
}

//=========================== MQL5 events ===========================//
int OnInit()
{
   g_symbol = (StringLen(InpSymbol)==0 ? _Symbol : InpSymbol);
   if(!SelectSymbol(g_symbol)) return INIT_FAILED;
   if(!UpdateSymbolInfo()) return INIT_FAILED;
   if(!CreateIndicators()) return INIT_FAILED;

   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(Slippage_Points);

   ResetDailyIfNeeded();

   PrintFormat("[EA] Initialized for %s on %s", g_symbol, EnumToString(InpTF));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Release indicators
   if(hMAFast != INVALID_HANDLE)  IndicatorRelease(hMAFast);
   if(hMASlow != INVALID_HANDLE)  IndicatorRelease(hMASlow);
   if(hRSI   != INVALID_HANDLE)   IndicatorRelease(hRSI);
   if(hADX   != INVALID_HANDLE)   IndicatorRelease(hADX);
   if(hATR   != INVALID_HANDLE)   IndicatorRelease(hATR);
   if(hHTFFast != INVALID_HANDLE) IndicatorRelease(hHTFFast);
   if(hHTFSlow != INVALID_HANDLE) IndicatorRelease(hHTFSlow);
}

void OnTick()
{
   // Manage open positions every tick
   ManageOpenPositions();

   // Execute entries only on new bar to avoid overtrading
   if(!IsNewBar()) return;

   Signal s = GetSignal();
   // Status overlay
   if(Debug_Mode)
   {
      bool guardOk   = DailyGuardAllowsTrading();
      bool sessOk    = IsWithinSession();
      bool spreadOk  = IsSpreadAcceptable();
      int  posCount  = CountOpenPositions(g_symbol, Magic_Number, -1);
      Comment(StringFormat("%s\nGuard:%s Sess:%s Spread:%s Pos:%d\nSig B:%s S:%s",
         g_symbol,
         (guardOk?"OK":"BLOCK"), (sessOk?"OK":"NO"), (spreadOk?"OK":"HIGH"), posCount,
         (s.buy?"Y":"-"), (s.sell?"Y":"-")));
   }
   CloseOnOppositeIfNeeded(s);
   TryEnter(s);
}

// Optional: keep daily counters consistent if broker sends trade events
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &req,const MqlTradeResult &res)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      long dealType; string sym; long magic;
      HistoryDealGetInteger(trans.deal, DEAL_TYPE, dealType);
      HistoryDealGetString(trans.deal, DEAL_SYMBOL, sym);
      HistoryDealGetInteger(trans.deal, DEAL_MAGIC, magic);
      if(sym==g_symbol && magic==Magic_Number)
      {
         if(dealType==DEAL_TYPE_BUY || dealType==DEAL_TYPE_SELL)
         {
            ResetDailyIfNeeded();
            g_tradesToday++;
         }
      }
   }
}

//============================= Notes ===============================//
// Attach to XAUUSD M5. Configure inputs per broker conditions.
// Risk_Per_Trade_Pct <= 1.0 recommended for cent 5k. Test on demo first.
// No EA guarantees profit or eliminates risk. Adjust risk to tolerance.
//+------------------------------------------------------------------+
