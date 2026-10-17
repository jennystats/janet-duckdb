# janet-duckdb

In-process DuckDB for Janet, via core ffi - no jpm native module, no C
build. It opens a DuckDB database inside the Janet process and hands
back handles: prepared statements, the full type matrix on both read
and bind, column-major result access, and a packed f32 lane that feeds
numeric kernels without a Janet element hop. All jenny modules
install under a `jennystats/` namespace directory - collision-proof
against bare-name shadowing, by construction. Prefer a shorter call
prefix? Alias at import (shown in the usage below).

Part of [Jenny Stats](https://github.com/jennystats), a home for Janet
data and statistics packages. Jenny is just Janet.

## What it is

- `(open path)` -> db handle, `(connect db)` -> conn, `(query conn
  sql)` -> result handle. Handles close via `:close`, so `with` works
  on every kind.
- **Prepared statements**: `(prepare conn sql)` + `(execute stmt
  params)` - positional tuple/array or named struct (`$1` or `$name`
  styles). Every bind goes through duckdb's own parameter interface.
- **Full type matrix, read and bind**: integers, floats, VARCHAR,
  BLOB, DATE, TIMESTAMP and its variants, TIME WITH TIME ZONE,
  INTERVAL, ENUM, DECIMAL, LIST, STRUCT, MAP, UNION. Values bind with
  the SQL-side cast `?::TYPE`; results decode to plain Janet values.
- **Result handles re-read like values**: rows are memoised on first
  read - `rows`, `first-row` and `columns` can be called repeatedly on
  the same result, in any order. There is no one-shot cursor trap.
- **pack-columns-f32**: `(pack-columns-f32 conn sql)` streams the
  result chunks and hands duckdb's native vector memory straight to
  janet-num's C kernel - no Janet element crosses the boundary. All
  columns must be DOUBLE; NULL becomes NaN. The result is the
  janet-num packed-handle shape, ready for `packed-slice-f32` and
  downstream C kernels.
- **describe-columns**: per-column type metadata, with an optional
  logical mode where nested types arrive as tagged tuples.

```janet
(import jennystats/duckdb)

(with [db (janet-duckdb/open ":memory:")]
  (with [conn (janet-duckdb/connect db)]
    (janet-duckdb/exec conn "CREATE TABLE t (i INTEGER, s VARCHAR)")
    (janet-duckdb/exec conn "INSERT INTO t VALUES (1, 'a'), (2, 'b')")
    (def rows (janet-duckdb/rows
                (janet-duckdb/query conn "SELECT * FROM t ORDER BY i")))
    # @[{:i 1 :s "a"} {:i 2 :s "b"}]

    # bind: cast in SQL, value in params
    (with [stmt (janet-duckdb/prepare conn
                 "SELECT ?::INTEGER AS i, ?::VARCHAR AS s")]
      (def res (janet-duckdb/execute stmt [7 "seven"]))
      (printf "%q" (janet-duckdb/first-row res)))  # {:i 7 :s "seven"}

    # C-to-C feed for numeric kernels: all-DOUBLE query, NULL -> NaN
    (def packed (janet-duckdb/pack-columns-f32 conn
      "SELECT i::DOUBLE AS a, (s IS NULL)::DOUBLE AS b FROM t"))))
```

Prefer shorter call sites? Alias at import:

```janet
(import jennystats/duckdb :as duckdb)
(duckdb/rows (duckdb/query conn "SELECT 41 + 1 AS v"))  # @[{:v 42}]
```

The behavioural specification is `specs/api-contract.md` (v1.6): the
full type matrix, preconditions, ownership, error taxonomy and the
libduckdb version coupling.

## Install

The module binds duckdb's C API over ffi, so it needs the pinned
shared library (verified sha256, four platforms, idempotent):

```bash
libs/install-duckdb.sh   # libduckdb 1.5.6 -> ~/.local/lib/duckdb/
```

Module dependencies: [janet-num](https://github.com/jennystats/janet-num)
(the pack-columns-f32 C kernel) and [janet-kit](https://github.com/jennystats/janet-kit)
(runtime type contracts). With the library in place:

```bash
jpm install https://github.com/jennystats/janet-duckdb
```

Lib resolution at import: `$DUCKDB_LIB`, then
`~/.local/lib/duckdb/libduckdb.so`, then the system dlopen search.
The import fails with an actionable message if none loads.

## Tests

```bash
./run_tests.sh
```

The smoke suite covers exact-table queries, type round-trips,
prepared statements, NUL-bearing string reads and crash-class probes.
It skips cleanly when libduckdb or the janet-num kernel is absent;
present-but-broken is a fail, never a skip. The suite also uses
[janet-json](https://github.com/jennystats/janet-json) for two
bind-lane rows.

## Known cuts, declared

- Appender, Arrow and pending-result interfaces are not exposed.
- BIT, BIGNUM and TIME_NS reads are unsupported.
- Integers beyond 2^53 arrive as `int/s64` / `int/u64` wrappers -
  exact values, but not plain doubles (`int/to-number` converts in
  band).
- DECIMAL params bind unsupported: duckdb reports the parameter
  without a usable logical type. DECIMAL reads are supported.
- libduckdb is pinned to 1.5.6. The result-struct layout and symbol
  names are version-coupled to 1.5.x; an upgrade needs the C API
  surface re-verified before the module can follow.

## Alternatives

- **[sqlite3](https://github.com/janet-lang/sqlite3)** - the official
  Janet SQLite module, a native jpm module built per Janet version.
  For users whose need is an embedded SQL engine around SQLite
  rather than DuckDB's analytics (columnar scans, aggregate-heavy
  queries, window functions, huge relations in one go), it is the
  direct route.

## License

AGPLv3 - see `LICENSE`.

This module is a port of [sbocq/janet-duckdb](https://github.com/sbocq/janet-duckdb)
(MIT) adapted to the Jenny Stats typed-contract stack - the original
work is sbocq's; full attribution also in the module header.

## AI assistance

The code in this repository was written with the assistance of a
large language model and reviewed by its maintainer.
