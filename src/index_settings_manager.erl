%% @author Couchbase <info@couchbase.com>
%% @copyright 2015-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
-module(index_settings_manager).

-include("ns_common.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behavior(json_settings_manager).

-export([start_link/0,
         get/1,
         get_from_config/3,
         update/2,
         update_txn/1,
         config_default/0,
         is_memory_optimized/1]).

-export([cfg_key/0,
         is_enabled/0,
         known_settings/0,
         on_update/2,
         config_upgrade_to_70/1,
         config_upgrade_to_71/1,
         config_upgrade_to_trinity/1]).

-import(json_settings_manager,
        [id_lens/1]).

-define(INDEX_CONFIG_KEY, {metakv, <<"/indexing/settings/config">>}).

start_link() ->
    json_settings_manager:start_link(?MODULE).

get(Key) ->
    json_settings_manager:get(?MODULE, Key, undefined).

get_from_config(Config, Key, Default) ->
    json_settings_manager:get_from_config(?MODULE, Config, Key, Default).

cfg_key() ->
    ?INDEX_CONFIG_KEY.

is_enabled() ->
    true.

on_update(Key, Value) ->
    gen_event:notify(index_events, {index_settings_change, Key, Value}).

update(Key, Value) ->
    json_settings_manager:update(?MODULE, [{Key, Value}]).

update_txn(Props) ->
    json_settings_manager:update_txn(?MODULE, Props).

-spec is_memory_optimized(any()) -> boolean().
is_memory_optimized(?INDEX_STORAGE_MODE_MEMORY_OPTIMIZED) ->
    true;
is_memory_optimized(_) ->
    false.

default_settings() ->
    DaysOfWeek = misc:get_days_list(),
    CircDefaults = [{daysOfWeek, list_to_binary(string:join(DaysOfWeek, ","))},
                    {abort_outside, false},
                    {interval, compaction_interval_default()}],

    [{memoryQuota, 512},
     {generalSettings,
      general_settings_defaults(?CURRENT_MIN_SUPPORTED_VERSION)},
     {compaction, compaction_defaults()},
     {storageMode, <<"">>},
     {compactionMode, <<"circular">>},
     {circularCompaction, CircDefaults}].

known_settings() ->
    %% Currently chronicle and ns_config upgrades are
    %% non-atomic. Additionally, since 7.1 the cluster compat version resides
    %% in chronicle. So it's possible for a node to observe an intermediate
    %% state where chronicle is upgraded while ns_config is not. So in those
    %% few places that rely on ns_config upgrades from pre-7.1 to 7.1,
    %% cluster_compat_mode:get_ns_config_compat_version() must be used.
    ClusterVersion = cluster_compat_mode:get_ns_config_compat_version(),
    known_settings(ClusterVersion).

known_settings(ClusterVersion) ->
    [{memoryQuota, memory_quota_lens()},
     {generalSettings, general_settings_lens(ClusterVersion)},
     {compaction, compaction_lens()},
     {storageMode, id_lens(<<"indexer.settings.storage_mode">>)},
     {compactionMode,
      id_lens(<<"indexer.settings.compaction.compaction_mode">>)},
     {circularCompaction, circular_compaction_lens()}].

%% settings manager populates settings per version. For each online upgrade,
%% it computes the delta between adjacent supported versions to update only the
%% settings that changed between the two.
%% Note that a node (running any version) is seeded with settings specified in
%% config_default(). If we specify settings(LATEST_VERSION) here, the node
%% contains settings as per LATEST_VERSION at start. A node with LATEST_VERSION
%% settings may be part of a cluster with compat_version v1 < latest_version. If
%% the version moves up from v1 to latest, config_upgrade_to_latest is called.
%% This will update settings that changed between v1 and latest (when the node
%% was already initialized with latest_version settings). So config_default()
%% must specify settings for the min supported version.
config_default() ->
    {?INDEX_CONFIG_KEY, json_settings_manager:build_settings_json(
                          default_settings(),
                          dict:new(),
                          known_settings(?CURRENT_MIN_SUPPORTED_VERSION))}.

memory_quota_lens() ->
    Key = <<"indexer.settings.memory_quota">>,

    Get = fun (Dict) ->
                  dict:fetch(Key, Dict) div ?MIB
          end,
    Set = fun (Value, Dict) ->
                  dict:store(Key, Value * ?MIB, Dict)
          end,
    {Get, Set}.

indexer_threads_lens() ->
    Key = <<"indexer.settings.max_cpu_percent">>,
    Get = fun (Dict) ->
                  dict:fetch(Key, Dict) div 100
          end,
    Set = fun (Value, Dict) ->
                  dict:store(Key, Value * 100, Dict)
          end,
    {Get, Set}.

general_settings_lens_props(ClusterVersion) ->
    case cluster_compat_mode:is_enabled_at(ClusterVersion, ?VERSION_70) of
        true ->
            [{redistributeIndexes,
              id_lens(<<"indexer.settings.rebalance.redistribute_indexes">>)},
             {numReplica,
              id_lens(<<"indexer.settings.num_replica">>)}];
        _ ->
            []
    end ++
    case cluster_compat_mode:is_enabled_at(ClusterVersion, ?VERSION_71) of
        true ->
            [{enablePageBloomFilter,
              id_lens(<<"indexer.settings.enable_page_bloom_filter">>)}];
        false ->
            []
    end ++
    case cluster_compat_mode:is_enabled_at(ClusterVersion, ?VERSION_TRINITY) of
        true ->
            [{memHighThreshold,
              id_lens(<<"indexer.settings.thresholds.mem_high">>)},
             {memLowThreshold,
              id_lens(<<"indexer.settings.thresholds.mem_low">>)},
             {unitsHighThreshold,
              id_lens(<<"indexer.settings.thresholds.units_high">>)},
             {unitsLowThreshold,
              id_lens(<<"indexer.settings.thresholds.units_low">>)},
             {blobStorageScheme,
              id_lens(<<"indexer.settings.rebalance.blob_storage_scheme">>)},
             {blobStorageBucket,
              id_lens(<<"indexer.settings.rebalance.blob_storage_bucket">>)},
             {blobStoragePrefix,
              id_lens(<<"indexer.settings.rebalance.blob_storage_prefix">>)},
             {blobStorageRegion,
              id_lens(<<"indexer.settings.rebalance.blob_storage_region">>)}];
        false ->
            []
    end ++
        [{indexerThreads,
          indexer_threads_lens()},
         {memorySnapshotInterval,
          id_lens(<<"indexer.settings.inmemory_snapshot.interval">>)},
         {stableSnapshotInterval,
          id_lens(<<"indexer.settings.persisted_snapshot.interval">>)},
         {maxRollbackPoints,
          id_lens(<<"indexer.settings.recovery.max_rollbacks">>)},
         {logLevel,
          id_lens(<<"indexer.settings.log_level">>)}].

default_rollback_points() ->
    case ns_config_default:init_is_enterprise() of
        true ->
            ?DEFAULT_MAX_ROLLBACK_PTS_PLASMA;
        false ->
            ?DEFAULT_MAX_ROLLBACK_PTS_FORESTDB
    end.

general_settings_defaults(ClusterVersion) ->
    case cluster_compat_mode:is_enabled_at(ClusterVersion, ?VERSION_70) of
        true ->
            NumReplica = config_profile:get_value({indexer, num_replica}, 0),
            [{redistributeIndexes, false},
             {numReplica, NumReplica}];
        _ ->
            []
    end ++
    case cluster_compat_mode:is_enabled_at(ClusterVersion, ?VERSION_71) of
        true ->
            [{enablePageBloomFilter, false}];
        false ->
            []
    end ++
    case cluster_compat_mode:is_enabled_at(ClusterVersion, ?VERSION_TRINITY) of
        true ->
            [{memHighThreshold,
              config_profile:get_value({indexer, mem_high_threshold}, 70)},
             {memLowThreshold,
              config_profile:get_value({indexer, mem_low_threshold}, 50)},
             {unitsHighThreshold,
              config_profile:get_value({indexer, units_high_threshold}, 60)},
             {unitsLowThreshold,
              config_profile:get_value({indexer, units_low_threshold}, 40)},
             {blobStorageScheme, <<"">>},
             {blobStorageBucket, <<"">>},
             {blobStoragePrefix, <<"">>},
             {blobStorageRegion, <<"">>}];

        false ->
            []
    end ++
        [{indexerThreads, 0},
         {memorySnapshotInterval, 200},
         {stableSnapshotInterval, 5000},
         {maxRollbackPoints, default_rollback_points()},
         {logLevel, <<"info">>}].

general_settings_lens(ClusterVersion) ->
    json_settings_manager:props_lens(general_settings_lens_props(ClusterVersion)).

compaction_interval_default() ->
    [{from_hour, 0},
     {to_hour, 0},
     {from_minute, 0},
     {to_minute, 0}].

compaction_interval_lens() ->
    Key = <<"indexer.settings.compaction.interval">>,
    Get = fun (Dict) ->
                  Int0 = binary_to_list(dict:fetch(Key, Dict)),
                  [From, To] = string:tokens(Int0, ","),
                  [FromH, FromM] = string:tokens(From, ":"),
                  [ToH, ToM] = string:tokens(To, ":"),
                  [{from_hour, list_to_integer(FromH)},
                   {from_minute, list_to_integer(FromM)},
                   {to_hour, list_to_integer(ToH)},
                   {to_minute, list_to_integer(ToM)}]
          end,
    Set = fun (Values0, Dict) ->
                  Values =
                      case Values0 of
                          [] ->
                              compaction_interval_default();
                          _ ->
                              Values0
                      end,

                  {_, FromHour} = lists:keyfind(from_hour, 1, Values),
                  {_, ToHour} = lists:keyfind(to_hour, 1, Values),
                  {_, FromMinute} = lists:keyfind(from_minute, 1, Values),
                  {_, ToMinute} = lists:keyfind(to_minute, 1, Values),

                  Value = iolist_to_binary(
                            io_lib:format("~2.10.0b:~2.10.0b,~2.10.0b:~2.10.0b",
                                          [FromHour, FromMinute, ToHour, ToMinute])),

                  dict:store(Key, Value, Dict)
          end,
    {Get, Set}.

circular_compaction_lens_props() ->
    [{daysOfWeek,
      id_lens(<<"indexer.settings.compaction.days_of_week">>)},
     {abort_outside,
      id_lens(<<"indexer.settings.compaction.abort_exceed_interval">>)},
     {interval, compaction_interval_lens()}].

circular_compaction_lens() ->
    json_settings_manager:props_lens(circular_compaction_lens_props()).

compaction_lens_props() ->
    [{fragmentation, id_lens(<<"indexer.settings.compaction.min_frag">>)},
     {interval, compaction_interval_lens()}].

compaction_defaults() ->
    [{fragmentation, 30},
     {interval, compaction_interval_default()}].

compaction_lens() ->
    json_settings_manager:props_lens(compaction_lens_props()).

config_upgrade_to_70(Config) ->
    config_upgrade_settings(Config, ?VERSION_66, ?VERSION_70).

config_upgrade_to_71(Config) ->
    config_upgrade_settings(Config, ?VERSION_70, ?VERSION_71).

config_upgrade_to_trinity(Config) ->
    config_upgrade_settings(Config, ?VERSION_71, ?VERSION_TRINITY).

config_upgrade_settings(Config, OldVersion, NewVersion) ->
    NewSettings = general_settings_defaults(NewVersion) --
        general_settings_defaults(OldVersion),
    json_settings_manager:upgrade_existing_key(
      ?MODULE, Config, [{generalSettings, NewSettings}],
      known_settings(NewVersion)).

-ifdef(TEST).
default_test() ->
    Versions = [?CURRENT_MIN_SUPPORTED_VERSION, ?VERSION_70, ?VERSION_71,
                ?VERSION_TRINITY],
    lists:foreach(fun(V) -> default_versioned(V) end, Versions).

default_versioned(Version) ->
    Keys = fun (L) -> lists:sort([K || {K, _} <- L]) end,

    ?assertEqual(Keys(known_settings(Version)),
                 Keys(default_settings())),
    ?assertEqual(Keys(compaction_lens_props()), Keys(compaction_defaults())),
    ?assertEqual(Keys(general_settings_lens_props(Version)),
                 Keys(general_settings_defaults(Version))).

config_upgrade_test() ->
    CmdList = config_upgrade_to_70([]),
    [{set, {metakv, Meta}, Data}] = CmdList,
    ?assertEqual(<<"/indexing/settings/config">>, Meta),
    ?assertEqual(<<"{\"indexer.settings.rebalance.redistribute_indexes\":false,"
                   "\"indexer.settings.num_replica\":0}">>, Data),

    CmdList2 = config_upgrade_to_71([]),
    [{set, {metakv, Meta2}, Data2}] = CmdList2,
    ?assertEqual(<<"/indexing/settings/config">>, Meta2),
    ?assertEqual(<<"{\"indexer.settings.enable_page_bloom_filter\":false}">>,
                 Data2),

    CmdList3 = config_upgrade_to_trinity([]),
    [{set, {metakv, Meta3}, Data3}] = CmdList3,
    ?assertEqual(<<"/indexing/settings/config">>, Meta3),
    ?assertEqual(<<"{\"indexer.settings.rebalance.blob_storage_region\":\"\","
                   "\"indexer.settings.thresholds.mem_high\":70,"
                   "\"indexer.settings.thresholds.units_low\":40,"
                   "\"indexer.settings.rebalance.blob_storage_scheme\":\"\","
                   "\"indexer.settings.rebalance.blob_storage_prefix\":\"\","
                   "\"indexer.settings.rebalance.blob_storage_bucket\":\"\","
                   "\"indexer.settings.thresholds.units_high\":60,"
                   "\"indexer.settings.thresholds.mem_low\":50}">>,
                 Data3).
-endif.
