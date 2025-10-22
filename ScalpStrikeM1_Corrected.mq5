//+------------------------------------------------------------------+
//|                                                  ScalpStrikeM1   |
//| High-risk M1 scalper: EMA9/EMA50 + MACD + RSI + ADX + ATR SL/TP  |
//| Tight TP/SL, limited martingale, trailing, daily target/stop,    |
//| and optional breakout pending orders (BuyStop/SellStop).         |
//| *** WARNING: HIGH RISK. Test in demo/backtest before live. ***   |
//+------------------------------------------------------------------+
#property copyright "Assistant"
#property version   "1.2"
#property strict

//==== Inputs: Risk & Profit Controls =========================================
input double  InitialLot            = 0.05;     // Lot khởi điểm
input double  LotMultiplier         = 1.8;      // Hệ số martingale
input int     MaxConsecLosses       = 3;        // Tối đa số lần tăng lot liên tiếp
input bool    UseRiskBasedLot       = false;    // true = dùng % rủi ro để tính lot
input double  RiskPercent           = 5.0;      // % vốn rủi ro trên 1 lệnh (nếu bật UseRiskBasedLot)
input double  MaxLotAbsolute        = 5.0;      // Giới hạn lot tuyệt đối

input double  DailyProfitTargetPct  = 100.0;    // % lãi trong ngày để dừng mở lệnh mới
input bool    CloseAllOnTarget      = true;     // Đạt target thì đóng hết lệnh
input double  EquityStopPercent     = 40.0;     // Mất % vốn so với đầu ngày -> đóng hết & dừng EA

//==== Inputs: Symbol, Pips/Points, Spread ====================================
input string  TradeSymbol           = "";       // Để trống = _Symbol
input int     PipPoints             = 10;       // 1 pip = ? points (Forex 5 digits ~10; vàng có thể =1 hoặc 10)
input double  MaxSpreadPoints       = 30;       // Spread tối đa (points) để cho phép vào lệnh

//==== Inputs: TP/SL & Trailing ===============================================
input bool    UseATRforSLTP         = true;     // Dùng ATR để tính SL/TP?
input int     ATR_Period            = 14;
input double  ATR_to_SL             = 1.0;      // SL = ATR * hệ số (nếu dùng ATR)
input double  RR_Min                = 1.5;      // TP = SL * RR_Min

input double  SL_pips               = 3.0;      // Nếu không dùng ATR: SL theo pip
input double  TP_pips               = 5.0;      // Nếu không dùng ATR: TP theo pip

input bool    UseTrailing           = true;     // Dùng trailing stop
input double  TrailingStart_pips    = 3.0;      // Bắt đầu trailing khi lãi >= giá trị này
input double  TrailingStep_pips     = 1.0;      // Mỗi lần dời SL theo bước này

//==== Inputs: Indicators (M1) ================================================
input ENUM_TIMEFRAMES TF            = PERIOD_M1;
input int     EMA_fast              = 9;
input int     EMA_slow              = 50;
input int     RSI_Period            = 14;
input int     ADX_Period            = 14;
input int     ADX_Threshold         = 25;
input int     MACD_fast             = 12;
input int     MACD_slow             = 26;
input int     MACD_signal           = 9;

//==== Inputs: Filters =========================================================
input bool    TradeLong             = true;
input bool    TradeShort            = true;
input bool    AvoidHighSpread       = true;

//==== Inputs: Breakout Pending Orders ========================================
input bool    UsePendingBreakout    = true;     // Dùng lệnh chờ breakout?
input double  PendingDistance_pips  = 3.0;      // Khoảng cách đặt BuyStop/SellStop
input int     PendingExpireMin      = 10;       // Hết hạn lệnh chờ (phút)
input bool    CancelOnOppSignal     = true;     // Hủy pending khi có tín hiệu ngược
input int     MaxPendingPerSide     = 1;        // Tối đa số lệnh chờ mỗi phía

//==== Misc ====================================================================
input int     Slippage              = 10;       // Tối đa trượt giá (points)
input int     MagicNumber           = 20251022;
input bool    OnePositionAtATime    = true;     // Mỗi lần chỉ 1 lệnh trên symbol

