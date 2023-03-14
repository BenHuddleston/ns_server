%% @author Couchbase <info@couchbase.com>
%% @copyright 2021-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
%% @doc Bucket related macros
%%

-define(MAGMA_FRAG_PERCENTAGE, 50).
-define(MIN_MAGMA_FRAG_PERCENTAGE, 10).
-define(MAX_MAGMA_FRAG_PERCENTAGE, 100).

-define(MAGMA_STORAGE_QUOTA_PERCENTAGE, 50).
-define(MIN_MAGMA_STORAGE_QUOTA_PERCENTAGE, 1).
-define(MAX_MAGMA_STORAGE_QUOTA_PERCENTAGE, 85).

-define(MAGMA_KEY_TREE_DATA_BLOCKSIZE, 4096).
-define(MIN_MAGMA_KEY_TREE_DATA_BLOCKSIZE, 4096).
-define(MAX_MAGMA_KEY_TREE_DATA_BLOCKSIZE, 131072).

-define(MAGMA_SEQ_TREE_DATA_BLOCKSIZE, 4096).
-define(MIN_MAGMA_SEQ_TREE_DATA_BLOCKSIZE, 4096).
-define(MAX_MAGMA_SEQ_TREE_DATA_BLOCKSIZE, 131072).

-define(NUM_WORKER_THREADS, 3).
-define(MIN_NUM_WORKER_THREADS, 2).
-define(MAX_NUM_WORKER_THREADS, 8).

-define(MEMBASE_HT_LOCKS, 47).
-define(MAX_NUM_REPLICAS, 3).
-define(MIN_DRIFT_BEHIND_THRESHOLD, 100).

-define(HISTORY_RETENTION_SECONDS_DEFAULT, 0).
-define(HISTORY_RETENTION_BYTES_DEFAULT, 0).
%% 2GiB in bytes
-define(HISTORY_RETENTION_BYTES_MIN, 2 * 1024 * 1024 * 1024).
-define(HISTORY_RETENTION_COLLECTION_DEFAULT_DEFAULT, true).
