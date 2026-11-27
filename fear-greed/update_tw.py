#!/usr/bin/env python3
"""抓取台股情緒相關的公開資料，寫入 fear-greed/tw.json，供 dashboard 的「台股情緒」區塊讀取。

資料來源（皆為證交所、期交所公開資料）：
- 期交所 OpenAPI PutCallRatio：臺指選擇權 Put/Call 比（一次給近 20 個交易日）
- 期交所 OpenAPI 三大法人-區分各期貨契約：外資臺股期貨淨未平倉（只給最新一日，每天累積）
- 證交所 FMTQIK：每日加權指數收盤與漲跌（本月與上月）
- 證交所 BFI82U：外資及陸資買賣超（最新一日，每天累積；另取本月累計）
- 證交所 MI_MARGN：融資金額餘額（最新一日，每天累積）
- FinMind 開放資料（備援：證交所 STOCK_DAY）：台積電（2330）每日收盤
- FRED（美國聖路易聯準銀行）：S&P 500、Nasdaq-100 每日收盤，用來和 CNN 恐懼貪婪指數對照

期交所的資料不允許網頁跨網域讀取，所以由這支程式每天抓一次、存成檔案。
證交所資料網頁可以直接讀，dashboard 會優先即時讀取，這裡的紀錄用來累積歷史與備援。
證交所對短時間大量請求會暫時封鎖，所以只抓最新資料、請求之間間隔數秒；
任何一個來源失敗都不會中斷，會保留舊資料並在 errors 欄位記錄。

用法：python3 fear-greed/update_tw.py   （只用標準函式庫）
"""
import json
import os
import re
import sys
import time
import urllib.request
from datetime import datetime, timedelta, timezone

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tw.json")
TWSE = "https://www.twse.com.tw/rwd/zh"
TAIFEX = "https://openapi.taifex.com.tw/v1"
TPE = timezone(timedelta(hours=8))
KEEP_DAYS = 130  # 每個序列保留的交易日數（約 6 個月）
DELAY = 5       # 證交所請求間隔（秒）

_last_twse = [0.0]
errors = []


def get_json(url, twse=False, tries=3):
    for i in range(tries):
        if twse:
            wait = DELAY - (time.time() - _last_twse[0])
            if wait > 0:
                time.sleep(wait)
        try:
            req = urllib.request.Request(url, headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode("utf-8-sig"))
        except Exception as e:  # noqa: BLE001
            print(f"  重試 {i + 1}/{tries}：{url}（{e}）", file=sys.stderr)
            time.sleep(8 * (i + 1))
        finally:
            if twse:
                _last_twse[0] = time.time()
    raise RuntimeError(f"無法取得 {url}")


def safe(label, fn):
    try:
        return fn()
    except Exception as e:  # noqa: BLE001
        errors.append(f"{label}：{e}")
        print(f"⚠️ {label} 失敗：{e}", file=sys.stderr)
        return None


def num(s):
    # 證交所數字可能帶千分位、正負號或註記字元（例如除權息日的 "X0.00"）
    m = re.search(r"-?\d+(?:\.\d+)?", str(s).replace(",", ""))
    return float(m.group()) if m else None


def iso8(s):  # "20261123" -> "2026-11-23"
    return f"{s[:4]}-{s[4:6]}-{s[6:8]}"


def roc_to_iso(s):  # "115/11/02" -> "2026-11-02"
    y, m, d = s.split("/")
    return f"{int(y) + 1911:04d}-{int(m):02d}-{int(d):02d}"


def put_call():
    return {iso8(r["Date"]): {"vol": num(r["PutCallVolumeRatio%"]), "oi": num(r["PutCallOIRatio%"])}
            for r in get_json(f"{TAIFEX}/PutCallRatio")}


def futures_oi():
    out = {}
    for r in get_json(f"{TAIFEX}/MarketDataOfMajorInstitutionalTradersDetailsOfFuturesContractsBytheDate"):
        if r.get("ContractCode") == "臺股期貨" and str(r.get("Item", "")).startswith("外資"):
            out[iso8(r["Date"])] = num(r["OpenInterest(Net)"])
    return out


def month_starts(n):
    """最近 n 個月的每月 1 日（由舊到新）。"""
    firsts = [datetime.now(TPE).date().replace(day=1)]
    for _ in range(n - 1):
        firsts.insert(0, (firsts[0] - timedelta(days=1)).replace(day=1))
    return firsts


def taiex(months):
    rows = {}
    for first in month_starts(months):
        d = get_json(f"{TWSE}/afterTrading/FMTQIK?response=json&date={first:%Y%m%d}", twse=True)
        for r in d.get("data", []) if d.get("stat") == "OK" else []:
            rows[roc_to_iso(r[0])] = {"close": num(r[4]), "change": num(r[5])}
    return rows


