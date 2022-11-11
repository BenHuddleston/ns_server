%% @author Couchbase <info@couchbase.com>
%% @copyright 2022-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.

-module(hibernation_manager).

-include("ns_common.hrl").
-include("cut.hrl").

%% TODO: These default timeouts are a function of the blobStorage
%% upload/download speeds and the size of the data - therefore needs
%% re-evaluation.

-define(PAUSE_BUCKET_TIMEOUT,
        ?get_timeout(pause_bucket, infinity)).

-define(RESUME_BUCKET_TIMEOUT,
        ?get_timeout(resume_bucket, infinity)).

-define(RESUME_BUCKET_DRY_RUN_TIMEOUT,
        ?get_timeout({dry_run, resume_bucket}, 5 * 60 * 1000)).

-export([pause_bucket/2,
         resume_bucket/2]).

-spec build_remote_path(
        Service :: atom(),
        RemotePath :: string()) -> string().
build_remote_path(Service, RemotePath) ->
    filename:join(RemotePath, atom_to_list(Service)).

supported_services() ->
    [index, fts].

build_workers_params(RemotePath) ->
    [{Service, ns_cluster_membership:service_active_nodes(Service),
      build_remote_path(Service, RemotePath)}
     || Service <- supported_services()].

pause_bucket(Bucket, RemotePath) ->
    spawn_link_hibernation_manager(
      pause_bucket, ?cut(do_pause_bucket(Bucket, RemotePath))).

resume_bucket(Bucket, RemotePath) ->
    spawn_link_hibernation_manager(
      resume_bucket, ?cut(do_resume_bucket(Bucket, RemotePath))).

spawn_link_hibernation_manager(Op, Body) ->
    proc_lib:spawn_link(
      fun () ->
              leader_activities:run_activity(
                Op, majority,
                fun () ->
                        leader_registry:register_name(?MODULE, self()),
                        Body()
                end)
      end).

do_pause_bucket(Bucket, RemotePath) ->
    WorkerParams = build_workers_params(RemotePath),

    ok = hibernation_utils:run_hibernation_op(
           fun ({Service, Nodes, RP}) ->
                   pause_bucket_body(
                     Service, Bucket, RP, Nodes)
           end, WorkerParams, ?PAUSE_BUCKET_TIMEOUT).

pause_bucket_body(Service, Bucket, RemotePath, Nodes) ->
    ProgressCallback = fun (_) -> ok end,

    service_manager:with_trap_exit_spawn_monitor_pause_bucket(
      Service, Bucket, RemotePath, Nodes, ProgressCallback, #{}).

do_resume_bucket(Bucket, RemotePath) ->
    WorkerParams = build_workers_params(RemotePath),

    %% Resume is performed in 2 stages.
    %%
    %% 1. dry_run phase: Services download
    %% bucket meta-data from the BlobStorage and evaluate if it is possible to
    %% resume the given bucket on the current cluster. If we get an ok from all
    %% the services we move on to the actual resume else the resume operation
    %% is aborted.
    %%
    %% 2. Actual resume: Services download bucket data (indexes etc) from the
    %% BlobStorage and send us ok - if any one of the Services fails, the
    %% entire Resume operation is aborted.

    ok = hibernation_utils:run_hibernation_op(
           fun ({Service, Nodes, RP}) ->
                   resume_bucket_body(
                     Service, Bucket, RP, true, Nodes)
           end, WorkerParams, ?RESUME_BUCKET_DRY_RUN_TIMEOUT),

    ok = hibernation_utils:run_hibernation_op(
           fun ({Service, Nodes, RP}) ->
                   resume_bucket_body(
                     Service, Bucket, RP, false, Nodes)
           end, WorkerParams, ?RESUME_BUCKET_TIMEOUT).

resume_bucket_body(Service, Bucket, RemotePath, DryRun, Nodes) ->
    ProgressCallback = fun (_) -> ok end,

    service_manager:with_trap_exit_spawn_monitor_resume_bucket(
      Service, Bucket, RemotePath, DryRun, Nodes, ProgressCallback, #{}).
