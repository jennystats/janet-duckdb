# smoke-duckdb  -  conformance: exact-table queries, type round-trips,
# prepared statements, error paths. Requires libduckdb (SKIP if absent  -
# run_tests.sh decides SKIP vs run; this file only runs when the lib exists).
(import janet-duckdb :as duckdb)

(defn assert-eq [a b msg]
  (unless (deep= a b) (errorf "FAIL %s: %q != %q" msg a b)))

(defn assert-raises [f msg-match]
  (var caught nil)
  (try (f) ([e] (set caught e)))
  (unless (and caught (string/find msg-match caught))
    (errorf "FAIL expected error matching %q, got %q" msg-match caught)))

# -- fixture: build the conformance db in :memory: --------------------------
(def db (duckdb/open ":memory:"))
(def conn (duckdb/connect db))

(duckdb/exec conn "CREATE TYPE mood AS ENUM ('happy', 'sad')")
(assert-eq 3
  (duckdb/exec conn "CREATE TABLE people (id INTEGER, name VARCHAR, score DOUBLE,
                    born DATE, seen TIMESTAMP, tags VARCHAR[], props STRUCT(k VARCHAR, n INTEGER, ok BOOLEAN),
                    feel mood, amt DECIMAL(4,2));
                    INSERT INTO people VALUES
                      (1, 'alice', 1.5, DATE '1990-04-01', TIMESTAMP '2025-06-15 10:30:00',
                       ['x', 'y'], {'k': 'a', 'n': 2, 'ok': true}, 'happy', 12.34),
                      (2, 'bob', NULL, DATE '1985-12-31', TIMESTAMP '2024-01-01 00:00:00',
                       NULL, {'k': 'b', 'n': 9, 'ok': false}, 'sad', 0.05),
                      (3, 'longer-than-twelve-chars', -2.5, DATE '2000-02-29',
                       TIMESTAMP '2026-10-02 12:00:00', ['a-long-tag'], {'k': 'c', 'n': 4, 'ok': NULL},
                       'happy', 99.99)")
  "exec returns rows changed")

# -- exact table read: struct rows ------------------------------------------
(def result (duckdb/query conn "SELECT id, name, score FROM people ORDER BY id"))
(assert-eq (duckdb/rows result)
  @[{:id 1 :name "alice" :score 1.5}
    {:id 2 :name "bob" :score nil}
    {:id 3 :name "longer-than-twelve-chars" :score -2.5}]
  "exact struct rows (incl NULL)")
(assert-eq (duckdb/rows result false :tuple)
  @[[1 "alice" 1.5] [2 "bob" nil] [3 "longer-than-twelve-chars" -2.5]]
  "exact tuple rows, no keywordize")
(assert-eq (duckdb/first-row result) {:id 1 :name "alice" :score 1.5} "first-row")
(duckdb/rows result) # second read of same result must work
(:close result)

# closed access must raise
(assert-raises (fn [] (duckdb/rows result)) "already closed")
(assert-raises (fn [] (:close result) (duckdb/rows result)) "already closed")

# -- types -------------------------------------------------------------------
(def types-row
  (duckdb/first-row
    (duckdb/query conn "SELECT born, seen, tags, props, feel, amt FROM people WHERE id = 1")))
(assert-eq (types-row :born) {:year 1990 :month 3 :month-day 0} "date -> janet date struct (0-based)")
(assert-eq (types-row :props) {:k "a" :n 2 :ok true} "struct -> struct (bool field true)")
(assert-eq (types-row :tags) @["x" "y"] "list -> array")
(assert-eq (types-row :feel) "happy" "enum -> string")
(assert-eq (types-row :amt) 12.34 "decimal -> double")
(def ts-row
  (duckdb/first-row
    (duckdb/query conn "SELECT seen, epoch_us(seen) AS us FROM people WHERE id = 1")))
(assert-eq (ts-row :seen) (ts-row :us) "timestamp = epoch micros (self-consistent)")
(assert (number? (ts-row :seen)) "timestamp is a number")

# NULL propagation through complex types
(def null-row
  (duckdb/first-row
    (duckdb/query conn "SELECT tags, props FROM people WHERE id = 2")))
(assert-eq (null-row :tags) nil "NULL list -> nil")
(assert-eq (null-row :props) {:k "b" :n 9 :ok false} "struct bool field false persists (not NULL)")

