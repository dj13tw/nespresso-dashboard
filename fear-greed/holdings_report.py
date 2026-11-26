#!/usr/bin/env python3
"""持股健檢資料：依持股清單抓公開資料，算出每檔的技術面、基本面與持有信心燈號。

本程式不含任何個人資料。持股清單由呼叫者提供（存在私人頁面裡，不放進 repo）。

用法：
  python3 holdings_report.py --holdings in.json --account account.json \
      [--prices prices.json] [--notes notes.json] --out-holdings out.json --out-prices prices_out.json

in.json        [{code,name,market:"TW"|"US",board:"上市"|"上櫃",kind:"stock"|"etf",sector,role:"核心"|"衛星",
                 shares,cost, price?,price_date?(美股手動價格)}]
account.json   {"cash_twd": <台股帳戶現金>, "usd_twd": <美元兌台幣匯率>}
prices.json    上次輸出的價格歷史 {rows:[{code,date,close}]}，用來累積，避免每天重抓歷史
notes.json     {"<code>": {"date","text","url","source","tone":"pos"|"neg"|"neutral"}}  人工整理的新聞摘要

資料來源（皆為公開資料）：
- FinMind 開放資料 TaiwanStockPrice：補抓歷史收盤價（一檔一個請求，只送股票代號）
- 櫃買中心 tradingStock：上櫃個股月成交（FinMind 失敗時的備援）
- 證交所 openapi STOCK_DAY_ALL、櫃買中心 openapi tpex_mainboard_daily_close_quotes：每日最新行情
- 證交所 openapi t187ap05_L、櫃買中心 openapi mopsfin_t187ap05_O：月營收
證交所對大量的個股歷史查詢會封鎖連線，所以不向證交所補抓歷史；請求之間間隔 8 秒。歷史資料只在不足時補抓一次。
"""
import argparse
import json
import re
import sys
import time
import urllib.request
from datetime import date, datetime, timedelta, timezone

TPE = timezone(timedelta(hours=8))
DELAY = 8
KEEP = 260          # 每檔保留的交易日數（約一年）
BACKFILL_MONTHS = 6  # 歷史不足 100 日時補抓的月數（足夠算 120 日均線）
_last = [0.0]


def get_json(url, tries=3):
    for i in range(tries):
        wait = DELAY - (time.time() - _last[0])
        if wait > 0:
            time.sleep(wait)
        try:
            req = urllib.request.Request(url, headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode("utf-8-sig"))
        except Exception as e:  # noqa: BLE001
            print(f"  重試 {i + 1}/{tries}：{url}（{e}）", file=sys.stderr)
            time.sleep(10 * (i + 1))
        finally:
            _last[0] = time.time()
    raise RuntimeError(f"無法取得 {url}")


def num(s):
    m = re.search(r"-?\d+(?:\.\d+)?", str(s).replace(",", ""))
    return float(m.group()) if m else None


def roc(s):  # "115/11/02" 或 "1151125" -> "2026-11-02"
    s = str(s).strip()
    if "/" in s:
        y, m, d = s.split("/")
    else:
        y, m, d = s[:-4], s[-4:-2], s[-2:]
    return f"{int(y) + 1911:04d}-{int(m):02d}-{int(d):02d}"


def month_starts(n):
    firsts = [datetime.now(TPE).date().replace(day=1)]
    for _ in range(n - 1):
        firsts.insert(0, (firsts[0] - timedelta(days=1)).replace(day=1))
    return firsts


