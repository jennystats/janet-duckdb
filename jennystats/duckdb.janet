# jennystats/duckdb.janet  -  in-process duckdb for janet via core ffi (no jpm, no C build).
#
# Port of sbocq/janet-duckdb (MIT) adapted to a typed-contract stack:
# defn/typed contracts, no judge, single self-contained file, pinned C API.
# Attribution: type marshaling, handle discipline and vector decode derive
# from https://github.com/sbocq/janet-duckdb (MIT, (c) sbocq).
#
# Pinned C API: duckdb v1.5.6 (libduckdb.so, installer libs/install-duckdb.sh).
# The duckdb_result struct layout below is version-coupled to 1.5.x.
#
# Lib resolution: $DUCKDB_LIB -> ~/.local/lib/duckdb/libduckdb.so -> dlopen search.
# Import fails with an actionable message if none loads.
#
# Public API (thin, stable - everything else is internal):
#   (open path &opt config-map)   -> db      {:ptr :close}
#   (connect db)                  -> conn    {:ptr :close}
#   (query conn sql &opt params)   -> result  {:ptr :column-names :column-types :close}
#   (rows result &opt keywordize coll-type)   -> array of structs|tuples
#   (first-row result ...)        -> struct|tuple | nil
#   (columns result)               -> column-major arrays (xgboost feed)
#   (exec conn sql &opt params)    -> rows changed
#   (prepare conn sql)             -> stmt    {:ptr :param-names :param-types :close}
#   (execute stmt &opt params)     -> result  (positional tuple/array | named struct/table)
#   (library-version)              -> string
# Handles close via (:close handle) - `with` works. params optional in the
# variadic wrappers; typed cores carry the contracts.

(import jennystats/typed :prefix "")
(import jennystats/num) # pack-columns-f32 uses the janet-num C-to-C kernel

#==------------------------------------------------------------------------==#
# Lib resolution
#==------------------------------------------------------------------------==#

(defn/typed lib-path {:args [] :ret :string} []
  "Resolve libduckdb.so: $DUCKDB_LIB, then the pinned home path, then
  the bare soname for the system dlopen search."
  (def env (get (os/environ) "DUCKDB_LIB"))
  (if env env
    (let [home (get (os/environ) "HOME")
          pinned (string home "/.local/lib/duckdb/libduckdb.so")]
      (if (not (nil? (os/stat pinned))) pinned "libduckdb.so"))))

(def lib (lib-path))

# fail actionably at import time, before any defbind resolves lazily;
# the load probe runs before ffi/context so an absent lib never
# surfaces the raw dlopen error
(unless (try (do (ffi/native lib) true) ([_] false))
  (errorf "duckdb: cannot load %s  -  run libs/install-duckdb.sh or set $DUCKDB_LIB" lib))
(ffi/context lib)

#==------------------------------------------------------------------------==#
# Constants + structs (duckdb v1.5.6 C API)
#==------------------------------------------------------------------------==#

(def DuckDBSuccess 0)
(def DuckDBError 1)

(def duckdb-database (ffi/struct :ptr))
(def duckdb-connection (ffi/struct :ptr))
(def duckdb-config (ffi/struct :ptr))
(def duckdb-prepared-statement (ffi/struct :ptr))
# internal result struct - VERSION-COUPLED to 1.5.x
(def duckdb-result (ffi/struct :uint64 :uint64 :uint64 :ptr :ptr :ptr))
(def duckdb-date (ffi/struct :int32))
(def duckdb-date-struct (ffi/struct :int32 :int8 :int8))
(def duckdb-time (ffi/struct :int64))
(def duckdb-time-struct (ffi/struct :int8 :int8 :int8 :int32))
(def duckdb-time-tz (ffi/struct :uint64))
(def duckdb-time-tz-struct (ffi/struct duckdb-time-struct :int32))
(def duckdb-timestamp (ffi/struct :int64))
(def duckdb-timestamp-s (ffi/struct :int64))
(def duckdb-timestamp-ms (ffi/struct :int64))
(def duckdb-timestamp-ns (ffi/struct :int64))
(def duckdb-interval (ffi/struct :int32 :int32 :int64))
(def duckdb-hugeint (ffi/struct :uint64 :int64))
(def duckdb-uhugeint (ffi/struct :uint64 :uint64))
(def duckdb-decimal-t (ffi/struct :uint8 :uint8 duckdb-hugeint))
(def duckdb-string-t (ffi/struct :uint32 @[:uint8 12]))
(def duckdb-list-entry (ffi/struct :uint64 :uint64))

# duckdb_type enum values (subset we decode; unknown -> error)
(def DUCKDB_TYPE_INVALID 0)
(def DUCKDB_TYPE_BOOLEAN 1)
(def DUCKDB_TYPE_TINYINT 2)
(def DUCKDB_TYPE_SMALLINT 3)
(def DUCKDB_TYPE_INTEGER 4)
(def DUCKDB_TYPE_BIGINT 5)
(def DUCKDB_TYPE_UTINYINT 6)
(def DUCKDB_TYPE_USMALLINT 7)
(def DUCKDB_TYPE_UINTEGER 8)
(def DUCKDB_TYPE_UBIGINT 9)
(def DUCKDB_TYPE_FLOAT 10)
(def DUCKDB_TYPE_DOUBLE 11)
(def DUCKDB_TYPE_TIMESTAMP 12)
(def DUCKDB_TYPE_DATE 13)
(def DUCKDB_TYPE_TIME 14)
(def DUCKDB_TYPE_INTERVAL 15)
(def DUCKDB_TYPE_HUGEINT 16)
(def DUCKDB_TYPE_UHUGEINT 32)
(def DUCKDB_TYPE_VARCHAR 17)
(def DUCKDB_TYPE_BLOB 18)
(def DUCKDB_TYPE_DECIMAL 19)
(def DUCKDB_TYPE_TIMESTAMP_S 20)
(def DUCKDB_TYPE_TIMESTAMP_MS 21)
(def DUCKDB_TYPE_TIMESTAMP_NS 22)
(def DUCKDB_TYPE_ENUM 23)
(def DUCKDB_TYPE_LIST 24)
(def DUCKDB_TYPE_STRUCT 25)
(def DUCKDB_TYPE_MAP 26)
(def DUCKDB_TYPE_ARRAY 33)
(def DUCKDB_TYPE_UUID 27)
(def DUCKDB_TYPE_UNION 28)
(def DUCKDB_TYPE_BIT 29)
(def DUCKDB_TYPE_TIME_TZ 30)
(def DUCKDB_TYPE_TIMESTAMP_TZ 31)
(def DUCKDB_TYPE_ANY 34)
(def DUCKDB_TYPE_BIGNUM 35)
(def DUCKDB_TYPE_SQLNULL 36)

#==------------------------------------------------------------------------==#
# FFI bindings (C symbol names verbatim - no renames)
#==------------------------------------------------------------------------==#

