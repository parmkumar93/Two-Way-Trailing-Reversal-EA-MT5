//+------------------------------------------------------------------+
//|                         Two-Way Trailing Reversal EA - FIXED     |
//|                                      Compile-ready MT5 MQL5 EA    |
//+------------------------------------------------------------------+
#property strict
#property version "1.10"

input double LotSize                       = 0.01;
input double DistanceUSD                   = 2.00;
input ulong  MagicNumber                   = 2026081301;
input int    DeviationPoints               = 50;
input double MaximumSpread                 = 0.0;     // Actual price spread. 0 disables.
input bool   EnableTrading                 = true;
input bool   StartWithBuy                  = true;
input bool   EnableLogs                    = true;
input int    PendingOrderExpirationMinutes = 0;       // 0 = GTC

#define EA_NAME    "Two-Way Trailing Reversal EA"
#define EA_COMMENT "TwoWayTrailReverse"

double g_highestBid = 0.0;
double g_lowestAsk  = 0.0;
ulong  g_lastPosTicket = 0;
int    g_lastPosType   = -1;
bool   g_busy = false;

//+------------------------------------------------------------------+
//| Logging                                                          |
//+------------------------------------------------------------------+
void Log(string msg)
{
   if(EnableLogs)
      Print(EA_NAME, " [", _Symbol, " Magic=", MagicNumber, "]: ", msg);
}

//+------------------------------------------------------------------+
//| Symbol helpers                                                   |
//+------------------------------------------------------------------+
int DigitsValue()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
}

double PointValue()
{
   double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(p <= 0.0) p = _Point;
   return p;
}

double TickSize()
{
   double t = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(t <= 0.0) t = PointValue();
   return t;
}

double Eps()
{
   return TickSize() * 0.5;
}

double NormPrice(double price)
{
   double tick = TickSize();
   int digits = DigitsValue();
   if(tick <= 0.0)
      return NormalizeDouble(price, digits);

   return NormalizeDouble(MathRound(price / tick) * tick, digits);
}

double NormPriceDown(double price)
{
   double tick = TickSize();
   int digits = DigitsValue();
   if(tick <= 0.0)
      return NormalizeDouble(price, digits);

   return NormalizeDouble(MathFloor(price / tick) * tick, digits);
}

double NormPriceUp(double price)
{
   double tick = TickSize();
   int digits = DigitsValue();
   if(tick <= 0.0)
      return NormalizeDouble(price, digits);

   return NormalizeDouble(MathCeil(price / tick) * tick, digits);
}

string P(double price)
{
   return DoubleToString(NormalizeDouble(price, DigitsValue()), DigitsValue());
}

int VolumeDigits(double step)
{
   int d = 0;
   while(d < 8)
   {
      if(MathAbs(NormalizeDouble(step, d) - step) < 0.000000001)
         return d;
      d++;
   }
   return 2;
}

double NormVolume(double vol)
{
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minv <= 0.0) minv = 0.01;
   if(maxv <= 0.0) maxv = 100.0;
   if(step <= 0.0) step = minv;

   if(vol < minv) vol = minv;
   if(vol > maxv) vol = maxv;

   vol = MathRound(vol / step) * step;

   if(vol < minv) vol = minv;
   if(vol > maxv) vol = maxv;

   return NormalizeDouble(vol, VolumeDigits(step));
}

string V(double vol)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   return DoubleToString(NormalizeDouble(vol, VolumeDigits(step)), VolumeDigits(step));
}

//+------------------------------------------------------------------+
//| Account mode                                                     |
//+------------------------------------------------------------------+
bool IsNetting()
{
   ENUM_ACCOUNT_MARGIN_MODE mode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   return mode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING ||
          mode == ACCOUNT_MARGIN_MODE_EXCHANGE;
}

//+------------------------------------------------------------------+
//| Tick and filters                                                 |
//+------------------------------------------------------------------+
bool GetTick(MqlTick &tick)
{
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Log("No tick data available.");
      return false;
   }

   if(tick.bid <= 0.0 || tick.ask <= 0.0)
   {
      Log("Invalid tick. Bid=" + P(tick.bid) + " Ask=" + P(tick.ask));
      return false;
   }

   return true;
}

bool SpreadOK()
{
   if(MaximumSpread <= 0.0)
      return true;

   MqlTick tick;
   if(!GetTick(tick))
      return false;

   double spread = tick.ask - tick.bid;

   if(spread > MaximumSpread)
   {
      Log("Spread too high. Spread=" + P(spread) + " MaximumSpread=" + P(MaximumSpread));
      return false;
   }

   return true;
}