def history(code, board, out):
    """補抓近幾個月的收盤價，寫進 out。先用 FinMind；上櫃股票失敗時改用櫃買中心。都失敗就丟出錯誤。"""
    start = month_starts(BACKFILL_MONTHS)[0]
    try:
        d = get_json(f"https://api.finmindtrade.com/api/v4/data?dataset=TaiwanStockPrice&data_id={code}"
                     f"&start_date={start:%Y-%m-%d}")
        rows = d.get("data") or []
        for r in rows:
            if r.get("close"):
                out[r["date"]] = float(r["close"])
        if rows:
            return out
    except Exception as e:  # noqa: BLE001
        print(f"  FinMind 失敗：{code}（{e}）", file=sys.stderr)
    if board != "上櫃":
        raise RuntimeError(f"{code} 沒有取得歷史資料")
    for first in month_starts(BACKFILL_MONTHS):
        d = get_json(f"https://www.tpex.org.tw/www/zh-tw/afterTrading/tradingStock?code={code}"
                     f"&date={first:%Y}%2F{first:%m}%2F01&response=json")
        for r in (d.get("tables") or [{}])[0].get("data", []):
            c = num(r[6])
            if c:
                out[roc(r[0])] = c
    return out


def latest_quotes():
    q = {}
    try:
        for r in get_json("https://openapi.twse.com.tw/v1/exchangeReport/STOCK_DAY_ALL"):
            c = num(r.get("ClosingPrice"))
            if c:
                q[r["Code"]] = (roc(r["Date"]), c)
    except Exception as e:  # noqa: BLE001
        print(f"⚠️ 上市當日行情失敗：{e}", file=sys.stderr)
    try:
        for r in get_json("https://www.tpex.org.tw/openapi/v1/tpex_mainboard_daily_close_quotes"):
            c = num(r.get("Close"))
            if c:
                q[r["SecuritiesCompanyCode"]] = (roc(r["Date"]), c)
    except Exception as e:  # noqa: BLE001
        print(f"⚠️ 上櫃當日行情失敗：{e}", file=sys.stderr)
    return q


def revenues():
    rev = {}
    for url in ("https://openapi.twse.com.tw/v1/opendata/t187ap05_L",
                "https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap05_O"):
        try:
            for r in get_json(url):
                ym = str(r["資料年月"])
                rev[r["公司代號"]] = {
                    "month": f"{int(ym[:-2]) + 1911}-{ym[-2:]}",
                    "yoy": num(r["營業收入-去年同月增減(%)"]),
                    "mom": num(r["營業收入-上月比較增減(%)"]),
                    "cum_yoy": num(r["累計營業收入-前期比較增減(%)"]),
                    "remark": (r.get("備註") or "").strip().strip("-"),
                }
        except Exception as e:  # noqa: BLE001
            print(f"⚠️ 月營收失敗：{url}（{e}）", file=sys.stderr)
    return rev


def ma(closes, n):
    return sum(closes[-n:]) / n if len(closes) >= n else None


def pct(a, b):
    return (a / b - 1) * 100 if a is not None and b else None


def r1(v):
    return round(v, 1) if v is not None else None