(ffi/defbind duckdb_library_version :string [])
(ffi/defbind duckdb_create_config :int [config-out :ptr])
(ffi/defbind duckdb_set_config :int [config :ptr name :string value :string])
(ffi/defbind duckdb_destroy_config :void [config-ptr-ptr :ptr])
(ffi/defbind duckdb_open_ext :int [path :string db-out :ptr config :ptr err-out :ptr])
(ffi/defbind duckdb_close :void [db-out :ptr])
(ffi/defbind duckdb_connect :int [db :ptr conn-out :ptr])
(ffi/defbind duckdb_disconnect :void [conn-out :ptr])
(ffi/defbind duckdb_query :int [conn :ptr sql :string result-ptr :ptr])
(ffi/defbind duckdb_destroy_result :void [result-ptr :ptr])
(ffi/defbind duckdb_result_error :string [result-ptr :ptr])
(ffi/defbind duckdb_result_error_type :int [result-ptr :ptr])
(ffi/defbind duckdb_column_count :uint64 [result-ptr :ptr])
(ffi/defbind duckdb_column_name :string [result-ptr :ptr col :uint64])
(ffi/defbind duckdb_column_type :int [result-ptr :ptr col :uint64])
(ffi/defbind duckdb_column_logical_type :ptr [result-ptr :ptr col :uint64])
(ffi/defbind duckdb_rows_changed :uint64 [result-ptr :ptr])
(ffi/defbind duckdb_fetch_chunk :ptr [result duckdb-result])
(ffi/defbind duckdb_destroy_data_chunk :void [chunk :ptr])
(ffi/defbind duckdb_data_chunk_get_size :uint64 [chunk :ptr])
(ffi/defbind duckdb_data_chunk_get_vector :ptr [chunk :ptr col :uint64])
(ffi/defbind duckdb_vector_get_column_type :ptr [vector :ptr])
(ffi/defbind duckdb_vector_get_data :ptr [vector :ptr])
(ffi/defbind duckdb_vector_get_validity :ptr [vector :ptr])
(ffi/defbind duckdb_validity_row_is_valid :bool [mask :ptr row :uint64])
(ffi/defbind duckdb_list_vector_get_child :ptr [vector :ptr])
(ffi/defbind duckdb_struct_vector_get_child :ptr [vector :ptr index :uint64])
(ffi/defbind duckdb_array_vector_get_child :ptr [vector :ptr])
(ffi/defbind duckdb_string_t_data :ptr [string-ptr :ptr])
(ffi/defbind duckdb_free :void [ptr :ptr])
(ffi/defbind duckdb_from_date duckdb-date-struct [date duckdb-date])
(ffi/defbind duckdb_to_date duckdb-date [date duckdb-date-struct])
(ffi/defbind duckdb_from_time duckdb-time-struct [time duckdb-time])
(ffi/defbind duckdb_to_time duckdb-time [time duckdb-time-struct])
(ffi/defbind duckdb_create_time_tz duckdb-time-tz [micros :int64 offset :int32])
(ffi/defbind duckdb_from_time_tz duckdb-time-tz-struct [time duckdb-time-tz])
(ffi/defbind duckdb_hugeint_to_double :double [val duckdb-hugeint])
(ffi/defbind duckdb_uhugeint_to_double :double [val duckdb-uhugeint])
(ffi/defbind duckdb_prepare :int [conn :ptr sql :string stmt-out :ptr])
(ffi/defbind duckdb_prepare_error :string [stmt :ptr])
(ffi/defbind duckdb_destroy_prepare :void [stmt-out :ptr])
(ffi/defbind duckdb_nparams :uint64 [stmt :ptr])
(ffi/defbind duckdb_parameter_name :ptr [stmt :ptr idx :uint64])
(ffi/defbind duckdb_param_logical_type :ptr [stmt :ptr idx :uint64])
(ffi/defbind duckdb_bind_parameter_index :int [stmt :ptr idx-out :ptr name :string])
(ffi/defbind duckdb_bind_null :int [stmt :ptr idx :uint64])
(ffi/defbind duckdb_bind_value :int [stmt :ptr idx :uint64 value :ptr])
(ffi/defbind duckdb_clear_bindings :void [stmt :ptr])
(ffi/defbind duckdb_execute_prepared :int [stmt :ptr result-ptr :ptr])
(ffi/defbind duckdb_destroy_value :void [value-ptr-ptr :ptr])
(ffi/defbind duckdb_create_bool :ptr [input :bool])
(ffi/defbind duckdb_create_int8 :ptr [input :int8])
(ffi/defbind duckdb_create_int16 :ptr [input :int16])
(ffi/defbind duckdb_create_int32 :ptr [input :int32])
(ffi/defbind duckdb_create_int64 :ptr [input :int64])
(ffi/defbind duckdb_create_uint8 :ptr [input :uint8])
(ffi/defbind duckdb_create_uint16 :ptr [input :uint16])
(ffi/defbind duckdb_create_uint32 :ptr [input :uint32])
(ffi/defbind duckdb_create_uint64 :ptr [input :uint64])
(ffi/defbind duckdb_create_float :ptr [input :float])
(ffi/defbind duckdb_create_double :ptr [input :double])
(ffi/defbind duckdb_create_varchar :ptr [text :string])
(ffi/defbind duckdb_create_date :ptr [input duckdb-date])
(ffi/defbind duckdb_create_time :ptr [input duckdb-time])
(ffi/defbind duckdb_create_time_tz_value :ptr [input duckdb-time-tz])
(ffi/defbind duckdb_create_timestamp :ptr [input duckdb-timestamp])
(ffi/defbind duckdb_create_timestamp_s :ptr [input duckdb-timestamp-s])
(ffi/defbind duckdb_create_timestamp_ms :ptr [input duckdb-timestamp-ms])
(ffi/defbind duckdb_create_timestamp_ns :ptr [input duckdb-timestamp-ns])
(ffi/defbind duckdb_create_timestamp_tz :ptr [input duckdb-timestamp])
(ffi/defbind duckdb_create_interval :ptr [input duckdb-interval])
(ffi/defbind duckdb_create_null_value :ptr [])
(ffi/defbind duckdb_create_struct_value :ptr [type :ptr values :ptr])
(ffi/defbind duckdb_create_list_value :ptr [type :ptr values :ptr count :uint64])
(ffi/defbind duckdb_create_array_value :ptr [type :ptr values :ptr count :uint64])
(ffi/defbind duckdb_create_map_value :ptr [map-type :ptr keys :ptr values :ptr count :uint64])
(ffi/defbind duckdb_create_union_value :ptr [union-type :ptr tag-index :uint64 value :ptr])
(ffi/defbind duckdb_destroy_logical_type :void [type-ptr-ptr :ptr])
(ffi/defbind duckdb_get_type_id :int [type :ptr])
(ffi/defbind duckdb_decimal_internal_type :int [type :ptr])
(ffi/defbind duckdb_decimal_scale :uint8 [type :ptr])
(ffi/defbind duckdb_enum_internal_type :int [type :ptr])
(ffi/defbind duckdb_enum_dictionary_size :uint64 [type :ptr])
(ffi/defbind duckdb_enum_dictionary_value :ptr [type :ptr index :uint64])
(ffi/defbind duckdb_list_type_child_type :ptr [type :ptr])
(ffi/defbind duckdb_struct_type_child_count :uint64 [type :ptr])
(ffi/defbind duckdb_struct_type_child_name :ptr [type :ptr index :uint64])
(ffi/defbind duckdb_struct_type_child_type :ptr [type :ptr index :uint64])
(ffi/defbind duckdb_map_type_key_type :ptr [type :ptr])
(ffi/defbind duckdb_map_type_value_type :ptr [type :ptr])
(ffi/defbind duckdb_array_type_child_type :ptr [type :ptr])
(ffi/defbind duckdb_array_type_array_size :uint64 [type :ptr])
(ffi/defbind duckdb_union_type_member_count :uint64 [type :ptr])
(ffi/defbind duckdb_union_type_member_name :ptr [type :ptr index :uint64])
(ffi/defbind duckdb_union_type_member_type :ptr [type :ptr index :uint64])

#==------------------------------------------------------------------------==#
# Small ffi helpers
#==------------------------------------------------------------------------==#

(defn/typed deref-c-string-ptr {:args [:any] :ret :string} [char-ptr]
  "Read a char* handed back by duckdb as a janet string; ffi/read
  needs a pointer cell, so the raw pointer is wrapped first."
  # ffi/read :string expects a char** - wrap the char* in a ptr cell
  (ffi/read :string (ffi/write :ptr char-ptr)))

(defn/typed destroy-logical-type-ptr {:args [:any] :ret nil} [type-ptr]
  "Free a duckdb_logical_type through its destroy out-parameter."
  (duckdb_destroy_logical_type (ffi/write :ptr type-ptr)))

(defn/typed destroy-value-ptr {:args [:any] :ret nil} [value-ptr]
  "Free a duckdb_value through its destroy out-parameter."
  (duckdb_destroy_value (ffi/write :ptr value-ptr)))

(def n64-min (int/s64 math/int-min))
(def n64-max (int/s64 math/int-max))