//------------------------------------------------------------------------------
string  sym;
double  point, digits, tickval, ticksize, volmin, volmax, volstep;
int     hEMAfast=-1, hEMAslow=-1, hRSI=-1, hADX=-1, hMACD=-1, hATR=-1;
double  dayStartEquity=0.0;
datetime dayStamp=0;
int     consecLosses=0;
bool    AllowNewTrades = true;     // sẽ tự OFF khi đạt target

//------------------------------------------------------------------------------
// Utility
//------------------------------------------------------------------------------
string SymbolToTrade(){ return (TradeSymbol=="" ? _Symbol : TradeSymbol); }

datetime DateOfDay(datetime t){ MqlDateTime x; TimeToStruct(t,x); x.hour=0; x.min=0; x.sec=0; return StructToTime(x); }

void ResetDayCounters()
{
  dayStamp       = DateOfDay(TimeCurrent());
  dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  AllowNewTrades = true; // reset mỗi ngày
}

int PositionsTotalByMagic(string symbol,int magic)
{
  int n=0;
  for(int i=0;i<PositionsTotal();i++)
  {
    ulong ticket = PositionGetTicket(i);
    if(PositionSelectByTicket(ticket))
    {
      if(PositionGetString(POSITION_SYMBOL)==symbol && (int)PositionGetInteger(POSITION_MAGIC)==magic) n++;
    }
  }
  return n;
}

//------------------------------------------------------------------------------
// Lifecycle
//------------------------------------------------------------------------------
int OnInit()
{
  sym     = SymbolToTrade();
  if(!SymbolInfoDouble(sym,SYMBOL_POINT,point))  { Print("Point load failed"); return INIT_FAILED; }
  digits  = (double)SymbolInfoInteger(sym,SYMBOL_DIGITS);
  tickval = SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
  ticksize= SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
  volmin  = SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
  volmax  = SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
  volstep = SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);

  // indicator handles
  hEMAfast = iMA(sym,TF,EMA_fast,0,MODE_EMA,PRICE_CLOSE);
  hEMAslow = iMA(sym,TF,EMA_slow,0,MODE_EMA,PRICE_CLOSE);
  hRSI     = iRSI(sym,TF,RSI_Period,PRICE_CLOSE);
  hADX     = iADX(sym,TF,ADX_Period);
  hMACD    = iMACD(sym,TF,MACD_fast,MACD_slow,MACD_signal,PRICE_CLOSE);
  hATR     = iATR(sym,TF,ATR_Period);

  if(hEMAfast==INVALID_HANDLE || hEMAslow==INVALID_HANDLE ||
     hRSI==INVALID_HANDLE || hADX==INVALID_HANDLE ||
     hMACD==INVALID_HANDLE || hATR==INVALID_HANDLE)
  {
    Print("Indicator handle failed"); return INIT_FAILED;
  }

  ResetDayCounters();
  Print("ScalpStrikeM1 initialized on ", sym);
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  if(hEMAfast!=-1) IndicatorRelease(hEMAfast);
  if(hEMAslow!=-1) IndicatorRelease(hEMAslow);
  if(hRSI!=-1)     IndicatorRelease(hRSI);
  if(hADX!=-1)     IndicatorRelease(hADX);
  if(hMACD!=-1)    IndicatorRelease(hMACD);
  if(hATR!=-1)     IndicatorRelease(hATR);
}

//------------------------------------------------------------------------------
// Indicators helpers
//------------------------------------------------------------------------------
double GetBuffer(int handle,int shift)
{
  double v[]; ArraySetAsSeries(v,true);
  if(CopyBuffer(handle,0,shift,1,v)<=0) return EMPTY_VALUE;
  return v[0];
}

double GetIndicatorADX(int shift)
{
  double main[]; ArraySetAsSeries(main,true);
  if(CopyBuffer(hADX,0,shift,1,main)<=0) return 0.0;
  return main[0];
}