def judge(h, m, market_dd):
    """回傳 (燈號, 一句話理由)。規則寫在這裡，頁面上「判斷方式」照這裡說明。"""
    if h["market"] == "US":
        return "未追蹤", "美股股價尚未自動更新，先不判斷。"
    if h["kind"] == "etf":
        return "綠", "ETF 跟隨市場整體表現，不需個別判斷公司狀況。"
    rv, note = m.get("rev"), m.get("note") or {}
    trend, dd = m.get("trend"), m.get("dd")
    rel = dd - market_dd if dd is not None and market_dd is not None else None
    parts = []
    if rv:
        parts.append(f"{rv['month'][5:]}月營收年增 {rv['yoy']:+.0f}%、今年累計 {rv['cum_yoy']:+.0f}%")
        fund = "good" if rv["yoy"] > 0 and rv["cum_yoy"] > 0 else "bad" if rv["yoy"] < 0 and rv["cum_yoy"] < 0 else "mixed"
    else:
        fund = None
        parts.append("沒有月營收資料")
    if dd is not None and rel is not None:
        parts.append(f"距近期高點 {dd:.0f}%（大盤 {market_dd:.0f}%）")
    else:
        parts.append("股價歷史還在累積，暫時只看營收")
    # 跌幅比大盤多 15 個百分點且在長期均線下，或多 25 個百分點以上，都算股價明顯弱於大盤
    weak_price = rel is not None and (rel < -25 or (rel < -15 and trend == "down"))
    if note.get("tone") == "neg":
        light, why = "紅", "有公司本身的負面消息，需要重新檢視持有理由"
    elif fund == "bad":
        light, why = "紅", "營收衰退，公司本身轉弱，需要重新檢視持有理由"
    elif fund == "mixed" and weak_price:
        light, why = "紅", "營收轉弱且股價明顯弱於大盤，需要重新檢視持有理由"
    elif fund == "mixed" or weak_price:
        light, why = "黃", "部分指標轉弱，先留意，不急著動作" if fund == "mixed" else "營收仍成長，但股價明顯弱於大盤，留意是否有公司本身的原因"
    elif fund == "good" and rel is None:
        light, why = "綠", "營收成長，公司營運沒有轉弱跡象；股價和大盤的比較要等歷史資料補齊"
    elif fund == "good":
        light, why = "綠", "營收成長，股價下跌主要跟隨大盤，公司營運沒有轉弱跡象"
    else:
        light, why = "黃", "資料不足，先留意"
    return light, "；".join(parts) + "。" + why + "。"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--holdings", required=True)
    ap.add_argument("--account", required=True)
    ap.add_argument("--prices")
    ap.add_argument("--notes")
    ap.add_argument("--out-holdings", required=True)
    ap.add_argument("--out-prices", required=True)
    ap.add_argument("--no-backfill", action="store_true", help="不補抓歷史，只更新當日行情與營收")
    a = ap.parse_args()
    holdings = json.load(open(a.holdings, encoding="utf-8"))
    acct = json.load(open(a.account, encoding="utf-8"))
    notes = json.load(open(a.notes, encoding="utf-8")) if a.notes else {}
    fx = float(acct["usd_twd"])

    hist = {}
    if a.prices:
        for r in json.load(open(a.prices, encoding="utf-8"))["rows"]:
            hist.setdefault(r["code"], {})[r["date"]] = r["close"]

    tw = [h for h in holdings if h["market"] == "TW"]
    # 歷史不足 100 日的持股補抓一次（新上市的 ETF 本來就沒有那麼長的歷史，補到的就是全部）。
    for h in sorted(tw, key=lambda x: -x["cost"]):
        if a.no_backfill or len(hist.get(h["code"], {})) >= 100:
            continue
        print(f"補抓歷史：{h['code']} {h['name']}…")
        try:
            history(h["code"], h.get("board"), hist.setdefault(h["code"], {}))
        except Exception as e:  # noqa: BLE001
            print(f"⚠️ {h['code']} 歷史失敗：{e}", file=sys.stderr)
    print("當日行情…")
    for code, (d, c) in latest_quotes().items():
        if code in hist:
            hist[code][d] = c
    print("月營收…")
    rev = revenues()

    metrics = {}
    for h in tw:
        s = sorted(hist.get(h["code"], {}).items())[-KEEP:]
        closes = [c for _, c in s]
        m = {"rev": rev.get(h["code"]), "note": notes.get(h["code"])}
        if closes:
            last = closes[-1]
            m.update(date=s[-1][0], close=last, days=len(closes), ma20=ma(closes, 20), ma60=ma(closes, 60),
                     ma120=ma(closes, 120), ret1m=pct(last, closes[-22]) if len(closes) > 21 else None)
            if len(closes) >= 60:  # 歷史太短時，高點與趨勢沒有意義，先不算
                m.update(hi=max(closes), dd=pct(last, max(closes)))
                m["trend"] = ("up" if m["ma60"] and m["ma120"] and last > m["ma60"] > m["ma120"] else
                              "down" if m["ma60"] and m["ma120"] and last < m["ma120"] and m["ma60"] < m["ma120"] else
                              "mixed")
        metrics[h["code"]] = m
    market_dd = (metrics.get("0050") or {}).get("dd")
    if market_dd is None:
        s = sorted(hist.get("0050", {}).items())
        market_dd = pct(s[-1][1], max(c for _, c in s)) if s else None

    rows = []
    for h in holdings:
        m = metrics.get(h["code"], {})
        if h["market"] == "US":
            price, pdate, cur = h.get("price"), h.get("price_date"), "USD"
            value = price * h["shares"] * fx if price else None
            cost = h["cost"] * fx
        else:
            price, pdate, cur = m.get("close"), m.get("date"), "TWD"
            value = price * h["shares"] if price else None
            cost = h["cost"]
        light, reason = judge(h, m, market_dd)
        rv, note = m.get("rev") or {}, m.get("note") or {}
        rows.append({
            "code": h["code"], "name": h["name"], "market": h["market"], "board": h.get("board"), "kind": h["kind"],
            "sector": h.get("sector", ""), "role": h.get("role", ""),
            "shares": h["shares"], "cost": round(h["cost"], 2), "price": price, "price_date": pdate, "currency": cur,
            "value_twd": round(value) if value else None, "cost_twd": round(cost),
            "pl_twd": round(value - cost) if value else None, "pl_pct": r1(pct(value, cost)) if value else None,
            "ma20": r1(m.get("ma20")), "ma60": r1(m.get("ma60")), "ma120": r1(m.get("ma120")),
            "above_ma60": (price > m["ma60"]) if m.get("ma60") and price else None,
            "above_ma120": (price > m["ma120"]) if m.get("ma120") and price else None,
            "trend": m.get("trend"), "ret_1m": r1(m.get("ret1m")), "drawdown": r1(m.get("dd")),
            "history_days": m.get("days"), "market_drawdown": r1(market_dd),
            "rev_month": rv.get("month"), "rev_yoy": r1(rv.get("yoy")), "rev_mom": r1(rv.get("mom")),
            "rev_cum_yoy": r1(rv.get("cum_yoy")), "rev_remark": rv.get("remark") or "",
            "light": light, "reason": reason,
            "news_date": note.get("date", ""), "news": note.get("text", ""), "news_url": note.get("url", ""),
            "news_source": note.get("source", ""), "news_tone": note.get("tone", ""),
        })
    rows.append({"code": "CASH", "name": "台股帳戶現金", "market": "TW", "kind": "cash", "sector": "現金", "role": "現金",
                 "value_twd": round(acct["cash_twd"]), "cost_twd": round(acct["cash_twd"]), "usd_twd": fx,
                 "light": "", "reason": ""})

    own = open(__file__, encoding="utf-8").read()
    stamp = datetime.now(TPE).strftime("%Y-%m-%d %H:%M")
    meta = [{"label": "holdings_report.py", "value": own, "type": "code", "lang": "python"},
            {"label": "更新時間（台北）", "value": stamp},
            {"label": "美元匯率假設", "value": str(fx)},
            {"label": "輸入", "value": "持股清單（私人頁面內）、證交所與櫃買中心公開行情與月營收"}]
    json.dump({"rows": rows, "meta": meta}, open(a.out_holdings, "w", encoding="utf-8"), ensure_ascii=False)
    prow = [{"code": c, "date": d, "close": v} for c, s in sorted(hist.items()) for d, v in sorted(s.items())[-KEEP:]]
    json.dump({"rows": prow, "meta": [{"label": "更新時間（台北）", "value": stamp},
                                      {"label": "來源", "value": "證交所、櫃買中心每日收盤價"}]},
              open(a.out_prices, "w", encoding="utf-8"), ensure_ascii=False)
    print(f"完成：{len(rows)} 筆持股、{len(prow)} 筆價格")


if __name__ == "__main__":
    main()