(defn/typed janet-from-int64 {:args [:any] :ret :any} [s64]
  "int64 to a plain number while exact in the ±2^53 double band;
  the core s64 wrapper survives beyond it."
  # shove int64 into a double where safe; keep core/s64 beyond ±2^53
  (if (<= n64-min s64 n64-max) (int/to-number s64) s64))

(defn/typed janet-from-uint64 {:args [:any] :ret :any} [u64]
  "uint64 to a plain number while exact in the double band; the core
  u64 wrapper survives beyond it (the unsigned symmetric of the s64
  lane - a value the module binds, it can read)."
  (try (int/to-number u64) ([_] u64)))

#==------------------------------------------------------------------------==#
# Date/time conversions
#==------------------------------------------------------------------------==#

(defn/typed janet-date-to-parts {:args [:struct] :ret :tuple} [janet-date]
  "Split an os/date-style struct into [date time] part tuples; month
  and month-day stay 0-based, the form duckdb's converters take."
  (def {:year year :month month :month-day month-day
        :hours hour :minutes min :seconds sec :micros micros} janet-date)
  [(when year [year (inc month) (inc month-day)])
   (when hour [hour min sec (or micros 0)])])

(defn/typed janet-date-from-parts {:args [:tuple] :ret :struct} [[date time]]
  "Inverse of janet-date-to-parts: date and time part tuples back to
  a single struct; missing parts decode as empty values."
  (def d (if date
           (let [[year month day] date] {:year year :month (dec month) :month-day (dec day)})
           {}))
  (def t (if time
           (let [[hour min sec micros] time] {:hours hour :minutes min :seconds sec :micros micros})
           {}))
  (table/to-struct (merge d t)))

(defn/typed janet-to-date {:args [:struct] :ret :any} [janet-date]
  "Date fields of a janet date struct to a duckdb_date; raises when
  the struct carries no date fields or lacks one of :year :month
  :month-day."
  (each k [:year :month :month-day]
    (when (nil? (get janet-date k))
      (errorf "duckdb: date requires :year :month :month-day (0-based), missing %q in %q"
              k janet-date)))
  (def [date _] (janet-date-to-parts janet-date))
  (duckdb_to_date date))

(defn/typed janet-from-date {:args [:any] :ret :struct} [date]
  "duckdb_date to a janet date struct (date fields only)."
  (janet-date-from-parts [(duckdb_from_date date) nil]))

(defn/typed janet-to-time {:args [:struct] :ret :any} [janet-date]
  "Time fields of a janet date struct to a duckdb_time; raises when
  the struct carries no time fields."
  (def [_ time] (janet-date-to-parts janet-date))
  (if time (duckdb_to_time time)
    (errorf "duckdb: no time fields in %q" janet-date)))

(defn/typed janet-from-time {:args [:any] :ret :struct} [duckdb-time]
  "duckdb_time to a janet date struct (time fields only)."
  (janet-date-from-parts [nil (duckdb_from_time duckdb-time)]))

(defn/typed janet-to-time-tz {:args [:struct] :ret :any} [janet-date]
  "Time fields plus :timezone-offset to a duckdb_time_tz; the offset
  defaults to 0; raises without time fields."
  (def [_ time] (janet-date-to-parts janet-date))
  (if time
    (let [[micros] (duckdb_to_time time)]
      (duckdb_create_time_tz micros (or (janet-date :timezone-offset) 0)))
    (errorf "duckdb: no time fields in %q" janet-date)))

(defn/typed janet-from-time-tz {:args [:any] :ret :struct} [duckdb-time-tz]
  "duckdb_time_tz to a time struct normalised to UTC with fields
  wrapped into [0, 24h) (mod-24h), carrying the original offset as
  :session-timezone-offset."
  (let [[time-struct offset] (duckdb_from_time_tz duckdb-time-tz)
        [local-micros] (duckdb_to_time time-struct)
        utc-micros (mod (- local-micros (* offset 1000000)) (* 24 3600 1000000))
        [hours minutes seconds micros] (duckdb_from_time [utc-micros])]
    {:hours hours :minutes minutes :seconds seconds :micros micros
     :session-timezone-offset offset}))

(defn/typed janet-from-timestamp {:args [:any] :ret :number} [duckdb-timestamp]
  "duckdb timestamp (epoch micros) to a plain number."
  (int/to-number (first duckdb-timestamp)))

(defn/typed janet-from-timestamp-ns {:args [:any] :ret :any} [duckdb-timestamp]
  "duckdb ns timestamp to a plain number inside the ±2^53 band;
  the s64 wrapper survives beyond it."
  (janet-from-int64 (first duckdb-timestamp)))

(defn/typed janet-from-interval {:args [:any] :ret :struct} [duckdb-interval]
  "duckdb interval to {:months :days :micros}."
  (def [months days micros] duckdb-interval)
  {:months months :days days :micros (janet-from-int64 micros)})

#==------------------------------------------------------------------------==#
# Type system: id -> key, key -> marshaling meta
#==------------------------------------------------------------------------==#

(defn/typed janet-bytes-from-string {:args [:any] :ret :tuple} [duckdb-string]
  "string_t to a byte tuple: up to 12 bytes are inlined in the
  struct, longer values go through the data pointer."
  # string_t: len <= 12 inlined in the struct, else data pointer
  (def [len inlined] duckdb-string)
  (if (<= len 12)
    (tuple/slice inlined 0 len)
    (slice (ffi/read @[:uint8 len] (duckdb_string_t_data (ffi/write duckdb-string-t duckdb-string))))))

(defn/typed janet-from-string {:args [:any] :ret :string} [duckdb-string]
  "string_t to a janet string."
  (string/from-bytes ;(janet-bytes-from-string duckdb-string)))

(defn/typed janet-from-blob {:args [:any] :ret :tuple} [duckdb-string]
  "string_t to a byte tuple (blob payload)."
  (janet-bytes-from-string duckdb-string))

(defn/typed utf8-valid? {:args [:any] :ret :boolean} [text]
  "Well-formed UTF-8 check: rejects truncated sequences, overlong
  encodings, surrogates and code points above U+10FFFF."
  (def b (string/bytes text))
  (def n (length b))
  (var i 0)
  (var ok true)
  (while (and ok (< i n))
    (def c (b i))
    (cond
      (< c 0x80) (++ i)
      (<= 0xC2 c 0xDF)
      (if (and (< (inc i) n) (<= 0x80 (b (inc i)) 0xBF)) (+= i 2) (set ok false))
      (<= 0xE0 c 0xEF)
      (if (and (< (+ i 2) n)
               (<= 0x80 (b (inc i)) 0xBF) (<= 0x80 (b (+ i 2)) 0xBF)
               (not (or (and (= c 0xE0) (< (b (inc i)) 0xA0))
                        (and (= c 0xED) (>= (b (inc i)) 0xA0)))))
        (+= i 3) (set ok false))
      (<= 0xF0 c 0xF4)
      (if (and (< (+ i 3) n)
               (<= 0x80 (b (inc i)) 0xBF) (<= 0x80 (b (+ i 2)) 0xBF)
               (<= 0x80 (b (+ i 3)) 0xBF)
               (not (or (and (= c 0xF0) (< (b (inc i)) 0x90))
                        (and (= c 0xF4) (> (b (inc i)) 0x8F)))))
        (+= i 4) (set ok false))
      (set ok false)))
  ok)

(defn/typed check-utf8 {:args [:any :string] :ret :string} [janet-value type-name]
  "Bind-boundary UTF-8 gate for VARCHAR/BLOB parameters; raw-byte
  binds and embedded NULs raise instead of reaching duckdb's C
  string boundary."
  (unless (string? janet-value)
    (errorf "duckdb: %s parameters must be valid UTF-8 strings, got %q" type-name janet-value))
  (when (index-of 0 (string/bytes janet-value))
    (errorf "duckdb: %s bind contains an embedded NUL - the varchar boundary is a C string, got %q"
            type-name janet-value))
  (unless (utf8-valid? janet-value)
    (errorf "duckdb: %s parameters must be valid UTF-8 strings, got %q" type-name janet-value))
  janet-value)

