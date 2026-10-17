#!/usr/bin/env janet
# duckdb-mixed-bench - 1M-row mixed-type table (text/int/float): in-process
# module vs CLI pushdown route. Identical complex query on both routes
# (join + filter + group-by + having + window rank + order, output capped
# at 25 rows so janet-side materialization stays honest but bounded).
# Usage: janet bench/duckdb-mixed-bench.janet [rows n-module n-cli]
# Defaults: 1M rows, 20 module runs, 10 cli runs. For 100M rows pass
# fewer runs - per-query cost is scan-bound and scales with rows.
(unless (get (os/environ) "JANET_PATH")
  (setdyn *syspath* (string (or (get (os/environ) "HOME") (error "HOME not set"))
                             "/.local/lib/janet")))
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")
(import jennystats/duckdb :as duckdb)

(def args (script-args))
(def ROWS (if-let [a (get args 0)] (scan-number a) 1000000))
(def N-MODULE (if-let [a (get args 1)] (scan-number a) 20))
(def N-CLI (if-let [a (get args 2)] (scan-number a) 10))
(def DB (string "/tmp/duckdb-mixed-bench-" ROWS ".db"))
(def SQL
  "SELECT s.region AS region, s.category AS category,
          count(*) AS n,
          sum(s.qty) AS total_qty,
          sum(s.qty * s.price * (1 - s.discount)) AS revenue,
          avg(s.discount) AS avg_disc,
          max(s.price) AS max_price,
          count(DISTINCT s.customer_id) AS customers,
          rank() OVER (PARTITION BY s.region
                       ORDER BY sum(s.qty * s.price * (1 - s.discount)) DESC) AS rnk
   FROM sales s
   JOIN products p ON p.id = s.id % 200
   WHERE s.qty > 2 AND s.tier = 'vip'
   GROUP BY s.region, s.category
   HAVING count(*) > 1000
   ORDER BY revenue DESC
   LIMIT 25")

(defn/typed build-db {:args [] :ret nil} []
  (printf "building %s (%d rows, mixed types) ..." DB ROWS)
  (with [db (duckdb/open DB)]
    (with [conn (duckdb/connect db)]
      (duckdb/exec conn "CREATE OR REPLACE TABLE products AS
        SELECT i AS id, (100 + i) AS sku, (i * 1.7)::DOUBLE AS base_cost,
               'prod-' || (i % 40) AS pname
        FROM range(200) t(i)")
      (duckdb/exec conn (string/format "CREATE OR REPLACE TABLE sales AS
        SELECT i AS id,
               (i %% %d) AS customer_id,
               ['electronics','clothing','food','toys','books'][1 + i %% 5] AS category,
               ['north','south','east','west'][1 + i %% 4] AS region,
               (1 + i %% 10) AS qty,
               (0.5 + (i %% 997) * 0.13)::DOUBLE AS price,
               ((i * 7) %% 97) / 97.0::DOUBLE AS discount,
               CASE WHEN i %% 3 = 0 THEN 'vip' ELSE 'regular' END AS tier
        FROM range(%d) t(i)" (min ROWS 5000) ROWS))))
  (printf "db ready"))

(defn/typed module-rows {:args [] :ret :array} []
  (with [db (duckdb/open DB)]
    (with [conn (duckdb/connect db)]
      (duckdb/rows (duckdb/query conn SQL)))))

# the realistic module usage: open once, query many - the route the
# in-process design exists for (the symmetric re-open above is the
# conservative comparison that pays db-open per query like the cli).
# Opened AFTER the build step below: a connection opened before the
# tables exist keeps the empty catalog and never sees them.
(var RES-DB nil)
(var RES-CONN nil)
(defn/typed module-resident-rows {:args [] :ret :array} []
  (duckdb/rows (duckdb/query RES-CONN SQL)))

(defn/typed parse-csv {:args [:string] :ret :array} [text]
  (def lines (filter |(not (empty? $)) (string/split "\n" text)))
  (when (empty? lines) (error "duckdb-mixed-bench: empty cli output"))
  (def rows @[])
  # -noheader on the cli side: every line is data
  (each line lines
    (def cols (string/split "," line))
    (when (some |(string/find "\"" $) cols)
      (error "duckdb-mixed-bench: quoted csv fields not expected"))
    (array/push rows cols))
  rows)

(defn/typed cli-rows {:args [] :ret :array} []
  (parse-csv (sh-capture (string "duckdb " DB " -csv -noheader -c " (sh-quote SQL)))))

(defn/typed timed-ms {:args [:function] :ret :tuple} [f]
  (def t0 (os/clock))
  (def out (f))
  [out (* 1000 (- (os/clock) t0))])

(defn/typed bench {:args [:string :function :number] :ret :tuple} [lbl f n]
  (def results @[])
  (def t-warm0 (os/clock))
  (def warm (f))
  (def warm-ms (* 1000 (- (os/clock) t-warm0)))
  (for _ 0 n
    (def [out ms] (timed-ms f))
    (array/push results ms)
    (unless (= (length out) (length warm))
      (errorf "row count drifted: %d vs %d" (length out) (length warm))))
  (sort results)
  (def best (results 0))
  (def avg (/ (reduce + 0 results) (length results)))
  (printf "%-8s: warm %.0f ms | %d runs: min %.0f ms, avg %.0f ms"
          lbl warm-ms n best avg)
  [warm best avg])

# (an aborted run can leave a valid-but-EMPTY db file - duckdb_open
# creates on open - so cache on size, not existence)
(def st (os/stat DB))
(unless (and st (> (st :size) 1000000)) (build-db))
(set RES-DB (duckdb/open DB))
(set RES-CONN (duckdb/connect RES-DB))

(def m (bench "module" module-rows N-MODULE))
(def r (bench "mod-res" module-resident-rows N-MODULE))
(def c (bench "cli" cli-rows N-CLI))
(:close RES-CONN)
(:close RES-DB)

# -- output equivalence between routes ---------------------------------------
(def mrows (m 0))
# parallel float aggregation varies in low mantissa bits run-to-run -
# bitwise deep= is too strict; same tolerance as the cli comparison
(for i 0 (length mrows)
  (def a (mrows i))
  (def b ((r 0) i))
  (unless (and (= (a :region) (b :region)) (= (a :category) (b :category))
               (= (a :n) (b :n)) (= (a :rnk) (b :rnk))
               (<= (math/abs (- (a :revenue) (b :revenue))) 0.01)
               (<= (math/abs (- (a :avg_disc) (b :avg_disc))) 0.000001))
    (errorf "resident rows differ at %d" i)))
(def crows (c 0))
(unless (= (length mrows) (length crows))
  (errorf "route mismatch: %d module rows vs %d cli rows" (length mrows) (length crows)))
(var checked 0)
(for i 0 (length mrows)
  (def mr (mrows i))
  (def cr (crows i))
  (unless (= (string (mr :region)) (cr 0)) (errorf "region mismatch row %d" i))
  (unless (= (string (mr :category)) (cr 1)) (errorf "category mismatch row %d" i))
  (unless (= (string (mr :n)) (cr 2)) (errorf "count mismatch row %d" i))
  (unless (<= (math/abs (- (mr :revenue) (scan-number (cr 4)))) 0.01)
    (errorf "revenue mismatch row %d: %q vs %s" i (mr :revenue) (cr 4)))
  (unless (= (string (mr :rnk)) (cr 8)) (errorf "rank mismatch row %d" i))
  (++ checked))
(printf "verified : %d rows agree across routes (strings/ints exact, floats ≤ 0.01)"
        checked)
(printf "RESULT: module min %.0f ms, resident-conn min %.0f ms, cli min %.0f ms/query - resident vs cli delta %.0f ms"
        (m 1) (r 1) (c 1) (- (c 1) (r 1)))
