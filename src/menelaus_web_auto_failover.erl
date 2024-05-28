%% @author Couchbase <info@couchbase.com>
%% @copyright 2017-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
-module(menelaus_web_auto_failover).

-include("cut.hrl").
-include("ns_common.hrl").

-export([handle_settings_get/1,
         handle_settings_post/1,
         handle_settings_reset_count/1,
         get_failover_on_disk_issues/1,
         config_check_can_abort_rebalance/0,
         default_config/1,
         get_stats/0,
         config_upgrade_to_72/1]).

-import(menelaus_util,
        [reply/2,
         reply_json/2,
         reply_json/3,
         reply_text/3,
         parse_validate_number/3,
         parse_validate_boolean_field/3]).

-define(AUTO_FAILOVER_MIN_TIMEOUT, ?get_param(auto_failover_min_timeout, 5)).
-define(AUTO_FAILOVER_MIN_CE_TIMEOUT, 30).
-define(AUTO_FAILOVER_MAX_TIMEOUT, 3600).

-define(CAN_ABORT_REBALANCE_CONFIG_KEY, can_abort_rebalance).
-define(DATA_DISK_ISSUES_CONFIG_KEY, failover_on_data_disk_issues).
-define(MIN_DATA_DISK_ISSUES_TIMEPERIOD, 5). %% seconds
-define(MAX_DATA_DISK_ISSUES_TIMEPERIOD, 3600). %% seconds

-define(FAILOVER_SERVER_GROUP_CONFIG_KEY, failover_server_group).
-define(FAILOVER_PRESERVE_DURABILITY_MAJORITY_CONFIG_KEY,
        failover_preserve_durability_majority).
-define(FAILOVER_PRESERVE_DURABILITY_MAJORITY_DEFAULT, false).

-define(ROOT_CONFIG_KEY, auto_failover_cfg).

-define(MAX_EVENTS_CONFIG_KEY, max_count).
-define(MIN_EVENTS_ALLOWED, 1).
-define(DEFAULT_EVENTS_ALLOWED, 1).

default_config(IsEnterprise) ->
    [{?ROOT_CONFIG_KEY,
      [{enabled, true},
       % timeout is the time (in seconds) a node needs to be
       % down before it is automatically faileovered
       {timeout, 120},
       % count is the number of nodes that were auto-failovered
       {count, 0},
       {failover_on_data_disk_issues, [{enabled, false},
                                       {timePeriod, 120}]},
       {failover_server_group, false},
       {max_count, 1},
       {failed_over_server_groups, []},
       {?CAN_ABORT_REBALANCE_CONFIG_KEY, IsEnterprise}]}].

max_events_allowed() ->
    case cluster_compat_mode:is_cluster_71() of
        true ->
            100;
        false ->
            3
    end.

interesting_stats() ->
    [enabled, count, maxCount].

exported_stat_name(maxCount) -> max_count;
exported_stat_name(Other) -> Other.

get_stats() ->
    Settings = settings_get_inner(),
    lists:filtermap(
      fun (Name) ->
              case lists:keyfind(Name, 1, Settings) of
                  {Name, Value} ->
                      {true, {exported_stat_name(Name), Value}};
                  false ->
                      false
              end
      end, interesting_stats()).

handle_settings_get(Req) ->
    Settings = settings_get_inner(),
    reply_json(Req, {struct, Settings}).

settings_get_inner() ->
    Config = auto_failover:get_cfg(),
    Enabled = proplists:get_value(enabled, Config),
    Timeout = proplists:get_value(timeout, Config),
    Count = proplists:get_value(count, Config),
    Settings = [{enabled, Enabled}, {timeout, Timeout}, {count, Count}],
    Settings ++ get_extra_settings(Config).

