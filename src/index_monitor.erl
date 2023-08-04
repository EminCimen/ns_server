%% @author Couchbase <info@couchbase.com>
%% @copyright 2021-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.

-module(index_monitor).

-behaviour(gen_server2).

-include("ns_common.hrl").
-include("cut.hrl").

-define(REFRESH_INTERVAL, ?get_param(refresh_interval, 2000)).
-define(DISK_ISSUE_THRESHOLD, ?get_param(disk_issue_threshold, 60)).
-define(MAX_HEALTH_CHECK_DURATION, ?get_param(max_health_check_duration, 2000)).

-export([start_link/0]).
-export([get_nodes/0,
         analyze_status/2,
         is_node_down/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_nodes() ->
    gen_server:call(?MODULE, get_nodes).

is_node_down(health_check_slow) ->
    {true, {"The index service took too long to respond to the health check",
            health_check_slow}};
is_node_down(io_failed) ->
    {true, {"I/O failures are detected by index service", io_failure}};
is_node_down({_, health_check_error} = Error) ->
    {true, Error}.

analyze_status(Node, AllNodes) ->
    health_monitor:analyze_local_status(
      Node, AllNodes, index, fun functools:id/1, healthy).

init([]) ->
    Self = self(),
    Self ! reload_config,
    service_agent:spawn_connection_waiter(Self, index),

    ns_pubsub:subscribe_link(
      ns_config_events,
      fun ({auto_failover_cfg, _}) ->
              Self ! reload_config;
          (_) ->
              ok
      end),

    {ok, HealthChecker} = work_queue:start_link(),
    {ok, #{refresh_timer_ref => undefined,
           health_checker => HealthChecker,
           tick => tock,
           disk_failures => 0,
           prev_disk_failures => undefined,
           last_tick_time => 0,
           last_tick_error => ok,
           enabled => false,
           num_samples => undefined,
           health_info => <<>>}}.

handle_cast({got_connection, Pid}, State) ->
    ?log_debug("Observed json_rpc_connection ~p", [Pid]),
    self() ! refresh,
    {noreply, State}.

handle_call(get_nodes, _From, MonitorState) ->
    #{tick := Tick,
      num_samples := NumSamples,
      health_info := HealthInfo,
      last_tick_time := LastTickTime,
      last_tick_error := LastTickError} = MonitorState,
    Time =
        case Tick of
            tock ->
                LastTickTime;
            {tick, StartTS} ->
                TS = os:timestamp(),
                max(timer:now_diff(TS, StartTS), LastTickTime)
        end,
    Status =
        case Time >= ?MAX_HEALTH_CHECK_DURATION * 1000 of
            true ->
                ?log_debug("Last health check API call was slower than ~pms",
                           [?MAX_HEALTH_CHECK_DURATION]),
                health_check_slow;
            false ->
                case LastTickError of
                    {error, Error} ->
                        ?log_debug("Detected health check error ~p", [Error]),
                        {Error, health_check_error};
                    ok ->
                        case is_unhealthy(HealthInfo, NumSamples) of
                            true ->
                                ?log_debug("Detected IO failure"),
                                io_failed;
                            false ->
                                healthy
                        end
                end
        end,
    {reply, dict:from_list([{node(), Status}]), MonitorState}.

handle_info({tick, HealthCheckResult}, MonitorState) ->
    #{tick := {tick, StartTS}} = MonitorState,
    TS = os:timestamp(),
    NewState = case HealthCheckResult of
                   {ok, DiskFailures} ->
                       MonitorState#{disk_failures => DiskFailures,
                                     last_tick_error => ok};
                   {error, _} = Error ->
                       MonitorState#{last_tick_error => Error}
               end,

    {noreply, NewState#{tick => tock,
                        last_tick_time => timer:now_diff(TS, StartTS)}};

handle_info(reload_config, MonitorState) ->
    Cfg = auto_failover:get_cfg(),
    {Enabled, NumSamples} =
        case auto_failover:is_enabled(Cfg) of
            false ->
                {false, undefined};
            true ->
                {true,
                 case menelaus_web_auto_failover:get_failover_on_disk_issues(
                        Cfg) of
                     {false, _} ->
                         undefined;
                     {true, TimePeriod} ->
                         round((TimePeriod * 1000)/?REFRESH_INTERVAL)
                 end}
        end,
    {noreply, MonitorState#{num_samples => NumSamples,
                            enabled => Enabled}};

handle_info(refresh, #{tick := {tick, StartTS},
                       health_info := HealthInfo,
                       num_samples := NumSamples} = MonitorState) ->
    ?log_debug("Health check initiated at ~p didn't respond in time. "
               "Tick is missing", [StartTS]),
    NewHealthInfo = register_tick(true, HealthInfo, NumSamples),
    {noreply,
     resend_refresh_msg(MonitorState#{health_info => NewHealthInfo})};

handle_info(refresh, #{tick := tock,
                       disk_failures := DiskFailures,
                       prev_disk_failures := PrevDiskFailures,
                       health_info := HealthInfo,
                       num_samples := NumSamples} = MonitorState) ->
    Healthy = PrevDiskFailures == undefined orelse
        DiskFailures =< PrevDiskFailures,
    NewHealthInfo = register_tick(Healthy, HealthInfo, NumSamples),
    NewState = MonitorState#{prev_disk_failures => DiskFailures,
                             health_info => NewHealthInfo},
    {noreply, resend_refresh_msg(initiate_health_check(NewState))}.

health_check(#{enabled := false,
               disk_failures := DiskFailures}) ->
    {ok, DiskFailures};
health_check(#{enabled := true}) ->
    case service_api:health_check(index) of
        {ok, {[{<<"diskFailures">>, DiskFailures}]}} ->
            {ok, DiskFailures};
        {error, Error} ->
            {error, Error}
    end.

resend_refresh_msg(#{refresh_timer_ref := undefined} = MonitorState) ->
    Ref = erlang:send_after(?REFRESH_INTERVAL, self(), refresh),
    MonitorState#{refresh_timer_ref => Ref};
resend_refresh_msg(#{refresh_timer_ref := Ref} = MonitorState) ->
    _ = erlang:cancel_timer(Ref),
    resend_refresh_msg(MonitorState#{refresh_timer_ref => undefined}).

initiate_health_check(#{health_checker := HealthChecker,
                        tick := tock} = MonitorState) ->
    Self = self(),
    TS = os:timestamp(),
    work_queue:submit_work(HealthChecker,
                           ?cut(Self ! {tick, health_check(MonitorState)})),
    MonitorState#{tick => {tick, TS}}.

register_tick(_Healthy, _HealthInfo, undefined) ->
    <<>>;
register_tick(Healthy, HealthInfo, NumSamples) ->
    kv_stats_monitor:register_tick(Healthy, HealthInfo, NumSamples).

is_unhealthy(_HealthInfo, undefined) ->
    false;
is_unhealthy(HealthInfo, NumSamples) ->
    Threshold = round(NumSamples * ?DISK_ISSUE_THRESHOLD / 100),
    kv_stats_monitor:is_unhealthy(HealthInfo, Threshold).
