%% @author Couchbase <info@couchbase.com>
%% @copyright 2020 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
-module(menelaus_web_prometheus).

%% API
-export([handle_get_local_metrics/2, handle_create_snapshot/1,
         handle_get_metrics/1, handle_sd_config/1]).

-include("ns_common.hrl").

-define(METRICS_TIMEOUT, 5000).
-define(PART_SIZE, 1024).
-define(WINDOW_SIZE, 3).

%%%===================================================================
%%% API
%%%===================================================================

handle_get_metrics(Req) ->
    Resp = mochiweb_request:respond({200, [], chunked}, Req),
    ns_server_stats:report_prom_stats(fun (M) -> report_metric(M, Resp) end,
                                      false),
    Settings = prometheus_cfg:settings(),
    Services = proplists:get_value(external_prometheus_services, Settings),
    NsServerProps = proplists:get_value(ns_server, Services, []),
    case proplists:get_bool(high_cardinality_enabled, NsServerProps) of
        true ->
            ns_server_stats:report_prom_stats(
              fun (M) -> report_metric(M, Resp) end, true);
        false -> ok
    end,
    AllTargets = proplists:get_value(targets, Settings),
    AlmostAllTargets = proplists:delete(ns_server, AllTargets),
    HighCardTargets = lists:filter(
                        fun ({Name, _Addr}) ->
                            Props = proplists:get_value(Name, Services, []),
                            proplists:get_bool(high_cardinality_enabled, Props)
                        end, AlmostAllTargets),
    %% Addr is supposed to be a loopback address (127.0.0.1 or [::1] depending
    %% on configured ip family) with port, hence no need to use https
    MakeURL = fun (Addr, Path) -> "http://" ++ Addr ++ Path end,
    Config = ns_config:latest(),
    AuthHeader =
        fun (kv) ->
                menelaus_rest:basic_auth_header(
                  ns_config:search_node_prop(Config, memcached, admin_user),
                  ns_config:search_node_prop(Config, memcached, admin_pass));
            (_) ->
                menelaus_rest:special_auth_header()
        end,
    URLs = [{MakeURL(Addr, "/_prometheusMetrics"), AuthHeader(Type)}
                || {Type, Addr} <- AlmostAllTargets] ++
           [{MakeURL(Addr, "/_prometheusMetricsHigh"), AuthHeader(Type)}
                || {Type, Addr} <- HighCardTargets],
    [proxy_chunks_from_url(URL, Resp) || URL <- URLs],
    mochiweb_response:write_chunk(<<>>, Resp).

handle_sd_config(Req) ->
    Nodes = menelaus_web_node:get_hostnames(Req, any),
    Yaml = [#{targets => [HostPort || {_, HostPort} <- Nodes]}],
    YamlBin = yaml:encode(Yaml),
    ClusterName = menelaus_web_pools:get_cluster_name(),
    Filename = io_lib:format("couchbase_sd_config_~s.yaml", [ClusterName]),
    ContentDisp = io_lib:format("attachment; filename=\"~s\"", [Filename]),
    ExtraHeaders = [{"Content-Disposition", lists:flatten(ContentDisp)}],
    menelaus_util:reply_ok(Req, "text/yaml", YamlBin, ExtraHeaders).

proxy_chunks_from_url({URL, AuthHeader}, Resp) ->
    Options = [{connect_timeout, ?METRICS_TIMEOUT},
               {partial_download, [{window_size, ?WINDOW_SIZE},
                                   {part_size, ?PART_SIZE}]}],
    Headers = [AuthHeader],
    case lhttpc:request(URL, 'GET', Headers, [], ?METRICS_TIMEOUT, Options) of
        {ok, {{200, _}, _Hdrs, Req}} when is_pid(Req) ->
            case proxy_chunks(Req, Resp) of
                ok -> ok;
                {error, Error} ->
                    ?log_error("Got error while reading chunks from ~s:~n~p",
                               [URL, Error])
            end;
        Bad ->
            ?log_error("Http get for ~s returned:~n~p", [URL, Bad]),
            ok
    end.

proxy_chunks(Req, Resp) ->
    case lhttpc:get_body_part(Req, ?METRICS_TIMEOUT) of
        {ok, {http_eob, _Trailers}} -> ok;
        {ok, Bin} when is_binary(Bin) ->
            mochiweb_response:write_chunk(Bin, Resp),
            proxy_chunks(Req, Resp);
        {error, _} = Error ->
            Error
    end.

%% It is supposed to be used by local prometheus to collect ns_server metrics
handle_get_local_metrics(IsHighCard, Req) ->
    Resp = mochiweb_request:respond({200, [], chunked}, Req),
    ns_server_stats:report_prom_stats(fun (M) -> report_metric(M, Resp) end,
                                      IsHighCard),
    mochiweb_response:write_chunk(<<>>, Resp).

handle_create_snapshot(Req) ->
    menelaus_util:ensure_local(Req),
    Settings = prometheus_cfg:settings(),
    Timeout = proplists:get_value(snapshot_timeout_msecs, Settings),
    case prometheus:create_snapshot(Timeout, Settings) of
        {ok, Response} ->
            menelaus_util:reply_text(Req, Response, 200);
        {error, Reason} ->
            menelaus_util:reply_text(Req, Reason, 500)
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

report_metric({Metric, Labels, Value}, Resp) ->
    LabelsIOList = [[name_to_iolist(K), <<"=\"">>, label_val_to_bin(V),
                     <<"\"">>] || {K, V} <- Labels],
    Line =
        [name_to_iolist(Metric), <<"{">>, lists:join(<<",">>, LabelsIOList),
         <<"} ">>, promQL:format_value(Value), <<"\n">>],
    mochiweb_response:write_chunk(Line, Resp);
report_metric({Prefix, Metric, Labels, Value}, Resp) ->
    Prefixed = [Prefix, <<"_">>, name_to_iolist(Metric)],
    report_metric({Prefixed, Labels, Value}, Resp).

name_to_iolist(A) when is_atom(A) -> atom_to_binary(A, latin1);
name_to_iolist(A) -> A.

label_val_to_bin(N) when is_integer(N) -> integer_to_binary(N);
label_val_to_bin(F) when is_float(F) -> float_to_binary(F);
label_val_to_bin(A) when is_atom(A) -> atom_to_binary(A, latin1);
label_val_to_bin(Bin) when is_binary(Bin) -> Bin;
label_val_to_bin(Str) when is_list(Str) -> list_to_binary(Str).

