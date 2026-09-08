# Two-Way Trailing Reversal EA (MT5)

A MetaTrader 5 Expert Advisor that implements a simple but robust **two-way trailing reversal** strategy.

### How it works
1. Opens an initial Buy or Sell (you choose).
2. Places a pending **Stop** order at `extreme price ± DistanceUSD`.
3. Trails that stop in the profitable direction.
4. When the stop is hit the position is reversed and the process repeats in the opposite direction.

The EA automatically:
- Handles both **hedging** and **netting** accounts
- Recovers from extra positions
- Respects broker stop-level / freeze-level restrictions
- Uses proper filling modes and volume normalization

### Installation
1. Copy `TwoWayTrailingReversal.mq5` into `MQL5/Experts/`
2. Compile in MetaEditor
3. Attach to any chart (Gold, Forex, Indices, Crypto – any symbol that has reasonable spreads)

### Recommended settings
- Gold (XAUUSD): `DistanceUSD = 2.0` – `5.0`
- Forex majors: `DistanceUSD = 0.0015` – `0.0030` (15–30 pips)
- Always test on a demo account first.

### Disclaimer
This EA is provided **as-is** for educational purposes.  
Trading involves substantial risk of loss. Past performance is not indicative of future results. Use at your own risk.

---
*Version 1.10 – Compile-ready MQL5*






LotSize (default 0.01)
Trading volume used for new positions. On netting accounts the reversal order size is automatically increased so it fully reverses the existing position.

DistanceUSD (default 2.00)
Trailing distance in the symbol’s price units (e.g. $2.00 on Gold / XAUUSD, or 0.00200 on EURUSD). This is how far the pending reversal stop is placed from the extreme price.

MagicNumber (default 2026081301)
Unique ID so the EA only manages its own trades and ignores other EAs or manual trades.

DeviationPoints (default 50)
Maximum slippage (in points) allowed when sending market orders.

MaximumSpread (default 0.0)
Maximum allowed spread in price units. Set to 0 to disable the filter.

EnableTrading (default true)
Master on/off switch. When false the EA does nothing.

StartWithBuy (default true)
If there is no open position, the EA opens a Buy first. Set to false to start with a Sell.

EnableLogs (default true)
Prints detailed information to the Experts tab (very useful for debugging).

PendingOrderExpirationMinutes (default 0)
How long pending stop orders stay valid. 0 = GTC (Good Till Cancelled).



