//+------------------------------------------------------------------+
//|                                                XAUUSD_ProfitBot.mq5 |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "Bot giao dịch XAUUSD tối ưu lợi nhuận với rủi ro thấp"

//--- Input parameters
input group "=== CÀI ĐẶT CƠ BẢN ==="
input double   InitialCapital = 5000.0;        // Vốn ban đầu (cent)
input double   TargetProfit = 20000.0;         // Mục tiêu lợi nhuận (cent)
input int      TradingDays = 7;                // Số ngày giao dịch
input double   MaxRiskPerTrade = 2.0;          // Rủi ro tối đa mỗi lệnh (%)
input double   MaxDailyRisk = 5.0;             // Rủi ro tối đa mỗi ngày (%)

input group "=== CHỈ BÁO KỸ THUẬT ==="
input int      RSI_Period = 14;                // Chu kỳ RSI
input int      RSI_Overbought = 70;            // RSI quá mua
input int      RSI_Oversold = 30;              // RSI quá bán
input int      MACD_Fast = 12;                 // MACD Fast EMA
input int      MACD_Slow = 26;                 // MACD Slow EMA
input int      MACD_Signal = 9;                // MACD Signal
input int      MA_Fast = 21;                   // Moving Average nhanh
input int      MA_Slow = 50;                   // Moving Average chậm
input int      BB_Period = 20;                 // Bollinger Bands chu kỳ
input double   BB_Deviation = 2.0;             // Bollinger Bands độ lệch

input group "=== QUẢN LÝ LỆNH ==="
input double   LotSize = 0.01;                 // Kích thước lệnh cơ bản
input int      MaxOpenTrades = 3;              // Số lệnh mở tối đa
input int      MagicNumber = 123456;           // Magic Number
input int      Slippage = 3;                   // Slippage (points)

//--- Global variables
double dailyProfit = 0.0;
double totalProfit = 0.0;
double currentCapital = 0.0;
int totalTrades = 0;
int winningTrades = 0;
datetime lastTradeTime = 0;
bool tradingEnabled = true;

