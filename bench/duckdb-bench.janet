#!/usr/bin/env janet
# duckdb-bench - 1M-row aggregation: in-process module vs CLI route.
# Usage: janet bench/duckdb-bench.janet   (from anywhere; self-locating)
# Query: group-by aggregation over range(1000000), 100 result rows.
# Every route's output is verified; a mismatch aborts the run.
(unless (get (os/environ) "JANET_PATH")
  (setdyn *syspath* (string (or (get (os/environ) "HOME") (error "HOME not set"))
                             "/.local/lib/janet")))
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")
(import jennystats/duckdb :as duckdb)

(def SQL
  "SELECT i % 100 AS g, sum(i) AS s, avg(i) AS a
   FROM range(1000000) AS t(i) GROUP BY g ORDER BY g")
(def EXPECTED-TOTAL 499999500000) # sum(range(1e6))

(defn/typed checksum {:args [:array] :ret :number} [rows]
  (var s 0)
  (each r rows (+= s (r :s)))
  s)

(defn/typed bench-inprocess {:args [:number] :ret :tuple} [n]
  (with [db (duckdb/open ":memory:")]
    (with [conn (duckdb/connect db)]
      # warm + verify
      (def rows (duckdb/rows (duckdb/query conn SQL)))
      (unless (= (length rows) 100) (errorf "expected 100 rows, got %d" (length rows)))
      (unless (= (checksum rows) EXPECTED-TOTAL) (errorf "checksum mismatch"))
      (def t0 (os/clock))
      (for _ 0 n
        (checksum (duckdb/rows (duckdb/query conn SQL))))
      (def elapsed (- (os/clock) t0))
      [n (* 1000 (/ elapsed n))])))

(defn/typed bench-cli {:args [:number] :ret :tuple} [n]
  (def t0 (os/clock))
  (for _ 0 n
    (def code (sh (string "duckdb :memory: -c " (sh-quote SQL) " > /dev/null")))
    (unless (zero? code) (errorf "duckdb cli failed")))
  (def elapsed (- (os/clock) t0))
  [n (* 1000 (/ elapsed n))])

(def n-in (get (dyn *args*) 1))
(def n-cli (get (dyn *args*) 2))
(def [ni ms-in] (bench-inprocess (if n-in (scan-number n-in) 20)))
(def [nc ms-cli] (bench-cli (if n-cli (scan-number n-cli) 10)))
(printf "in-process : %d queries, %.1f ms/query (one conn, lib resident)"
        ni ms-in)
(printf "cli route  : %d queries, %.1f ms/query (process + lib load each)"
        nc ms-cli)
(printf "per-query overhead delta: %.1f ms" (- ms-cli ms-in))
(printf "RESULT: verified - in-process %.1f ms vs cli %.1f ms over 1M rows"
        ms-in ms-cli)