(defn/typed type-id-to-key {:args [:number] :ret :keyword} [type-id]
  "duckdb type id to the module's type keyword; raises on ids outside
  the decoded subset."
  (case type-id
    DUCKDB_TYPE_INVALID :unknown
    DUCKDB_TYPE_BOOLEAN :bool
    DUCKDB_TYPE_TINYINT :tinyint
    DUCKDB_TYPE_SMALLINT :smallint
    DUCKDB_TYPE_INTEGER :int
    DUCKDB_TYPE_BIGINT :bigint
    DUCKDB_TYPE_UTINYINT :utinyint
    DUCKDB_TYPE_USMALLINT :usmallint
    DUCKDB_TYPE_UINTEGER :uint
    DUCKDB_TYPE_UBIGINT :ubigint
    DUCKDB_TYPE_FLOAT :float
    DUCKDB_TYPE_DOUBLE :double
    DUCKDB_TYPE_TIMESTAMP :timestamp
    DUCKDB_TYPE_DATE :date
    DUCKDB_TYPE_TIME :time
    DUCKDB_TYPE_INTERVAL :interval
    DUCKDB_TYPE_HUGEINT :hugeint
    DUCKDB_TYPE_UHUGEINT :uhugeint
    DUCKDB_TYPE_VARCHAR :varchar
    DUCKDB_TYPE_BLOB :blob
    DUCKDB_TYPE_DECIMAL :decimal
    DUCKDB_TYPE_TIMESTAMP_S :timestamp_s
    DUCKDB_TYPE_TIMESTAMP_MS :timestamp_ms
    DUCKDB_TYPE_TIMESTAMP_NS :timestamp_ns
    DUCKDB_TYPE_ENUM :enum
    DUCKDB_TYPE_LIST :list
    DUCKDB_TYPE_STRUCT :struct
    DUCKDB_TYPE_MAP :map
    DUCKDB_TYPE_ARRAY :array
    DUCKDB_TYPE_UUID :uuid
    DUCKDB_TYPE_UNION :union
    DUCKDB_TYPE_BIT :bit
    DUCKDB_TYPE_TIME_TZ :time_tz
    DUCKDB_TYPE_TIMESTAMP_TZ :timestamp_tz
    DUCKDB_TYPE_ANY :any
    DUCKDB_TYPE_BIGNUM :bignum
    DUCKDB_TYPE_SQLNULL :sqlnull
    (errorf "duckdb: unknown type id %q" type-id)))

(defn/typed type-key-meta {:args [:keyword] :ret :struct} [type-key]
  "Type keyword to marshaling meta: simple types carry their ffi type
  and value cast; complex types are flagged for recursive decode.
  Raises on unknown keywords."
  # simple types: {:simple true :ffi-type f :from-value j}; complex: {:simple false}
  (def [ffi-type from-value]
    (case type-key
      :bool [:bool nil]
      :tinyint [:int8 nil]
      :smallint [:int16 nil]
      :int [:int32 nil]
      :bigint [:int64 janet-from-int64]
      :utinyint [:uint8 nil]
      :usmallint [:uint16 nil]
      :uint [:uint32 nil]
      :ubigint [:uint64 janet-from-uint64]
      :float [:float nil]
      :double [:double nil]
      :timestamp [duckdb-timestamp janet-from-timestamp]
      :date [duckdb-date janet-from-date]
      :time [duckdb-time janet-from-time]
      :interval [duckdb-interval janet-from-interval]
      :hugeint [duckdb-hugeint duckdb_hugeint_to_double]
      :uhugeint [duckdb-uhugeint duckdb_uhugeint_to_double]
      :varchar [duckdb-string-t janet-from-string]
      :blob [duckdb-string-t janet-from-blob]
      :decimal [nil nil]
      :timestamp_s [duckdb-timestamp-s janet-from-timestamp]
      :timestamp_ms [duckdb-timestamp-ms janet-from-timestamp]
      :timestamp_ns [duckdb-timestamp-ns janet-from-timestamp-ns]
      :enum [nil nil]
      :list [nil nil]
      :struct [nil nil]
      :map [nil nil]
      :array [nil nil]
      :uuid [duckdb-hugeint nil]
      :union [nil nil]
      :bit [nil nil]
      :time_tz [duckdb-time-tz janet-from-time-tz]
      :timestamp_tz [duckdb-timestamp janet-from-timestamp]
      :any [nil nil]
      :unknown [nil nil]
      :bignum [nil nil]
      :sqlnull [nil nil]
      (errorf "duckdb: unknown type key %q" type-key)))
  (if ffi-type
    {:simple true :type-key type-key :ffi-type ffi-type :from-value from-value}
    {:simple false :type-key type-key}))

(defn/typed logical-type-from-ptr {:args [:any] :ret :struct} [type-ptr]
  "duckdb_logical_type to the full recursive meta: child types for
  list/array, key and value types for map, members for struct and
  union, dictionary and scale for enum and decimal. The caller owns
  the pointer; only fetched children are destroyed here."
  (def type-key (type-id-to-key (duckdb_get_type_id type-ptr)))
  (def meta (type-key-meta type-key))
  (if (meta :simple) meta
    (case type-key
      :decimal
      {:simple false :type-key type-key
       :scale (duckdb_decimal_scale type-ptr)
       :internal-type-key (type-id-to-key (duckdb_decimal_internal_type type-ptr))}
      :enum
      (let [size (int/to-number (duckdb_enum_dictionary_size type-ptr))
            dict (table/new size)]
        (for i 0 size
          (def val-ptr (duckdb_enum_dictionary_value type-ptr i))
          (defer (duckdb_free val-ptr)
            (put dict i (deref-c-string-ptr val-ptr))))
        {:simple false :type-key type-key
         :dict (table/to-struct dict)
         :internal-type-key (type-id-to-key (duckdb_enum_internal_type type-ptr))})
      :list
      (let [child (duckdb_list_type_child_type type-ptr)]
        (defer (destroy-logical-type-ptr child)
          {:simple false :type-key type-key :child-type (logical-type-from-ptr child)}))
      :struct
      (let [count (int/to-number (duckdb_struct_type_child_count type-ptr))
            keys (array/new count)
            types (array/new count)]
        (for i 0 count
          (def name-ptr (duckdb_struct_type_child_name type-ptr i))
          (defer (duckdb_free name-ptr)
            (array/push keys (keyword (deref-c-string-ptr name-ptr))))
          (def child (duckdb_struct_type_child_type type-ptr i))
          (defer (destroy-logical-type-ptr child)
            (array/push types (logical-type-from-ptr child))))
        {:simple false :type-key type-key
         :keys (tuple/slice keys) :key-types (tuple/slice types)})
      :map
      {:simple false :type-key type-key
       :key-type (let [k (duckdb_map_type_key_type type-ptr)]
                   (defer (destroy-logical-type-ptr k) (logical-type-from-ptr k)))
       :val-type (let [v (duckdb_map_type_value_type type-ptr)]
                   (defer (destroy-logical-type-ptr v) (logical-type-from-ptr v)))}
      :array
      (let [child (duckdb_array_type_child_type type-ptr)]
        (defer (destroy-logical-type-ptr child)
          {:simple false :type-key type-key
           :array-size (int/to-number (duckdb_array_type_array_size type-ptr))
           :child-type (logical-type-from-ptr child)}))
      :union
      (let [count (int/to-number (duckdb_union_type_member_count type-ptr))
            tags (array/new count)
            types (array/new count)]
        (for i 0 count
          (def name-ptr (duckdb_union_type_member_name type-ptr i))
          (defer (duckdb_free name-ptr)
            (array/push tags (keyword (deref-c-string-ptr name-ptr))))
          (def child (duckdb_union_type_member_type type-ptr i))
          (defer (destroy-logical-type-ptr child)
            (array/push types (logical-type-from-ptr child))))
        {:simple false :type-key type-key
         :tag-keys (tuple/slice tags) :tag-types (tuple/slice types)})
      :unknown
      {:simple false :type-key type-key}
      (errorf "duckdb: type not supported: %q" type-key))))

