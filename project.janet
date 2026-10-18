# project.janet - jpm package manifest for janet-duckdb.
(declare-project
  :name "janet-duckdb"
  :description "In-process DuckDB for Janet via core ffi - prepared statements, full type matrix, pack-columns-f32 feed"
  :license "AGPL-3.0"
  :version "0.1.2")

(declare-source
  :source ["jennystats"]
  :dependencies ["https://github.com/jennystats/janet-kit"
                 "https://github.com/jennystats/janet-num"
                 "https://github.com/jennystats/janet-json"])
