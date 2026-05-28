/ yf_demo.q - fetch Yahoo Finance daily prices for a symbol into a table
/ usage (from q):  \l yf_demo.q
/                  t:yf[`AAPL]                  / default 1mo / 1d
/                  t:yf2[`AAPL;"6mo";"1d"]       / explicit range / interval
/ ------------------------------------------------------------------------
/ Fetches over HTTPS via system `curl` rather than .Q.hg, because the local q
/ build has no working TLS (.Q.hg on an https url -> "Protocol not available").
/ curl also lets us send a User-Agent so Yahoo doesn't answer with HTTP 429.

/ -- helpers --------------------------------------------------------------

/ unix epoch seconds -> q date
.yf.d:{1970.01.01+`int$x div 86400}

/ build the chart endpoint url
.yf.url:{[sym;range;interval]
  "https://query1.finance.yahoo.com/v8/finance/chart/",
    string[sym],"?range=",range,"&interval=",interval}

/ HTTPS GET via curl -> response body (char vector)
.yf.get:{[url]
  raze system "curl -s -H \"User-Agent: Mozilla/5.0\" \"",url,"\""}

/ -- fetch ----------------------------------------------------------------

/ core fetch: sym (symbol), range (string), interval (string) -> table
yf2:{[sym;range;interval]
  r:.j.k .yf.get .yf.url[sym;range;interval];        / GET + parse JSON
  c:r`chart;
  if[not 0n~c`error; '`$"yahoo error: ",.j.j c`error];  / null float = no error
  res:first c`result;                                / first (only) result
  ts:res`timestamp;                                  / unix seconds
  q:first res[`indicators]`quote;                    / ohlcv dict of lists
  adj:first res[`indicators]`adjclose;               / adjclose dict
  ([] sym:count[ts]#sym;
      date:.yf.d ts;
      open:`float$q`open;
      high:`float$q`high;
      low:`float$q`low;
      close:`float$q`close;
      adjclose:`float$adj`adjclose;
      volume:`long$q`volume)}

/ convenience wrapper with sensible defaults
yf:{[sym] yf2[sym;"1mo";"1d"]}

/ -- demo -----------------------------------------------------------------
/ uncomment to run on load:
yf[`AAPL]