(defn/typed logical-type-simplify {:args [:struct] :ret :any} [ltype]
  "Recursive type meta to the compact spec shape used in
  :param-types and column descriptions: a bare keyword for simple
  types, [keyword shape] for complex ones."
  (if (ltype :simple) (ltype :type-key)
    [(ltype :type-key)
     (case (ltype :type-key)
       :struct {:keys (ltype :keys)
                :key-types (tuple/slice (map logical-type-simplify (ltype :key-types)))}
       :union {:tag-keys (ltype :tag-keys)
               :tag-types (tuple/slice (map logical-type-simplify (ltype :tag-types)))}
       :list {:child-type (logical-type-simplify (ltype :child-type))}
       :map {:key-type (logical-type-simplify (ltype :key-type))
             :val-type (logical-type-simplify (ltype :val-type))}
       :array {:child-type (logical-type-simplify (ltype :child-type))
               :array-size (ltype :array-size)}
       :decimal {:scale (ltype :scale) :internal-type-key (ltype :internal-type-key)}
       :enum {:dict (ltype :dict) :internal-type-key (ltype :internal-type-key)}
       {})]))

#==------------------------------------------------------------------------==#
# Vector decode (chunk -> janet arrays)
#==------------------------------------------------------------------------==#

(defn/typed janet-array-from-data {:args [:any :any :number :number :any :any] :ret :array} [data-ptr ffi-type offset len validity-mask cast-fn]
  "Read len raw values at offset from a vector's data pointer;
  invalid rows decode as nil, the per-type cast (identity when none)
  applies elementwise."
  (def sz (ffi/size ffi-type))
  (if (nil? validity-mask)
    (let [vals (ffi/read @[ffi-type len] data-ptr (* offset sz))]
      (if cast-fn
        (let [out (array/new len)]
          (eachp [i v] vals (put out i (cast-fn v))) out)
        vals))
    (let [out (array/new len)
          cast-fn (or cast-fn identity)]
      (var row-idx offset)
      (for i 0 len
        (put out i (when (duckdb_validity_row_is_valid validity-mask row-idx)
                     (cast-fn (ffi/read ffi-type data-ptr (* row-idx sz)))))
        (++ row-idx))
      out)))

(defn/typed janet-array-from-vector {:args [:any :number :number] :ret :array} [vector-ptr offset len]
  "Decode one vector slice to a janet array, recursing through
  list, struct, map, array and union children; decimal and enum run
  through their internal representation. Raises on unsupported
  types."
  (def ltype-ptr (duckdb_vector_get_column_type vector-ptr))
  (defer (destroy-logical-type-ptr ltype-ptr)
    (def ltype (logical-type-from-ptr ltype-ptr))
    (def validity-mask (duckdb_vector_get_validity vector-ptr))
    (def data-ptr (duckdb_vector_get_data vector-ptr))
    (if (ltype :simple)
      (janet-array-from-data data-ptr (ltype :ffi-type) offset len validity-mask (ltype :from-value))
      (case (ltype :type-key)
        :decimal
        (let [scale (math/pow 10 (ltype :scale))
              internal (type-key-meta (ltype :internal-type-key))]
          (janet-array-from-data data-ptr (internal :ffi-type) offset len validity-mask
                                 (fn [v] (/ ((or (internal :from-value) identity) v) scale))))
        :enum
        (let [internal (type-key-meta (ltype :internal-type-key))
              dict (ltype :dict)]
          (janet-array-from-data data-ptr (internal :ffi-type) offset len validity-mask
                                 (fn [v] (get dict v))))
        :list
        (let [child (duckdb_list_vector_get_child vector-ptr)]
          (seq [entry :in (janet-array-from-data data-ptr duckdb-list-entry offset len validity-mask nil)]
            (when entry
              (def [eoffset elen] entry)
              (janet-array-from-vector child (int/to-number eoffset) (int/to-number elen)))))
        :struct
        (let [keys (ltype :keys)
              size (length keys)
              vals (array/new size)]
          (for i 0 size
            (array/push vals (janet-array-from-vector
                               (duckdb_struct_vector_get_child vector-ptr i) offset len)))
          (var row-idx (dec offset))
          (seq [i :range [0 len]]
            (when (duckdb_validity_row_is_valid validity-mask (++ row-idx))
              (struct ;(mapcat array keys (map |(get $0 i) vals))))))
        :map
        (let [child (duckdb_list_vector_get_child vector-ptr)]
          (seq [entry :in (janet-array-from-data data-ptr duckdb-list-entry offset len validity-mask nil)]
            (when entry
              (def [eoffset elen] entry)
              (def kvs (janet-array-from-vector child (int/to-number eoffset) (int/to-number elen)))
              (def tbl (table/new (length kvs)))
              (loop [{:key k :value v} :in kvs] (put tbl k v))
              tbl)))
        :array
        (let [array-size (ltype :array-size)
              child (duckdb_array_vector_get_child vector-ptr)]
          (var row-idx (dec offset))
          (seq [child-offset :range [offset (+ offset (* len array-size)) array-size]]
            (when (duckdb_validity_row_is_valid validity-mask (++ row-idx))
              (tuple/slice (janet-array-from-vector child child-offset array-size)))))
        :union
        (let [tag-keys (ltype :tag-keys)
              size (inc (length tag-keys))
              vals (array/new size)]
          (for i 0 size
            (array/push vals (janet-array-from-vector
                               (duckdb_struct_vector_get_child vector-ptr i) offset len)))
          (def tag-ids (vals 0))
          (var row-idx (dec offset))
          (seq [i :range [0 len]]
            (when (duckdb_validity_row_is_valid validity-mask (++ row-idx))
              (def tag-id (get tag-ids i))
              [(get tag-keys tag-id) (get (get vals (inc tag-id)) i)])))
        (errorf "duckdb: type not supported: %q" (ltype :type-key))))))

#==------------------------------------------------------------------------==#
# Result handles
#==------------------------------------------------------------------------==#

(defn/typed make-result {:args [:any] :ret :struct} [result-ptr]
  "Wrap a result pointer in the result handle: column names and type
  keys, the value-copied struct for chunk streaming, the fetch cache,
  and a guarded idempotent :close (:assert-valid raises on reads
  after close)."
  (def column-count (int/to-number (duckdb_column_count result-ptr)))
  (def names (array/new column-count))
  (def types (array/new column-count))
  (loop [i :range [0 column-count]]
    (array/push names (duckdb_column_name result-ptr i))
    (array/push types (type-id-to-key (duckdb_column_type result-ptr i))))
  (var valid true)
  {:ptr result-ptr
   :column-count column-count
   :column-names (tuple/slice names)
   :column-types (tuple/slice types)
   :struct (ffi/read duckdb-result result-ptr)
   :cache @{}
   :close (fn [self]
            (when valid
              (duckdb_destroy_result (self :ptr))
              (set valid false))
            nil)
   :assert-valid (fn [_]
                   (unless valid
                     (error "duckdb: result already closed"))
                   nil)})

(defn/typed rows-changed {:args [:struct] :ret :number} [result]
  "Rows-changed count of a result; raises after close."
  ((result :assert-valid) result)
  (int/to-number (duckdb_rows_changed (result :ptr))))

(defn/typed fetch-columns {:args [:struct] :ret :struct} [result]
  "Column fetch as
  {:column-names :column-types :columns :row-count}; chunk streaming
  is one-shot in duckdb, so the first fetch is cached and every
  later call returns the cache: the result handle reads like a
  value. Raises after close."
  # chunk streaming is one-shot in duckdb; cache the first fetch so a result
  # handle behaves like a value (rows/first-row can be called repeatedly)
  ((result :assert-valid) result)
  (def cache (result :cache))
  (or (cache :columns)
      (let [columns
            (do
              (def column-count (result :column-count))
              (def columns (array/new column-count))
              (for i 0 column-count (array/push columns @[]))
              (loop [chunk :iterate (duckdb_fetch_chunk (result :struct))
                     :until (nil? chunk)]
                (defer (duckdb_destroy_data_chunk (ffi/write :ptr chunk))
                  # vector memory, including the >12-byte string_t :ptr
                  # lane, is valid only inside this defer scope; hoisting
                  # the decode out of the chunk loop would read freed
                  # memory after chunk release
                  (def size (int/to-number (duckdb_data_chunk_get_size chunk)))
                  (for col 0 column-count
                    (array/concat (columns col)
                                  (janet-array-from-vector (duckdb_data_chunk_get_vector chunk col) 0 size)))))
              {:column-count column-count
               :column-names (result :column-names)
               :column-types (result :column-types)
               :columns columns
               :row-count (if (zero? column-count) 0 (length (columns 0)))})
            _ (put cache :columns columns)]
        columns)))