bool GetMACD(double &m0,double &s0,double &m1,double &s1)
{
  double mainBuf[], sigBuf[];
  ArraySetAsSeries(mainBuf,true);
  ArraySetAsSeries(sigBuf,true);
  if(CopyBuffer(hMACD,0,0,2,mainBuf)<=0) return false;  // main
  if(CopyBuffer(hMACD,1,0,2,sigBuf)<=0)  return false;  // signal
  m0 = mainBuf[0]; s0 = sigBuf[0];
  m1 = mainBuf[1]; s1 = sigBuf[1];
  return true;
}

double GetATRPoints()
{
  double a[]; ArraySetAsSeries(a,true);
  if(CopyBuffer(hATR,0,0,1,a)<=0) return 0.0;
  return (a[0]/point); // ATR theo points
}

//------------------------------------------------------------------------------
// Money & Lot
//------------------------------------------------------------------------------
double ClampLot(double lot)
{
  lot = MathMin(lot, MaxLotAbsolute);
  if(lot < volmin) lot = volmin;
  // align to step
  double steps = MathFloor(lot/volstep);
  double nlot  = steps*volstep;
  if(nlot < volmin) nlot = volmin;
  if(nlot > volmax) nlot = volmax;
  int prec = (int)MathRound(-MathLog10(volstep));
  if(prec<0) prec=2;
  return NormalizeDouble(nlot, prec);
}

double CalcLot(double sl_points)
{
  // Martingale from consecutive losses
  int mSteps = MathMin(consecLosses, MaxConsecLosses);
  double martiLot = InitialLot;
  for(int i=0;i<mSteps;i++) martiLot *= LotMultiplier;

  if(!UseRiskBasedLot)
  {
    return ClampLot(martiLot);
  }

  // Risk-based lot (aggressive): risk = Equity * % / (SL money per 1 lot)
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  double riskMoney = equity * (RiskPercent/100.0);

  // money per point per 1 lot (approx)
  double valuePerPointPerLot = (ticksize>0 ? tickval / ticksize : 0);
  if(valuePerPointPerLot<=0) valuePerPointPerLot = 1.0;

  double slMoneyPerLot = sl_points * valuePerPointPerLot;
  double riskLot = (slMoneyPerLot>0 ? riskMoney / slMoneyPerLot : InitialLot);

  double finalLot = MathMax(riskLot, martiLot); // lấy lớn hơn giữa riskLot và martingale bước hiện tại
  return ClampLot(finalLot);
}

//------------------------------------------------------------------------------
// Orders & Positions
//------------------------------------------------------------------------------
bool ModifySLTP(ulong ticket,double newSL,double newTP)
{
  MqlTradeRequest  req;
  MqlTradeResult   res;
  ZeroMemory(req); ZeroMemory(res);
  req.action   = TRADE_ACTION_SLTP;
  req.symbol   = sym;
  req.magic    = MagicNumber;
  req.position = ticket;
  req.sl       = newSL;
  req.tp       = newTP;
  if(!OrderSend(req,res))
  {
    Print("Modify SLTP failed: ", GetLastError(), " ret=", res.retcode);
    return false;
  }
  return true;
}