bool TradingOK()
{
   if(!EnableTrading)
      return false;

   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      Log("Terminal not connected.");
      return false;
   }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Log("AutoTrading disabled in terminal.");
      return false;
   }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Log("EA trading permission disabled.");
      return false;
   }

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      Log("Account trading disabled.");
      return false;
   }

   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);

   if(mode == SYMBOL_TRADE_MODE_DISABLED)
   {
      Log("Symbol trading disabled by broker.");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Broker stop/freeze distance                                      |
//+------------------------------------------------------------------+
double MinStopDistance()
{
   double point = PointValue();

   int stops  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   double dist = MathMax(stops * point, freeze * point);
   dist = MathMax(dist, TickSize());

   return dist;
}

//+------------------------------------------------------------------+
//| Position/order counting                                          |
//+------------------------------------------------------------------+
int CountManagedPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         count++;
      }
   }

   return count;
}

bool GetManagedPosition(ulong &ticket,
                        ENUM_POSITION_TYPE &type,
                        double &volume,
                        double &open_price)
{
   ticket = 0;
   volume = 0.0;
   open_price = 0.0;
   type = POSITION_TYPE_BUY;

   long newest_time = -1;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      long tm = (long)PositionGetInteger(POSITION_TIME_MSC);

      if(ticket == 0 || tm > newest_time)
      {
         ticket = t;
         newest_time = tm;
         type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         volume = PositionGetDouble(POSITION_VOLUME);
         open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }

   return ticket != 0;
}

int CountManagedOrders()
{
   int count = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;

      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == MagicNumber)
      {
         count++;
      }
   }

   return count;
}

bool GetPending(ENUM_ORDER_TYPE wanted,
                ulong &ticket,
                double &price,
                double &volume)
{
   ticket = 0;
   price = 0.0;
   volume = 0.0;

   bool found = false;
   double best_price = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != wanted)
         continue;

      double p = OrderGetDouble(ORDER_PRICE_OPEN);

      if(!found)
      {
         found = true;
         ticket = t;
         price = p;
         volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
         best_price = p;
      }
      else
      {
         if(wanted == ORDER_TYPE_SELL_STOP && p > best_price)
         {
            ticket = t;
            price = p;
            volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
            best_price = p;
         }

         if(wanted == ORDER_TYPE_BUY_STOP && p < best_price)
         {
            ticket = t;
            price = p;
            volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
            best_price = p;
         }
      }
   }

   return found;
}

//+------------------------------------------------------------------+
//| Delete orders                                                    |
//+------------------------------------------------------------------+
bool DeleteOrder(ulong ticket)
{
   if(ticket == 0)
      return true;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action = TRADE_ACTION_REMOVE;
   req.order  = ticket;
   req.symbol = _Symbol;
   req.magic  = MagicNumber;

   ResetLastError();

   if(!OrderSend(req, res))
   {
      Log("OrderDelete send failed. Ticket=" + (string)ticket +
          " LastError=" + (string)GetLastError());
      return false;
   }

   if(res.retcode != TRADE_RETCODE_DONE)
   {
      Log("OrderDelete rejected. Ticket=" + (string)ticket +
          " Retcode=" + (string)res.retcode +
          " Comment=" + res.comment);
      return false;
   }

   Log("Pending order deleted. Ticket=" + (string)ticket);
   return true;
}

void DeleteAllManagedOrdersExcept(ulong keep_ticket, ENUM_ORDER_TYPE keep_type)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(t == keep_ticket && type == keep_type)
         continue;

      DeleteOrder(t);
   }
}

void DeleteAllManagedOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;

      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == MagicNumber)
      {
         DeleteOrder(t);
      }
   }
}