(defn/typed columns-to-rows {:args [:struct :boolean :keyword] :ret :array} [cols keywordize coll-type]
  "Column arrays to an array of rows: structs (column names
  keywordised on request) or tuples; any other coll-type raises."
  (def {:column-count column-count :column-names names :columns columns :row-count row-count} cols)
  (def dict-keys (if keywordize (map keyword names) names))
  (def rows (array/new row-count))
  (case coll-type
    :struct
    (let [row (table/new column-count)]
      (for r 0 row-count
        (eachp [c column] columns
          (put row (get dict-keys c) (get column r)))
        (array/push rows (table/to-struct row))
        (table/clear row)))
    :tuple
    (let [row (array/new column-count)]
      (for r 0 row-count
        (eachp [_ column] columns (array/push row (get column r)))
        (array/push rows (tuple/slice row))
        (array/clear row)))
    (errorf "duckdb: coll-type must be :struct or :tuple, got %q" coll-type))
  rows)

(defn/typed result-rows {:args [:struct :boolean :keyword] :ret :array} [result keywordize coll-type]
  "Rows core: fetch (memoised), then convert; raises after close."
  ((result :assert-valid) result)
  (columns-to-rows (fetch-columns result) keywordize coll-type))

(defn/typed result-first {:args [:struct :boolean :keyword] :ret :any} [result keywordize coll-type]
  "First-row core: the first row, or nil on an empty result."
  (def rows (result-rows result keywordize coll-type))
  (if (empty? rows) nil (rows 0)))

(defn/typed describe-columns {:args [:struct :boolean] :ret :struct} [result logical?]
  "{:column-count :column-names :column-types} of a result; with
  logical? the types carry their full nested shape (struct keys,
  list children, enum dictionaries). Raises after close."
  ((result :assert-valid) result)
  {:column-count (result :column-count)
   :column-names (result :column-names)
   :column-types
   (if logical?
     (let [result-ptr (result :ptr)]
       (tuple/slice
         (seq [i :range [0 (result :column-count)]]
           (def ltype-ptr (duckdb_column_logical_type result-ptr i))
           (defer (destroy-logical-type-ptr ltype-ptr)
             (logical-type-simplify (logical-type-from-ptr ltype-ptr))))))
     (result :column-types))})

#==------------------------------------------------------------------------==#
# Value creation (janet -> duckdb_value, for binding)
#==------------------------------------------------------------------------==#

# plain-double bands per integer type; wrappers (int/s64, int/u64)
# carry exact values and pass through to the native validator
(def int-ranges
  {:tinyint [-128 127] :smallint [-32768 32767]
   :int [-2147483648 2147483647]
   :bigint [-9007199254740992 9007199254740992]
   :utinyint [0 255] :usmallint [0 65535] :uint [0 4294967295]
   :ubigint [0 9007199254740992]})

(defn/typed check-int-range {:args [:any :keyword] :ret :any} [janet-value type-key]
  "Range gate for integer binds: a plain number must be finite, whole
  and inside the type's band - each failure raises naming the value
  and the requirement; wrapped int/s64 and int/u64 values pass
  through to the native validator for exact beyond-band binds."
  (def [lo hi] (get int-ranges type-key [nil nil]))
  (def type-name (string/ascii-upper (string type-key)))
  (when (number? janet-value)
    (cond
      (or (nan? janet-value) (= math/inf janet-value) (= (- math/inf) janet-value))
      (errorf "duckdb: %s bind %q is not finite - no integer conversion" type-name janet-value)
      (not= janet-value (math/floor janet-value))
      (errorf "duckdb: %s bind %q is not an integer" type-name janet-value)
      (not (and (>= janet-value lo) (<= janet-value hi)))
      (errorf "duckdb: %s bind %q out of range [%d, %d]; wrap exact beyond-band values with int/s64 or int/u64"
              type-name janet-value lo hi)))
  janet-value)

(defn/typed struct-field-value {:args [:any :any] :ret :any} [janet-value k]
  "Declared struct field lookup accepting keyword and string keys
  (the json decode shape); a field absent in both key forms raises
  instead of binding NULL. A present field binds its value, false
  included - the lookup tests presence, never value truthiness."
  (if (index-of k (keys janet-value))
    (get janet-value k)
    (if (index-of (string k) (keys janet-value))
      (get janet-value (string k))
      (errorf "duckdb: struct field %q missing from %q" k janet-value))))