void CloseAllPositions()
{
  for(int i=PositionsTotal()-1;i>=0;i--)
  {
    ulong ticket = PositionGetTicket(i);
    if(!PositionSelectByTicket(ticket)) continue;
    if(PositionGetString(POSITION_SYMBOL)!=sym) continue;

    long   type   = PositionGetInteger(POSITION_TYPE);
    double volume = PositionGetDouble(POSITION_VOLUME);
    double price  = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(sym,SYMBOL_BID)
                                              : SymbolInfoDouble(sym,SYMBOL_ASK);

    MqlTradeRequest  req;
    MqlTradeResult   res;
    ZeroMemory(req); ZeroMemory(res);
    req.action   = TRADE_ACTION_DEAL;
    req.symbol   = sym;
    req.magic    = MagicNumber;
    req.volume   = volume;
    req.type     = (type==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
    req.price    = price;
    req.deviation= Slippage;
    req.position = ticket;

    if(!OrderSend(req,res))
      Print("Close position failed: ", GetLastError(), " ret=", res.retcode);
  }
}

//------------------------------------------------------------------------------
// Market Orders
//------------------------------------------------------------------------------
void TryOpenMarket(bool buy)
{
  // Compute SL/TP in points
  double sl_pts=0, tp_pts=0;
  if(UseATRforSLTP)
  {
    double atr_pts = GetATRPoints();
    if(atr_pts<=0) return;
    sl_pts = MathMax(1.0, atr_pts * ATR_to_SL);
    tp_pts = MathMax(1.0, sl_pts * RR_Min);
  }
  else
  {
    sl_pts = MathMax(1.0, SL_pips * PipPoints);
    tp_pts = MathMax(1.0, TP_pips * PipPoints);
  }

  // Lot size
  double lot = CalcLot(sl_pts);
  if(lot<=0) return;

  // Price & SL/TP
  double ask = SymbolInfoDouble(sym,SYMBOL_ASK);
  double bid = SymbolInfoDouble(sym,SYMBOL_BID);
  double price = buy ? ask : bid;

  double sl = 0.0, tp = 0.0;
  if(buy)
  {
    sl = price - sl_pts*point;
    tp = price + tp_pts*point;
  }
  else
  {
    sl = price + sl_pts*point;
    tp = price - tp_pts*point;
  }

  // Place market order
  MqlTradeRequest  req;
  MqlTradeResult   res;
  ZeroMemory(req); ZeroMemory(res);
  req.action   = TRADE_ACTION_DEAL;
  req.symbol   = sym;
  req.magic    = MagicNumber;
  req.type     = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
  req.volume   = lot;
  req.price    = price;
  req.sl       = sl;
  req.tp       = tp;
  req.deviation= Slippage;

  if(!OrderSend(req,res))
  {
    Print("OrderSend failed: ", GetLastError(), " ret=", res.retcode);
    return;
  }
  else
  {
    Print("Opened ", (buy?"BUY":"SELL"), " ", DoubleToString(lot,2), " at ", price, " SL=", sl, " TP=", tp, " ticket=", res.order);
  }
}

//------------------------------------------------------------------------------
// Pending Orders (Breakout) - FIXED
//------------------------------------------------------------------------------
int PendingCount(bool buy)
{
  int n=0;
  for(int i=0;i<OrdersTotal();i++)
  {
    ulong ticket = OrderGetTicket(i);
    if(ticket==0) continue;
    if(!OrderSelect(ticket)) continue;
    if(OrderGetString(ORDER_SYMBOL)!=sym) continue;
    if((int)OrderGetInteger(ORDER_MAGIC)!=MagicNumber) continue;
    ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if(buy && t==ORDER_TYPE_BUY_STOP) n++;
    if(!buy && t==ORDER_TYPE_SELL_STOP) n++;
  }
  return n;
}

bool PlacePending(bool buy)
{
  // don't open if already too many pendings on that side
  if(PendingCount(buy) >= MaxPendingPerSide) return false;

  double price = buy ? SymbolInfoDouble(sym,SYMBOL_ASK) : SymbolInfoDouble(sym,SYMBOL_BID);
  double dist_points = PendingDistance_pips * PipPoints * point;
  double pend_price = buy ? price + dist_points : price - dist_points;

  // compute SL/TP similar to TryOpenMarket()
  double sl_pts=0, tp_pts=0;
  if(UseATRforSLTP)
  {
    double atr_pts = GetATRPoints();
    if(atr_pts<=0) return false;
    sl_pts = MathMax(1.0, atr_pts * ATR_to_SL);
    tp_pts = MathMax(1.0, sl_pts * RR_Min);
  }
  else
  {
    sl_pts = MathMax(1.0, SL_pips * PipPoints);
    tp_pts = MathMax(1.0, TP_pips * PipPoints);
  }

  double lot = CalcLot(sl_pts);
  if(lot<=0) return false;

  double sl = buy ? pend_price - sl_pts*point : pend_price + sl_pts*point;
  double tp = buy ? pend_price + tp_pts*point : pend_price - tp_pts*point;

  MqlTradeRequest  req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
  req.action  = TRADE_ACTION_PENDING;
  req.symbol  = sym;
  req.magic   = MagicNumber;
  req.type    = buy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
  req.volume  = lot;
  req.price   = NormalizeDouble(pend_price, (int)digits);
  req.sl      = NormalizeDouble(sl, (int)digits);
  req.tp      = NormalizeDouble(tp, (int)digits);
  req.deviation = Slippage;

  // set expiration
  datetime exp = TimeCurrent() + PendingExpireMin*60;
  req.type_filling = ORDER_FILLING_RETURN;
  req.type_time    = ORDER_TIME_SPECIFIED;
  req.expiration   = exp;

  if(!OrderSend(req,res))
  {
    Print("PlacePending failed: ", GetLastError(), " ret=", res.retcode);
    return false;
  }
  Print("Placed ", (buy?"BUYSTOP":"SELLSTOP"), " lot=", lot, " @", req.price, " SL=", req.sl, " TP=", req.tp);
  return true;
}

void CancelOppositePendings(bool buySignal)
{
  for(int i=OrdersTotal()-1;i>=0;i--)
  {
    ulong ticket = OrderGetTicket(i);
    if(ticket==0) continue;
    if(!OrderSelect(ticket)) continue;
    if(OrderGetString(ORDER_SYMBOL)!=sym) continue;
    if((int)OrderGetInteger(ORDER_MAGIC)!=MagicNumber) continue;
    ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    bool opp = buySignal ? (t==ORDER_TYPE_SELL_STOP) : (t==ORDER_TYPE_BUY_STOP);
    if(opp)
    {
      MqlTradeRequest  req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
      req.action = TRADE_ACTION_REMOVE; 
      req.order = ticket; 
      req.symbol = sym; 
      req.magic = MagicNumber;
      if(!OrderSend(req,res))
        Print("Cancel pending failed: ", GetLastError(), " ret=", res.retcode);
    }
  }
}

//------------------------------------------------------------------------------
// Trailing stop for open positions - FIXED
//------------------------------------------------------------------------------
void ManageTrailing()
{
  if(!UseTrailing) return;
  for(int i=0;i<PositionsTotal();i++)
  {
    ulong ticket = PositionGetTicket(i);
    if(ticket==0) continue;
    if(!PositionSelectByTicket(ticket)) continue;
    if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
    if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

    long    type   = PositionGetInteger(POSITION_TYPE);
    double  price  = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(sym,SYMBOL_BID)
                                               : SymbolInfoDouble(sym,SYMBOL_ASK);
    double  sl     = PositionGetDouble(POSITION_SL);
    double  open   = PositionGetDouble(POSITION_PRICE_OPEN);

    double  profitPips = (type==POSITION_TYPE_BUY)
                       ? (price-open)/(point*PipPoints)
                       : (open-price)/(point*PipPoints);

    if(profitPips < TrailingStart_pips) continue;

    if(type==POSITION_TYPE_BUY)
    {
      double trailPrice = price - (TrailingStep_pips*PipPoints*point);
      if(sl==0 || trailPrice > sl)
      {
        ModifySLTP(ticket, NormalizeDouble(trailPrice,(int)digits), PositionGetDouble(POSITION_TP));
      }
    }
    else
    {
      double trailPrice = price + (TrailingStep_pips*PipPoints*point);
      if(sl==0 || trailPrice < sl)
      {
        ModifySLTP(ticket, NormalizeDouble(trailPrice,(int)digits), PositionGetDouble(POSITION_TP));
      }
    }
  }
}

//------------------------------------------------------------------------------
// Tick
//------------------------------------------------------------------------------
void OnTick()
{
  // Day change?
  if(DateOfDay(TimeCurrent()) != dayStamp) ResetDayCounters();

  // Equity protections
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  double ddPct  = (dayStartEquity>0 ? (dayStartEquity - equity)/dayStartEquity * 100.0 : 0);
  double gainPct= (dayStartEquity>0 ? (equity - dayStartEquity)/dayStartEquity * 100.0 : 0);

  if(ddPct >= EquityStopPercent)
  {
    Print("Equity stop reached. Closing all & removing EA.");
    CloseAllPositions();
    ExpertRemove();
    return;
  }

  if(gainPct >= DailyProfitTargetPct)
  {
    if(AllowNewTrades)
    {
      Print("Daily profit target reached. Stop entering new trades.");
      AllowNewTrades = false;
      if(CloseAllOnTarget) CloseAllPositions();
    }
  }

  // Spread filter
  double spreadPts = (SymbolInfoDouble(sym,SYMBOL_ASK)-SymbolInfoDouble(sym,SYMBOL_BID))/point;
  if(AvoidHighSpread && spreadPts > MaxSpreadPoints) return;

  // Trailing
  ManageTrailing();

  // If not allowed to open new, stop here
  if(!AllowNewTrades) return;

  // One position rule
  if(OnePositionAtATime && PositionsTotalByMagic(sym,MagicNumber)>0) return;

  // Read indicators (current bar)
  double emaF = GetBuffer(hEMAfast,0);
  double emaS = GetBuffer(hEMAslow,0);
  double rsi  = GetBuffer(hRSI,0);
  double adx  = GetIndicatorADX(0);

  if(emaF==EMPTY_VALUE || emaS==EMPTY_VALUE || rsi==EMPTY_VALUE || adx<=0) return;

  double macd_main0, macd_signal0, macd_main1, macd_signal1;
  if(!GetMACD(macd_main0,macd_signal0,macd_main1,macd_signal1)) return;
  bool macdBull = (macd_main1 < macd_signal1) && (macd_main0 > macd_signal0);
  bool macdBear = (macd_main1 > macd_signal1) && (macd_main0 < macd_signal0);

  // Trend filters
  bool trendUp   = (emaF > emaS);
  bool trendDown = (emaF < emaS);
  bool strong    = (adx >= ADX_Threshold);

  // Entry logic: Prefer pending breakout if enabled
  if(UsePendingBreakout)
  {
    if(TradeLong && trendUp && strong && macdBull && rsi > 30 && rsi < 80)
    {
      if(CancelOnOppSignal) CancelOppositePendings(true);
      PlacePending(true);
      return; // tránh gửi cả pending và market cùng lúc
    }
    if(TradeShort && trendDown && strong && macdBear && rsi < 70 && rsi > 20)
    {
      if(CancelOnOppSignal) CancelOppositePendings(false);
      PlacePending(false);
      return;
    }
  }
  else
  {
    if(TradeLong && trendUp && strong && macdBull && rsi > 30 && rsi < 80)
    {
      TryOpenMarket(true);
      return;
    }
    if(TradeShort && trendDown && strong && macdBear && rsi < 70 && rsi > 20)
    {
      TryOpenMarket(false);
      return;
    }
  }
}

//------------------------------------------------------------------------------
// Track wins/losses to drive martingale - FIXED
//------------------------------------------------------------------------------
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
  // We care when a position is closed (a DEAL with entry OUT)
  if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;

  if(!HistorySelect(TimeCurrent()-7*24*3600, TimeCurrent())) return;
  ulong deal_id = trans.deal;
  if(deal_id==0) return;

  if(!HistoryDealSelect(deal_id)) return;
  long   entry   = (long)HistoryDealGetInteger(deal_id, DEAL_ENTRY);
  string dsym    = HistoryDealGetString(deal_id, DEAL_SYMBOL);

  if(dsym!=sym) return;
  if(entry != DEAL_ENTRY_OUT) return;  // only when position is closed

  double profit = HistoryDealGetDouble(deal_id, DEAL_PROFIT)
                + HistoryDealGetDouble(deal_id, DEAL_SWAP)
                + HistoryDealGetDouble(deal_id, DEAL_COMMISSION);

  if(profit < 0)
  {
    consecLosses++;
    if(consecLosses > MaxConsecLosses) consecLosses = MaxConsecLosses;
  }
  else
  {
    consecLosses = 0; // reset on win
  }

  Print("Closed deal: profit=", DoubleToString(profit,2), " consecLosses=", consecLosses);
}
//+------------------------------------------------------------------+