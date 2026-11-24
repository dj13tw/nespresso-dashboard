#!/usr/bin/env python3
"""抓取台股情緒相關的公開資料，寫入 fear-greed/tw.json，供 dashboard 的「台股情緒」區塊讀取。

資料來源（皆為證交所、期交所公開資料）：
- 期交所 OpenAPI PutCallRatio：臺指選擇權 Put/Call 比（一次給近 20 個交易日）
- 期交所 OpenAPI 三大法人-區分各期貨契約：外資臺股期貨淨未平倉（只給最新一日，每天累積）
- 證交所 FMTQIK：每日加權指數收盤與漲跌（本月與上月）
- 證交所 BFI82U：外資及陸資買賣超（最新一日，每天累積；另取本月累計）
- 證交所 MI_MARGN：融資金額餘額（最新一日，每天累積）

期交所的資料不允許網頁跨網域讀取，所以由這支程式每天抓一次、存成檔案。
證交所資料網頁可以直接讀，dashboard 會優先即時讀取，這裡的紀錄用來累積歷史與備援。
證交所對短時間大量請求會暫時封鎖，所以只抓最新資料、請求之間間隔數秒；
任何一個來源失敗都不會中斷，會保留舊資料並在 errors 欄位記錄。

用法：python3 fear-greed/update_tw.py   （只用標準函式庫）
"""
import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timedelta, timezone

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tw.json")
TWSE = "https://www.twse.com.tw/rwd/zh"
TAIFEX = "https://openapi.taifex.com.tw/v1"
TPE = timezone(timedelta(hours=8))
KEEP_DAYS = 60  # 每個序列保留的交易日數
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
    s = str(s).replace(",", "").strip()
    return float(s) if s not in ("", "--", "-") else None


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


def taiex():
    this = datetime.now(TPE).date().replace(day=1)
    last = (this - timedelta(days=1)).replace(day=1)
    rows = {}
    for first in (last, this):
        d = get_json(f"{TWSE}/afterTrading/FMTQIK?response=json&date={first:%Y%m%d}", twse=True)
        for r in d.get("data", []) if d.get("stat") == "OK" else []:
            rows[roc_to_iso(r[0])] = {"close": num(r[4]), "change": num(r[5])}
    return rows


def foreign_row(d):
    for r in d.get("data", []):
        if r[0].startswith("外資及陸資"):
            return num(r[3])  # 買賣差額（元）
    return None


def foreign_day():
    d = get_json(f"{TWSE}/fund/BFI82U?response=json", twse=True)
    return {iso8(d["date"]): foreign_row(d)} if d.get("stat") == "OK" else {}


def foreign_month():
    d = get_json(f"{TWSE}/fund/BFI82U?response=json&type=month", twse=True)
    return {"through": iso8(d["date"]), "value": foreign_row(d)} if d.get("stat") == "OK" else None


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
    tx = safe("證交所 加權指數", taiex)
    fd = safe("證交所 外資買賣超", foreign_day)
    fm = safe("證交所 外資本月累計", foreign_month)
    mg = safe("證交所 融資餘額", margin)

    out = {
        "updated": datetime.now(TPE).strftime("%Y-%m-%d %H:%M"),
        "taiex": merged("taiex", tx),                      # 加權指數收盤、漲跌點數
        "foreign_flow": merged("foreign_flow", fd),        # 外資現貨買賣超（元）
        "foreign_flow_month": fm or old.get("foreign_flow_month"),
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
    for k in ("taiex", "foreign_flow", "margin", "put_call", "foreign_futures_oi"):
        print(f"  {k}: {len(out[k])} 日")
    if errors:
        print("  失敗：" + "；".join(errors))


if __name__ == "__main__":
    main()
