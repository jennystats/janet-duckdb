# sweep-duckdb - full-surface SQL sweep: every supported type is read
# through a real query and, where the contract binds it, round-tripped
# through a prepared parameter. The reference is the 2.0.1 CLI (path
# passed as arg 1): the module's own CAST(expr AS VARCHAR) must equal
# the CLI's, and the value decoded by the module must re-bind to the
# same text.
# Usage: strict test/sweep-duckdb.janet <duckdb-cli-path>
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")
(import jennystats/duckdb :as d)

(def args (script-args))
(def cli (get args 0 "/home/phillc/.local/bin/duckdb"))

# cell: {:name :expr :type :bindable :cli :expect}
#   :type     cast target used for the read and the bind round trip: the
#             decoded value is bound back through CAST(? AS <type>) unless
#             :bindable is false
#   :bindable explicit opt-out (false) for the documented bind cuts; every
#             cell with a :type and no false opt-out is round-tripped
#   :cli      compare the module's VARCHAR against the CLI's (default true)
#   :expect   :error means the read must raise the documented cut
(def cells
  @[{:name "tinyint" :expr "127::TINYINT" :type "TINYINT"}
    {:name "smallint" :expr "(-32768)::SMALLINT" :type "SMALLINT"}
    {:name "integer" :expr "2147483647::INTEGER" :type "INTEGER"}
    {:name "bigint-exact" :expr "4503599627370496::BIGINT" :type "BIGINT"}
    {:name "bigint-beyond-2p53" :expr "9007199254740993::BIGINT" :type "BIGINT"}
    {:name "utinyint" :expr "255::UTINYINT" :type "UTINYINT"}
    {:name "usmallint" :expr "65535::USMALLINT" :type "USMALLINT"}
    {:name "uinteger" :expr "4294967295::UINTEGER" :type "UINTEGER"}
    {:name "ubigint-in-band" :expr "4503599627370496::UBIGINT" :type "UBIGINT"}
    {:name "ubigint-beyond-2p53" :expr "18446744073709551615::UBIGINT" :type "UBIGINT"}
    {:name "boolean" :expr "true::BOOLEAN" :type "BOOLEAN"}
    {:name "float" :expr "CAST(1.1 AS FLOAT)" :type "FLOAT"}
    {:name "double-rounding" :expr "CAST(0.1 AS DOUBLE) + CAST(0.2 AS DOUBLE)" :type "DOUBLE"}
    {:name "double-third" :expr "CAST(1.0 AS DOUBLE) / CAST(3.0 AS DOUBLE)" :type "DOUBLE"}
    {:name "decimal-10-3" :expr "CAST(123.456 AS DECIMAL(10,3))" :bindable false}
    {:name "decimal-38-6" :expr "CAST(12345678901234567890.123456 AS DECIMAL(38,6))" :bindable false}
    {:name "varchar-unicode" :expr "'héllo wörld'::VARCHAR" :type "VARCHAR"}
    {:name "varchar-long" :expr "repeat('abc', 400)::VARCHAR" :type "VARCHAR"}
    {:name "varchar-interior-nul" :expr "('a' || chr(0) || 'b')::VARCHAR" :cli false}
    {:name "blob-nul" :expr "from_hex('00010203ff')::BLOB" :cli false}
    {:name "date" :expr "DATE '2024-02-29'" :type "DATE"}
    {:name "time" :expr "TIME '01:02:03.123456'" :type "TIME"}
    {:name "time-tz" :expr "CAST('01:02:03+02' AS TIMETZ)" :type "TIMETZ"
     # read exposes UTC fields plus :session-timezone-offset; bind takes
     # local fields plus :timezone-offset, so the round trip converts
     :rebind (fn [v]
               (def utc (+ (* (v :hours) 3600000000) (* (v :minutes) 60000000)
                           (* (v :seconds) 1000000) (v :micros)))
               (def local (mod (+ utc (* (v :session-timezone-offset) 1000000))
                               (* 24 3600 1000000)))
               {:hours (math/floor (/ local 3600000000))
                :minutes (math/floor (/ (mod local 3600000000) 60000000))
                :seconds (math/floor (/ (mod local 60000000) 1000000))
                :micros (mod local 1000000)
                :timezone-offset (v :session-timezone-offset)})}
    {:name "timestamp" :expr "TIMESTAMP '2024-05-06 07:08:09.123456'" :type "TIMESTAMP"}
    {:name "timestamp-s" :expr "CAST(TIMESTAMP '2024-05-06 07:08:09' AS TIMESTAMP_S)" :type "TIMESTAMP_S"}
    {:name "timestamp-ms" :expr "CAST(TIMESTAMP '2024-05-06 07:08:09.123' AS TIMESTAMP_MS)" :type "TIMESTAMP_MS"}
    {:name "timestamp-ns" :expr "CAST(TIMESTAMP '2024-05-06 07:08:09.123456789' AS TIMESTAMP_NS)" :type "TIMESTAMP_NS"}
    {:name "timestamptz" :expr "TIMESTAMPTZ '2024-05-06 07:08:09+02'" :type "TIMESTAMPTZ"}
    {:name "interval" :expr "INTERVAL 3 MONTH + INTERVAL 4 DAY + INTERVAL 5 SECOND" :type "INTERVAL"}
    {:name "interval-neg" :expr "(- INTERVAL 2 DAY) + INTERVAL 1 SECOND" :type "INTERVAL"}
    {:name "date-plus-month" :expr "DATE '2024-01-31' + INTERVAL 1 MONTH" :type "TIMESTAMP"}
    {:name "uuid" :expr "CAST('00112233-4455-6677-8899-aabbccddeeff' AS UUID)" :bindable false}
    {:name "enum" :expr "CAST('b' AS ENUM('a','b','c'))" :bindable false}
    {:name "list-int" :expr "[1,2,3]::INTEGER[]" :type "INTEGER[]"}
    {:name "list-null" :expr "['a',NULL,'c']::VARCHAR[]" :type "VARCHAR[]"}
    {:name "list-nested" :expr "[[1,2],[3]]::INTEGER[][]" :type "INTEGER[][]"}
    {:name "struct" :expr "{'a': 1, 'b': 'x'}::STRUCT(a INTEGER, b VARCHAR)" :type "STRUCT(a INTEGER, b VARCHAR)"}
    {:name "map" :expr "MAP {'k': 7}" :type "MAP(VARCHAR, INTEGER)" :cli false}
    {:name "array-fixed" :expr "CAST([1,2,3] AS INTEGER[3])" :type "INTEGER[3]"}
    {:name "union" :expr "CAST(42 AS UNION(a INTEGER, b VARCHAR))" :type "UNION(a INTEGER, b VARCHAR)"}
    {:name "hugeint" :expr "170141183460469231731687303715884105727::HUGEINT" :bindable false}
    {:name "uhugeint" :expr "340282366920938463463374607431768211455::UHUGEINT" :bindable false}
    {:name "sqlnull" :expr "NULL" :bindable false}
    {:name "bit-cut" :expr "'101'::BIT" :expect :error}
    {:name "bignum-cut" :expr "'123456789012345678901234567890'::BIGNUM" :expect :error}])