def tsmc(months):
    """台積電每日收盤。先用 FinMind 開放資料（一個請求）；失敗才向證交所逐月查詢，後者容易被封鎖。"""
    start = month_starts(months)[0]
    try:
        d = get_json(f"https://api.finmindtrade.com/api/v4/data?dataset=TaiwanStockPrice&data_id=2330"
                     f"&start_date={start:%Y-%m-%d}")
        rows = {r["date"]: {"close": float(r["close"]), "change": float(r["spread"])}
                for r in d.get("data") or [] if r.get("close")}
        if rows:
            return rows
    except Exception as e:  # noqa: BLE001
        print(f"  FinMind 台積電失敗：{e}", file=sys.stderr)
    rows = {}
    for first in month_starts(months):
        d = get_json(f"{TWSE}/afterTrading/STOCK_DAY?response=json&date={first:%Y%m%d}&stockNo=2330", twse=True)
        for r in d.get("data", []) if d.get("stat") == "OK" else []:
            rows[roc_to_iso(r[0])] = {"close": num(r[6]), "change": num(r[7])}
    return rows


def fred(series_id):
    start = (datetime.now(TPE).date() - timedelta(days=200)).isoformat()
    url = f"https://fred.stlouisfed.org/graph/fredgraph.csv?id={series_id}&cosd={start}"
    for i in range(3):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                lines = r.read().decode("utf-8").strip().splitlines()[1:]
            out = {}
            for line in lines:
                day, val = line.split(",")
                if val not in ("", "."):
                    out[day] = float(val)
            return out
        except Exception as e:  # noqa: BLE001
            print(f"  重試 {i + 1}/3：{url}（{e}）", file=sys.stderr)
            time.sleep(8 * (i + 1))
    raise RuntimeError(f"無法取得 {url}")


def foreign_row(d):
    for r in d.get("data", []):
        if r[0].startswith("外資及陸資"):
            return num(r[3])  # 買賣差額（元）
    return None


def foreign_day():
    d = get_json(f"{TWSE}/fund/BFI82U?response=json", twse=True)
    return {iso8(d["date"]): foreign_row(d)} if d.get("stat") == "OK" else {}


def margin():
    d = get_json(f"{TWSE}/marginTrading/MI_MARGN?response=json&selectType=MS", twse=True)
    if d.get("stat") != "OK" or not d.get("tables"):
        return {}
    for r in d["tables"][0]["data"]:
        if r[0].startswith("融資金額"):
            # 同時記錄前日餘額，第一天就能算出單日變化
            return {"_prev": num(r[4]), iso8(d["date"]): num(r[5])}
    return {}


def main():
    old = {}
    if os.path.exists(OUT):
        with open(OUT, encoding="utf-8") as f:
            old = json.load(f)

    def merged(key, new):
        m = dict(old.get(key, {}))
        m.update({k: v for k, v in (new or {}).items() if v is not None and not k.startswith("_")})
        return dict(sorted(m.items())[-KEEP_DAYS:])

    pc = safe("期交所 Put/Call 比", put_call)
    oi = safe("期交所 外資期貨未平倉", futures_oi)
    # 第一次執行時補足約 6 個月；之後只抓本月與上月
    months = lambda key: 2 if len(old.get(key, {})) >= 100 else 6  # noqa: E731
    tx = safe("證交所 加權指數", lambda: taiex(months("taiex")))
    ts = safe("台積電", lambda: tsmc(months("tsmc")))
    fd = safe("證交所 外資買賣超", foreign_day)
    mg = safe("證交所 融資餘額", margin)
    sp = safe("FRED S&P 500", lambda: fred("SP500"))
    nd = safe("FRED Nasdaq-100", lambda: fred("NASDAQ100"))

    out = {
        "updated": datetime.now(TPE).strftime("%Y-%m-%d %H:%M"),
        "taiex": merged("taiex", tx),                      # 加權指數收盤、漲跌點數
        "foreign_flow": merged("foreign_flow", fd),        # 外資現貨買賣超（元）
        "tsmc": merged("tsmc", ts),                        # 台積電收盤、漲跌（元）
        "sp500": merged("sp500", sp),                      # S&P 500 收盤（美東日期）
        "ndx": merged("ndx", nd),                          # Nasdaq-100 收盤（美東日期）
        "margin": merged("margin", mg),                    # 融資餘額（仟元）
        "margin_prev": (mg or {}).get("_prev", old.get("margin_prev")),
        "put_call": merged("put_call", pc),                # 臺指選擇權 P/C 比（%）
        "foreign_futures_oi": merged("foreign_futures_oi", oi),  # 外資臺股期貨淨未平倉（口）
        "errors": errors,
    }
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"完成：{OUT}")
    for k in ("taiex", "tsmc", "sp500", "ndx", "foreign_flow", "margin", "put_call", "foreign_futures_oi"):
        print(f"  {k}: {len(out[k])} 日")
    if errors:
        print("  失敗：" + "；".join(errors))


if __name__ == "__main__":
    main()