//--- Indicator handles
int rsi_handle;
int macd_handle;
int ma_fast_handle;
int ma_slow_handle;
int bb_handle;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Khởi tạo các chỉ báo
    rsi_handle = iRSI(_Symbol, PERIOD_M15, RSI_Period, PRICE_CLOSE);
    macd_handle = iMACD(_Symbol, PERIOD_M15, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
    ma_fast_handle = iMA(_Symbol, PERIOD_M15, MA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    ma_slow_handle = iMA(_Symbol, PERIOD_M15, MA_Slow, 0, MODE_EMA, PRICE_CLOSE);
    bb_handle = iBands(_Symbol, PERIOD_M15, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
    
    if(rsi_handle == INVALID_HANDLE || macd_handle == INVALID_HANDLE || 
       ma_fast_handle == INVALID_HANDLE || ma_slow_handle == INVALID_HANDLE || 
       bb_handle == INVALID_HANDLE)
    {
        Print("Lỗi khởi tạo chỉ báo!");
        return INIT_FAILED;
    }
    
    currentCapital = InitialCapital;
    Print("Bot XAUUSD ProfitBot đã khởi động!");
    Print("Vốn ban đầu: ", InitialCapital, " cent");
    Print("Mục tiêu: ", TargetProfit, " cent trong ", TradingDays, " ngày");
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // Giải phóng handles
    if(rsi_handle != INVALID_HANDLE) IndicatorRelease(rsi_handle);
    if(macd_handle != INVALID_HANDLE) IndicatorRelease(macd_handle);
    if(ma_fast_handle != INVALID_HANDLE) IndicatorRelease(ma_fast_handle);
    if(ma_slow_handle != INVALID_HANDLE) IndicatorRelease(ma_slow_handle);
    if(bb_handle != INVALID_HANDLE) IndicatorRelease(bb_handle);
    
    Print("Bot đã dừng. Tổng lợi nhuận: ", totalProfit, " cent");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    if(!tradingEnabled) return;
    
    // Kiểm tra điều kiện giao dịch
    if(!IsNewBar()) return;
    if(CountOpenTrades() >= MaxOpenTrades) return;
    
    // Cập nhật thông tin vốn
    UpdateCapital();
    
    // Kiểm tra rủi ro hàng ngày
    if(dailyProfit < -MaxDailyRisk * InitialCapital / 100)
    {
        Print("Đã đạt giới hạn rủi ro hàng ngày. Dừng giao dịch hôm nay.");
        return;
    }
    
    // Lấy tín hiệu giao dịch
    int signal = GetTradingSignal();
    
    if(signal == 1) // Tín hiệu mua
    {
        OpenBuyOrder();
    }
    else if(signal == -1) // Tín hiệu bán
    {
        OpenSellOrder();
    }
    
    // Quản lý lệnh hiện tại
    ManageOpenTrades();
}

//+------------------------------------------------------------------+
//| Kiểm tra bar mới                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    static datetime lastBarTime = 0;
    datetime currentBarTime = iTime(_Symbol, PERIOD_M15, 0);
    
    if(currentBarTime != lastBarTime)
    {
        lastBarTime = currentBarTime;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Lấy tín hiệu giao dịch                                          |
//+------------------------------------------------------------------+
int GetTradingSignal()
{
    // Lấy dữ liệu chỉ báo
    double rsi_values[3];
    double macd_main[3], macd_signal[3];
    double ma_fast[3], ma_slow[3];
    double bb_upper[3], bb_lower[3], bb_middle[3];
    
    if(CopyBuffer(rsi_handle, 0, 0, 3, rsi_values) < 3) return 0;
    if(CopyBuffer(macd_handle, 0, 0, 3, macd_main) < 3) return 0;
    if(CopyBuffer(macd_handle, 1, 0, 3, macd_signal) < 3) return 0;
    if(CopyBuffer(ma_fast_handle, 0, 0, 3, ma_fast) < 3) return 0;
    if(CopyBuffer(ma_slow_handle, 0, 0, 3, ma_slow) < 3) return 0;
    if(CopyBuffer(bb_handle, 0, 0, 3, bb_upper) < 3) return 0;
    if(CopyBuffer(bb_handle, 1, 0, 3, bb_lower) < 3) return 0;
    if(CopyBuffer(bb_handle, 2, 0, 3, bb_middle) < 3) return 0;
    
    double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    
    // Tín hiệu mua (BUY)
    bool buy_signal = false;
    if(rsi_values[0] < RSI_Oversold && rsi_values[1] >= RSI_Oversold) // RSI vượt lên từ vùng quá bán
    {
        if(ma_fast[0] > ma_slow[0] && ma_fast[1] <= ma_slow[1]) // MA nhanh cắt lên MA chậm
        {
            if(macd_main[0] > macd_signal[0] && macd_main[1] <= macd_signal[1]) // MACD cắt lên
            {
                if(current_price > bb_middle[0]) // Giá trên đường giữa BB
                {
                    buy_signal = true;
                }
            }
        }
    }
    
    // Tín hiệu bán (SELL)
    bool sell_signal = false;
    if(rsi_values[0] > RSI_Overbought && rsi_values[1] <= RSI_Overbought) // RSI vượt xuống từ vùng quá mua
    {
        if(ma_fast[0] < ma_slow[0] && ma_fast[1] >= ma_slow[1]) // MA nhanh cắt xuống MA chậm
        {
            if(macd_main[0] < macd_signal[0] && macd_main[1] >= macd_signal[1]) // MACD cắt xuống
            {
                if(current_price < bb_middle[0]) // Giá dưới đường giữa BB
                {
                    sell_signal = true;
                }
            }
        }
    }
    
    if(buy_signal) return 1;
    if(sell_signal) return -1;
    return 0;
}

//+------------------------------------------------------------------+
//| Mở lệnh mua                                                     |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double lot = CalculateLotSize();
    double sl = CalculateStopLoss(ask, true);
    double tp = CalculateTakeProfit(ask, true);
    
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_DEAL;
    request.symbol = _Symbol;
    request.volume = lot;
    request.type = ORDER_TYPE_BUY;
    request.price = ask;
    request.sl = sl;
    request.tp = tp;
    request.magic = MagicNumber;
    request.comment = "XAUUSD_ProfitBot_BUY";
    request.type_filling = ORDER_FILLING_FOK;
    
    if(OrderSend(request, result))
    {
        if(result.retcode == TRADE_RETCODE_DONE)
        {
            Print("Lệnh mua đã mở thành công. Ticket: ", result.order);
            totalTrades++;
            lastTradeTime = TimeCurrent();
        }
        else
        {
            Print("Lỗi mở lệnh mua: ", result.retcode);
        }
    }
}

//+------------------------------------------------------------------+
//| Mở lệnh bán                                                     |
//+------------------------------------------------------------------+
void OpenSellOrder()
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot = CalculateLotSize();
    double sl = CalculateStopLoss(bid, false);
    double tp = CalculateTakeProfit(bid, false);
    
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_DEAL;
    request.symbol = _Symbol;
    request.volume = lot;
    request.type = ORDER_TYPE_SELL;
    request.price = bid;
    request.sl = sl;
    request.tp = tp;
    request.magic = MagicNumber;
    request.comment = "XAUUSD_ProfitBot_SELL";
    request.type_filling = ORDER_FILLING_FOK;
    
    if(OrderSend(request, result))
    {
        if(result.retcode == TRADE_RETCODE_DONE)
        {
            Print("Lệnh bán đã mở thành công. Ticket: ", result.order);
            totalTrades++;
            lastTradeTime = TimeCurrent();
        }
        else
        {
            Print("Lỗi mở lệnh bán: ", result.retcode);
        }
    }
}

//+------------------------------------------------------------------+
//| Tính toán kích thước lệnh                                       |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
    double risk_amount = currentCapital * MaxRiskPerTrade / 100.0;
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double stop_distance = 50 * SymbolInfoDouble(_Symbol, SYMBOL_POINT); // 50 points stop loss
    
    double lot = risk_amount / (stop_distance / tick_size * tick_value);
    
    // Giới hạn kích thước lệnh
    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    lot = MathMax(lot, min_lot);
    lot = MathMin(lot, max_lot);
    lot = NormalizeDouble(lot / lot_step, 0) * lot_step;
    
    return MathMax(lot, LotSize);
}