(defn/typed janet-to-duckdb-value {:args [:any :any :any] :ret :any} [janet-value simplified-type logical-type-ptr]
  "Encode a janet value to a duckdb_value under the parameter's
  simplified logical type; nil encodes NULL, as does the :null
  keyword (json decode's null shape, for round-trip fidelity). Simple
  types go to their scalar constructors, complex types recurse. An
  unknown type raises with the add-a-cast-in-SQL hint; the caller
  owns the returned pointer and must destroy it."
  # returns a duckdb_value ptr; caller must destroy-value-ptr it
  (cond
    (or (nil? janet-value) (= janet-value :null)) (duckdb_create_null_value)

    (keyword? simplified-type)
    (case simplified-type
      :bool (if (boolean? janet-value)
             (duckdb_create_bool janet-value)
             (errorf "duckdb: BOOLEAN bind %q is not a boolean" janet-value))
      :tinyint (duckdb_create_int8 (check-int-range janet-value :tinyint))
      :smallint (duckdb_create_int16 (check-int-range janet-value :smallint))
      :int (duckdb_create_int32 (check-int-range janet-value :int))
      :bigint (duckdb_create_int64 (check-int-range janet-value :bigint))
      :utinyint (duckdb_create_uint8 (check-int-range janet-value :utinyint))
      :usmallint (duckdb_create_uint16 (check-int-range janet-value :usmallint))
      :uint (duckdb_create_uint32 (check-int-range janet-value :uint))
      :ubigint (duckdb_create_uint64 (check-int-range janet-value :ubigint))
      :float (duckdb_create_float janet-value)
      :double (duckdb_create_double janet-value)
      :varchar (duckdb_create_varchar (check-utf8 janet-value "VARCHAR"))
      :blob (duckdb_create_varchar (check-utf8 janet-value "BLOB"))
      :date (duckdb_create_date (janet-to-date janet-value))
      :time (duckdb_create_time (janet-to-time janet-value))
      :time_tz (duckdb_create_time_tz_value (janet-to-time-tz janet-value))
      :timestamp (duckdb_create_timestamp [janet-value])
      :timestamp_tz (duckdb_create_timestamp_tz [janet-value])
      :timestamp_s (duckdb_create_timestamp_s [janet-value])
      :timestamp_ms (duckdb_create_timestamp_ms [janet-value])
      :timestamp_ns (duckdb_create_timestamp_ns [janet-value])
      :interval (let [{:months m :days d :micros u} janet-value]
                  (duckdb_create_interval [m d u]))
      (errorf "duckdb: unsupported simple type for binding: %q" simplified-type))

    (tuple? simplified-type)
    (let [[type-key meta] simplified-type]
      (case type-key
        :struct
        (let [keys (meta :keys)
              types (meta :key-types)
              count (length keys)
              ptrs (array/new count)]
          (defer (each v ptrs (destroy-value-ptr v))
            (for i 0 count
              (def child-ptr (duckdb_struct_type_child_type logical-type-ptr i))
              (defer (destroy-logical-type-ptr child-ptr)
                (array/push ptrs
                            (janet-to-duckdb-value (struct-field-value janet-value (get keys i))
                                                   (get types i) child-ptr))))
            (duckdb_create_struct_value logical-type-ptr (ffi/write @[:ptr count] ptrs))))
        :list
        (let [len (length janet-value)
              child-meta (meta :child-type)
              child-ptr (duckdb_list_type_child_type logical-type-ptr)]
          (defer (destroy-logical-type-ptr child-ptr)
            (if (zero? len)
              (duckdb_create_list_value child-ptr (ffi/write @[:ptr 0] @[]) 0)
              (let [ptrs (array/new len)]
                (defer (each v ptrs (destroy-value-ptr v))
                  (each v janet-value
                    (array/push ptrs (janet-to-duckdb-value v child-meta child-ptr)))
                  (duckdb_create_list_value child-ptr (ffi/write @[:ptr len] ptrs) len))))))
        :map
        (let [count (length janet-value)]
          (if (zero? count)
            (duckdb_create_map_value logical-type-ptr (ffi/write @[:ptr 0] @[])
                                      (ffi/write @[:ptr 0] @[]) 0)
            (let [key-ptr (duckdb_map_type_key_type logical-type-ptr)
                  val-ptr (duckdb_map_type_value_type logical-type-ptr)]
              (defer (do (destroy-logical-type-ptr key-ptr) (destroy-logical-type-ptr val-ptr))
                (def key-ptrs (array/new count))
                (def val-ptrs (array/new count))
                (defer (do (each v key-ptrs (destroy-value-ptr v))
                           (each v val-ptrs (destroy-value-ptr v)))
                  (eachp [k v] janet-value
                    (when (= k :null)
                      (error "duckdb: MAP keys cannot be NULL - the :null keyword is the json NULL shape; bind the string \"null\" to carry the text"))
                    (array/push key-ptrs (janet-to-duckdb-value (if (keyword? k) (string k) k)
                                                               (meta :key-type) key-ptr))
                    (array/push val-ptrs (janet-to-duckdb-value v (meta :val-type) val-ptr)))
                  (duckdb_create_map_value logical-type-ptr
                                           (ffi/write @[:ptr count] key-ptrs)
                                           (ffi/write @[:ptr count] val-ptrs)
                                           count))))))
        :array
        (let [expected (meta :array-size)]
          (unless (= (length janet-value) expected)
            (errorf "duckdb: array requires %d elements, got %d" expected (length janet-value)))
          (def child-ptr (duckdb_array_type_child_type logical-type-ptr))
          (defer (destroy-logical-type-ptr child-ptr)
            (def ptrs (array/new expected))
            (defer (each v ptrs (destroy-value-ptr v))
              (each v janet-value
                (array/push ptrs (janet-to-duckdb-value v (meta :child-type) child-ptr)))
              (duckdb_create_array_value child-ptr (ffi/write @[:ptr expected] ptrs) expected))))
        :union
        (let [tag-keys (meta :tag-keys)
              [tag value] janet-value
              tag-idx (index-of tag tag-keys)]
          (when (nil? tag-idx)
            (errorf "duckdb: union tag %q not found" tag))
          (def member-ptr (duckdb_union_type_member_type logical-type-ptr tag-idx))
          (defer (destroy-logical-type-ptr member-ptr)
            (def duckdb-val (janet-to-duckdb-value value (get (meta :tag-types) tag-idx) member-ptr))
            (duckdb_create_union_value logical-type-ptr tag-idx duckdb-val)))
        :unknown
        (errorf "duckdb: parameter type unknown  -  add a cast in SQL (e.g. ?::INTEGER)")
        (errorf "duckdb: unsupported complex type for binding: %q" type-key)))

    (errorf "duckdb: bad simplified type %q" simplified-type)))

#==------------------------------------------------------------------------==#
# Prepared statements
#==------------------------------------------------------------------------==#

(defn/typed bind {:args [:struct :number :any] :ret nil} [stmt param-idx janet-value]
  "Positional 1-based bind of one parameter; nil binds NULL; raises
  when the index exceeds the statement's param count and after the
  statement is closed."
  ((stmt :assert-valid) stmt)
  (def prepared-ptr (stmt :ptr))
  (unless (and (pos? param-idx) (<= param-idx (stmt :param-count)))
    (errorf "duckdb: parameter index %d out of range (statement has %d params)"
            param-idx (stmt :param-count)))
  (def cached-type (get (stmt :param-types) (dec param-idx)))
  (if (nil? janet-value)
    (when (= (duckdb_bind_null prepared-ptr param-idx) DuckDBError)
      (errorf "duckdb: failed to bind NULL to parameter %d" param-idx))
    (let [ltype-ptr (duckdb_param_logical_type prepared-ptr param-idx)]
      (defer (destroy-logical-type-ptr ltype-ptr)
        (def value-ptr (janet-to-duckdb-value janet-value cached-type ltype-ptr))
        (defer (destroy-value-ptr value-ptr)
          (when (= (duckdb_bind_value prepared-ptr param-idx value-ptr) DuckDBError)
            (errorf "duckdb: failed to bind parameter %d" param-idx)))))))

(defn/typed bind-named {:args [:struct :any :any] :ret nil} [stmt param-name janet-value]
  "Resolve a parameter name to its index, then bind; raises when the
  name is absent or after the statement is closed."
  ((stmt :assert-valid) stmt)
  (def idx-ptr (ffi/write :uint64 0))
  (when (= (duckdb_bind_parameter_index (stmt :ptr) idx-ptr (string param-name)) DuckDBError)
    (errorf "duckdb: parameter %q not found" param-name))
  (bind stmt (int/to-number (ffi/read :uint64 idx-ptr)) janet-value))

(defn/typed prepare {:args [:struct :string] :ret :struct} [conn sql]
  "SQL to a stmt handle
  {:ptr :param-count :param-names :param-types} with a guarded
  idempotent :close; a prepare failure raises with duckdb's prepare
  error, and use after close raises on both ends."
  ((conn :assert-valid) conn)
  (def stmt-out (ffi/write :ptr (ffi/write duckdb-prepared-statement [nil])))
  (when (= (duckdb_prepare (conn :ptr) sql stmt-out) DuckDBError)
    (errorf "duckdb: %s" (duckdb_prepare_error (ffi/read :ptr stmt-out))))
  (def prepared-ptr (ffi/read :ptr stmt-out))
  (def param-count (int/to-number (duckdb_nparams prepared-ptr)))
  (def names (array/new param-count))
  (def types (array/new param-count))
  (for i 1 (inc param-count)
    (def name-ptr (duckdb_parameter_name prepared-ptr i))
    (defer (duckdb_free name-ptr)
      (array/push names (keyword (deref-c-string-ptr name-ptr))))
    (def ltype-ptr (duckdb_param_logical_type prepared-ptr i))
    (defer (destroy-logical-type-ptr ltype-ptr)
      (array/push types (logical-type-simplify (logical-type-from-ptr ltype-ptr)))))
  (var valid true)
  {:ptr prepared-ptr
   :param-count param-count
   :param-names (tuple/slice names)
   :param-types (tuple/slice types)
   :close (fn [self]
            (when valid
              (duckdb_destroy_prepare stmt-out)
              (set valid false))
            nil)
   :assert-valid (fn [_]
                   (unless valid
                     (error "duckdb: stmt already closed"))
                   nil)})

(defn/typed execute* {:args [:struct :any] :ret :struct} [stmt params]
  "Bind params - positional for tuple/array, named for
  struct/table - execute, return a result handle; raises after the
  statement is closed; duckdb's execute error raises after cleanup."
  ((stmt :assert-valid) stmt)
  (cond
    (indexed? params) (eachp [i v] params (bind stmt (inc i) v))
    (dictionary? params) (eachp [k v] params (bind-named stmt (string k) v))
    (errorf "duckdb: params must be tuple/array (positional) or struct/table (named), got %q" params))
  (def result-ptr (ffi/write duckdb-result [0 0 0 nil nil nil]))
  (when (= (duckdb_execute_prepared (stmt :ptr) result-ptr) DuckDBError)
    (def err (duckdb_result_error result-ptr))
    (defer (duckdb_destroy_result result-ptr)
      (errorf "duckdb: %s" err)))
  (make-result result-ptr))

(defn/typed clear-bindings {:args [:struct] :ret nil} [stmt]
  "Reset a statement's bindings for a fresh round; raises after the
  statement is closed."
  ((stmt :assert-valid) stmt)
  (duckdb_clear_bindings (stmt :ptr)))

#==------------------------------------------------------------------------==#
# Database + connection + query
#==------------------------------------------------------------------------==#

(defn/typed open* {:args [:string :any] :ret :struct} [path config-map]
  "Open a database (path, config map of struct or table) to a db
  handle; config failures and open failures raise with duckdb's
  message."
  (unless (or (struct? config-map) (table? config-map))
    (errorf "duckdb: config map must be a struct or table, got %q" config-map))
  (def config-out (ffi/write :ptr (ffi/write duckdb-config [nil])))
  (when (= (duckdb_create_config config-out) DuckDBError)
    (error "duckdb: failed to allocate config"))
  (def db-out (ffi/write :ptr (ffi/write duckdb-database [nil])))
  (defer (duckdb_destroy_config config-out)
    (def config-ptr (ffi/read :ptr config-out))
    (eachp [k v] config-map
      (when (= (duckdb_set_config config-ptr (string k) (string v)) DuckDBError)
        (errorf "duckdb: cannot set config option %q=%q" k v)))
    (def err-cell (ffi/write :string ""))
    (when (= (duckdb_open_ext path db-out config-ptr err-cell) DuckDBError)
      (def err-ptr (ffi/read :ptr err-cell))
      (defer (duckdb_free err-ptr)
        (errorf "duckdb: %s" (deref-c-string-ptr err-ptr)))))
  (var valid true)
  {:ptr (ffi/read :ptr db-out)
   :close (fn [self]
            (when valid
              (duckdb_close db-out)
              (set valid false))
            nil)
   :assert-valid (fn [_]
                   (unless valid
                     (error "duckdb: db already closed"))
                   nil)})

(defn/typed connect {:args [:struct] :ret :struct} [db]
  "db handle to a conn handle with a guarded idempotent :close;
  raises after the db is closed; all queries run on conns."
  ((db :assert-valid) db)
  (def conn-out (ffi/write :ptr (ffi/write duckdb-connection [nil])))
  (when (= (duckdb_connect (db :ptr) conn-out) DuckDBError)
    (error "duckdb: failed to connect"))
  (var valid true)
  {:ptr (ffi/read :ptr conn-out)
   :close (fn [self]
            (when valid
              (duckdb_disconnect conn-out)
              (set valid false))
            nil)
   :assert-valid (fn [_]
                   (unless valid
                     (error "duckdb: conn already closed"))
                   nil)})

(defn/typed query* {:args [:struct :string] :ret :struct} [conn sql]
  "SQL to a result handle; errors carry duckdb's message and the
  typed error class, never swallowed; raises after the conn is
  closed."
  ((conn :assert-valid) conn)
  (def result-ptr (ffi/write duckdb-result [0 0 0 nil nil nil]))
  (when (= (duckdb_query (conn :ptr) sql result-ptr) DuckDBError)
    (def err (duckdb_result_error result-ptr))
    (def err-type (keyword (string "error-" (duckdb_result_error_type result-ptr))))
    (defer (duckdb_destroy_result result-ptr)
      (errorf "duckdb %s: %s" err-type err)))
  (make-result result-ptr))

(defn/typed pack-columns-f32 {:args [:struct :string] :ret :struct} [conn sql]
  "C-to-C column feed for packed kernels: run the query, stream its
  chunks and hand duckdb's native vector memory to janet-num's
  interleave kernel - no janet element crosses the boundary. All
  columns must be DOUBLE; NULL becomes NaN. Returns the janet-num
  packed-handle shape {:nrow :ncol :column-names}, which
  packed-slice-f32 and the dmatrix-from-packed lane consume directly."
  # C-to-C handoff: query -> duckdb chunk vectors (already native
  # memory) -> janet-num interleave kernel -> row-major f32 packed
  # buffer. ZERO janet elements cross the boundary. Columns must be
  # DOUBLE; NULLs become NaN (xgboost `missing` semantics). Returns
  # the same handle shape as num/pack-columns-f32, so
  # xgboost/dmatrix-from-packed consumes it directly.
  ((conn :assert-valid) conn)
  (with [result (query* conn sql)]
    (def ncol (result :column-count))
    (when (zero? ncol) (error "duckdb: no columns"))
    (each t (result :column-types)
      (unless (= t :double)
        (errorf "duckdb: pack-columns-f32 needs DOUBLE columns, got %s" t)))
    # stream chunks (one-shot iterator): keep every chunk alive for
    # the kernel calls - reachability is the lesson from the segfault;
    # chunks destroyed only after the last kernel call
    (def chunks @[])
    (var total 0)
    (loop [chunk :iterate (duckdb_fetch_chunk (result :struct))
           :until (nil? chunk)]
      (array/push chunks chunk)
      (+= total (int/to-number (duckdb_data_chunk_get_size chunk))))
    (def out (buffer/new-filled (* 4 total ncol) 0))
    (var row-offset 0)
    (each chunk chunks
      (def size (int/to-number (duckdb_data_chunk_get_size chunk)))
      (def data-ptrs @[])
      (def mask-ptrs @[])
      (for c 0 ncol
        (def vec (duckdb_data_chunk_get_vector chunk c))
        (array/push data-ptrs (duckdb_vector_get_data vec))
        (array/push mask-ptrs (duckdb_vector_get_validity vec)))
      (num/interleave-chunk-f32 (ffi/write @[:ptr ncol] data-ptrs)
                                      (ffi/write @[:ptr ncol] mask-ptrs)
                                      ncol size row-offset out)
      (+= row-offset size))
    (each chunk chunks
      (duckdb_destroy_data_chunk (ffi/write :ptr chunk)))
    {:ptr out :nrow total :ncol ncol :bytes (* 4 total ncol)
     :column-names (result :column-names)
     :free (fn [_] nil)}))

(defn/typed library-version {:args [] :ret :string} []
  "The libduckdb build version string (the pinned library's own
  report, for sanity checks at the console)."
  (duckdb_library_version))