# -- prepared statements: positional + named + round-trip --------------------
(defn roundtrip [params row-key expected]
  (with [stmt (duckdb/prepare conn "SELECT ?::INTEGER AS i, ?::VARCHAR AS s, ?::DOUBLE AS f,
                                   ?::DATE AS d, ?::TIMESTAMP AS t, ?::VARCHAR[] AS l,
                                   ?::STRUCT(k VARCHAR, n INTEGER) AS st")]
    (with [res (duckdb/execute stmt params)]
      (assert-eq ((duckdb/first-row res) row-key) expected row-key))))

(roundtrip [42 "hello" 1.25 {:year 2025 :month 0 :month-day 1} 1700000000000000
             @["a" "b"] {:k "z" :n 5}]
  :i 42)
(roundtrip [42 "hello" 1.25 {:year 2025 :month 0 :month-day 1} 1700000000000000
             @["a" "b"] {:k "z" :n 5}]
  :s "hello")
(roundtrip [42 "hello" 1.25 {:year 2025 :month 0 :month-day 1} 1700000000000000
             @["a" "b"] {:k "z" :n 5}]
  :f 1.25)
(roundtrip [42 "hello" 1.25 {:year 2025 :month 0 :month-day 1} 1700000000000000
             @["a" "b"] {:k "z" :n 5}]
  :d {:year 2025 :month 0 :month-day 1})
(roundtrip [42 "hello" 1.25 {:year 2025 :month 0 :month-day 1} 1700000000000000
             @["a" "b"] {:k "z" :n 5}]
  :t 1700000000000000)
(roundtrip [42 "hello" 1.25 {:year 2025 :month 0 :month-day 1} 1700000000000000
             @["a" "b"] {:k "z" :n 5}]
  :l @["a" "b"])
(roundtrip [42 "hello" 1.25 {:year 2025 :month 0 :month-day 1} 1700000000000000
             @["a" "b"] {:k "z" :n 5}]
  :st {:k "z" :n 5})

(with [stmt (duckdb/prepare conn "SELECT $1::INTEGER AS x, $2::VARCHAR AS y")]
  (with [res (duckdb/execute stmt {:1 7 :2 "seven"})]
    (assert-eq (duckdb/first-row res) {:x 7 :y "seven"} "named params ($1 style)")))

(with [stmt (duckdb/prepare conn "SELECT ?::INTEGER AS i")]
  (assert-eq (stmt :param-count) 1 "param count")
  (assert-eq (stmt :param-names) [:1] "param names"))

# -- column-major (xgboost feed) ----------------------------------------------
(def cols (duckdb/columns (duckdb/query conn "SELECT id, score FROM people ORDER BY id")))
(assert-eq (cols :columns) @[@[1 2 3] @[1.5 nil -2.5]] "column-major arrays")
(assert-eq (cols :column-names) ["id" "score"] "column names")
(assert-eq (cols :column-types) [:int :double] "column types")

# -- query with params sugar ---------------------------------------------------
(assert-eq (duckdb/rows (duckdb/query conn "SELECT name FROM people WHERE id > ? ORDER BY id" [1]))
           @[{:name "bob"} {:name "longer-than-twelve-chars"}] "query+positional sugar")
(assert-eq (duckdb/rows (duckdb/query conn "SELECT name FROM people WHERE id = $1" {"1" 2}))
           @[{:name "bob"}] "query+named sugar")

# -- error paths ---------------------------------------------------------------
(assert-raises (fn [] (duckdb/query conn "SELEC * FROM people")) "syntax")
(assert-raises (fn [] (duckdb/query conn "SELECT * FROM missing_table")) "missing_table")
(assert-raises (fn [] (duckdb/open "/nonexistent/dir/x.db")) "IO Error")
(assert-raises (fn [] (with [stmt (duckdb/prepare conn "SELECT ?::INTEGER")] (duckdb/execute stmt [1 2])))
               "out of range")
(assert-raises (fn [] (with [stmt (duckdb/prepare conn "SELECT ?")] (duckdb/execute stmt [1])))
               "cast in SQL")

# -- multi-query on one open db (the point of in-process) ----------------------
(assert-eq 1 (duckdb/exec conn "DELETE FROM people WHERE id = 2") "exec delete")
(assert-eq (duckdb/rows (duckdb/query conn "SELECT count(*) AS n FROM people"))
           @[{:n 2}] "count after delete")
(assert-eq (duckdb/rows (duckdb/query conn "SELECT count(*) AS n FROM people WHERE feel = 'happy'"))
           @[{:n 2}] "second query same conn")

# -- file db round-trip ----------------------------------------------------------
(def dbfile "/tmp/duckdb-smoke-file.db")
(when (os/stat dbfile) (os/rm dbfile))
(with [fdb (duckdb/open dbfile)]
  (with [fconn (duckdb/connect fdb)]
    (duckdb/exec fconn "CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (5)")))
(with [fdb (duckdb/open dbfile)]
  (with [fconn (duckdb/connect fdb)]
    (assert-eq (duckdb/rows (duckdb/query fconn "SELECT x FROM t"))
               @[{:x 5}] "file db persists")))
(when (os/stat dbfile) (os/rm dbfile))

# -- C-to-C handoff: duckdb/pack-columns-f32 + xgboost parity ----------------------
(import janet-num)
(duckdb/exec conn "CREATE TABLE cc AS
  SELECT (i * 1.5)::DOUBLE AS a, (i * 2.25 + 0.5)::DOUBLE AS b,
         CASE WHEN i % 7 = 3 THEN NULL ELSE (i * -0.75)::DOUBLE END AS c
  FROM range(10000) t2(i)")
(def cc3 (duckdb/pack-columns-f32 conn "SELECT a, b, c FROM cc ORDER BY a"))
(assert-eq [(cc3 :nrow) (cc3 :ncol)] [10000 3] "cc packed shape")
(def cc-slice (janet-num/packed-slice-f32 cc3 12))
(assert (nan? (cc-slice 11)) "C-to-C NULL -> NaN (row 3 col c)")
(assert (not (nan? (cc-slice 0))) "C-to-C non-NULL stays a value")
(def cc-arrs ((duckdb/columns (duckdb/query conn "SELECT a, b FROM cc ORDER BY a")) :columns))
(def cc-jj (janet-num/pack-columns-f32 cc-arrs))
(def cc-cc2 (duckdb/pack-columns-f32 conn "SELECT a, b FROM cc ORDER BY a"))
(assert-eq (string (cc-cc2 :ptr)) (string (cc-jj :ptr))
  "C-to-C packed == janet-arrays packed (byte-identical)")
(assert-raises (fn [] (duckdb/pack-columns-f32 conn "SELECT a, b, c::VARCHAR FROM cc")) "DOUBLE")

# -- bind-side matrix cells (positional round-trips) --------------------------
(defn roundtrip-row [sql params expected]
  (assert-eq (duckdb/first-row (duckdb/query conn sql params)) expected sql))

(roundtrip-row "SELECT ?::UTINYINT AS u8, ?::USMALLINT AS u16,
                 ?::UINTEGER AS u32, ?::UBIGINT AS u64" [1 1000 1000000 9007199254740992]
  {:u8 1 :u16 1000 :u32 1000000 :u64 9007199254740992})
(roundtrip-row "SELECT ?::FLOAT AS f" [1.5] {:f 1.5})
(roundtrip-row "SELECT ?::BLOB AS b" ["ab"] {:b [97 98]})
(roundtrip-row "SELECT ?::TIME AS t" [{:hours 10 :minutes 30 :seconds 0 :micros 0}]
  {:t {:hours 10 :minutes 30 :seconds 0 :micros 0}})
# time_tz bind lane: bound local time + offset reads back UTC-normalised
(roundtrip-row "SELECT ?::TIME WITH TIME ZONE AS t"
  [{:hours 10 :minutes 30 :seconds 0 :micros 0 :timezone-offset 3600}]
  {:t {:hours 9 :minutes 30 :seconds 0 :micros 0 :session-timezone-offset 3600}})
# TIME WITH TIME ZONE full round-trip: '12:34:56+02' reads back as a struct
# with the UTC-normalised time and the session offset 2
(duckdb/exec conn "CREATE TABLE tz (t TIME WITH TIME ZONE)")
(duckdb/exec conn "INSERT INTO tz VALUES (TIMETZ '12:34:56+02')")
(assert-eq (duckdb/first-row (duckdb/query conn "SELECT t FROM tz"))
  {:t {:hours 10 :minutes 34 :seconds 56 :micros 0 :session-timezone-offset 7200}}
  "time_tz round-trip (12:34:56+02 -> 10:34:56 UTC, offset 7200s)")
(roundtrip-row "SELECT ?::INTERVAL AS i" [{:months 1 :days 2 :micros 3000000}]
  {:i {:months 1 :days 2 :micros 3000000}})
(roundtrip-row "SELECT ?::MAP(VARCHAR, INTEGER) AS m" [{"a" 1 "b" 2}]
  {:m @{"a" 1 "b" 2}})
(roundtrip-row "SELECT ?::INTEGER[3] AS a" [@[1 2 3]] {:a [1 2 3]})
(roundtrip-row "SELECT ?::UNION(a INTEGER, b VARCHAR) AS u" [[:a 42]] {:u [:a 42]})
(roundtrip-row "SELECT ?::TIMESTAMP_S AS t" [1700000000] {:t 1700000000})
(roundtrip-row "SELECT ?::TIMESTAMP_MS AS t" [1700000000000] {:t 1700000000000})
(roundtrip-row "SELECT ?::TIMESTAMP WITH TIME ZONE AS t" [1700000000000000]
  {:t 1700000000000000})
# TIMESTAMP_NS beyond the ±2^53 plain-double band: bind as an s64-wrapped value
# (int/s64 of the decimal string); the read comes back s64-wrapped too
(roundtrip-row "SELECT ?::TIMESTAMP_NS AS t" [(int/s64 "1700000000000000000")]
  {:t (int/s64 "1700000000000000000")})
# DECIMAL params are a documented bind cut: duckdb reports the parameter
# without a usable logical type; the read lane is pinned by the fixture table
(assert-raises (fn [] (duckdb/query conn "SELECT ?::DECIMAL(4,2) AS d" [12.34]))
               "unsupported complex type for binding")

# -- B1: time_tz mod-24h wrap --------------------------------------------------
# UTC micros >= 24h or exactly 0 must wrap to [0, 24h), never hours 24/28
(duckdb/exec conn "CREATE TABLE tz2 (t TIME WITH TIME ZONE)")
(duckdb/exec conn "INSERT INTO tz2 VALUES (TIMETZ '00:00:00+00'),
  (TIMETZ '23:00:00-05'), (TIMETZ '12:00:00-12')")
(def tz2 (duckdb/rows (duckdb/query conn "SELECT t FROM tz2")))
(assert-eq (tz2 0)
  {:t {:hours 0 :minutes 0 :seconds 0 :micros 0 :session-timezone-offset 0}}
  "time_tz 00:00:00+00 -> hours 0 (not 24)")
(assert-eq (tz2 1)
  {:t {:hours 4 :minutes 0 :seconds 0 :micros 0 :session-timezone-offset -18000}}
  "time_tz 23:00:00-05 -> UTC 04:00 (not 28)")
(assert-eq (tz2 2)
  {:t {:hours 0 :minutes 0 :seconds 0 :micros 0 :session-timezone-offset -43200}}
  "time_tz 12:00:00-12 -> hours 0 (not 24)")

# -- planned cuts: error phrasing on read --------------------------------------
(duckdb/exec conn "CREATE TABLE cutb AS SELECT CAST('101' AS BIT) AS b")
(assert-raises (fn [] (duckdb/rows (duckdb/query conn "SELECT b FROM cutb"))) "type not supported")
(duckdb/exec conn "CREATE TABLE cutn AS SELECT CAST(123456789012345678901234567890 AS BIGNUM) AS n")
(assert-raises (fn [] (duckdb/rows (duckdb/query conn "SELECT n FROM cutn"))) "type not supported")
(duckdb/exec conn "CREATE TABLE cutt AS SELECT CAST('10:30:00' AS TIME_NS) AS t")
(assert-raises (fn [] (duckdb/rows (duckdb/query conn "SELECT t FROM cutt"))) "unknown type id")

# -- describe-columns: plain + logical shapes ----------------------------------
(duckdb/exec conn "CREATE TABLE dtab (i INTEGER, l VARCHAR[],
  s STRUCT(k VARCHAR, n INTEGER), e mood, d DECIMAL(4,2),
  m MAP(VARCHAR, INTEGER), un UNION(a INTEGER, b VARCHAR), ts TIMESTAMP)")
(def dres (duckdb/query conn "SELECT * FROM dtab"))
(assert-eq (duckdb/describe-columns dres false)
  {:column-count 8
   :column-names (tuple "i" "l" "s" "e" "d" "m" "un" "ts")
   :column-types (tuple :int :list :struct :enum :decimal :map :union :timestamp)}
  "describe-columns plain types")
(assert-eq (duckdb/describe-columns dres true)
  {:column-count 8
   :column-names (tuple "i" "l" "s" "e" "d" "m" "un" "ts")
   :column-types (tuple :int
     [:list {:child-type :varchar}]
     [:struct {:keys (tuple :k :n) :key-types (tuple :varchar :int)}]
     [:enum {:dict {0 "happy" 1 "sad"} :internal-type-key :utinyint}]
     [:decimal {:internal-type-key :smallint :scale 2}]
     [:map {:key-type :varchar :val-type :int}]
     [:union {:tag-keys (tuple :a :b) :tag-types (tuple :int :varchar)}]
     :timestamp)}
  "describe-columns logical shapes")
(:close dres)

# -- columns edge shapes -------------------------------------------------------
(duckdb/exec conn "CREATE TABLE emptyt (x INTEGER)")
(assert-eq (duckdb/columns (duckdb/query conn "SELECT x FROM emptyt"))
  {:column-count 1 :column-names (tuple "x") :column-types (tuple :int)
   :columns @[@[]] :row-count 0}
  "empty scan: column-major shape with 0-length arrays")
(assert-raises (fn [] (duckdb/rows (duckdb/query conn "SELECT 1 AS x") true :nonsense))
               "coll-type must be :struct or :tuple")

# -- open with config map ------------------------------------------------------
(assert-raises (fn [] (duckdb/open ":memory:" {"access_mode" "READ_ONLY"}))
               "read-only mode")
(def rofile "/tmp/duckdb-smoke-ro.db")
(when (os/stat rofile) (os/rm rofile))
(with [seed (duckdb/open rofile)]
  (with [seedc (duckdb/connect seed)]
    (duckdb/exec seedc "CREATE TABLE t (x INTEGER)")))
(with [rodb (duckdb/open rofile {"access_mode" "READ_ONLY"})]
  (with [roconn (duckdb/connect rodb)]
    (assert-raises (fn [] (duckdb/exec roconn "INSERT INTO t VALUES (1)"))
                   "read-only mode")
    (assert-eq (duckdb/rows (duckdb/query roconn "SELECT x FROM t")) @[] "RO read ok")))
(when (os/stat rofile) (os/rm rofile))
(with [ml (duckdb/open ":memory:" {"memory_limit" "128MB"})]
  (with [mlc (duckdb/connect ml)]
    (assert-eq (duckdb/first-row (duckdb/query mlc "SELECT 41 + 1 AS v")) {:v 42}
               "valid config opens and queries")))

# -- s64 band: bigint exact, hugeint double, uuid raw pair ---------------------
(duckdb/exec conn "CREATE TABLE band (b BIGINT, h HUGEINT)")
(duckdb/exec conn "INSERT INTO band VALUES (9007199254740993, 9007199254740993),
  (-9007199254740993, 10000000000000000000)")
(def brows (duckdb/rows (duckdb/query conn "SELECT b, h FROM band")))
# BIGINT reads run through janet-from-int64: exact inside the s64 range,
# s64-wrapped beyond the ±2^53 double band
(assert-eq ((brows 0) :b) (int/s64 "9007199254740993") "bigint 2^53+1 exact, s64-wrapped")
(assert-eq ((brows 1) :b) (int/s64 "-9007199254740993") "bigint -2^53-1 exact")
# HUGEINT reads cast through duckdb's to_double: the precision cliff is the
# documented boundary - 2^53+1 lands on the double 2^53
(assert-eq ((brows 0) :h) 9007199254740992 "hugeint 2^53+1 -> double 2^53 (cliff)")
(assert-eq ((brows 1) :h) 1e19 "hugeint 1e19 as double")
# UUID reads keep the raw 16-byte hugeint pair (wrapped ints, no conversion);
# duckdb stores the string form with the top bit flipped
(def urow (duckdb/first-row
            (duckdb/query conn "SELECT uuid '00000000-0000-0000-0000-000000000001' AS u,
                                        uuid '00000000-0000-0000-0000-000000000002' AS v")))
(assert-eq (urow :u) [(int/u64 "1") (int/s64 "-9223372036854775808")] "uuid raw pair")
(assert (not (deep= (urow :u) (urow :v))) "distinct uuids distinct pairs")

# -- pack-columns-f32: zero-row result -----------------------------------------
(duckdb/exec conn "CREATE TABLE ccz (a DOUBLE, b DOUBLE)")
(def pz (duckdb/pack-columns-f32 conn "SELECT a, b FROM ccz"))
(assert-eq [(pz :nrow) (pz :ncol) (pz :bytes)] [0 2 0] "zero-row packed, no error")
(assert-eq (pz :column-names) (tuple "a" "b") "zero-row keeps column names")

# -- D1: import-time guard ordering (subprocess probe) ------------------------
# A bad $DUCKDB_LIB must surface the actionable message naming the installer,
# not the raw dlopen error: the load probe runs before ffi/context
(def d1-out "/tmp/duckdb-smoke-d1.txt")
(os/execute ["/bin/sh" "-c" (string
  "DUCKDB_LIB=/tmp/nonexistent-d1/libduckdb.so"
  " JANET_PATH=" (or (get (os/environ) "JANET_PATH") "modules:tests/lib")
  " janet -e '(def [_ e] (protect (import janet-duckdb :as duckdb))) (print e)' > " d1-out " 2>&1")])
(def d1-msg (string/trim (string (slurp d1-out))))
(assert (string/find "install-duckdb.sh" d1-msg)
        (string "D1: guard must name the installer, got: " d1-msg))
(when (os/stat d1-out) (os/rm d1-out))

# -- N1-N3: bind taxonomy ------------------------------------------------------
# N1: struct binds accept string keys (json decode shape); missing fields raise
(roundtrip-row "SELECT ?::STRUCT(k VARCHAR, n INTEGER) AS st" [{"k" "a" "n" 2}]
  {:st {:k "a" :n 2}})
(assert-raises (fn [] (duckdb/query conn "SELECT ?::STRUCT(k VARCHAR, n INTEGER) AS st" [{:k "a"}]))
                "struct field :n missing")
# N2: params-shape guard message fires (was %T, a format bug)
(assert-raises (fn [] (duckdb/query conn "SELECT ?::INTEGER AS i" "not-params"))
                "params must be tuple/array")
# N3: integer out-of-range binds raise with the band, never wrap silently
(assert-raises (fn [] (duckdb/query conn "SELECT ?::UTINYINT AS u" [300])) "out of range")
(assert-raises (fn [] (duckdb/query conn "SELECT ?::TINYINT AS t" [128])) "out of range")
# UBIGINT: plain double beyond the 2^53 band raises with the band message;
# int/u64 wrappers carry exact values (read lane stays in-band, compare in SQL)
(assert-raises (fn [] (duckdb/query conn "SELECT ?::UBIGINT AS u" [18000000000000000000]))
                "out of range")
(roundtrip-row "SELECT (?::UBIGINT = 18000000000000000000)::BOOLEAN AS eq"
  [(int/u64 "18000000000000000000")] {:eq true})
# DATE partial struct raises naming the missing field
(assert-raises (fn [] (duckdb/query conn "SELECT ?::DATE AS d" [{:year 1990 :month 3}]))
                "missing :month-day")
# MAP keyword keys stringify (named-params path parity)
(roundtrip-row "SELECT ?::MAP(VARCHAR, INTEGER) AS m" [{:k1 10}] {:m @{"k1" 10}})

# -- B1: a present struct field binds, false included --------------------------
(roundtrip-row "SELECT ?::STRUCT(k BOOLEAN) AS v" [{:k false}] {:v {:k false}})
(roundtrip-row "SELECT ?::STRUCT(a STRUCT(b STRUCT(c BOOLEAN))) AS v"
  [{:a {:b {:c false}}}] {:v {:a {:b {:c false}}}})
(roundtrip-row "SELECT ?::STRUCT(k BOOLEAN)[] AS l" [[{:k false}]] {:l @[{:k false}]})
(with [nstmt (duckdb/prepare conn "SELECT $p::STRUCT(k BOOLEAN) AS v")]
  (with [nres (duckdb/execute nstmt {:p {:k false}})]
    (assert-eq (duckdb/first-row nres) {:v {:k false}} "B1 named-params false field")))
(roundtrip-row "SELECT ?::STRUCT(k BOOLEAN) AS v" [@{:k false}] {:v {:k false}})
# controls: no silent-NULL conflation in any of these shapes
(roundtrip-row "SELECT ?::STRUCT(k BOOLEAN) AS v" [{"k" false}] {:v {:k false}})
(roundtrip-row "SELECT ?::STRUCT(k BOOLEAN) AS v" [{:k true}] {:v {:k true}})
(assert-raises (fn [] (duckdb/query conn "SELECT ?::BOOLEAN AS b" [1]))
                "not a boolean")
(roundtrip-row "SELECT ?::MAP(VARCHAR, BOOLEAN) AS m" [{:k false}] {:m @{"k" false}})
(roundtrip-row "SELECT ?::BOOLEAN[] AS l" [[false]] {:l @[false]})
(assert-raises (fn [] (duckdb/query conn "SELECT ?::STRUCT(k BOOLEAN) AS v" [{:x 1}]))
                "struct field :k missing")

# -- T1: UBIGINT read lane - u64 wrapper beyond the band -----------------------
(roundtrip-row "SELECT ?::UBIGINT AS u" [(int/u64 "18000000000000000000")]
  {:u (int/u64 "18000000000000000000")})

# -- T2: config map accepts tables ----------------------------------------------
(with [db2 (duckdb/open ":memory:" @{:threads 1})]
  (with [c2 (duckdb/connect db2)]
    (assert-eq (duckdb/first-row (duckdb/query c2 "SELECT 41 + 1 AS v")) {:v 42}
               "T2 table config opens and queries")))

# -- T3: json :null keyword binds SQL NULL -------------------------------------
(import json)
(roundtrip-row "SELECT ?::STRUCT(k VARCHAR, n INTEGER) AS st"
  [{:k "a" :n :null}] {:st {:k "a" :n nil}})
(roundtrip-row "SELECT ?::STRUCT(k VARCHAR, n INTEGER) AS st"
  [(json/decode "{\"k\":\"a\",\"n\":null}")] {:st {:k "a" :n nil}})

# -- T4: non-integral / non-boolean / non-finite typed binds raise -------------
(assert-raises (fn [] (duckdb/query conn "SELECT ?::INTEGER AS i" [0.5]))
                "is not an integer")
(assert-raises (fn [] (duckdb/query conn "SELECT ?::INTEGER AS i" [math/inf]))
                "is not finite")
(assert-raises (fn [] (duckdb/query conn "SELECT ?::INTEGER AS i" [math/nan]))
                "is not finite")

# -- T5: BLOB reads deliver unsigned bytes [0, 255] ----------------------------
(duckdb/exec conn "CREATE TABLE blb (b BLOB)")
(duckdb/exec conn "INSERT INTO blb VALUES (from_hex('00ffc3'))")
(assert-eq (duckdb/first-row (duckdb/query conn "SELECT b FROM blb"))
  {:b [0 255 195]} "T5 blob reads unsigned bytes")
# bind lane boundary: duckdb converts STRING -> BLOB ascii-only; a
# non-ascii byte must arrive via SQL (from_hex) or file import
(assert-raises (fn [] (duckdb/query conn "SELECT ?::BLOB AS b" ["ÿ"]))
                "Invalid byte encountered")
(roundtrip-row "SELECT ?::BLOB AS b" ["ab"] {:b [97 98]})

# -- B1: string_t long-read lane - NUL-bearing long values exact ---------------
# >12-byte VARCHAR/BLOB with any 0x00 must read exact; multi-row calls
# must not die on one bad value. Permanent fixtures: nulv/nulb carry
# >=20-byte NUL-bearing values every suite run (the string_t seam can
# never go blind again).
(duckdb/exec conn "CREATE TABLE nulv (v VARCHAR, b BLOB)")
(duckdb/exec conn "INSERT INTO nulv VALUES
  (rpad(chr(65),10,chr(120)) || chr(0) || rpad(chr(66),9,chr(121)),
   from_hex('414243004445464748494A4B4C004D'))")
(def nul-row (duckdb/first-row (duckdb/query conn "SELECT v, b FROM nulv")))
(assert-eq (nul-row :v)
  (string "Axxxxxxxxx" (string/from-bytes 0) "Byyyyyyyy")
  "B1 long VARCHAR, interior NUL, exact")
(assert-eq (nul-row :b)
  (tuple 0x41 0x42 0x43 0x00 0x44 0x45 0x46 0x47 0x48 0x49 0x4A 0x4B 0x4C 0x00 0x4D)
  "B1 long BLOB, interior NUL, exact")
(assert-eq ((duckdb/first-row (duckdb/query conn "SELECT from_hex('004142434445464748494A4B4C') AS b")) :b)
  (tuple 0x00 0x41 0x42 0x43 0x44 0x45 0x46 0x47 0x48 0x49 0x4A 0x4B 0x4C)
  "B1 13-byte BLOB, NUL first, exact")
(assert-eq ((duckdb/first-row (duckdb/query conn "SELECT from_hex('4142434445464748494A4B4C00') AS b")) :b)
  (tuple 0x41 0x42 0x43 0x44 0x45 0x46 0x47 0x48 0x49 0x4A 0x4B 0x4C 0x00)
  "B1 13-byte BLOB, NUL last, exact")
(assert-eq ((duckdb/first-row (duckdb/query conn "SELECT from_hex('0041424344454647484941') AS b")) :b)
  (tuple 0x00 0x41 0x42 0x43 0x44 0x45 0x46 0x47 0x48 0x49 0x41)
  "B1 12-byte inline BLOB with NUL (inline lane stays exact)")
(assert-eq ((duckdb/first-row (duckdb/query conn "SELECT rpad(chr(122),20,chr(121)) AS v")) :v)
  "zyyyyyyyyyyyyyyyyyyy" "B1 NUL-free long VARCHAR (sound, not lucky)")
(duckdb/exec conn "CREATE TABLE nulb (b BLOB)")
(duckdb/exec conn "INSERT INTO nulb VALUES (from_hex('4142434445464748494A4B4C')),
  (from_hex('004142434445464748494A4B4C'))")
(assert-eq (duckdb/rows (duckdb/query conn "SELECT b FROM nulb"))
  @[{:b (tuple 0x41 0x42 0x43 0x44 0x45 0x46 0x47 0x48 0x49 0x4A 0x4B 0x4C)}
    {:b (tuple 0x00 0x41 0x42 0x43 0x44 0x45 0x46 0x47 0x48 0x49 0x4A 0x4B 0x4C)}]
  "B1 multi-row: row 2 NUL-bearing, whole rows call exact")
# file-import lane: read_blob on a NUL-bearing fixture file
(def nulfile "/tmp/duckdb-smoke-nul.bin")
(spit nulfile (string/from-bytes 0 65 66 0 67 68 69 70 0 71 72 73 74 75 76 77 78 79 80 0))
(assert-eq ((duckdb/first-row (duckdb/query conn (string "SELECT content FROM read_blob('" nulfile "')"))) :content)
  (tuple 0 65 66 0 67 68 69 70 0 71 72 73 74 75 76 77 78 79 80 0)
  "B1 file-import lane: NUL-bearing blob reads exact")
(when (os/stat nulfile) (os/rm nulfile))

# -- B2: NULL-valued MAP entries drop on read ----------------------------------
# documented cut, not a defect to fix: janet dictionaries cannot carry
# nil values (structs AND tables drop them), so a NULL-valued MAP
# entry has no representable read target - the key vanishes
(assert-eq (duckdb/first-row (duckdb/query conn "SELECT MAP {chr(107): NULL} AS m"))
  {:m @{}} "B2 NULL-valued MAP entry drops (documented cut)")
(assert-eq (duckdb/first-row (duckdb/query conn "SELECT MAP {chr(107): 1, chr(106): NULL} AS m"))
  {:m @{"k" 1}} "B2 NULL-valued second entry drops, first exact")
(assert-eq (duckdb/first-row (duckdb/query conn "SELECT MAP {chr(107): NULL, chr(106): 2} AS m"))
  {:m @{"j" 2}} "B2 NULL first entry drops, second exact")
(roundtrip-row "SELECT ?::MAP(VARCHAR, INTEGER) AS m" [{:k 1 :j :null}]
  {:m @{"k" 1}})

# -- D3: bind-boundary messages ------------------------------------------------
(assert-raises (fn [] (duckdb/query conn "SELECT ?::VARCHAR AS v"
                                   [(string "a" (string/from-bytes 0) "b")]))
                "embedded NUL")
(assert-raises (fn [] (duckdb/query conn "SELECT ?::BLOB AS b"
                                   [(string "a" (string/from-bytes 0) "b")]))
                "embedded NUL")
(assert-raises (fn [] (duckdb/query conn "SELECT ?::MAP(VARCHAR, INTEGER) AS m" [{:null 1}]))
                "MAP keys cannot be NULL")
(assert-raises (fn [] (duckdb/query conn "SELECT ?::MAP(INTEGER, INTEGER) AS m" [{:null 1}]))
                "MAP keys cannot be NULL")

# -- B2/B3: crash-class subprocess probes -------------------------------------
# invalid-UTF8 binds and use-after-close ops must raise clean janet
# errors in a child process - exit 0 with a message, never SIGSEGV (139)
# valid multibyte UTF-8 stays green on the guarded lane
(roundtrip-row "SELECT ?::VARCHAR AS v" ["héllo 'quoted'"] {:v "héllo 'quoted'"})
(defn subprobe [code]
  (def script "/tmp/duckdb-smoke-sub.janet")
  (def out "/tmp/duckdb-smoke-sub.txt")
  (spit script code)
  (def rc (os/execute ["/bin/sh" "-c" (string
    "JANET_PATH=" (or (get (os/environ) "JANET_PATH") "modules:tests/lib")
    " janet " script " > " out " 2>&1")]))
  (def msg (string/trim (string (slurp out))))
  (when (os/stat out) (os/rm out))
  (when (os/stat script) (os/rm script))
  [rc msg])

(defn probe-common []
  "(import janet-duckdb :as duckdb)
   (def db (duckdb/open \":memory:\"))
   (def conn (duckdb/connect db))
   (def p (fn [e] (print \"ERR \" e)))
   ")
(defn assert-no-crash [rc msg tag]
  (assert (and (= rc 0) (string/find "duckdb:" msg))
          (string tag ": expected clean raise (rc 0), got rc " rc ": " msg)))

(let [[rc msg] (subprobe (string (probe-common)
  "(try (duckdb/query conn \"SELECT ?::VARCHAR AS v\" [(string \"\\xFF\" \"x\")])
     ([e] (print \"duckdb-sub \" e)))"))]
  (assert-no-crash rc msg "B2 invalid-UTF8 VARCHAR bind")
  (assert (string/find "UTF-8" msg) "B2: error must name the UTF-8 requirement"))
(let [[rc msg] (subprobe (string (probe-common)
  "(try (duckdb/query conn \"SELECT ?::BLOB AS v\" [(string \"\\xFF\" \"x\")])
     ([e] (print \"duckdb-sub \" e)))"))]
  (assert-no-crash rc msg "B2 invalid-UTF8 BLOB bind")
  (assert (string/find "UTF-8" msg) "B2: error must name the UTF-8 requirement"))
(let [[rc msg] (subprobe (string (probe-common)
  "(def stmt (duckdb/prepare conn \"SELECT 1 AS x\"))
   (:close stmt)
   (try (duckdb/execute stmt) ([e] (print \"duckdb-sub \" e)))"))]
  (assert-no-crash rc msg "B3 execute after stmt close")
  (assert (string/find "already closed" msg) "B3: message must say already closed"))
(let [[rc msg] (subprobe (string (probe-common)
  "(def stmt (duckdb/prepare conn \"SELECT ?::INTEGER AS x\"))
   (:close stmt)
   (try (duckdb/bind stmt 1 5) ([e] (print \"duckdb-sub \" e)))"))]
  (assert-no-crash rc msg "B3 bind after stmt close"))
(let [[rc msg] (subprobe (string (probe-common)
  "(:close conn)
   (try (duckdb/query conn \"SELECT 1 AS x\") ([e] (print \"duckdb-sub \" e)))"))]
  (assert-no-crash rc msg "B3 query after conn close")
  (assert (string/find "already closed" msg) "B3: message must say already closed"))
(let [[rc msg] (subprobe (string (probe-common)
  "(:close db)
   (try (duckdb/connect db) ([e] (print \"duckdb-sub \" e)))"))]
  (assert-no-crash rc msg "B3 connect after db close")
  (assert (string/find "already closed" msg) "B3: message must say already closed"))
# double-close stays idempotent on all three
(let [[rc msg] (subprobe (string (probe-common)
  "(:close conn) (:close conn)
   (:close db) (:close db)
   (print \"duckdb-sub idempotent\")"))]
  (assert (and (= rc 0) (string/find "idempotent" msg))
          (string "double-close must stay idempotent, got rc " rc ": " msg)))

# -- teardown ---------------------------------------------------------------------
(:close conn)
(:close db)
(print "duckdb smoke ok")