//+------------------------------------------------------------------+
//| Tính toán Stop Loss                                             |
//+------------------------------------------------------------------+
double CalculateStopLoss(double price, bool is_buy)
{
    double atr = GetATR(14);
    double sl_distance = atr * 1.5; // 1.5 ATR
    
    if(is_buy)
        return price - sl_distance;
    else
        return price + sl_distance;
}

//+------------------------------------------------------------------+
//| Tính toán Take Profit                                           |
//+------------------------------------------------------------------+
double CalculateTakeProfit(double price, bool is_buy)
{
    double atr = GetATR(14);
    double tp_distance = atr * 2.5; // 2.5 ATR (Risk:Reward = 1:1.67)
    
    if(is_buy)
        return price + tp_distance;
    else
        return price - tp_distance;
}

//+------------------------------------------------------------------+
//| Lấy giá trị ATR                                                 |
//+------------------------------------------------------------------+
double GetATR(int period)
{
    int atr_handle = iATR(_Symbol, PERIOD_M15, period);
    double atr_values[1];
    
    if(CopyBuffer(atr_handle, 0, 0, 1, atr_values) < 1)
    {
        IndicatorRelease(atr_handle);
        return 50 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    }
    
    IndicatorRelease(atr_handle);
    return atr_values[0];
}