//+------------------------------------------------------------------+
//| Filling mode helper                                              |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING BestFillingMode()
{
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;

   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Send market order                                                |
//+------------------------------------------------------------------+
bool SendMarket(ENUM_ORDER_TYPE type)
{
   if(!TradingOK())
      return false;

   if(!SpreadOK())
      return false;

   MqlTick tick;
   if(!GetTick(tick))
      return false;

   double vol = NormVolume(LotSize);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.magic        = MagicNumber;
   req.volume       = vol;
   req.type         = type;
   req.deviation    = DeviationPoints;
   req.comment      = EA_COMMENT;
   req.type_filling = BestFillingMode();

   if(type == ORDER_TYPE_BUY)
      req.price = tick.ask;
   else
      req.price = tick.bid;

   ResetLastError();

   Log("Sending market order: " + EnumToString(type) +
       " Volume=" + V(vol) +
       " Price=" + P(req.price) +
       " Filling=" + EnumToString(req.type_filling));

   if(!OrderSend(req, res))
   {
      Log("Market OrderSend failed. LastError=" + (string)GetLastError());
      return false;
   }

   if(res.retcode != TRADE_RETCODE_DONE &&
      res.retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      Log("Market order rejected. Retcode=" + (string)res.retcode +
          " Comment=" + res.comment +
          " Deal=" + (string)res.deal +
          " Order=" + (string)res.order);
      return false;
   }

   Log("Market order executed. Type=" + EnumToString(type) +
       " Deal=" + (string)res.deal +
       " Price=" + P(res.price) +
       " Volume=" + V(vol));

   return true;
}

//+------------------------------------------------------------------+
//| Pending price validation                                         |
//+------------------------------------------------------------------+
bool ValidPendingPrice(ENUM_ORDER_TYPE type, double desired, double &price)
{
   MqlTick tick;
   if(!GetTick(tick))
      return false;

   double min_dist = MinStopDistance();

   if(DistanceUSD + Eps() < min_dist)
   {
      Log("Broker stop-level restriction. DistanceUSD=" + P(DistanceUSD) +
          " MinimumRequired=" + P(min_dist) +
          ". No pending order sent.");
      return false;
   }

   if(type == ORDER_TYPE_SELL_STOP)
   {
      price = NormPriceDown(desired);

      double max_allowed = NormPriceDown(tick.bid - min_dist);

      if(price > max_allowed)
         price = max_allowed;

      if(price <= 0.0 || tick.bid - price < min_dist - Eps())
      {
         Log("Invalid SELL STOP price. Bid=" + P(tick.bid) +
             " Price=" + P(price) +
             " MinDist=" + P(min_dist));
         return false;
      }

      return true;
   }

   if(type == ORDER_TYPE_BUY_STOP)
   {
      price = NormPriceUp(desired);

      double min_allowed = NormPriceUp(tick.ask + min_dist);

      if(price < min_allowed)
         price = min_allowed;

      if(price <= 0.0 || price - tick.ask < min_dist - Eps())
      {
         Log("Invalid BUY STOP price. Ask=" + P(tick.ask) +
             " Price=" + P(price) +
             " MinDist=" + P(min_dist));
         return false;
      }

      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Reversal pending volume                                          |
//+------------------------------------------------------------------+
double ReversalVolume(double active_volume)
{
   double target = NormVolume(LotSize);

   if(IsNetting())
      return NormVolume(active_volume + target);

   return target;
}

//+------------------------------------------------------------------+
//| Send pending stop                                                |
//+------------------------------------------------------------------+
bool SendPendingStop(ENUM_ORDER_TYPE type,
                     double desired_price,
                     double active_volume)
{
   if(!TradingOK())
      return false;

   double price = 0.0;

   if(!ValidPendingPrice(type, desired_price, price))
      return false;

   double vol = ReversalVolume(active_volume);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action      = TRADE_ACTION_PENDING;
   req.symbol      = _Symbol;
   req.magic       = MagicNumber;
   req.volume      = vol;
   req.type        = type;
   req.price       = price;
   req.sl          = 0.0;
   req.tp          = 0.0;
   req.comment     = EA_COMMENT;

   if(PendingOrderExpirationMinutes > 0)
   {
      req.type_time  = ORDER_TIME_SPECIFIED;
      req.expiration = TimeCurrent() + PendingOrderExpirationMinutes * 60;
   }
   else
   {
      req.type_time = ORDER_TIME_GTC;
   }

   /*
      For pending orders, ORDER_FILLING_RETURN is usually accepted.
      Some brokers ignore filling for pending orders.
   */
   req.type_filling = ORDER_FILLING_RETURN;

   ResetLastError();

   Log("Sending pending order: " + EnumToString(type) +
       " Volume=" + V(vol) +
       " Price=" + P(price));

   if(!OrderSend(req, res))
   {
      Log("Pending OrderSend failed. LastError=" + (string)GetLastError());
      return false;
   }

   if(res.retcode != TRADE_RETCODE_DONE &&
      res.retcode != TRADE_RETCODE_PLACED)
   {
      Log("Pending order rejected. Retcode=" + (string)res.retcode +
          " Comment=" + res.comment +
          " Order=" + (string)res.order);
      return false;
   }

   if(type == ORDER_TYPE_SELL_STOP)
      Log("SELL STOP placed. Price=" + P(price) + " Volume=" + V(vol));
   else
      Log("BUY STOP placed. Price=" + P(price) + " Volume=" + V(vol));

   return true;
}

//+------------------------------------------------------------------+
//| Modify pending order                                             |
//+------------------------------------------------------------------+
bool ModifyPending(ulong ticket,
                   ENUM_ORDER_TYPE type,
                   double desired_price)
{
   double price = 0.0;

   if(!ValidPendingPrice(type, desired_price, price))
      return false;

   if(!OrderSelect(ticket))
      return false;

   double old_price = OrderGetDouble(ORDER_PRICE_OPEN);

   if(MathAbs(old_price - price) <= Eps())
      return true;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action = TRADE_ACTION_MODIFY;
   req.order  = ticket;
   req.symbol = _Symbol;
   req.magic  = MagicNumber;
   req.price  = price;
   req.sl     = 0.0;
   req.tp     = 0.0;

   if(PendingOrderExpirationMinutes > 0)
   {
      req.type_time  = ORDER_TIME_SPECIFIED;
      req.expiration = TimeCurrent() + PendingOrderExpirationMinutes * 60;
   }
   else
   {
      req.type_time = ORDER_TIME_GTC;
   }

   ResetLastError();

   if(!OrderSend(req, res))
   {
      Log("Order modification send failed. LastError=" + (string)GetLastError());
      return false;
   }

   if(res.retcode != TRADE_RETCODE_DONE &&
      res.retcode != TRADE_RETCODE_NO_CHANGES)
   {
      Log("Order modification rejected. Retcode=" + (string)res.retcode +
          " Comment=" + res.comment);
      return false;
   }

   if(type == ORDER_TYPE_SELL_STOP)
      Log("SELL STOP trailed upward. Old=" + P(old_price) + " New=" + P(price));
   else
      Log("BUY STOP trailed downward. Old=" + P(old_price) + " New=" + P(price));

   return true;
}

//+------------------------------------------------------------------+
//| Close extra positions for hedging recovery                       |
//+------------------------------------------------------------------+
void CloseExtraPositionsKeepNewest()
{
   ulong newest = 0;
   long newest_time = -1;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      long tm = (long)PositionGetInteger(POSITION_TIME_MSC);

      if(newest == 0 || tm > newest_time)
      {
         newest = t;
         newest_time = tm;
      }
   }

   if(newest == 0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(t == newest)
         continue;

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      ENUM_POSITION_TYPE ptype =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double volume = PositionGetDouble(POSITION_VOLUME);

      MqlTick tick;
      if(!GetTick(tick))
         continue;

      req.action       = TRADE_ACTION_DEAL;
      req.position     = t;
      req.symbol       = _Symbol;
      req.magic        = MagicNumber;
      req.volume       = volume;
      req.deviation    = DeviationPoints;
      req.comment      = EA_COMMENT + " close extra";
      req.type_filling = BestFillingMode();

      if(ptype == POSITION_TYPE_BUY)
      {
         req.type  = ORDER_TYPE_SELL;
         req.price = tick.bid;
      }
      else
      {
         req.type  = ORDER_TYPE_BUY;
         req.price = tick.ask;
      }

      if(OrderSend(req, res))
      {
         Log("Closed extra old position. Ticket=" + (string)t +
             " Retcode=" + (string)res.retcode);
      }
      else
      {
         Log("Failed to close extra position. Ticket=" + (string)t +
             " Error=" + (string)GetLastError());
      }
   }

   DeleteAllManagedOrders();
}

//+------------------------------------------------------------------+
//| Manage BUY                                                       |
//+------------------------------------------------------------------+
void ManageBuy(ulong pos_ticket, double pos_volume, double pos_open)
{
   MqlTick tick;
   if(!GetTick(tick))
      return;

   ulong sell_stop_ticket;
   double sell_stop_price;
   double sell_stop_volume;

   bool has_sell_stop =
      GetPending(ORDER_TYPE_SELL_STOP,
                 sell_stop_ticket,
                 sell_stop_price,
                 sell_stop_volume);

   DeleteAllManagedOrdersExcept(has_sell_stop ? sell_stop_ticket : 0,
                                ORDER_TYPE_SELL_STOP);

   bool new_position =
      g_lastPosTicket != pos_ticket ||
      g_lastPosType != POSITION_TYPE_BUY ||
      g_highestBid <= 0.0;

   if(new_position)
   {
      g_lastPosTicket = pos_ticket;
      g_lastPosType   = POSITION_TYPE_BUY;
      g_lowestAsk     = 0.0;

      g_highestBid = MathMax(pos_open, tick.bid);

      if(has_sell_stop)
         g_highestBid = MathMax(g_highestBid, sell_stop_price + DistanceUSD);

      Log("BUY position detected. Ticket=" + (string)pos_ticket +
          " Entry=" + P(pos_open) +
          " HighestBid=" + P(g_highestBid));
   }

   if(tick.bid > g_highestBid)
      g_highestBid = tick.bid;

   double desired = g_highestBid - DistanceUSD;

   if(!has_sell_stop)
   {
      SendPendingStop(ORDER_TYPE_SELL_STOP, desired, pos_volume);
      return;
   }

   double new_price = 0.0;
   if(!ValidPendingPrice(ORDER_TYPE_SELL_STOP, desired, new_price))
      return;

   if(new_price > sell_stop_price + Eps())
      ModifyPending(sell_stop_ticket, ORDER_TYPE_SELL_STOP, desired);
}

//+------------------------------------------------------------------+
//| Manage SELL                                                      |
//+------------------------------------------------------------------+
void ManageSell(ulong pos_ticket, double pos_volume, double pos_open)
{
   MqlTick tick;
   if(!GetTick(tick))
      return;

   ulong buy_stop_ticket;
   double buy_stop_price;
   double buy_stop_volume;

   bool has_buy_stop =
      GetPending(ORDER_TYPE_BUY_STOP,
                 buy_stop_ticket,
                 buy_stop_price,
                 buy_stop_volume);

   DeleteAllManagedOrdersExcept(has_buy_stop ? buy_stop_ticket : 0,
                                ORDER_TYPE_BUY_STOP);

   bool new_position =
      g_lastPosTicket != pos_ticket ||
      g_lastPosType != POSITION_TYPE_SELL ||
      g_lowestAsk <= 0.0;

   if(new_position)
   {
      g_lastPosTicket = pos_ticket;
      g_lastPosType   = POSITION_TYPE_SELL;
      g_highestBid    = 0.0;

      g_lowestAsk = MathMin(pos_open, tick.ask);

      if(has_buy_stop)
         g_lowestAsk = MathMin(g_lowestAsk, buy_stop_price - DistanceUSD);

      Log("SELL position detected. Ticket=" + (string)pos_ticket +
          " Entry=" + P(pos_open) +
          " LowestAsk=" + P(g_lowestAsk));
   }

   if(tick.ask < g_lowestAsk)
      g_lowestAsk = tick.ask;

   double desired = g_lowestAsk + DistanceUSD;

   if(!has_buy_stop)
   {
      SendPendingStop(ORDER_TYPE_BUY_STOP, desired, pos_volume);
      return;
   }

   double new_price = 0.0;
   if(!ValidPendingPrice(ORDER_TYPE_BUY_STOP, desired, new_price))
      return;

   if(new_price < buy_stop_price - Eps())
      ModifyPending(buy_stop_ticket, ORDER_TYPE_BUY_STOP, desired);
}

//+------------------------------------------------------------------+
//| Main manager                                                     |
//+------------------------------------------------------------------+
void Manage()
{
   if(!EnableTrading)
      return;

   if(!TradingOK())
      return;

   int pos_count = CountManagedPositions();

   if(pos_count > 1)
   {
      Log("More than one managed position detected. Recovery: closing older positions.");
      CloseExtraPositionsKeepNewest();
      return;
   }

   ulong pos_ticket;
   ENUM_POSITION_TYPE pos_type;
   double pos_volume;
   double pos_open;

   bool has_position =
      GetManagedPosition(pos_ticket, pos_type, pos_volume, pos_open);

   if(has_position)
   {
      if(pos_type == POSITION_TYPE_BUY)
         ManageBuy(pos_ticket, pos_volume, pos_open);
      else
         ManageSell(pos_ticket, pos_volume, pos_open);

      return;
   }

   int order_count = CountManagedOrders();

   if(order_count > 0)
   {
      Log("No position, but existing EA pending order detected. Not opening new initial trade.");
      return;
   }

   g_highestBid = 0.0;
   g_lowestAsk = 0.0;
   g_lastPosTicket = 0;
   g_lastPosType = -1;

   if(!SpreadOK())
      return;

   if(StartWithBuy)
   {
      Log("No position/order found. Opening initial BUY.");
      SendMarket(ORDER_TYPE_BUY);
   }
   else
   {
      Log("No position/order found. Opening initial SELL.");
      SendMarket(ORDER_TYPE_SELL);
   }
}

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   Log("EA initialized. If no trade opens, check Experts tab for exact rejection retcode/comment.");
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Log("EA removed. Reason=" + (string)reason);
}

void OnTick()
{
   if(g_busy)
      return;

   g_busy = true;
   Manage();
   g_busy = false;
}

void OnTimer()
{
   if(g_busy)
      return;

   g_busy = true;
   Manage();
   g_busy = false;
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      Log("Trade transaction detected. EA will rescan position/order state.");
   }
}
//+------------------------------------------------------------------+