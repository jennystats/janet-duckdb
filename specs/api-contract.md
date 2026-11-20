# Spec - janet-duckdb public API contract (v1.8, libduckdb 2.0.1)

Prose contract (a formal specification language is not the right tool
here; the duckdb C API is the external truth). Canonical signatures: the module
docstrings in `janet-duckdb.janet`. This document adds what
signatures cannot carry: preconditions, effects, ownership, the type
matrix and the error taxonomy. Binding truth: `janet-duckdb.janet`
(ffi/defbind + wrappers, pinned to libduckdb v2.0.1 from
`libs/install-duckdb.sh`); external truth: the duckdb C API.

## 1. Layering

- **Janet wrapper layer** (janet-duckdb.janet): argument validation, handle
  construction, actionable errors, type decode and value encode. All
  argument validation lives here - the C layer trusts its caller.
- **C API layer** (libduckdb v2.0.1): reached only through
  `ffi/defbind` bindings with verbatim duckdb symbol names. The
  `duckdb_result` struct layout comes from the stable C API v1 surface
  (six fields: `:uint64 :uint64 :uint64 :ptr :ptr :ptr`), identical in
  1.5.6 and 2.0.1; the coupling is quarantined inside this module -
  callers never touch the layout.
- **Handle structs**: every handle (db, conn, stmt, result) is a
  struct with `:ptr`, a `:close` function and `:assert-valid`, which
  raises on any use after close. `with` works through `:close` on all
  handle types.
- **Lib resolution** at import: `$DUCKDB_LIB` then
  `~/.local/lib/duckdb/libduckdb.so` then the system dlopen search.
  The load is probed before the ffi context is set, so every failing
  path raises the same actionable error naming
  `libs/install-duckdb.sh`.

## 2. Call shapes

Public surface (everything else in the module is internal):

```
(open path &opt config-map)     -> db handle      (path defaults :memory:,
                                                   but must still be
                                                   passed; (open) is a
                                                   compile error)
(connect db)                    -> conn handle
(query conn sql &opt params)    -> result handle
(rows result &opt keywordize coll-type) -> array of structs|tuples
(first-row result &opt keywordize coll-type) -> first row | nil
(columns result)                -> column-major struct (below)
     struct keys: :column-count :column-names :column-types :columns
     :row-count - :columns is an array of per-column arrays; access a
     column by index ((columns :columns) i), not by name
(describe-columns result &opt logical?) -> per-column type metadata;
     nested types in logical? mode are tagged tuples, e.g.
     (:struct {:key-types ... :keys ...}) - not plain structs
(exec conn sql &opt params)     -> rows-changed number
(prepare conn sql)              -> stmt handle
(execute stmt &opt params)      -> result handle
(pack-columns-f32 conn sql)     -> f32 packed handle (section 7)
(library-version)               -> libduckdb build string
```

- Preconditions: `connect` needs an open db; `query`/`exec`/`prepare`
  need a live conn; `rows`/`first-row`/`columns` need a result not yet
  closed (enforced by `:assert-valid`). Violations raise.
- `rows` options: `keywordize` (default true - column names as
  keywords) and `coll-type` (default `:struct`; the only other value
  is `:tuple` - anything else raises).
- `query` with params prepares, binds and executes in one call; the
  statement is destroyed before the result returns. Without params the
  query goes straight through `duckdb_query`.
- `exec` closes its result before returning the count, so it never
  leaks a handle on success.