#==------------------------------------------------------------------------==#
# Public variadic wrappers (dispatch-only; contracts live in the typed cores)
#==------------------------------------------------------------------------==#

(defn open "Open a duckdb database (default :memory:), optionally
  with a config map of duckdb options; returns a db handle." [path &opt config-map]
  (default path ":memory:")
  (default config-map {})
  (open* path config-map))

(defn query "Run SQL on a conn; with params (positional tuple/array
  or named struct/table) the statement is prepared, bound and
  destroyed in one call." [conn sql &opt params]
  (if params
    (with [stmt (prepare conn sql)] (execute* stmt params))
    (query* conn sql)))

(defn rows "Result to an array of rows: structs (keywordised by
  default) or tuples via coll-type :tuple. Re-reads of one open
  result are memoised." [result &opt keywordize coll-type]
  (default keywordize true)
  (default coll-type :struct)
  (result-rows result keywordize coll-type))

(defn first-row "First row of a result, or nil when empty; the
  same options as rows." [result &opt keywordize coll-type]
  (default keywordize true)
  (default coll-type :struct)
  (result-first result keywordize coll-type))

(defn columns "Result to the column-major struct
  {:column-names :column-types :columns :row-count} - the feed for
  packed kernels and column-wise work. Re-reads are memoised." [result]
  (fetch-columns result))

(defn exec "Run SQL and return the number of rows changed; the
  result handle is closed before returning." [conn sql &opt params]
  (with [result (query conn sql params)]
    (rows-changed result)))

(defn execute "Execute a prepared statement with fresh params
  (default none); returns a result handle." [stmt &opt params]
  (default params [])
  (execute* stmt params))
