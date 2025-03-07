%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2021-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included
%% in the file licenses/BSL-Couchbase.txt.  As of the Change Date specified
%% in that file, in accordance with the Business Source License, use of this
%% software will be governed by the Apache License, Version 2.0, included in
%% the file licenses/APL2.txt.
-module(sigar).

-behaviour(gen_server).

-include("ns_common.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_link/0,
         get_all/2,
         get_gauges/1,
         get_cgroups_info/0,
         stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
          port :: port() | undefined,
          most_recent_data :: map() | undefined,
          most_recent_data_ts_usec :: integer() | undefined,
          most_recent_unpacked :: {#{bitstring() := number() | boolean()},
                                   [{atom(), number()}],
                                   #{bitstring() := number() | boolean()}}
                                   | undefined
         }).

-define(SIGAR_CACHE_TIME_USEC, 1000000).
-define(CGROUPS_INFO_SIZE, 96).
-define(GLOBAL_STATS_SIZE, 112).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_all(Opaque, PidNames) ->
    gen_server:call(?MODULE, {get_all, Opaque, PidNames}).

get_gauges(Items) ->
    gen_server:call(?MODULE, {get_gauges, Items}).

get_cgroups_info() ->
    gen_server:call(?MODULE, get_cgroups_info).

stop() ->
    gen_server:call(?MODULE, stop).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    Name = lists:flatten(io_lib:format("portsigar for ~s", [node()])),
    Port = spawn_sigar(Name, ns_server:get_babysitter_pid()),
    {ok, #state{port = Port}}.

handle_call({get_all, undefined, PidNames}, _From, State) ->
    handle_call({get_all, {undefined, undefined, undefined}, PidNames}, _From,
                State);
handle_call({get_all, {PrevTS, PrevCounters, PrevCGroups}, PidNames}, _From,
            State) ->
    NewState = update_sigar_data(State),
    #state{most_recent_unpacked = {Counters, Gauges, CGroups},
           most_recent_data_ts_usec = TS} = NewState,
    HostCounters = compute_cpu_stats(PrevCounters, Counters),
    Cores = proplists:get_value(cpu_cores_available, Gauges),
    CGroupsCounters =
        case maps:get(<<"supported">>, CGroups, false) of
            true -> compute_cgroups_counters(Cores, PrevTS, TS,
                                             PrevCGroups, CGroups);
            false when HostCounters == [] -> [];
            false -> default_cgroups_counters(HostCounters)
        end,
    ProcStats = get_process_stats(NewState#state.most_recent_data, PidNames),
    {reply, {{HostCounters ++ CGroupsCounters, Gauges, ProcStats},
     {TS, Counters, CGroups}}, NewState};

handle_call({get_gauges, Items}, _From, State) ->
    NewState = maybe_update_stats(State),
    {_, Gauges, _} = NewState#state.most_recent_unpacked,
    Res = [{I, proplists:get_value(I, Gauges)} || I <- Items],
    {reply, Res, NewState};

handle_call(get_cgroups_info, _From, State) ->
    NewState = maybe_update_stats(State),
    {_, _, CGroupsInfo} = NewState#state.most_recent_unpacked,
    {reply, CGroupsInfo, State};

handle_call(stop, _From, #state{port = Port} = State) ->
    catch port_close(Port),
    {stop, normal, ok, State#state{port = undefined}};

handle_call(Request, _From, State) ->
    ?log_error("Unhandled call: ~p", [Request]),
    {noreply, State}.

handle_cast(Msg, State) ->
    ?log_error("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info({Port, {exit_status, Status}}, #state{port = Port} = State) ->
    ?log_error("Received exit_status ~p from sigar", [Status]),
    {stop, {sigar, Status}, State};
handle_info({Port, eof}, #state{port = Port} = State) ->
    ?log_error("Received eof from sigar"),
    {stop, {sigar, eof}, State};
handle_info(Info, State) ->
    ?log_error("Unhandled info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

spawn_sigar(Name, BabysitterPid) ->
    Path = path_config:component_path(bin, "sigar_port"),
    ?log_info("Spawning sigar process '~s'(~p) with babysitter pid: ~p",
              [Name, Path, BabysitterPid]),
    open_port({spawn_executable, Path},
              [stream, use_stdio, exit_status, binary, eof,
               {arg0, Name},
               {args, ["--json", integer_to_list(BabysitterPid)]}]).

grab_stats(Port) ->
    port_command(Port, <<"\n":8/native>>),
    recv_data(Port, <<"">>).

%% The first line contains the size of the JSON output to follow.
recv_data(Port, Acc) ->
    receive
        {Port, {data, Curr}} ->
            Data = <<Curr/binary, Acc/binary>>,
            case binary:split(Data, <<"\n">>) of
                [Length, Rest] ->
                    Remaining = binary_to_integer(Length) - erlang:size(Rest),
                    recv_data_with_length(Port, Rest, Remaining);
                _ -> recv_data(Port, Data)
            end;
        {Port, {exit_status, Status}} ->
            ?log_error("Received exit_status ~p from sigar", [Status]),
            exit({sigar, Status});
        {Port, eof} ->
            ?log_error("Received eof from sigar"),
            exit({sigar, eof})
    end.

recv_data_with_length(_Port, Acc, _WantedLength = 0) ->
    Bin = erlang:iolist_to_binary(Acc),
    {Decoded} = parse_json_elem(ejson:decode(Bin)),
    maps:from_list(Decoded);
recv_data_with_length(Port, Acc, WantedLength) ->
    receive
        {Port, {data, Data}} ->
            Size = size(Data),
            if
                Size =< WantedLength ->
                    recv_data_with_length(Port, [Acc | Data],
                                          WantedLength - Size);
                Size > WantedLength ->
                    erlang:error({too_big_recv, Size, WantedLength, Data, Acc})
            end;
        {Port, {exit_status, Status}} ->
            ?log_error("Received exit_status ~p from sigar", [Status]),
            exit({sigar, Status});
        {Port, eof} ->
            ?log_error("Received eof from sigar"),
            exit({sigar, eof})
    end.

%% Every JSON element is currently an integer/boolean/string. Most are strings
%% even if they represent numeric data. There is some contention on whether all
%% JSON libraries can represent 64-bit integers (or are limited to 2^53). So
%% they are transmitted as strings. Convert every bitstring to integer/float
%% when possible.
parse_json_elem({K, V}) -> {K, parse_json_elem(V)};
parse_json_elem({Obj}) -> {parse_json_elem(Obj)};
parse_json_elem(Data) when is_list(Data) ->
    lists:map(fun parse_json_elem/1, Data);
parse_json_elem(Data) when is_boolean(Data) -> Data;
parse_json_elem(Data) when is_integer(Data) -> Data;
parse_json_elem(Data) when is_float(Data) -> Data;
parse_json_elem(Data) when is_binary(Data) ->
    try binary_to_integer(Data) of
        Y -> Y
    catch _:_ ->
            try binary_to_float(Data) of
                X -> X
            catch _:_ ->
                    Data
            end,
            Data
    end.

cpu_filter_counter(<<"cpu_", End/binary>>, Val) ->
    case binary:split(End, <<"_ms">>) of
        [_, <<>>] when is_number(Val) -> true;
        _ -> false
    end;
cpu_filter_counter(_, _) ->
     false.

get_number(StatsMap, Field) ->
    case maps:get(Field, StatsMap, undefined) of
        X when is_number(X) -> X;
        _ -> 0
end.

get_global_stats(StatsMap) ->
    CgroupsInfo =
        case maps:get(<<"control_group_info">>, StatsMap, undefined) of
            undefined -> #{<<"supported">> => false};
            {CgroupsStats} ->
                Map1 = maps:from_list(CgroupsStats),
                maps:put(<<"supported">>, true, Map1)
        end,
    {CGMemLimit, CGMemUsed, CGMemActual} =
        case CgroupsInfo of
            #{<<"supported">> := true, <<"memory_current">> := MCurr,
               <<"memory_cache">> := MCache, <<"memory_max">> := MMax}
              when is_number(MCurr), is_number(MCache), is_number(MMax) ->
                {MMax, MCurr, MCurr - MCache};
            _ -> {undefined, undefined, undefined}
        end,
    MemTotal = get_number(StatsMap, <<"mem_total">>),
    MemUsed = get_number(StatsMap, <<"mem_used">>),
    {MemLimit, _} = memory_quota:choose_limit(MemTotal, MemUsed,
                                              {CGMemLimit, CGMemUsed}),
    %% Suppressing dialyzer warning here
    %% Dialyzer thinks that system_info can't return 'unknown', while according
    %% to doc it seems like it actually can. So, in order to avoid a warning
    %% the value is compared with 0 insead of explicit match to 'unknown'
    HostCoresAvailable = case erlang:system_info(logical_processors) of
                             P when is_number(P), P > 0 -> P;
                             _ -> 0
                         end,
    CoresAvailable = case maps:get(<<"num_cpu_prc">>, CgroupsInfo, undefined) of
                         N when is_number(N) ->
                             %% do not round it, cpu utilization will break
                             N / 100;
                         _ -> HostCoresAvailable
                     end,
    Counters = case maps:get(<<"cpu_total_ms">>, StatsMap, undefined) of
                   X when is_number(X) ->
                       CMap = maps:filter(fun cpu_filter_counter/2, StatsMap),
                       maps:put(<<"supported">>, true, CMap);
                   _ -> #{<<"supported">> => false}
               end,
    Gauges =
        [{cpu_cores_available, CoresAvailable},
         {cpu_host_cores_available, HostCoresAvailable},
         {swap_total, get_number(StatsMap, <<"swap_total">>)},
         {swap_used, get_number(StatsMap, <<"swap_used">>)},
         {mem_limit, MemLimit},
         {mem_total, MemTotal},
         {mem_used_sys, MemUsed},
         {mem_actual_used, get_number(StatsMap, <<"mem_actual_used">>)},
         {mem_actual_free, get_number(StatsMap, <<"mem_actual_free">>)},
         {mem_free, get_number(StatsMap, <<"mem_actual_free">>)},
         {allocstall, get_number(StatsMap, <<"allocstall">>)}] ++
        [{mem_cgroup_limit, CGMemLimit} || CGMemLimit /= undefined] ++
        [{mem_cgroup_actual_used, CGMemActual} || CGMemActual /= undefined] ++
        [{mem_cgroup_used, CGMemUsed} || CGMemUsed /= undefined],

    {Counters, Gauges, CgroupsInfo}.

get_process_stats(StatsMap, ProcNames) ->
    collapse_duplicates(populate_processes(StatsMap, ProcNames)).

collapse_duplicates(Sample) ->
    Sorted = lists:keysort(1, Sample),
    lists:foldl(fun do_collapse_duplicates/2, [], Sorted).

do_collapse_duplicates({K, V1}, [{K, V2} | Acc]) ->
    [{K, V1 + V2} | Acc];
do_collapse_duplicates(KV, Acc) ->
    [KV | Acc].

%% The "_faults" stats are reported with suffix _raw.
fix_stat_name(Stat) ->
    case Stat of
        <<"minor_faults">> -> <<"minor_faults_raw">>;
        <<"major_faults">> -> <<"major_faults_raw">>;
        <<"page_faults">> -> <<"page_faults_raw">>;
        _ -> Stat
    end.

populate_proc_stat(ProcName, Stat, Value) ->
    case Stat of
        <<"name">> -> false;
        <<"pid">> -> false;
        <<"ppid">> -> false;
        _ ->
            StatName = fix_stat_name(Stat),
            case Value of
                X when is_number(X) ->
                    {true, {proc_stat_name(ProcName, StatName), X}};
                _ -> false
            end
    end.

populate_proc_stats(Stats, ProcNames) ->
    {<<"pid">>, Pid} = lists:keyfind(<<"pid">>, 1, Stats),
    {<<"name">>, Name} = lists:keyfind(<<"name">>, 1, Stats),
    ProcName =
        case lists:keyfind(Pid, 1, ProcNames) of
            false -> Name;
            {Pid, BetterName} -> BetterName
        end,
    lists:filtermap(fun({Stat, Value}) ->
                            populate_proc_stat(ProcName, Stat, Value) end,
                    Stats).

populate_processes(StatsMap, ProcNames) ->
    ProcStats = maps:get(<<"interesting_procs">>, StatsMap, undefined),
    case ProcStats of
        undefined -> [];
        Val -> lists:flatten(
                 lists:map(
                   fun({Stats}) -> populate_proc_stats(Stats, ProcNames) end,
                   Val))
    end.

proc_stat_name(ProcName, Stat) ->
    <<ProcName/binary, $/, Stat/binary>>.

compute_cpu_stats(undefined, _Counters) -> [];
compute_cpu_stats(#{<<"supported">> := true} = OldCounters,
                  #{<<"supported">> := true} = Counters) ->
    Diffs = maps:map(fun (Key, Value) ->
                             OldValue = maps:get(Key, OldCounters, undefined),
                             case OldValue of
                                 X when is_number(X), is_number(Value) ->
                                     Value - X;
                                 _ -> 0
                             end
                     end, Counters),
    Idle = maps:get(<<"cpu_idle_ms">>, Diffs, 0),
    User = maps:get(<<"cpu_user_ms">>, Diffs, 0),
    Sys = maps:get(<<"cpu_sys_ms">>, Diffs, 0),
    Irq = maps:get(<<"cpu_irq_ms">>, Diffs, 0),
    Stolen = maps:get(<<"cpu_stolen_ms">>, Diffs, 0),
    Total = maps:get(<<"cpu_total_ms">>, Diffs),

    [{cpu_host_utilization_rate, compute_utilization(Total - Idle, Total)},
     {cpu_host_user_rate, compute_utilization(User, Total)},
     {cpu_host_sys_rate, compute_utilization(Sys, Total)},
     {cpu_irq_rate, compute_utilization(Irq, Total)},
     {cpu_stolen_rate, compute_utilization(Stolen, Total)}];
compute_cpu_stats(_, _) -> [].

compute_cgroups_counters(Cores, PrevTS, TS,
                         #{<<"supported">> := true} = Old,
                         #{<<"supported">> := true} = New)
                                        when is_number(PrevTS), is_number(TS),
                                             is_number(Cores), Cores > 0 ->
    TimeDelta = TS - PrevTS,
    ComputeRate = fun (Key) ->
                          OldV = maps:get(Key, Old, undefined),
                          NewV = maps:get(Key, New, undefined),
                          case {OldV =/= undefined, NewV =/= undefined} of
                              {true, true}
                                when is_number(OldV), is_number(NewV) ->
                                  compute_utilization(NewV - OldV,
                                                      TimeDelta * Cores);
                              _  -> 0
                          end
                  end,
    [{cpu_utilization_rate, ComputeRate(<<"usage_usec">>)},
     {cpu_user_rate, ComputeRate(<<"user_usec">>)},
     {cpu_sys_rate, ComputeRate(<<"system_usec">>)},
     {cpu_throttled_rate, ComputeRate(<<"throttled_usec">>)},
     {cpu_burst_rate, ComputeRate(<<"burst_usec">>)}];
compute_cgroups_counters(_, _, _, _, _) ->
    [].

default_cgroups_counters(HostCounters) ->
    [{cpu_utilization_rate,
      proplists:get_value(cpu_host_utilization_rate, HostCounters)},
     {cpu_user_rate,
      proplists:get_value(cpu_host_user_rate, HostCounters)},
     {cpu_sys_rate,
      proplists:get_value(cpu_host_sys_rate, HostCounters)}].

compute_utilization(Used, Total) ->
    try
        100 * Used / Total
    catch error:badarith ->
            0
    end.

maybe_update_stats(#state{most_recent_data_ts_usec = TS} = State) ->
    case TS == undefined orelse timestamp() - TS >= ?SIGAR_CACHE_TIME_USEC of
        true -> update_sigar_data(State);
        false -> State
    end.

timestamp() -> erlang:monotonic_time(microsecond).

update_sigar_data(#state{port = Port} = State) ->
    StatsMap = grab_stats(Port),
    State#state{most_recent_data = StatsMap,
                most_recent_data_ts_usec = timestamp(),
                most_recent_unpacked = get_global_stats(StatsMap)}.

-ifdef(TEST).
validate_results(Json, CountersExpected, GaugesExpected, CGExpected, PExpect,
                PNames) ->
    StatsMap = recv_data_with_length(31, Json, 0),
    {Counters, Gauges, CGroupsInfo} = get_global_stats(StatsMap),
    ?assertEqual(CGroupsInfo, CGExpected),
    ?assertEqual(Counters, CountersExpected),
    Result = [{K1, V1} || {K1, V1} <- Gauges, {K2, V2} <- GaugesExpected,
                          K1 =:= K2, V1 =/= V2],
    ?assertEqual(Result, []),
    OtherKeys = Gauges -- GaugesExpected,
    NonNumeric = [{K, V} || {K, V} <- OtherKeys, not is_number(V)],
    ?assertEqual(NonNumeric, []),
    CgroupsKeys = [mem_cgroup_limit, mem_cgroup_actual_used, mem_cgroup_used],
    CgroupList = [{K, V} || {K, V} <- OtherKeys, K1 <- CgroupsKeys, K =:= K1],
    case maps:get(<<"supported">>, CGExpected) of
        false -> ?assertEqual(CgroupList, []);
        true -> ?assertEqual(length(CgroupList), length(CgroupsKeys))
    end,
    ProcStats = get_process_stats(StatsMap, PNames),
    ?assertEqual(ProcStats, PExpect).

sigar_json_test() ->
    Acc0 = <<"{\n\"cpu_idle_ms\": \"655676420\",\n\"cpu_irq_ms\": \"0\",\n\""
             "cpu_stolen_ms\": \"0\",\n\"cpu_sys_ms\": \"25792540\",\n\""
             "cpu_total_ms\": \"732003090\",\n\"cpu_user_ms\":\"50534130\",\n\""
             "interesting_procs\": [\n{\n\"cpu_utilization\": \"4\",\n\""
             "major_faults\": \"3\",\n\"minor_faults\": \"19\",\n\"name\": \""
             "beam.smp\",\n\"page_faults\": \"21835\",\n\"pid\": \"65595\",\n\""
             "ppid\": \"65587\"\n},\n{\n\"cpu_utilization\": \"5\",\n\""
             "major_faults\": \"1\",\n\"minor_faults\": \"2\",\n\"name\":\""
             "sigar_port\",\n\"page_faults\": \"1298\",\n\"pid\":\"65618\",\n\""
             "ppid\": \"65607\"\n}\n],\n\"mem_actual_free\":\"4063666176\",\n\""
             "mem_actual_used\": \"30296072192\",\n\"mem_total\": \""
             "34359738368\",\n\"mem_used\": \"33626083328\",\n\"swap_total\": "
             "\"1\",\n\"swap_used\": \"2\"\n}">>,
    CountersExpected0 = #{<<"supported">> => true,
                          <<"cpu_idle_ms">> => 655676420,
                          <<"cpu_irq_ms">> => 0,
                          <<"cpu_stolen_ms">> => 0,
                          <<"cpu_sys_ms">> => 25792540,
                          <<"cpu_total_ms">> => 732003090,
                          <<"cpu_user_ms">> => 50534130},
    GaugesExpected0 = [{swap_total, 1},
                       {swap_used, 2},
                       {mem_total, 34359738368},
                       {mem_used_sys, 33626083328},
                       {mem_actual_used, 30296072192},
                       {mem_actual_free, 4063666176},
                       {mem_free, 4063666176},
                       {allocstall, 0}],
    Cgroups0 = #{<<"supported">> => false},
    PNames0 = [{65595, <<"Process0">>}, {65618, <<"Process1">>}],
    Proc0 = [{<<"Process1/page_faults_raw">>,1298},
        {<<"Process1/minor_faults_raw">>,2},
        {<<"Process1/major_faults_raw">>,1},
        {<<"Process1/cpu_utilization">>,5},
        {<<"Process0/page_faults_raw">>,21835},
        {<<"Process0/minor_faults_raw">>,19},
        {<<"Process0/major_faults_raw">>,3},
        {<<"Process0/cpu_utilization">>,4}],
    validate_results(Acc0, CountersExpected0, GaugesExpected0, Cgroups0, Proc0,
                    PNames0),
    Acc1 = <<"{\n\"allocstall\": \"1\",\n\"control_group_info\": {\n\""
             "num_cpu_prc\": 8,\n\"memory_current\": \"324\","
             "\n\"memory_cache\": \"123\"\n,\"memory_max\": \"491\"\n},\n\""
             "cpu_idle_ms\": \"655676420\",\n\"cpu_irq_ms\": \"0\",\n\""
             "cpu_stolen_ms\": \"0\",\n\"cpu_sys_ms\": \"25792540\",\n\""
             "cpu_user_ms\": \"50534130\",\n\"interesting_procs\": [\n{\n\""
             "cpu_utilization\": \"34\",\n\"major_faults\": \"10\",\n\""
             "minor_faults\": \"3\",\n\"name\": \"beam.smp\",\n\"page_faults\""
             ": \"23235\",\n\"pid\": \"35525\",\n\"ppid\": \"65587\"\n},\n{\n\""
             "cpu_utilization\": \"1\",\n\"major_faults\": \"0\",\n\""
             "minor_faults\": \"33\",\n\"name\": \"sigar_port\",\n\""
             "page_faults\": \"13398\",\n\"pid\": \"20618\",\n\"ppid\": \""
             "65607\"\n}\n],\n\"mem_actual_free\": \"4063666176\",\n\""
             "mem_actual_used\": \"30296072192\",\n\"mem_total\": \""
             "34359738368\",\n\"mem_used\": \"33626083328\",\n\"swap_total\": "
             "\"1\",\n\"swap_used\": \"2\"\n}">>,
    GaugesExpected1 = [{swap_total, 1},
                       {swap_used, 2},
                       {mem_total, 34359738368},
                       {mem_used_sys, 33626083328},
                       {mem_actual_used, 30296072192},
                       {mem_actual_free, 4063666176},
                       {mem_free, 4063666176},
                       {allocstall, 1},
                       {cores_available, 8}],
    Cgroups1 = #{<<"supported">> => true,
                 <<"num_cpu_prc">> => 8,
                 <<"memory_current">> => 324,
                 <<"memory_cache">> => 123,
                 <<"memory_max">> => 491},
    PNames1 = [{35525, <<"Process2">>}, {20618, <<"Process3">>}],
    Proc1 = [{<<"Process3/page_faults_raw">>,13398},
        {<<"Process3/minor_faults_raw">>,33},
        {<<"Process3/major_faults_raw">>,0},
        {<<"Process3/cpu_utilization">>,1},
        {<<"Process2/page_faults_raw">>,23235},
        {<<"Process2/minor_faults_raw">>,3},
        {<<"Process2/major_faults_raw">>,10},
        {<<"Process2/cpu_utilization">>,34}],
    CountersExpected1 = #{<<"supported">> => false},
    validate_results(Acc1, CountersExpected1, GaugesExpected1, Cgroups1, Proc1,
                    PNames1),
    CountersExpected2 = #{<<"supported">> => true,
                          <<"cpu_idle_ms">> => 655676513,
                          <<"cpu_irq_ms">> => 2,
                          <<"cpu_stolen_ms">> => 1,
                          <<"cpu_sys_ms">> => 232792540,
                          <<"cpu_total_ms">> => 2332003090,
                          <<"cpu_user_ms">> => 323534130},
    ?assertEqual(compute_cpu_stats(CountersExpected1, CountersExpected2), []),
    ?assertEqual(compute_cpu_stats(CountersExpected2, CountersExpected1), []),
    Rates = compute_cpu_stats(CountersExpected0, CountersExpected2),
    RateKeys = [cpu_host_utilization_rate, cpu_host_user_rate,
                cpu_host_sys_rate, cpu_irq_rate, cpu_stolen_rate],
    Expected = [{K, V} || K <- RateKeys, {K1, V} <- Rates, K =:= K1,
                          is_number(V)],
    ?assertEqual(length(Expected), length(RateKeys)).
-endif.

