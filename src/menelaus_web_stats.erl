%% @author Couchbase <info@couchbase.com>
%% @copyright 2020-2021 Couchbase, Inc.
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
%%

%% @doc rest api for stats
-module(menelaus_web_stats).

-export([handle_range_post/1, handle_range_get/2,
         handle_get_settings/2, handle_post_settings/2]).

-include("ns_common.hrl").
-include("rbac.hrl").
-include("cut.hrl").

-define(MAX_TS, 9999999999999).
-define(MIN_TS, -?MAX_TS).
-define(DEFAULT_PROMETHEUS_QUERY_TIMEOUT, 60000).
-define(DERIVED_PARAM_LABEL, <<"__derived_param_name_label__">>).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


params() ->
    Services = all_services(),

    [{"enabled",
      #{type => bool}},
     {"scrapeInterval",
      #{cfg_key => scrape_interval, type => pos_int}},
     {"scrapeTimeout",
      #{cfg_key => scrape_timeout, type => pos_int}},
     {"snapshotCreationTimeout",
      #{cfg_key => snapshot_timeout_msecs, type => pos_int}},
     {"scrapeIntervalsCalculationPeriod",
      #{cfg_key => intervals_calculation_period, type => pos_int_or_minus_one}},
     {"cbcollect.statsMaxSize",
      #{cfg_key => cbcollect_stats_dump_max_size, type => pos_int}},
     {"cbcollect.statsMinPeriod",
      #{cfg_key => cbcollect_stats_min_period, type => pos_int}},
     {"expectedAvgSampleSize",
      #{cfg => average_sample_size, type => pos_int}},
     {"logExecutedQueries",
      #{cfg_key => log_queries, type => bool}},
     {"derivedMetricsFilter",
      #{cfg_key => derived_metrics_filter, type => derived_metrics_filter}},
     {"derivedMetricsCalculationInterval",
      #{cfg_key => derived_metrics_interval, type => pos_int_or_minus_one}},

     {"prometheus.retentionSize",
      #{cfg_key => retention_size, type => pos_int}},
     {"prometheus.retentionTime",
      #{cfg_key => retention_time, type => pos_int}},
     {"prometheus.walCompression",
      #{cfg_key => wal_compression, type => bool}},
     {"prometheus.authEnabled",
      #{cfg_key => prometheus_auth_enabled, type => bool}},
     {"prometheus.logLevel",
      #{cfg_key => log_level,
        type => {one_of, string, ["debug", "info", "warn", "error"]}}},
     {"prometheus.maxBlockDuration",
      #{cfg_key => max_block_duration, type => pos_int}},
     {"prometheus.queryMaxSamples",
      #{cfg_key => query_max_samples, type => pos_int}},
     {"prometheus.reportMetrics",
      #{cfg_key => prometheus_metrics_enabled, type => bool}},
     {"prometheus.reportMetricsInterval",
      #{cfg_key => prometheus_metrics_scrape_interval, type => pos_int}},
     {"prometheus.listenAddr",
      #{cfg_key => listen_addr_type,
        type => {one_of, existing_atom, [loopback, any]}}},
     {"pruningInterval",
      #{cfg_key => pruning_interval, type => pos_int}},
     {"decimation.enabled",
      #{cfg_key => decimation_enabled, type => bool}},
     {"decimation.matchPatterns",
      #{cfg_key => decimation_match_patterns, type => prom_patterns}},
     {"truncation.enabled",
      #{cfg_key => truncation_enabled, type => bool}},
     {"truncation.matchPatterns",
      #{cfg_key => truncation_match_patterns, type => prom_patterns}},
     {"truncation.age",
      #{cfg_key => truncate_max_age, type => pos_int}},
     {"truncation.minInterval",
      #{cfg_key => min_truncation_interval, type => non_neg_int}}] ++
    [{"services." ++ N ++ ".highCardEnabled",
      #{cfg_key => [services, S, high_cardinality_enabled], type => bool}}
     || {S, N} <- Services] ++
    [{"services." ++ N ++ ".highCardScrapeInterval",
      #{cfg_key => [services, S, high_cardinality_scrape_interval],
        type => pos_int_or_minus_one}}
     || {S, N} <- Services] ++
    [{"services." ++ N ++ ".highCardScrapeTimeout",
      #{cfg_key => [services, S, high_cardinality_scrape_timeout],
        type => pos_int}}
     || {S, N} <- Services] ++
    [{"statsExport." ++ N ++ ".highCardEnabled",
      #{cfg_key => [external_prometheus_services, S, high_cardinality_enabled],
        type => bool}}
     || {S, N} <- Services].

type_spec(derived_metrics_filter) ->
    #{validators => [fun derived_metrics_filter/2],
      formatter => fun format_derived_metrics_filter/1};
type_spec(prom_patterns) ->
    #{validators => [{string_list, ","},
                     validate_list(fun prom_pattern/1, _, _)],
      formatter => {string_list, ","}};
type_spec(pos_int_or_minus_one) ->
    #{validators => [int, validator:validate(
                            fun (-1) -> ok;
                                (N) when N > 0 -> ok;
                                (_) ->
                                    {error, "must be a positive integer or -1"}
                            end, _, _)],
      formatter => int}.

format_derived_metrics_filter(all) -> {value, <<"all">>};
format_derived_metrics_filter(L) -> {value, [list_to_binary(M) || M <- L]}.

derived_metrics_filter(Name, State) ->
    Err = "must be either \"all\" or list of strings",
    validator:validate(
        case validator:is_json(State) of
            true ->
                fun (<<"all">>) -> {value, all};
                    (List) when is_list(List) ->
                        case lists:all(fun is_binary/1, List) of
                            true ->
                                Metrics = [binary_to_list(B) || B <- List],
                                verify_derived_metrics(Metrics);
                            false -> {error, Err}
                        end;
                    (_NotList) ->
                        {error, Err}
                end;
            false ->
                fun ("all") -> {value, all};
                    (Str) ->
                        Tokens = string:lexemes(Str, ","),
                        Metrics = [string:trim(T) || T <- Tokens],
                        verify_derived_metrics(Metrics)
                end
        end, Name, State).

validate_list(Fun, Name, State) ->
    validator:validate(
      fun (List) ->
          try
             {value, lists:map(
                       fun (E) ->
                           case Fun(E) of
                               {value, V} -> V;
                               {error, Err} -> throw(Err)
                           end
                       end, List)}
          catch
              throw:Err -> {error, Err}
          end
      end, Name, State).

prom_pattern(Str) ->
    Trimmed = string:trim(Str),
    Msg = <<"bad prometheus patterns">>,
    case re:run(Trimmed, <<"^{(.*)}$">>, [{capture, all_but_first, list}]) of
        {match, _} -> {value, Trimmed};
        nomatch -> {error, Msg}
    end.

handle_get_settings(Path, Req) ->
    Settings = prometheus_cfg:with_applied_defaults(
                 ns_config:read_key_fast(stats_settings, [])),
    menelaus_web_settings2:handle_get(Path, params(), fun type_spec/1,
                                      Settings, Req).

handle_post_settings(Path, Req) ->
    menelaus_web_settings2:handle_post(
      apply_props(Path, _, _), Path, params(), fun type_spec/1, Req).

apply_props(Path, PropList, Req) ->
    OldProps = ns_config:read_key_fast(stats_settings, []),
    NewProps = lists:foldl(
                 fun ({KeyTokens, Value}, Acc) ->
                     apply_value(KeyTokens, Value, Acc)
                 end, OldProps, PropList),
    validate_metrics_settings(prometheus_cfg:with_applied_defaults(NewProps)),
    ns_config:set(stats_settings, NewProps),
    handle_get_settings(Path, Req).

validate_metrics_settings(Settings) ->
    case proplists:get_value(scrape_interval, Settings) <
         proplists:get_value(scrape_timeout, Settings) of
        true ->
            Msg = <<"scrapeInterval must be greater than or equal to "
                    "scrapeTimeout">>,
            menelaus_util:global_error_exception(400, Msg);
        false -> ok
    end.

apply_value([], Value, _PropList) -> Value;
apply_value([Key | Tail], Value, PropList) ->
    Res = misc:key_update(Key, PropList,
                          fun (SubProplist) ->
                              apply_value(Tail, Value, SubProplist)
                          end),
    case Res of
        false -> [{Key, apply_value(Tail, Value, [])} | PropList];
        _ -> Res
    end.

handle_range_post(Req) ->
    PermFilters =
        case promql_filters_for_identity(menelaus_auth:get_identity(Req)) of
            [] -> menelaus_util:web_exception(403, "Forbidden");
            F -> F
        end,
    Now = os:system_time(millisecond),
    validator:handle(
      fun (List) ->
          %% New process is needed to avoid leaving response messages in
          %% mochiweb handler process's mailbox in case of timeout or other
          %% problems
          misc:executing_on_new_process(
            fun () ->
                Monitors = start_node_extractors_monitoring(List),
                Requests = lists:map(send_metrics_request(_, PermFilters),
                                     List),
                reply_with_chunked_json_array(
                  fun ({Ref, Props}, DownHosts) ->
                      read_metrics_response(Ref, Props, Now, DownHosts)
                  end, [], lists:zip(Requests, List), Req),
                stop_node_extractors_monitoring(Monitors)
            end)
      end, Req, json_array, post_validators(Now, Req)).

reply_with_chunked_json_array(Fun, AccInit, List, Req) ->
    HTTPResp = menelaus_util:reply_ok(
                 Req, "application/json; charset=utf-8", chunked),
    Write = mochiweb_response:write_chunk(_, HTTPResp),
    Write(<<"[">>),
    _ = lists:foldl(
          fun (E, {IsFirst, Acc}) ->
              case IsFirst of
                  true -> ok;
                  false -> Write(<<",">>)
              end,
              try
                  {Res, NewAcc} = Fun(E, Acc),
                  Write(ejson:encode(Res)),
                  {false, NewAcc}
              catch
                  Type:What:Stack ->
                      {Msg, Report} =
                          menelaus_util:server_error_report(Req, Type, What,
                                                            Stack),
                      ?log_error("Server error during processing: ~p",
                                 [Report]),
                      ErrorReply = {[{data, []},
                                     {errors, [{[{node, node()},
                                                 {error, Msg}]}]}]},
                      Write(ejson:encode(ErrorReply)),
                      {false, Acc}
              end
          end, {true, AccInit}, List),
    Write(<<"]">>),
    Write(<<>>).

handle_range_get([], _Req) ->
    menelaus_util:web_exception(404, "not found");
handle_range_get([MetricName | NotvalidatedFunctions], Req) ->
    PermFilters =
        case promql_filters_for_identity(menelaus_auth:get_identity(Req)) of
            [] -> menelaus_util:web_exception(403, "Forbidden");
            F -> F
        end,
    Functions = try validate_functions(NotvalidatedFunctions)
                catch
                    error:invalid_function ->
                        menelaus_util:web_exception(404, "not found")
                end,
    Now = os:system_time(millisecond),
    validator:handle(
      fun (Props) ->
          Labels = lists:filter(fun ({K, _V}) ->
                                     not lists:member(K, [timeWindow, step,
                                                          start, 'end', nodes,
                                                          aggregationFunction,
                                                          timeout,
                                                          alignTimestamps])
                                end, Props),
          AllLabels = [{<<"name">>, iolist_to_binary(MetricName)} | Labels],
          Metric = lists:map(
                     fun ({Name, Value}) ->
                         {[{<<"label">>, Name}, {<<"value">>, Value}]}
                     end, AllLabels),
          NewProps = [{metric, Metric}, {applyFunctions, Functions} | Props],
          %% New process is needed to avoid leaving response messages in
          %% mochiweb handler process's mailbox in case of timeout or other
          %% problems
          misc:executing_on_new_process(
            fun () ->
                Monitors = start_node_extractors_monitoring([Props]),
                Ref = send_metrics_request(NewProps, PermFilters),
                {Res, _} = read_metrics_response(Ref, NewProps, Now, []),
                stop_node_extractors_monitoring(Monitors),
                menelaus_util:reply_json(Req, Res)
            end)
      end, Req, qs, get_validators(Now, MetricName, Req)).

post_validators(Now, Req) ->
    [validate_metric_json(metric, _),
     validator:required(metric, _),
     validator:string_array(applyFunctions, _),
     validate_functions(applyFunctions, _),
     validator:string_array(nodes, _) | validators(Now, Req)] ++
    [validator:validate_relative(
       fun (special, Metric) ->
               case is_derived_metric(extract_metric_name(Metric)) of
                   false ->
                       {error, <<"'special' aggregation is not available for "
                                 "non-derived metric">>};
                   _ -> ok
               end;
           (_, _) -> ok
       end, aggregationFunction, metric, _),
     validator:unsupported(_)].

get_validators(Now, MetricName, Req) ->
    [validator:token_list(nodes, ", ", _) | validators(Now, Req)] ++
    [validator:validate(
       fun (special) ->
               case is_derived_metric(iolist_to_binary(MetricName)) of
                   false ->
                       {error, <<"'special' aggregation is not available for "
                                 "non-derived metric">>};
                   _ -> ok
               end;
           (_) -> ok
       end, aggregationFunction, _)].

validators(Now, Req) ->
    NowSec = Now div 1000,
    [validate_time_duration(timeWindow, _),
     validator:default(timeWindow, "1m", _),
     validator:boolean(alignTimestamps, _),
     validate_nodes_v2(nodes, _, Req),
     validator:default(nodes,
                       ?cut(menelaus_web_node:get_hostnames(Req, any)), _),
     validator:one_of(aggregationFunction,
                      [max, min, avg, sum, none, special], _),
     validator:convert(aggregationFunction,
                       fun (L) when is_binary(L) -> binary_to_atom(L, latin1);
                           (L) -> list_to_atom(L)
                       end, _),
     validate_time_duration(step, _),
     validator:default(step, "10s", _),
     validator:integer(start, ?MIN_TS, ?MAX_TS, _),
     validator:integer('end', ?MIN_TS, ?MAX_TS, _),
     validate_negative_ts(start, NowSec, _),
     validate_negative_ts('end', NowSec, _),
     validator:greater_or_equal('end', start, _),
     validator:default(start, NowSec - 60, _),
     validator:default('end', NowSec, _),
     maybe_align_start(_),
     validator:integer(timeout, 1, 60*5*1000, _),
     validator:default(timeout, ?DEFAULT_PROMETHEUS_QUERY_TIMEOUT, _)].

start_node_extractors_monitoring(List) ->
    AllNodes = lists:foldl(
                 fun (Props, Acc) ->
                     Nodes = [N || {N, _} <- proplists:get_value(nodes, Props)],
                     lists:umerge(lists:sort(Nodes), Acc)
                 end, [], List),
    lists:map(fun (N) -> erlang:monitor(process, {ns_server_stats, N}) end,
              AllNodes).

stop_node_extractors_monitoring(Refs) ->
    lists:map(
      fun (Ref) ->
          erlang:demonitor(Ref, [flush])
      end, Refs).

is_derived_metric(Name) ->
    get_derived_metric(Name) =/= [].

get_derived_metric(Name, Key) ->
    proplists:get_value(Key, get_derived_metric(Name)).

get_derived_metric(<<"index_fragmentation">>) ->
    [{params, [<<"fragmented_size">>, <<"total_size">>]},
     {aggregation_fun,
      fun (FragmentedSizes, TotalSizes) ->
          aggregate('div', [aggregate(sum, FragmentedSizes),
                            aggregate(sum, TotalSizes)])
      end},
     {query,
      fun (ExtraLabels) ->
          FragmentedSize =
            {call, sum, {without, [<<"index">>, <<"collection">>, <<"scope">>]},
             [{'*', [{ignoring, [<<"name">>]}],
               [{[{eq, <<"name">>, <<"index_disk_size">>} | ExtraLabels]},
                {[{eq, <<"name">>, <<"index_frag_percent">>} | ExtraLabels]}]}]},
          TotalSize =
            {call, sum, {without, [<<"index">>, <<"collection">>, <<"scope">>]},
             [{[{eq, <<"name">>, <<"index_disk_size">>} | ExtraLabels]}]},
          [FragmentedSize, TotalSize]
      end}];
get_derived_metric(_) -> [].

send_metrics_request(Props, PermFilters) ->
    Functions = proplists:get_value(applyFunctions, Props, []),
    Window = proplists:get_value(timeWindow, Props),
    Labels = proplists:get_value(metric, Props),
    MetricName = extract_metric_name(proplists:get_value(metric, Props, [])),
    Query =
        case get_derived_metric(MetricName, params) of
            undefined ->
                construct_promql_query(Labels, Functions, Window, PermFilters);
            _ ->
                derived_metric_query(Labels, PermFilters)
        end,
    Start = proplists:get_value(start, Props),
    End = proplists:get_value('end', Props),
    Step = proplists:get_value(step, Props),
    Timeout = proplists:get_value(timeout, Props),
    Nodes = proplists:get_value(nodes, Props),
    NodesToPoll = lists:usort([N || {N, _} <- Nodes]),
    Ref = make_ref(),
    lists:foreach(
      fun (N) ->
          Req = {extract, {self(), {Ref, N}}, Query, Start, End, Step, Timeout},
          gen_server:cast({ns_server_stats, N}, Req)
      end, NodesToPoll),
    Ref.

read_metrics_response(Ref, Props, StartTimestampMs, DownHosts) ->
    Nodes = proplists:get_value(nodes, Props),
    Timeout = proplists:get_value(timeout, Props),
    {BadRes, GoodRes} =
        misc:partitionmap(
          fun ({Node, HostPort}) ->
              case lists:member(HostPort, DownHosts) of
                  true -> {left, {HostPort, down}};
                  false ->
                      TimeLeft = max(StartTimestampMs + Timeout -
                                     os:system_time(millisecond), 0),
                      receive
                          {{Ref, Node}, {ok, R}} -> {right, {HostPort, R}};
                          {{Ref, Node}, {error, R}} -> {left, {HostPort, R}};
                          {'DOWN', _, _, {ns_server_stats, Node}, _} ->
                              {left, {HostPort, down}}
                      after TimeLeft ->
                          {left, {HostPort, timeout}}
                      end
              end
          end, Nodes),
    AggFunction = proplists:get_value(aggregationFunction, Props, none),
    MetricName = extract_metric_name(proplists:get_value(metric, Props, [])),
    IsDerived = is_derived_metric(MetricName),
    CleanedRes = [{N, clean_metric_props(R)} || {N, R} <- GoodRes],
    Data = merge_metrics(CleanedRes, Props, IsDerived, AggFunction),
    Errors = [{[{node, N},
                {error, format_error(R)}]}
                 || {N, R} <- BadRes],
    NewDownHosts = lists:usort(DownHosts ++ [H || {H, down} <- BadRes]),
    Start = proplists:get_value(start, Props),
    End = proplists:get_value('end', Props),
    {{[{data, Data}, {errors, Errors}, {startTimestamp, Start},
       {endTimestamp, End}]}, NewDownHosts}.

validate_metric_json(Name, State) ->
    validator:validate(
      fun ([]) ->
              {error, "must not be empty"};
          (Labels) when is_list(Labels) ->
              try
                  lists:foreach(
                    fun ({Props}) -> validate_label_props(Props);
                        (_) -> throw("must be a list of JSON objects")
                    end, Labels),
                  ok
              catch
                  throw:Msg -> {error, Msg}
              end;
          (_) ->
              {error, "must be a list of JSON objects"}
      end, Name, State).

validate_label_props(LabelProps) ->
    lists:foreach(
      fun ({N, _}) ->
          case lists:member(N, [<<"label">>, <<"value">>, <<"operator">>]) of
              true -> ok;
              false -> throw(io_lib:format("unknown label prop: ~s", [N]))
          end
      end, LabelProps),
    case proplists:is_defined(<<"label">>, LabelProps) and
         proplists:is_defined(<<"value">>, LabelProps) of
        true -> ok;
        false -> throw("all metric labels must contain "
                       "'label' and 'value' keys")
    end,
    Op = proplists:get_value(<<"operator">>, LabelProps, <<"=">>),
    case lists:member(Op, [<<"=">>, <<"!=">>, <<"=~">>, <<"!~">>, <<"any">>,
                           <<"not_any">>]) of
        true -> ok;
        false -> throw(io_lib:format("invalid operator: ~p", [Op]))
    end,
    Name = proplists:get_value(<<"label">>, LabelProps),
    case is_binary(Name) of
        true -> ok;
        false -> throw("Label name must be a string")
    end,
    Val = proplists:get_value(<<"value">>, LabelProps),
    case lists:member(Op, [<<"any">>, <<"not_any">>]) of
        true ->
            (is_list(Val) andalso lists:all(fun is_binary/1, Val)) orelse
                throw(io_lib:format("label value for ~s must be a list of "
                                    "strings when used with '~s' operation",
                                    [Name, Op]));
        false ->
            is_binary(Val) orelse
                throw(io_lib:format("label value for ~s must be a string",
                                    [Name]))
    end.

validate_functions(Name, State) ->
    validator:validate(
      fun (L) ->
          try
              {value, validate_functions(L)}
          catch
              error:invalid_function ->
                  {error, "invalid list of functions"}
          end
      end, Name, State).

clean_metric_props(Metrics) ->
    lists:map(
      fun ({MetricProps}) ->
          {misc:key_update(<<"metric">>, MetricProps,
                           fun ({P}) ->
                               {functools:chain(
                                  P, [proplists:delete(<<"job">>, _),
                                      proplists:delete(<<"__name__">>, _)])}
                           end)}
      end, Metrics).

aggregate_results(Results, AggregationParams, AggregationFun) ->
    UnpackedResults = [{maps:from_list(Metric), Values}
                        || {Props} <- Results,
                           [{<<"metric">>, {Metric}},
                            {<<"values">>, Values}] <- [lists:sort(Props)]],
    lists:map(
      fun ({NamePropsMap, List}) ->
          {[{<<"metric">>, {maps:to_list(NamePropsMap)}},
            {<<"values">>, aggregate_values(List, AggregationParams,
                                            AggregationFun)}]}
      end, misc:groupby_map(
             fun ({M, V}) ->
                PName = maps:get(?DERIVED_PARAM_LABEL, M, default_param),
                %% if this metric is part of a derived metric,
                %% the name label will lead to incorrect groupping (we will
                %% set other name for it after aggregation anyway).
                LabelsToRemove = [?DERIVED_PARAM_LABEL] ++
                                 [<<"name">> || PName =/= default_param],
                {maps:without(LabelsToRemove, M), {PName, V}}
             end, UnpackedResults)).

%% List :: [{ParamName, list([Timestamp, ValueAsStr])}]
%% Example:
%% [{param1, [[16243234, "1"], [16243235, "1"], [16243236, "1"]]},
%% [{param1, [[16243234, "2"],                  [16243236, "2"]]},
%% [{param2, [[16243234, "3"], [16243235, "3"], [16243236, "3"]]},
%% [{param2, [[16243234, "4"], [16243235, "4"]                 ]}]
aggregate_values(List, AggregationParams, AggregationFun) ->
      %% List2 :: [{ParamName, list(list([Timestamp, ValueAsStr]))}]
      %% Example:
      %% [{param1, [[[16243234, "1"], [16243235, "1"], [16243236, "1"]],
      %%            [[16243234, "2"],                  [16243236, "2"]]]},
      %%  {param2, [[[16243234, "3"], [16243235, "3"], [16243236, "3"]],
      %%            [[16243234, "4"], [16243235, "4"],                ]]}]
      List2 = misc:groupby_map(fun functools:id/1, List),

      Timestamps = lists:umerge(lists:map(?cut([TS || [TS, _V] <- _1]),
                                          [L || {_, L} <- List])),
      Normalize = normalize_datapoints(Timestamps, _, []),

      %% List3 :: [[[ValueAsStr]]]
      %% Example:
      %%        Node1              Node2
      %% [ [["1", "1", "1"], ["2", "NaN", "2"]],   <- param1
      %%   [["3", "3", "3"], ["4", "4", "NaN"]] ]  <- param2
      List3 = [lists:map(Normalize, proplists:get_value(P, List2, []))
               || P <- AggregationParams],

      %% List4 :: [[[ValueAsStr]]]
      %% Example: [ [["1", "2"], ["1", "NaN"], ["1", "2"]],
      %%            [["3", "4"], ["3", "4"], ["3", "NaN"]] ]
      List4 = lists:map(
                fun ([]) ->
                        [[] || _ <- Timestamps];
                    (ValueLists) ->
                        misc:zipwithN(fun (L) -> L end, ValueLists)
                end, List3),

      %% List5 :: [AggregatedValueAsStr]
      %% Example: [AggregationFun([1, 2], [3, 4]),
      %%           AggregationFun([1, undefined], [3, 4]),
      %%           AggregationFun([1, 2], [3, undefined])]
      %% and if AggregationFun is sum, List4 will be [10, 8, 6]
      List5 = misc:zipwithN(
                fun (ValuesLists) ->
                   ParsedValuesLists =
                     [[prometheus:parse_value(V) || V <- Values]
                      || Values <- ValuesLists],
                   Res = erlang:apply(AggregationFun, ParsedValuesLists),
                   prometheus:format_value(Res)
                end, List4),

      %% Values :: [ [Timestamp, AggregatedValueAsStr] ]
      %% Example: [[16243234, 10], [16243235, 8], [16243236, 6]]
      lists:zipwith(?cut([_1, _2]), Timestamps, List5).

-ifdef(TEST).

aggregate_results_test() ->
    ?assertEqual([], aggregate_results([], [<<"op1">>], undefined)),

    Values = [
        %% From node 1
        {[{<<"metric">>, {[{<<"name">>, <<"m1">>}, {<<"b">>, <<"b1">>},
                           {?DERIVED_PARAM_LABEL, <<"op1">>}]}},
          {<<"values">>, [[1, <<"2">>], [2, <<"3">>], [3, <<"5">>]]}]},
        {[{<<"metric">>, {[{<<"name">>, <<"m1">>}, {<<"b">>, <<"b2">>},
                           {?DERIVED_PARAM_LABEL, <<"op1">>}]}},
          {<<"values">>, [[1, <<"7">>], [2, <<"11">>], [3, <<"13">>]]}]},
        {[{<<"metric">>, {[{<<"name">>, <<"m2">>}, {<<"b">>, <<"b1">>},
                           {?DERIVED_PARAM_LABEL, <<"op2">>}]}},
          {<<"values">>, [[1, <<"17">>], [2, <<"19">>], [3, <<"23">>]]}]},
        {[{<<"metric">>, {[{<<"name">>, <<"m2">>}, {<<"b">>, <<"b2">>},
                           {?DERIVED_PARAM_LABEL, <<"op2">>}]}},
          {<<"values">>, [               [2, <<"31">>], [3, <<"37">>]]}]},
        %% From node 2
        {[{<<"metric">>, {[{<<"name">>, <<"m1">>}, {<<"b">>, <<"b1">>},
                           {?DERIVED_PARAM_LABEL, <<"op1">>}]}},
          {<<"values">>, [[1, <<"41">>], [2, <<"43">>], [3, <<"47">>]]}]},
        {[{<<"metric">>, {[{<<"name">>, <<"m1">>}, {<<"b">>, <<"b2">>},
                           {?DERIVED_PARAM_LABEL, <<"op1">>}]}},
          {<<"values">>, [[1, <<"53">>], [2, <<"59">>], [3, <<"61">>]]}]},
        {[{<<"metric">>, {[{<<"name">>, <<"m2">>}, {<<"b">>, <<"b1">>},
                           {?DERIVED_PARAM_LABEL, <<"op2">>}]}},
          {<<"values">>, [[1, <<"67">>], [2, <<"71">>], [3, <<"73">>]]}]},
        {[{<<"metric">>, {[{<<"name">>, <<"m2">>}, {<<"b">>, <<"b2">>},
                           {?DERIVED_PARAM_LABEL, <<"op2">>}]}},
          {<<"values">>, [[1, <<"79">>], [2, <<"83">>], [3, <<"89">>]]}]}
    ],
    Res = aggregate_results(Values, [<<"op1">>, <<"op2">>, <<"op3">>],
                            fun (Op1, Op2, Op3) ->
                                 %% Op3 is missing in values
                                 ?assertEqual([], Op3),
                                 %% Need +1 to add some asymmetry
                                 aggregate(sum, Op1) * (aggregate(sum, Op2) + 1)
                            end),
    ?assertEqual([{[{<<"metric">>, {[{<<"b">>, <<"b1">>}]}},
                   {<<"values">>,
                    [[1, <<"3655">>], %% (2 + 41) * (17 + 67 + 1)
                     [2, <<"4186">>], %% (3 + 43) * (19 + 71 + 1)
                     [3, <<"5044">>]]}]}, %% (5 + 47) * (23 + 73 + 1)
                  {[{<<"metric">>, {[{<<"b">>, <<"b2">>}]}},
                    {<<"values">>,
                     [[1, <<"4800">>], %% (7 + 53) * ((miss) + 79 + 1)
                      [2, <<"8050">>], %% (11 + 59) * (31 + 83 + 1)
                      [3, <<"9398">>]]}]}], %% (13 + 61) * (37 + 89 + 1)
                 Res).
-endif.

metrics_add_label(Res, Labels) ->
    lists:map(
      fun ({Props}) ->
          {misc:key_update(<<"metric">>, Props,
                           fun ({P}) -> {Labels ++ P} end)}
      end, Res).

merge_metrics(NodesResults, _ReqProps, false, none) ->
    lists:flatmap(
      fun ({Node, List}) -> metrics_add_label(List, [{nodes, [Node]}]) end,
      NodesResults);
merge_metrics(NodesResults, _ReqProps, false, AggFunctionName) ->
    {Nodes, ResultsLists} = lists:unzip(NodesResults),
    FlatResults = lists:flatten(ResultsLists),
    AggFun2 = aggregate(AggFunctionName, _),
    %% When request is not supposed to contain any named parameters we use
    %% 'default_param' atom to point to all the metrics without any param name
    %% label
    FlatAggregated = aggregate_results(FlatResults, [default_param], AggFun2),
    metrics_add_label(FlatAggregated, [{nodes, Nodes}]);
merge_metrics(NodesResults, ReqProps, true, none) ->
    Name = extract_metric_name(proplists:get_value(metric, ReqProps, [])),
    AggFun = get_derived_metric(Name, aggregation_fun),
    Params = get_derived_metric(Name, params),
    NodesResults2 = [{N, aggregate_results(R, Params, AggFun)}
                         || {N, R} <- NodesResults],
    lists:flatmap(
      fun ({Node, List}) ->
          metrics_add_label(List, [{nodes, [Node]}, {name, Name}])
      end, NodesResults2);
merge_metrics(NodesResults, ReqProps, true, special) ->
    Name = extract_metric_name(proplists:get_value(metric, ReqProps, [])),
    AggFun = get_derived_metric(Name, aggregation_fun),
    Params = get_derived_metric(Name, params),
    {Nodes, ResultsLists} = lists:unzip(NodesResults),
    FlatResults = lists:flatten(ResultsLists),
    FlatAggregated = aggregate_results(FlatResults, Params, AggFun),
    metrics_add_label(FlatAggregated, [{nodes, Nodes}, {name, Name}]);

merge_metrics(NodesResults, ReqProps, true, AggFunctionName) ->
    Name = extract_metric_name(proplists:get_value(metric, ReqProps, [])),
    AggFun = get_derived_metric(Name, aggregation_fun),
    Params = get_derived_metric(Name, params),
    NodesResults2 = [{N, aggregate_results(R, Params, AggFun)}
                         || {N, R} <- NodesResults],
    {Nodes, ResultsLists} = lists:unzip(NodesResults2),
    FlatResults = lists:flatten(ResultsLists),
    AggFun2 = aggregate(AggFunctionName, _),
    FlatAggregated = aggregate_results(FlatResults, [default_param], AggFun2),
    metrics_add_label(FlatAggregated, [{nodes, Nodes}, {name, Name}]).

construct_promql_query(Labels, Functions, Window, PermFilters) ->
    {RangeVFunctions, InstantVFunctions} =
        lists:splitwith(fun is_range_vector_function/1, Functions),
    functools:chain(
      Labels,
      [lists:map(fun construct_promql_labels_ast/1, _),
       ?cut(lists:map(fun ({PermFilter}) -> {_ ++ PermFilter} end,
                      PermFilters)),
       case RangeVFunctions of
           [] -> fun functools:id/1;
           _ -> lists:map(fun (Ast) -> range_vector(Ast, Window) end, _)
       end,
       lists:map(fun (Ast) -> apply_functions(Ast, RangeVFunctions) end, _),
       {'or', _},
       apply_functions(_, InstantVFunctions),
       prometheus:format_promql(_)]).

derived_metric_query(Labels, AuthorizationLabelsList) ->
    LabelsAst = lists:map(fun construct_promql_labels_ast/1, Labels),

    {[{eq, <<"name">>, Name}], RestLabels} =
        lists:partition(
          fun ({eq, <<"name">>, _}) -> true;
              ({_, _, _}) -> false
          end, LabelsAst),

    prometheus:format_promql(
      {'or', lists:flatmap(
               fun ({AuthorizationLabels}) ->
                   ExtraLabels = RestLabels ++ AuthorizationLabels,
                   ParamAsts = (get_derived_metric(Name, query))(ExtraLabels),
                   Params = get_derived_metric(Name, params),
                   [{call, label_replace, none,
                     [AST, ?DERIVED_PARAM_LABEL, N, <<>>, <<>>]}
                    || {N, AST} <- lists:zip(Params, ParamAsts)]
               end, AuthorizationLabelsList)}).

construct_promql_labels_ast({MetricProps}) ->
    Label = proplists:get_value(<<"label">>, MetricProps),
    Value = proplists:get_value(<<"value">>, MetricProps),
    Op = case proplists:get_value(<<"operator">>, MetricProps, <<"=">>) of
             <<"=">> -> eq;
             <<"!=">> -> not_eq;
             <<"=~">> -> re;
             <<"!~">> -> not_re;
             <<"any">> -> eq_any;
             <<"not_any">> -> not_any
         end,
    {Op, Label, Value}.

range_vector(Ast, TimeWindow) -> {range_vector, Ast, TimeWindow}.

apply_functions(Ast, Functions) ->
    lists:foldl(
      fun ({histogram_quantile, Q}, AccAst) ->
              {call, histogram_quantile, none, [Q, AccAst]};
          ({F, by, Labels}, AccAst) ->
              {call, F, {by, Labels}, [AccAst]};
          (F, AccAst) ->
              {call, F, none, [AccAst]}
      end, Ast, Functions).

is_range_vector_function(Function) ->
    lists:member(Function, [rate, irate, increase, avg_over_time, min_over_time,
                            max_over_time, deriv, delta, idelta]).

validate_functions(Functions) ->
    Parsed =
        lists:map(
          fun ("rate") -> rate;
              ("irate") -> irate;
              ("increase") -> increase;
              ("avg_over_time") -> avg_over_time;
              ("min_over_time") -> min_over_time;
              ("max_over_time") -> max_over_time;
              ("deriv") -> deriv;
              ("delta") -> delta;
              ("idelta") -> idelta;
              ("sum") -> sum;
              ("min") -> min;
              ("max") -> max;
              ("avg") -> avg;
              ("p" ++ PStr) ->
                  try list_to_integer(PStr) of
                      P when 0 < P; P =< 100  -> {histogram_quantile, P/100};
                      _ -> error(invalid_function)
                  catch
                      _:_ -> error(invalid_function)
                  end;
              (_) -> error(invalid_function)
          end, Functions),

    %% If sum is used inside quantile, we should sum by le. The reason is
    %% because the histogram_quantile function needs 'le' label to present.
    %% The same logic works for other aggregative functions, like min, max, etc.
    %% For example:
    %% "http_request_duration_bucket/sum/p90" should be converted
    %%   histogram_quantile(0.9, sum by (le) (http_request_duration_bucket))
    %% instead of
    %%   histogram_quantile(0.9, sum(http_request_duration_bucket))
    %% which will not work
    Reversed =
        lists:foldl(
          fun ({histogram_quantile, _} = F, Acc) ->
                  case Acc of
                      [] -> [F];
                      [PrevF | T] ->
                          case lists:member(PrevF, [sum, min, max, avg]) of
                              true -> [F, {PrevF, by, ["le"]} | T];
                              false -> [F | Acc]
                          end
                  end;
              (F, Acc) ->
                  [F | Acc]
          end, [], Parsed),
    lists:reverse(Reversed).

%% If no unit is specified, we assume it's in seconds
validate_time_duration(Name, State) ->
    validator:validate(
      fun (Duration) when is_number(Duration), Duration =< 0.001 ->
              {error, <<"must be greater than 1ms">>};
          (Duration) when is_integer(Duration) ->
              {value, integer_to_list(Duration) ++ "s"};
          (Duration) when is_float(Duration) ->
              MS = round(Duration * 1000),
              {value, integer_to_list(MS) ++ "ms"};
          (Duration) ->
              DurationStr = case is_binary(Duration) of
                                true -> binary_to_list(Duration);
                                false -> Duration
                            end,
              try list_to_integer(DurationStr) of
                  Int -> {value, integer_to_list(Int) ++ "s"}
              catch _:_ ->
                  case prometheus:parse_time_duration(DurationStr) of
                      {ok, _} -> {value, DurationStr};
                      {error, Error} -> {error, Error}
                  end
              end
      end, Name, State).

promql_filters_for_identity(Identity) ->
    CompiledRoles = menelaus_roles:get_compiled_roles(Identity),
    PermCheck =
        fun (Obj) ->
            menelaus_roles:is_allowed(collection_perm(Obj), CompiledRoles)
        end,
    case PermCheck([all, all, all]) of
        true -> [{[]}]; %% one empty filter
        false ->
            Roles = menelaus_roles:get_roles(Identity),
            Definitions = menelaus_roles:get_definitions(all),
            PermMap = build_stats_perm_map(Roles, PermCheck, Definitions),
            convert_perm_map_to_promql_ast(PermMap)
    end.

collection_perm([B, S, C]) -> {[{collection, [B, S, C]}, stats], read};
collection_perm([B, S]) ->    {[{collection, [B, S, all]}, stats], read};
collection_perm([B]) ->       {[{collection, [B, all, all]}, stats], read}.

build_stats_perm_map(UserRoles, PermCheckFun, RolesDefinitions) ->
    ParamDefs = menelaus_roles:get_param_defs(_, RolesDefinitions),
    StrippedParams =
        [{Defs, menelaus_roles:strip_ids(Defs, P)} || {R, P} <- UserRoles,
                                                      Defs <- [ParamDefs(R)]],
    Params =
        misc:groupby_map(
          fun ({[bucket_name], B}) -> {buckets, B};
              ({?RBAC_SCOPE_PARAMS, [B, any]}) -> {buckets, [B]};
              ({?RBAC_COLLECTION_PARAMS, [B, any, any]}) -> {buckets, [B]};
              ({?RBAC_SCOPE_PARAMS, S}) -> {scopes, S};
              ({?RBAC_COLLECTION_PARAMS, [B, S, any]}) -> {scopes, [B, S]};
              ({?RBAC_COLLECTION_PARAMS, P}) -> {collections, P}
          end, StrippedParams),

    CheckParam =
        fun F([Obj], CheckPerm, Acc) ->
                case CheckPerm([Obj]) of
                    true -> Acc#{Obj => true};
                    false -> Acc
                end;
            F([Obj | T], CheckPerm, Acc) ->
                case maps:get(Obj, Acc, #{}) of
                    true -> Acc;
                    Map ->
                        NewCheckPerm = fun (E) -> CheckPerm([Obj | E]) end,
                        SubAcc = F(T, NewCheckPerm, Map),
                        Acc#{Obj => SubAcc}
                end
        end,

    CheckParamPerm = ?cut(CheckParam(_1, PermCheckFun, _2)),

    functools:chain(
      #{},
      [lists:foldl(CheckParamPerm, _,
                   proplists:get_value(buckets, Params, [])),
       lists:foldl(CheckParamPerm, _,
                   proplists:get_value(scopes, Params, [])),
       lists:foldl(CheckParamPerm, _,
                   proplists:get_value(collections, Params, []))]).

convert_perm_map_to_promql_ast(PermMap) ->
    AllowedBuckets = maps:keys(maps:filter(fun (_, V) -> V =:= true end,
                                           PermMap)),
    Filters =
        [{[{eq_any, "bucket", AllowedBuckets}]} || AllowedBuckets =/= []] ++
        maps:fold(
          fun (_Bucket, true, Acc) -> Acc;
              (Bucket, ScopePermMap, Acc) ->
                  AllowedScopes = maps:keys(
                                    maps:filter(fun (_, V) -> V =:= true end,
                                                ScopePermMap)),
                  [{[{eq, "bucket", Bucket},
                     {re, "scope", lists:join("|", AllowedScopes)}]}
                        || AllowedScopes =/= []] ++
                  maps:fold(
                    fun (_Scope, true, Acc2) -> Acc2;
                        (Scope, CollectionsPermMap, Acc2) ->
                            AllowedCols = maps:keys(
                                            maps:filter(
                                              fun (_, V) -> V =:= true end,
                                              CollectionsPermMap)),
                            [{[{eq, "bucket", Bucket},
                               {eq, "scope", Scope},
                               {re, "collection", lists:join("|", AllowedCols)}]}
                                    || AllowedCols =/= []] ++ Acc2
                    end, Acc, ScopePermMap)
          end, [], PermMap),
    case Filters of
        [] -> [];
        _ -> [{[{not_re, "bucket", ".+"}]} | Filters]
    end.


verify_derived_metrics(Metrics) ->
    AllDerivedMetrics = all_derived_metrics(),
    case [M || M <- Metrics, not lists:member(M, AllDerivedMetrics)] of
        [] -> {value, Metrics};
        InvalidMetrics ->
            {error, io_lib:format("Invalid derived metrics: ~p",
                                  [InvalidMetrics])}
    end.

all_derived_metrics() ->
    Services = [S || {S, _} <- all_services()],
    Settings = prometheus_cfg:settings(),
    [N || S <- Services, {N, _} <- prometheus_cfg:derived_metrics(S, Settings)].

all_services() ->
    InstallType = case cluster_compat_mode:is_enterprise() of
                      true -> enterprise;
                      false -> community
                  end,
    [{S, atom_to_list(ns_cluster_membership:json_service_name(S))}
        || S <- [ns_server, xdcr |
                 ns_cluster_membership:allowed_services(InstallType)]].

validate_nodes_v2(Name, State, Req) ->
    validator:validate(
      fun (Nodes) ->
              {Right, Wrong} =
                  misc:partitionmap(
                    fun (HostName) ->
                            case menelaus_web_node:find_node_hostname(
                                   HostName, Req, any) of
                                {error, _} ->
                                    {right, HostName};
                                {ok, Node} ->
                                    {left, {Node, list_to_binary(HostName)}}
                            end
                    end, Nodes),
              case Wrong of
                  [] ->
                      {value, Right};
                  _ ->
                      {error, io_lib:format("Unknown hostnames: ~p", [Wrong])}
              end
      end, Name, State).

normalize_datapoints([], [], Acc) ->
    lists:reverse(Acc);
normalize_datapoints([T | Tail1], [[T, V] | Tail2], Acc) ->
    normalize_datapoints(Tail1, Tail2, [V | Acc]);
normalize_datapoints([_ | Tail1], Values, Acc) ->
    normalize_datapoints(Tail1, Values, [<<"NaN">> | Acc]).

aggregate(sum, List) -> foldl2(fun prometheus_sum/2, undefined, List);
aggregate(max, List) -> foldl2(fun prometheus_max/2, undefined, List);
aggregate(min, List) -> foldl2(fun prometheus_min/2, undefined, List);
aggregate(avg, List) ->
    case aggregate(sum, List) of
        undefined -> undefined;
        infinity -> infinity;
        neg_infinity -> neg_infinity;
        N -> N / length(List)
    end;
aggregate('div', [Op1, Op2]) ->
    if Op2 == 0 -> undefined;
       is_number(Op1) andalso is_number(Op2) -> Op1 / Op2;
       Op2 == undefined -> undefined;
       Op2 == infinity andalso is_number(Op1) -> 0;
       Op2 == neg_infinity andalso is_number(Op1) -> 0;
       Op1 == undefined -> undefined;
       Op1 == infinity andalso is_number(Op2) -> infinity;
       Op1 == neg_infinity andalso is_number(Op2) -> neg_infinity;
       is_atom(Op1) andalso is_atom(Op2) -> undefined
    end.

foldl2(_, Acc, []) -> Acc;
foldl2(F, Acc, [E | Tail]) ->
    case F(E, Acc) of
        {stop, Res} -> Res;
        {ok, NewAcc} -> foldl2(F, NewAcc, Tail)
    end.

-ifdef(TEST).

aggregate_test() ->
    ?assertEqual(undefined, aggregate(sum, [])),
    ?assertEqual(undefined, aggregate(max, [])),
    ?assertEqual(undefined, aggregate(min, [])),
    ?assertEqual(undefined, aggregate(avg, [])).

aggregate_randomized_test() ->
    RandomList = fun (N, K, Extra) ->
            L = lists:seq(1,N),
            Undefined = lists:duplicate(K, undefined),
            {lists:sum(L), misc:shuffle(L ++ Undefined ++ Extra)}
        end,
    lists:foreach(
      fun (_) ->
              N = rand:uniform(30),
              K = rand:uniform(20),
              {Sum, List} = RandomList(N, K, []),
              ?assertEqual(Sum, aggregate(sum, List)),
              ?assertEqual(N, aggregate(max, List)),
              ?assertEqual(1, aggregate(min, List)),
              ?assertEqual(Sum / length(List), aggregate(avg, List)),

              {_, List2} = RandomList(N, K, [infinity]),
              ?assertEqual(infinity, aggregate(sum, List2)),
              ?assertEqual(infinity, aggregate(max, List2)),
              ?assertEqual(1, aggregate(min, List2)),
              ?assertEqual(infinity, aggregate(avg, List2)),

              {_, List3} = RandomList(N, K, [neg_infinity]),
              ?assertEqual(neg_infinity, aggregate(sum, List3)),
              ?assertEqual(N, aggregate(max, List3)),
              ?assertEqual(neg_infinity, aggregate(min, List3)),
              ?assertEqual(neg_infinity, aggregate(avg, List3)),

              {_, List4} = RandomList(N, K, lists:duplicate(3, neg_infinity) ++
                                            lists:duplicate(3, infinity)),
              ?assertEqual(undefined, aggregate(sum, List4)),
              ?assertEqual(infinity, aggregate(max, List4)),
              ?assertEqual(neg_infinity, aggregate(min, List4)),
              ?assertEqual(undefined, aggregate(avg, List4))
      end, lists:seq(1,1000)).

aggregate_div_test() ->
    ?assertEqual(3.0, aggregate('div', [6, 2])),
    ?assertEqual(undefined, aggregate('div', [6, 0])),
    ?assertEqual(undefined, aggregate('div', [undefined, 123])),
    ?assertEqual(undefined, aggregate('div', [123, undefined])),
    ?assertEqual(undefined, aggregate('div', [undefined, infinity])),
    ?assertEqual(undefined, aggregate('div', [undefined, neg_infinity])),
    ?assertEqual(undefined, aggregate('div', [infinity, infinity])),
    ?assertEqual(undefined, aggregate('div', [neg_infinity, infinity])),
    ?assertEqual(undefined, aggregate('div', [infinity, neg_infinity])),
    ?assertEqual(undefined, aggregate('div', [infinity, undefined])),
    ?assertEqual(undefined, aggregate('div', [neg_infinity, undefined])),
    ?assertEqual(undefined, aggregate('div', [infinity, 0])),
    ?assertEqual(undefined, aggregate('div', [neg_infinity, 0])),
    ?assertEqual(0, aggregate('div', [2, infinity])),
    ?assertEqual(0, aggregate('div', [2, neg_infinity])),
    ?assertEqual(infinity, aggregate('div', [infinity, 2])),
    ?assertEqual(neg_infinity, aggregate('div', [neg_infinity, 2])).

-endif.

prometheus_sum(undefined, V) -> {ok, V};
prometheus_sum(V, undefined) -> {ok, V};
prometheus_sum(infinity, neg_infinity) -> {stop, undefined};
prometheus_sum(neg_infinity, infinity) -> {stop, undefined};
prometheus_sum(infinity, _) -> {ok, infinity};
prometheus_sum(_, infinity) -> {ok, infinity};
prometheus_sum(neg_infinity, _) -> {ok, neg_infinity};
prometheus_sum(_, neg_infinity) -> {ok, neg_infinity};
prometheus_sum(V1, V2) -> {ok, V1 + V2}.

prometheus_max(undefined, V) -> {ok, V};
prometheus_max(V, undefined) -> {ok, V};
prometheus_max(infinity, _) -> {stop, infinity};
prometheus_max(_, infinity) -> {stop, infinity};
prometheus_max(V, neg_infinity) -> {ok, V};
prometheus_max(neg_infinity, V) -> {ok, V};
prometheus_max(V1, V2) when V1 >= V2 -> {ok, V1};
prometheus_max(_V1, V2) -> {ok, V2}.

prometheus_min(undefined, V) -> {ok, V};
prometheus_min(V, undefined) -> {ok, V};
prometheus_min(neg_infinity, _) -> {stop, neg_infinity};
prometheus_min(_, neg_infinity) -> {stop, neg_infinity};
prometheus_min(V, infinity) -> {ok, V};
prometheus_min(infinity, V) -> {ok, V};
prometheus_min(V1, V2) when V1 >= V2 -> {ok, V2};
prometheus_min(V1, _V2) -> {ok, V1}.

validate_negative_ts(Name, Now, State) ->
    validator:validate(
      fun (TS) when TS < 0 ->
              {value, Now + TS};
          (_) ->
              ok
      end, Name, State).

maybe_align_start(State) ->
    validator:validate_relative(
      fun (_Start, false) -> ok;
          (Start, true) ->
              Step = validator:get_value(step, State),
              End = validator:get_value('end', State),
              case (Step =/= undefined) andalso (End =/= undefined) of
                  true ->
                      {ok, StepMs} = prometheus:parse_time_duration(Step),
                      StartMs = Start * 1000,
                      Aligned = (math:ceil(StartMs / StepMs) * StepMs) / 1000,
                      case Aligned > End of
                          true -> {error, "[start, end] interval doesn't "
                                          "contain any aligned datapoints"};
                          false -> {value, Aligned}
                      end;
                  false ->
                      %% it doesn't make sense to do the check if 'end' or
                      %% 'step' is invalid
                      ok
              end
      end, start, alignTimestamps, State).

format_error(Bin) when is_binary(Bin) -> Bin;
format_error(timeout) -> <<"Request timed out">>;
format_error({exit, {{nodedown, _}, _}}) -> <<"Node is down">>;
format_error({exit, _}) -> <<"Unexpected server error">>;
format_error({failed_connect, _}) -> <<"Connect to stats backend failed">>;
format_error(down) -> <<"Node is not available">>;
format_error(Unknown) -> misc:format_bin("Unexpected error - ~10000p",
                                         [Unknown]).

extract_metric_name([]) -> undefined;
extract_metric_name([{Props} | Labels]) ->
    case proplists:get_value(<<"label">>, Props) of
        <<"name">> -> proplists:get_value(<<"value">>, Props);
        _ -> extract_metric_name(Labels)
    end.