//+------------------------------------------------------------------+
//| Quản lý lệnh mở                                                 |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);
            double profit = PositionGetDouble(POSITION_PROFIT);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            // Trailing Stop
            if(profit > 0)
            {
                double new_sl = 0;
                if(type == POSITION_TYPE_BUY)
                {
                    new_sl = current_price - GetATR(14) * 1.0;
                    if(new_sl > PositionGetDouble(POSITION_SL))
                    {
                        ModifyPosition(ticket, new_sl, PositionGetDouble(POSITION_TP));
                    }
                }
                else if(type == POSITION_TYPE_SELL)
                {
                    new_sl = current_price + GetATR(14) * 1.0;
                    if(new_sl < PositionGetDouble(POSITION_SL) || PositionGetDouble(POSITION_SL) == 0)
                    {
                        ModifyPosition(ticket, new_sl, PositionGetDouble(POSITION_TP));
                    }
                }
            }
            
            // Đóng lệnh nếu lợi nhuận đạt mục tiêu
            if(profit >= currentCapital * 0.05) // 5% lợi nhuận
            {
                ClosePosition(ticket);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Sửa đổi lệnh                                                    |
//+------------------------------------------------------------------+
void ModifyPosition(ulong ticket, double sl, double tp)
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_SLTP;
    request.position = ticket;
    request.sl = sl;
    request.tp = tp;
    
    if(OrderSend(request, result))
    {
        if(result.retcode != TRADE_RETCODE_DONE)
        {
            Print("Lỗi sửa đổi lệnh: ", result.retcode);
        }
    }
}

//+------------------------------------------------------------------+
//| Đóng lệnh                                                       |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_DEAL;
    request.position = ticket;
    request.symbol = _Symbol;
    request.volume = PositionGetDouble(POSITION_VOLUME);
    request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
    request.price = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                   SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    request.magic = MagicNumber;
    request.comment = "XAUUSD_ProfitBot_CLOSE";
    
    if(OrderSend(request, result))
    {
        if(result.retcode == TRADE_RETCODE_DONE)
        {
            Print("Lệnh đã đóng. Ticket: ", ticket, " Profit: ", PositionGetDouble(POSITION_PROFIT));
            if(PositionGetDouble(POSITION_PROFIT) > 0) winningTrades++;
        }
    }
}

//+------------------------------------------------------------------+
//| Đếm số lệnh mở                                                  |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
    int count = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            count++;
    }
    return count;
}

//+------------------------------------------------------------------+
//| Cập nhật vốn                                                    |
//+------------------------------------------------------------------+
void UpdateCapital()
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    currentCapital = equity;
    totalProfit = equity - InitialCapital;
    
    // Cập nhật lợi nhuận hàng ngày
    static datetime lastDay = 0;
    datetime currentDay = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
    
    if(currentDay != lastDay)
    {
        dailyProfit = 0;
        lastDay = currentDay;
    }
    
    // Kiểm tra mục tiêu
    if(totalProfit >= TargetProfit)
    {
        Print("Đã đạt mục tiêu lợi nhuận! Tổng lợi nhuận: ", totalProfit, " cent");
        tradingEnabled = false;
    }
}

//+------------------------------------------------------------------+
//| Expert tick function for timer                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
    // Hiển thị thông tin mỗi 60 giây
    static int counter = 0;
    counter++;
    
    if(counter >= 60) // Mỗi 60 giây
    {
        Print("=== THÔNG TIN BOT ===");
        Print("Vốn hiện tại: ", currentCapital, " cent");
        Print("Lợi nhuận: ", totalProfit, " cent (", (totalProfit/InitialCapital)*100, "%)");
        Print("Số lệnh: ", totalTrades, " | Thắng: ", winningTrades);
        Print("Lệnh mở: ", CountOpenTrades());
        counter = 0;
    }
}