- `rows`/`first-row`/`columns` re-read safely: see section 3.
- **SQL shape**: with params, a multi-statement string raises and
  nothing executes (the prepare path refuses it); without params,
  every statement executes - all side effects persist, any
  statement's error raises the call - and the first SELECT's result
  is returned (the last statement's when there is no SELECT). Send
  statements one by one. Empty or comment-only SQL returns a valid
  zero-column result, not an error.
- **Config map**: `open` takes a struct or table of duckdb options;
  names are case-insensitive, values must be string-coercible
  (strings, numbers, keywords coerce; a non-coercible value raises
  the cannot-set message naming the option). A nil-valued option
  silently vanishes - Janet structs and tables cannot carry nil
  values, the same language cut as struct fields.

## 3. Handle lifecycle

- **Ownership**: the wrapper owns every C object. `:close` destroys
  the underlying object exactly once (idempotent - a second close is
  a no-op). The ptr-ptr discipline matches duckdb's own out-parameter
  API: open/close, connect/disconnect, prepare/destroy,
  execute/destroy-result.
- **Ordering**: close a conn before its db, a stmt before its conn.
  duckdb tolerates much of this; the contract asks for correct order
  and reserves no guarantee for out-of-order closes.
- **Result re-read**: duckdb chunk streaming is one-shot per result.
  The first fetch is memoised in the result handle, so `rows`,
  `first-row` and `columns` behave like value reads and may be called
  repeatedly on one open result. This deviates from duckdb's own
  one-shot streaming deliberately: a result handle is a value, not a
  cursor.
- **After close**: any use of a closed handle raises "<kind> already
  closed" (`:assert-valid` on db, conn, stmt and result). Double-close
  is safe on every handle kind.
- **`with`**: all handles work with `with` via `:close`.

## 4. Parameter binding

- **Positional**: params as tuple or array; index 1-based in order.
  Out-of-range index raises naming the statement's param count.
- **Named**: params as struct or table; each key maps to the
  statement parameter of the same name (duckdb `$1` style names
  arrive as keywords like `:1`). A missing name raises.
- **Encoding** (Janet value to duckdb value, per the statement's
  parameter logical type): nil binds NULL; booleans, all signed and
  unsigned ints, floats and doubles pass through; strings bind as
  varchar (and as blob payloads); dates bind from Janet date structs
  (`:year :month :month-day`, 0-based like `os/date` - all three
  fields required, a partial struct raises naming the missing
  field); times from the time fields; time_tz additionally honours
  `:timezone-offset` (in seconds); timestamps are micros numbers (the
  `_s`, `_ms`, `_tz` and `_ns` variants take the same micros-scale
  number in their own unit); intervals bind from
  `{:months :days :micros}`; lists, structs, maps, arrays and unions
  bind recursively (a union binds as `[tag value]`; an array length
  must equal its declared size).
- **Integer bands**: a plain number bound to an integer type must be
  finite, whole and inside the type's band - each failure raises
  naming the value and the requirement, never a silent
  two's-complement wrap. Exact beyond-band values bind through
  `int/s64` / `int/u64` wrappers (the same band rule the ns-scale
  path uses); UBIGINT accepts wrappers over its full range, and its
  read lane returns the u64 wrapper beyond 2^53 (symmetric with
  BIGINT's s64 wrapper). BOOLEAN binds validate the value class:
  only `true`/`false` bind, anything else raises naming the value.
- **UTF-8 requirement**: VARCHAR and BLOB parameters must be
  well-formed UTF-8 strings; raw-byte strings and embedded NULs raise
  a `duckdb:` validation error at the bind boundary rather than
  reaching duckdb's C-string boundary (raw bytes crash the host VM,
  NULs hit Janet's own internal error). Raw-byte payloads are a
  documented cut - carry them via SQL literals or file import.
  Wrong-typed scalar values (e.g. an array bound to an INTEGER
  parameter) raise the native cfunction message - a documented class.
- **STRUCT keys**: struct and table binds resolve declared fields by
  keyword (idiomatic) or string key (the json decode shape); a
  present field binds its value at any depth, `false` included - a
  field absent in both forms raises. Never a silent NULL bind. MAP
  parameters stringify keyword keys (parity with the named params
  path); MAP keys cannot be NULL - a `:null` key raises (bind the
  string "null" to carry that text). The json module's `:null`
  keyword is reserved: it always binds SQL NULL in any position;
  bind the string ":null" to carry that literal text.
- **Band rule for ns-scale binds**: plain doubles beyond the ±2^53
  exact band cannot cross the ffi int64 boundary - neither `int/s64`
  nor the ffi layer accepts them. Bind such values as s64-wrapped
  strings (`(int/s64 "1700000000000000000")`); the read comes back
  s64-wrapped the same way.
- **DECIMAL parameters are a hard cut**: duckdb reports a DECIMAL
  parameter without a usable logical type even inside casts, so
  prepared DECIMAL params raise; carry decimals as SQL literals or
  bind a DOUBLE and cast in the SELECT list.
- **Unknown parameter type** (`SELECT ?` with no cast): SUPERSEDED in
  0.1.3 (below) - duckdb reports such parameters without a usable type
  until the SQL pins one; the bind now infers the type from the value.
- Statements are reusable: `execute` binds fresh params each call;
  `clear-bindings` (internal) resets between rounds. Public users
  re-execute without clearing. Omitted params bind an empty tuple,
  which is correct only for a statement that takes none - a
  parameterised statement reused that way keeps its previous bindings
  (measured on 0.1.3).

## 5. Type matrix

Read (query result to Janet) and bind (Janet to parameter). Type keys
are the module's keywords (`:int`, `:timestamp`, ...).

| duckdb type | read -> Janet | bind from Janet |
|---|---|---|
| NULL cell | nil | nil |
| SQLNULL (2.0 logical type) | nil for every row (the vector data is never read) | not bindable; bind nil to a typed parameter instead |
| BOOLEAN | true/false | bool |
| TINYINT..BIGINT | number (bigint beyond 2^53 stays a core s64) | integer in band |
| UTINYINT..UBIGINT | number (UBIGINT u64-wrapped beyond 2^53, symmetric with BIGINT) | integer in band (int/s64, int/u64 wrappers beyond) |
| FLOAT, DOUBLE | number | number |
| VARCHAR | string (values with interior NULs read exact) | string (well-formed UTF-8; embedded NULs raise) |
| BLOB | tuple of unsigned bytes [0, 255], NUL-bearing values exact (length-bounded pointer read) | string (well-formed UTF-8, no embedded NULs; the STRING -> BLOB conversion is ascii-only and non-ascii strings RAISE duckdb's Conversion Error - high bytes via SQL hex or file import) |
| DATE | struct `{:year :month :month-day}` (0-based month and day) | same struct |
| TIME | struct (time fields) | same fields |
| TIME_TZ | struct (UTC fields wrapped into [0, 24h) - mod-24h) + `:session-timezone-offset` (seconds) | fields + `:timezone-offset` (seconds) |
| TIMESTAMP, _TZ | number (epoch micros) | micros number |
| TIMESTAMP_S, _MS | number (seconds, millis) | number in unit |
| TIMESTAMP_NS | s64-wrapped nanos beyond 2^53, else number | number |
| INTERVAL | `{:months :days :micros}` | same struct |
| HUGEINT, UHUGEINT | double (via duckdb's to_double) | - (bind as double-typed cast) |
| DECIMAL | double (scale applied) | - (bind via double cast) |
| ENUM | dictionary string | - (varchar cast) |
| LIST | array (nested recursively) | array/tuple |
| STRUCT | struct (immutable) | struct/table (keyword or string keys; a missing declared field raises) |
| MAP | table (mutable; NULL-valued entries drop - Janet dictionaries cannot carry nil values) | struct/table (keyword keys stringify; keys cannot be NULL) |
| ARRAY | tuple of fixed size | array/tuple of declared size |
| UNION | `[tag value]` pair | same pair |
| UUID | raw hugeint pair (16 bytes, no double conversion) | - |

Cuts, raising on read: BIT and BIGNUM raise "type not supported";
TIME_NS values in duckdb TIMESTAMP_NS columns read fine - the
unsupported ns form is duckdb's separate TIME_NS id, which raises
the generic "unknown type id" error. Binding edge types (a bare
string or integer literal parameter) require a cast in SQL. The
2.0.1 enum also carries TIMESTAMP_TZ_NS (id 42); no SQL cast target
produces such a column, and a column of that type from a file would
raise "unknown type id 42" like TIME_NS - the same documented cut.

Known decode asymmetries, deliberate: MAP columns read as mutable
tables, STRUCT columns as immutable structs; UUID keeps the exact
16-byte pair where HUGEINT converts to double.

Engine semantics that moved with the 2.0 pin, user-visible through
this module because SQL passes through unchanged:

- **Integer division and modulo by zero raise** (`Invalid Input
  Error: Division by zero`); 1.5.6 returned NULL for both. `TRY(...)`
  or `SET error_on_division_by_zero=false` restores the NULL result.
- **An untyped NULL column reports the SQLNULL type** rather than an
  inferred INTEGER. The module decodes it as nil, so reads are
  unchanged.
- **Bind-completeness errors reword**: a prepared statement executed
  with no parameters now says `Values were not provided for the
  following parameters: 1` instead of `Expected 1 parameters, but
  none were supplied`. Both are DUCKDB-class errors.

## 6. Error taxonomy

| class | source | message shape |
|---|---|---|
| VALIDATION | wrapper misuse: bad coll-type, out-of-range parameter index, unknown parameter name, wrong array length, unknown union tag, non-date struct | `duckdb: ...` naming the offending value and the requirement |
| DUCKDB | the engine: syntax, missing tables, constraint and IO failures, prepare failures | duckdb's own message, prefixed `duckdb <error-type>:` with the typed keyword (query path) or `duckdb: ...` (prepare/execute path); never swallowed |
| ENVIRONMENT | libduckdb absent or unloadable | names `libs/install-duckdb.sh` or `$DUCKDB_LIB` (with the D1 caveat above) |

Every message is actionable: it names the offending value, the fix,
or the installer.

## 7. janet-num dependency

`pack-columns-f32 conn sql` queries, streams the result chunks and
hands duckdb's native vector memory to janet-num's
`interleave-chunk-f32` C kernel: no janet element crosses the
boundary. All columns must be DOUBLE; NULL becomes NaN (xgboost
missing semantics). The result is the janet-num packed-handle shape
`{:ptr :nrow :ncol :bytes :column-names}`, so
`janet-num/packed-slice-f32` and the xgboost dmatrix-from-packed lane
consume it directly. Requires janet-num 0.1.1+ (jennystats).

## 8. Version coupling

libduckdb v2.0.1 is pinned by `libs/install-duckdb.sh` (sha256
verified per platform: linux-amd64, linux-arm64, osx-universal,
windows-amd64; every platform's digest was recomputed from a full
download and equals the release metadata's, not copied). The pin
moved 1.5.6 -> 2.0.1 on 2026-11-20, the first bugfix release of the
2.0 line and the agreed wait condition set after the 2.0.0 review.
The installer's asset scheme changed with 2.0: releases now ship
`duckdb-shared-libs-<platform>.tar.gz` (the 1.5 line shipped
`libduckdb-<platform>.zip`); the library file names are unchanged.

The C API surface was re-verified mechanically, not by assumption:

- **Symbols**: all 95 bound symbols resolve in the 2.0.1 binary, and
  their declarations are byte-identical between the v1.5.6 and
  v2.0.1 headers.
- **Structs**: all 18 bound struct layouts are identical between the
  two headers; the `duckdb.h` shipped in the release tarball is
  byte-identical to the header at tag v2.0.1.
- **Enums**: 42 `DUCKDB_TYPE_*` values unchanged; the 2.0.1 enum adds
  `TIMESTAMP_TZ_NS` (42), which no SQL cast target produces.
- **Result struct at runtime**: 48 bytes, three counters then three
  pointers, verified on a 2500-row chunked result (column count and
  row streaming land exactly; the deprecated counters stay zero for
  streaming results, as in 1.5.6).
- **Full-surface sweep**: 45 cells covering every supported type read
  through a real query and, where bindable, round-tripped through a
  prepared parameter, compared against the 2.0.1 CLI as the oracle -
  all exact, and cell-for-cell identical to the same sweep against
  1.5.6 (no silent semantic drift in the type surface).

The `duckdb_result` layout and the `duckdb_fetch_chunk` symbol name
come from the stable C API v1 surface; 1.5.6 already carried the same
declarations (the API version macro in the 2.0.1 header still reads
1.5.6). A future libduckdb upgrade re-runs the same mechanical checks
before the pin moves: symbol resolution, struct diff, enum diff, load
probe, sweep.

The module also closes the union-parameter bind leak it inherited. A
temporary `duckdb_value` per union bind was never destroyed (81 bytes
per bind, measured through glibc `mallinfo2`); it is now destroyed
after `duckdb_create_union_value` copies it, and the same measurement
shows no linear growth. 1.5.6 still loads, but 2.0.1 is the verified
pin.

## Change protocol

A new public function or option is a minor version bump of this
contract plus a smoke row. A change to any signature, precondition,
type-matrix cell or error class in this document is breaking: major
bump, smoke updates, consumers re-verified, one commit.

Changes:

- **v1.8 (0.1.4, 2026-11-20)**: the libduckdb pin moved 1.5.6 -> 2.0.1
  (first bugfix of the 2.0 line). Installer asset scheme and all four
  platform digests updated; the C API surface re-verified (95/95
  symbols, 18/18 struct layouts, 42 enum values plus one added, result
  struct at runtime, 45-cell type sweep against the CLI - section 8).
  Two behavior changes reach callers through the engine and are
  recorded in section 5: integer division/modulo by zero raises
  instead of returning NULL, and an untyped NULL column reports
  SQLNULL (still decoded as nil). The union-parameter bind leak (81
  bytes per bind) is closed.
- **v1.7 (0.1.3)**: uninferrable parameters bind by the value's own
  type - string VARCHAR, whole number BIGINT, other number DOUBLE,
  boolean BOOLEAN; any other value raises naming its type. duckdb
  deliberately leaves such a parameter open (upstream design: the
  client supplies the type); the common trigger is any parameter
  following a parameterised read_parquet argument. The DECIMAL hard
  cut and the explicit-cast discipline are unchanged - inference is
  the fallback on the open parameter, never a replacement for casts
  where a type is already pinned.
- **v1.6 (2026-10-16)**: the libduckdb pin moved 1.5.5 -> 1.5.6
  (bugfix and security release, same Variegata line). Installer pins updated to the official
  release digests on all four platforms; linux-amd64 verified
  byte-exact by full download. The version-coupled surfaces
  (result-struct layout, duckdb_fetch_chunk) re-verified against
  1.5.6 - no drift; module and CLI
  agree on version for the first time.
- **v1.5 (2026-10-16)**: call-shape documentation
  completed: columns struct keys spelled out (access by index, not
  name); describe-columns logical? tagged-tuple shapes documented
  (tagged tuples, not plain structs).
- **v1.4 (2026-10-16)**: the string_t long-read
  lane is a length-bounded pointer read (duckdb_string_t_data bound
  `:ptr`, never a strlen conversion): NUL-bearing >12-byte
  VARCHAR/BLOB values read exact and multi-row calls no longer die;
  permanent NUL/length smoke fixtures added (the string_t seam);
  embedded-NUL binds raise a `duckdb:` message instead of Janet's
  internal error; MAP `:null` keys raise naming the NULL rule;
  NULL-valued MAP entries documented as dropped on read (Janet
  dictionaries cannot carry nil values - an emit-key option would
  be unrepresentable); the `:null` keyword
  documented as reserved; non-ascii BLOB binds documented as
  raising duckdb's Conversion Error; wrong-typed scalar binds
  documented as native-class messages.
- **v1.3 (2026-10-16)**: struct binds carry a
  present field's value, `false` included, at any depth (the
  silent-NULL conflation for false fields is closed; a presence test
  replaces the truthiness-shortcut lookup); the multi-statement line
  rewritten (params path raises and
  executes nothing; no-params path runs every statement and returns
  the first SELECT's result, the last statement's when there is no
  SELECT - the old "truncates the rest" wording was wrong in both
  directions); UBIGINT reads return the u64 wrapper beyond 2^53 (a
  value the module binds, it can now read); config maps accept
  tables, values must be string-coercible, nil-valued options
  vanish (Janet semantics); the json `:null` keyword binds SQL NULL;
  non-finite, non-integral integer binds and non-boolean BOOLEAN
  binds raise naming the value; BLOB reads deliver unsigned bytes
  [0, 255] and the STRING -> BLOB bind conversion is documented
  ascii-only.
- **v1.2 (2026-10-15)**: TIME_TZ reads
  wrap UTC fields into [0, 24h) (the old decoder left hours 24+);
  use-after-close raises on all four handle kinds (was a segfault
  class on db/conn/stmt); VARCHAR/BLOB binds require well-formed
  UTF-8 (raw bytes crashed the VM at the C-string boundary);
  integer binds range-check with the band instead of wrapping
  silently; UBIGINT extends the s64 band rule to wrappers with an
  in-band read lane; STRUCT binds accept string keys and raise on
  missing fields; MAP keyword keys stringify; DATE partial structs
  raise naming the field; multi-statement truncation and the
  empty-SQL result documented as duckdb's own query-boundary
  behavior.
- **v1.1 (2026-10-15)**: TIME_TZ read cell met (the decoder returned
  a table against its typed struct contract and raised; now
  UTC-normalised fields plus `:session-timezone-offset` in seconds);
  import-time lib guard now fires before the ffi context, so the
  installer-naming message is reachable on every failing path;
  ns-scale band rule and DECIMAL bind cut documented from the
  measured evidence.
- **v1.0 (2026-10-14)**: first written contract.
