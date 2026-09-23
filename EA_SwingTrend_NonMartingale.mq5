//+------------------------------------------------------------------+
//| EA_SwingTrend_NonMartingale.mq5                                   |
//| Strategi: Trend-following + pullback entry, ATR-based SL/TP,      |
//| position sizing fixed-fractional (risk % tetap per trade).        |
//| TIDAK menggunakan Martingale, Grid, atau High-Frequency Trading.  |
//| Cocok diuji di MT5 Strategy Tester (Exness real account,          |
//| mode "Every tick based on real ticks").                            |
//|                                                                    |
//| Berlaku generik untuk semua instrumen: Forex, Logam (XAU/XAG),    |
//| Index (JP225, US500, dll), Crypto (BTCUSD, ETHUSD),                |
//| Energi (XBRUSD/Brent, XTIUSD/WTI).                                 |
//+------------------------------------------------------------------+
#property copyright "Tugas Backtest - No Martingale/Grid/HFT"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//================== INPUT PARAMETERS ==================
input group "=== Trend Filter (Higher Timeframe) ==="
input ENUM_TIMEFRAMES TF_Trend        = PERIOD_H4;   // Timeframe untuk filter trend
input int             EMA_Fast_Period = 50;          // EMA cepat (trend filter)
input int             EMA_Slow_Period = 200;         // EMA lambat (trend filter)

input group "=== Entry Timeframe (Pullback) ==="
input ENUM_TIMEFRAMES TF_Entry        = PERIOD_H1;   // Timeframe entry
input int             EMA_Pullback    = 20;          // EMA pullback di entry TF
input int             RSI_Period      = 14;          // Periode RSI
input double          RSI_Buy_Level   = 50.0;        // RSI harus > level ini utk BUY
input double          RSI_Sell_Level  = 50.0;        // RSI harus < level ini utk SELL

input group "=== Risk & Money Management (Fixed-Fractional, NO Martingale) ==="
input double          RiskPercent     = 1.0;         // Risiko per trade (% dari equity)
input double          ATR_Multiplier_SL = 2.0;       // SL = ATR x multiplier
input double          RiskRewardRatio = 2.0;         // TP = SL x rasio ini
input int             ATR_Period      = 14;          // Periode ATR
input int             MaxOpenPositions= 1;           // Maks posisi terbuka bersamaan (per simbol)
input bool            UseTrailingStop = true;         // Aktifkan trailing stop
input double          TrailingStart_ATR = 1.5;       // Mulai trailing setelah profit x ATR
input double          TrailingStep_ATR  = 0.5;       // Jarak trailing (x ATR)

input group "=== Filter Anti-HFT (jaga jarak antar transaksi) ==="
input int             MinBarsBetweenTrades = 3;      // Minimal jumlah bar sebelum entry baru
input int             Magic_Number    = 202602;      // Magic number EA

//================== GLOBAL VARIABLES ==================
int hEMA_Fast_Trend, hEMA_Slow_Trend, hEMA_Pullback_Entry, hRSI_Entry, hATR_Entry;
datetime lastTradeBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   hEMA_Fast_Trend    = iMA(_Symbol, TF_Trend, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_Trend    = iMA(_Symbol, TF_Trend, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Pullback_Entry= iMA(_Symbol, TF_Entry, EMA_Pullback, 0, MODE_EMA, PRICE_CLOSE);
   hRSI_Entry         = iRSI(_Symbol, TF_Entry, RSI_Period, PRICE_CLOSE);
   hATR_Entry         = iATR(_Symbol, TF_Entry, ATR_Period);

   if(hEMA_Fast_Trend==INVALID_HANDLE || hEMA_Slow_Trend==INVALID_HANDLE ||
      hEMA_Pullback_Entry==INVALID_HANDLE || hRSI_Entry==INVALID_HANDLE || hATR_Entry==INVALID_HANDLE)
   {
      Print("ERROR: gagal membuat indikator handle");
      return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hEMA_Fast_Trend);
   IndicatorRelease(hEMA_Slow_Trend);
   IndicatorRelease(hEMA_Pullback_Entry);
   IndicatorRelease(hRSI_Entry);
   IndicatorRelease(hATR_Entry);
}

//+------------------------------------------------------------------+
//| Helper: ambil 1 nilai indikator                                   |
//+------------------------------------------------------------------+
double GetValue(int handle, int shift=0)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) <= 0) return(0);
   return(buf[0]);
}