(defn/typed cli-varchar {:args [:string] :ret :string} [expr]
  "The 2.0.1 CLI's VARCHAR rendering of expr (the reference)."
  (def f (string "/tmp/sweep-q-" (gensym) ".sql"))
  (spit f (string "SELECT CAST((" expr ") AS VARCHAR);\n"))
  (def out (sh-capture (string cli " -noheader -list < " (sh-quote f))))
  (os/rm f)
  out)

(def db (d/open ":memory:"))
(def conn (d/connect db))

(def summary @{:pass 0 :fail 0 :errors @[]})

(defn/typed check-cell {:args [:struct] :ret nil} [cell]
  "One sweep cell: read + CLI compare + bind round trip."
  (def name (cell :name))
  (def expr (cell :expr))
  (def want-error (= (cell :expect) :error))
  (def probs @[])
  (def row
    (try
      (do
        (def r (d/query conn (string "SELECT (" expr ") AS v, CAST((" expr ") AS VARCHAR) AS s")))
        (def row (d/first-row r))
        (:close r)
        row)
      ([e] (array/push probs (string "read-error: " (string/triml (string e)))) nil)))
  (cond
    want-error
    (if (nil? row)
      (do (++ (summary :pass)) (print (string "CELL " name " | PASS-cut | " (string/join probs " ; "))))
      (do (++ (summary :fail)) (array/push (summary :errors) name)
          (print (string "CELL " name " | FAIL-cut-not-raised"))))

    (nil? row)
    (do (++ (summary :fail)) (array/push (summary :errors) name)
        (print (string "CELL " name " | FAIL | " (string/join probs " ; "))))

    (do
      (def v (row :v))
      (def s (row :s))
      (def cli? (not= false (cell :cli)))
      (when cli?
        (def cli-text (cli-varchar expr))
        (unless (or (= s cli-text) (and (nil? s) (= cli-text "NULL")))
          (array/push probs (string "cli: module=" (string/format "%j" s)
                                    " cli=" (string/format "%j" cli-text)))))
      (when (and (cell :type) (not= false (cell :bindable)))
        (def ctype (cell :type))
        (def bv (if (cell :rebind) ((cell :rebind) v) v))
        (def stmt (d/prepare conn (string "SELECT CAST(? AS " ctype ") AS v2,"
                                         " CAST(CAST(? AS " ctype ") AS VARCHAR) AS s2")))
        (def r2 (try (d/execute stmt @[bv bv])
                     ([e] (array/push probs (string "bind-error: " (string/triml (string e)))) nil)))
        (when r2
          (def row2 (d/first-row r2))
          (:close r2)
          (unless (= (row2 :s2) s)
            (array/push probs (string "bind-text: " (string/format "%j" (row2 :s2))
                                      " vs read " (string/format "%j" s))))
          (unless (= (string/format "%j" (row2 :v2)) (string/format "%j" v))
            (array/push probs (string "value: bind=" (string/format "%j" (row2 :v2))
                                      " read=" (string/format "%j" v)))))
        (:close stmt))
      (if (empty? probs)
        (do (++ (summary :pass)) (print (string "CELL " name " | PASS | " (string/format "%j" s))))
        (do (++ (summary :fail)) (array/push (summary :errors) name)
            (print (string "CELL " name " | FAIL | " (string/join probs " ; "))))))))

(each cell cells (check-cell cell))

(:close conn)
(:close db)
(print (string "SUMMARY pass=" (summary :pass) " fail=" (summary :fail)
               " failing=" (string/join (summary :errors) ",")))
(print "END")