handle_settings_post(Req) ->
    ValidateOnly = proplists:get_value(
                     "just_validate", mochiweb_request:parse_qs(Req)) =:= "1",
    Config = auto_failover:get_cfg(),
    case {ValidateOnly,
          validate_settings_auto_failover(
            mochiweb_request:parse_post(Req), Config)} of
        {false, false} ->
            auto_failover:disable(disable_extras(Config)),
            ns_audit:disable_auto_failover(Req),
            reply(Req, 200);
        {false, {error, Errors}} ->
            Errors1 = [<<Msg/binary, "\n">> || {_, Msg} <- Errors],
            reply_text(Req, Errors1, 400);
        {false, Params} ->
            Timeout = proplists:get_value(timeout, Params),
            %% maxCount will not be set for CE and pre-upgrade so use the
            %% default.
            MaxCount = proplists:get_value(maxCount, Params,
                                           ?DEFAULT_EVENTS_ALLOWED),
            Extras = proplists:get_value(extras, Params),
            auto_failover:enable(Timeout, MaxCount, Extras),
            ns_audit:enable_auto_failover(Req, Timeout, MaxCount, Extras),
            reply(Req, 200);
        {true, {error, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 400);
        %% Validation only and no errors
        {true, _}->
            reply_json(Req, {struct, [{errors, null}]}, 200)
    end.

%% @doc Resets the number of nodes that were automatically failovered to zero
handle_settings_reset_count(Req) ->
    auto_failover:reset_count(),
    ns_audit:reset_auto_failover_count(Req),
    reply(Req, 200).

get_failover_on_disk_issues(Config) ->
    case proplists:get_value(?DATA_DISK_ISSUES_CONFIG_KEY, Config) of
        undefined ->
            undefined;
        Val ->
            Enabled = proplists:get_value(enabled, Val),
            TimePeriod = proplists:get_value(timePeriod, Val),
            {Enabled, TimePeriod}
    end.

%% Internal Functions

validate_settings_auto_failover(Args, Config) ->
    case parse_validate_boolean_field("enabled", '_', Args) of
        [{ok, _, true}] ->
            parse_validate_other_params(Args, Config);
        [{ok, _, false}] ->
            false;
        _ ->
            {error, boolean_err_msg(enabled)}
    end.

parse_validate_other_params(Args, Config) ->
    Min = case cluster_compat_mode:is_enterprise() of
              true ->
                  ?AUTO_FAILOVER_MIN_TIMEOUT;
              false ->
                  ?AUTO_FAILOVER_MIN_CE_TIMEOUT
          end,
    Max = ?AUTO_FAILOVER_MAX_TIMEOUT,
    Timeout = proplists:get_value("timeout", Args),
    case parse_validate_number(Timeout, Min, Max) of
        {ok, Val} ->
            parse_validate_extras(Args, [{timeout, Val}, {extras, []}],
                                  Config);
        _ ->
            {error, range_err_msg(timeout, Min, Max)}
    end.

parse_validate_extras(Args, CurrRV, Config) ->
    case cluster_compat_mode:is_enterprise() of
        true ->
            try
                parse_validate_extras_inner(Args, CurrRV, Config)
            catch E ->
                {error, E}
            end;
        false ->
            %% TODO - Check for unsupported params
            CurrRV
    end.

parse_validate_extras_inner(Args, CurrRV, Config) ->
    functools:chain(
        CurrRV,
        [parse_validate_max_count(Args, _, Config),
         parse_validate_failover_disk_issues(Args, _, Config),
         parse_validate_server_group_failover(Args, _),
         parse_validate_can_abort_rebalance(Args, _),
         parse_validate_preserve_durability_majority(Args, _)]).

parse_validate_preserve_durability_majority(Args, CurrRV) ->
    case cluster_compat_mode:is_cluster_72() of
        false ->
            CurrRV;
        true ->
            parse_validate_preserve_durability_majority_inner(Args, CurrRV)
    end.

parse_validate_preserve_durability_majority_inner(Args, CurrRV) ->
    StrKey = "failoverPreserveDurabilityMajority",
    case parse_validate_boolean_field(StrKey, '_', Args) of
        [] ->
            CurrRV;
        [{ok, _, Value}] ->
            add_extras([{?FAILOVER_PRESERVE_DURABILITY_MAJORITY_CONFIG_KEY,
                         Value}], CurrRV);
        [{error, _, _}] ->
            {error, boolean_err_msg(StrKey)}
    end.

parse_validate_can_abort_rebalance(Args, CurrRV) ->
    StrKey = "canAbortRebalance",
    case parse_validate_boolean_field(StrKey, '_', Args) of
        [] ->
            CurrRV;
        [{ok, _, Value}] ->
            add_extras([{?CAN_ABORT_REBALANCE_CONFIG_KEY, Value}], CurrRV);
        [{error, _, _}] ->
            erlang:throw(boolean_err_msg(StrKey))
    end.

parse_validate_max_count(Args, CurrRV, Config) ->
    CurrMax = proplists:get_value(?MAX_EVENTS_CONFIG_KEY, Config),
    Min = ?MIN_EVENTS_ALLOWED,
    Max = max_events_allowed(),
    MaxCount = proplists:get_value("maxCount", Args, integer_to_list(CurrMax)),
    case parse_validate_number(MaxCount, Min, Max) of
        {ok, Val} ->
            [{maxCount, Val} | CurrRV];
        _->
            erlang:throw(range_err_msg(maxCount, Min, Max))
    end.

parse_validate_failover_disk_issues(Args, CurrRV, Config) ->
    Key = "failoverOnDataDiskIssues",
    KeyEnabled = Key ++ "[enabled]",
    KeyTimePeriod = Key ++ "[timePeriod]",

    TimePeriod = proplists:get_value(KeyTimePeriod, Args),
    Min = ?MIN_DATA_DISK_ISSUES_TIMEPERIOD,
    Max = ?MAX_DATA_DISK_ISSUES_TIMEPERIOD,
    TimePeriodParsed = parse_validate_number(TimePeriod, Min, Max),

    case parse_validate_boolean_field(KeyEnabled, '_', Args) of
        [{ok, _, true}] ->
            case TimePeriodParsed of
                {ok, Val} ->
                    Extra = set_failover_on_disk_issues(true, Val),
                    add_extras(Extra, CurrRV);
                _ ->
                    erlang:throw(range_err_msg(KeyTimePeriod, Min, Max))
            end;
        [{ok, _, false}] ->
            {_, CurrTP} = get_failover_on_disk_issues(Config),
            Extra = disable_failover_on_disk_issues(CurrTP),
            add_extras(Extra, CurrRV);
        [] ->
            case TimePeriodParsed =/= invalid of
                true ->
                    %% User has passed the timePeriod paramater
                    %% but enabled is missing.
                    erlang:throw(boolean_err_msg(KeyEnabled));
                false ->
                    CurrRV
            end;
        _ ->
            erlang:throw(boolean_err_msg(KeyEnabled))
    end.

disable_failover_on_disk_issues(TP) ->
    set_failover_on_disk_issues(false, TP).

set_failover_on_disk_issues(Enabled, TP) ->
    [{?DATA_DISK_ISSUES_CONFIG_KEY, [{enabled, Enabled}, {timePeriod, TP}]}].

parse_validate_server_group_failover(Args, CurrRV) ->
    case cluster_compat_mode:is_cluster_71() of
        false ->
            parse_validate_server_group_failover_inner(Args, CurrRV);
        true ->
            CurrRV
    end.

parse_validate_server_group_failover_inner(Args, CurrRV) ->
    Key = "failoverServerGroup",
    case parse_validate_boolean_field(Key, '_', Args) of
        [{ok, _, Val}] ->
            Extra = [{?FAILOVER_SERVER_GROUP_CONFIG_KEY, Val}],
            add_extras(Extra, CurrRV);
        [] ->
            CurrRV;
        _ ->
            erlang:throw(boolean_err_msg(Key))
    end.

add_extras(Add, CurrRV) ->
    {extras, Old} = lists:keyfind(extras, 1, CurrRV),
    lists:keyreplace(extras, 1, CurrRV, {extras, Add ++ Old}).

range_err_msg(Key, Min, Max) ->
    [{Key, list_to_binary(io_lib:format("The value of \"~s\" must be a positive integer in a range from ~p to ~p", [Key, Min, Max]))}].

boolean_err_msg(Key) ->
    [{Key, list_to_binary(io_lib:format("The value of \"~s\" must be true or false", [Key]))}].

config_check_can_abort_rebalance() ->
    proplists:get_value(?CAN_ABORT_REBALANCE_CONFIG_KEY,
                        auto_failover:get_cfg(), false).

get_extra_settings(Config) ->
    case cluster_compat_mode:is_enterprise() of
        true ->
            {Enabled, TimePeriod} = get_failover_on_disk_issues(Config),
            lists:flatten(
              [{failoverOnDataDiskIssues,
                {struct, [{enabled, Enabled}, {timePeriod, TimePeriod}]}},
               {maxCount, proplists:get_value(?MAX_EVENTS_CONFIG_KEY, Config)},
               [{canAbortRebalance,
                 proplists:get_value(
                   ?CAN_ABORT_REBALANCE_CONFIG_KEY, Config)}],
               [{failoverServerGroup,
                 proplists:get_value(?FAILOVER_SERVER_GROUP_CONFIG_KEY,
                                     Config)} ||
                   not cluster_compat_mode:is_cluster_71()],
               [{failoverPreserveDurabilityMajority,
                 proplists:get_value(
                     ?FAILOVER_PRESERVE_DURABILITY_MAJORITY_CONFIG_KEY,
                     Config)}
                   || cluster_compat_mode:is_cluster_72()]]);
        false ->
            []
    end.

disable_extras(Config) ->
    case cluster_compat_mode:is_enterprise() of
        true ->
            {_, CurrTP} = get_failover_on_disk_issues(Config),
            lists:flatten(
              [disable_failover_on_disk_issues(CurrTP),
               [{?CAN_ABORT_REBALANCE_CONFIG_KEY, false}],
               [{?FAILOVER_SERVER_GROUP_CONFIG_KEY, false} ||
                   not cluster_compat_mode:is_cluster_71()]]);
        false ->
            []
    end.

config_upgrade_to_72(Config) ->
    [{set, ?ROOT_CONFIG_KEY,
      auto_failover:get_cfg(Config) ++
            [{?FAILOVER_PRESERVE_DURABILITY_MAJORITY_CONFIG_KEY,
              ?FAILOVER_PRESERVE_DURABILITY_MAJORITY_DEFAULT}]}].