//+------------------------------------------------------------------+
//| Hitung jumlah posisi terbuka milik EA ini di simbol ini            |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int cnt = 0;
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==Magic_Number)
            cnt++;
      }
   }
   return(cnt);
}

//+------------------------------------------------------------------+
//| Position sizing fixed-fractional (BUKAN martingale)                |
//| Lot dihitung dari % risiko equity dan jarak SL, TIDAK pernah        |
//| diperbesar karena loss sebelumnya.                                  |
//+------------------------------------------------------------------+
double CalcLotSize(double slDistancePoints)
{
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney  = equity * (RiskPercent/100.0);
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickValue<=0 || tickSize<=0 || slDistancePoints<=0) return(0);

   double valuePerPoint = tickValue * (point/tickSize);
   double lot = riskMoney / (slDistancePoints * valuePerPoint);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot/stepLot)*stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return(lot);
}

//+------------------------------------------------------------------+
//| Filter anti-HFT: pastikan sudah lewat N bar sejak trade terakhir   |
//+------------------------------------------------------------------+
bool EnoughBarsSinceLastTrade()
{
   datetime t0 = iTime(_Symbol, TF_Entry, 0);
   int barsElapsed = (int)((t0 - lastTradeBarTime) / PeriodSeconds(TF_Entry));
   return(barsElapsed >= MinBarsBetweenTrades);
}

//+------------------------------------------------------------------+
//| Trailing stop sederhana berbasis ATR                                |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(!UseTrailingStop) return;
   double atr = GetValue(hATR_Entry, 0);
   if(atr<=0) return;

   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=Magic_Number) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);
      long   type      = PositionGetInteger(POSITION_TYPE);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type==POSITION_TYPE_BUY)
      {
         double profit = bid - openPrice;
         if(profit >= TrailingStart_ATR*atr)
         {
            double newSL = bid - TrailingStep_ATR*atr;
            if(newSL > curSL) trade.PositionModify(ticket, newSL, curTP);
         }
      }
      else if(type==POSITION_TYPE_SELL)
      {
         double profit = openPrice - ask;
         if(profit >= TrailingStart_ATR*atr)
         {
            double newSL = ask + TrailingStep_ATR*atr;
            if(newSL < curSL || curSL==0) trade.PositionModify(ticket, newSL, curTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick: hanya evaluasi sinyal pada open bar baru (anti-HFT)         |
//+------------------------------------------------------------------+
void OnTick()
{
   ManageTrailingStop();

   static datetime lastBarTime = 0;
   datetime curBarTime = iTime(_Symbol, TF_Entry, 0);
   if(curBarTime == lastBarTime) return; // hanya proses sekali per bar baru
   lastBarTime = curBarTime;

   if(CountOpenPositions() >= MaxOpenPositions) return;
   if(!EnoughBarsSinceLastTrade()) return;

   // --- Trend filter di TF lebih tinggi ---
   double emaFastTrend = GetValue(hEMA_Fast_Trend, 1);
   double emaSlowTrend = GetValue(hEMA_Slow_Trend, 1);
   bool uptrend   = emaFastTrend > emaSlowTrend;
   bool downtrend = emaFastTrend < emaSlowTrend;

   // --- Entry filter (pullback + momentum) ---
   double close1   = iClose(_Symbol, TF_Entry, 1);
   double emaPull1 = GetValue(hEMA_Pullback_Entry, 1);
   double rsi1     = GetValue(hRSI_Entry, 1);
   double atr1     = GetValue(hATR_Entry, 1);
   if(atr1<=0) return;

   bool buySignal  = uptrend   && close1 > emaPull1 && rsi1 > RSI_Buy_Level;
   bool sellSignal = downtrend && close1 < emaPull1 && rsi1 < RSI_Sell_Level;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double slDistance = ATR_Multiplier_SL * atr1;
   double slPoints   = slDistance / point;

   if(buySignal)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = ask - slDistance;
      double tp  = ask + slDistance*RiskRewardRatio;
      double lot = CalcLotSize(slPoints);
      if(lot>0)
      {
         if(trade.Buy(lot, _Symbol, ask, sl, tp, "SwingTrend-Buy"))
            lastTradeBarTime = curBarTime;
      }
   }
   else if(sellSignal)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = bid + slDistance;
      double tp  = bid - slDistance*RiskRewardRatio;
      double lot = CalcLotSize(slPoints);
      if(lot>0)
      {
         if(trade.Sell(lot, _Symbol, bid, sl, tp, "SwingTrend-Sell"))
            lastTradeBarTime = curBarTime;
      }
   }
}
//+------------------------------------------------------------------+
