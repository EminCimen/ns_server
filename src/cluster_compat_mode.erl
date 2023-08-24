%% @author Couchbase <info@couchbase.com>
%% @copyright 2012-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.

-module(cluster_compat_mode).

-include("cut.hrl").
-include("ns_common.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([get_compat_version/0,
         get_ns_config_compat_version/0,
         is_enabled/1, is_enabled_at/2,
         consider_switching_compat_mode/0,
         is_index_aware_rebalance_on/0,
         is_index_pausing_on/0,
         rebalance_ignore_view_compactions/0,
         is_cluster_71/0,
         is_version_71/1,
         is_cluster_72/0,
         is_version_72/1,
         is_cluster_trinity/0,
         is_version_trinity/1,
         is_enterprise/0,
         is_enterprise/1,
         is_saslauthd_enabled/0,
         is_cbas_enabled/0,
         supported_compat_version/0,
         min_supported_compat_version/0,
         effective_cluster_compat_version/0,
         effective_cluster_compat_version_for/1,
         is_developer_preview/0,
         is_developer_preview/1,
         get_cluster_capabilities/0,
         tls_supported/0,
         tls_supported/1,
         preserve_durable_mutations/0]).

%% NOTE: this is rpc:call-ed by mb_master
-export([mb_master_advertised_version/0]).

n1ql_cluster_capabilities(Version) ->
    [costBasedOptimizer, indexAdvisor, javaScriptFunctions, inlineFunctions,
     enhancedPreparedStatements] ++
        case is_enabled_at(Version, ?VERSION_TRINITY) of
            true ->
                [readFromReplica];
            false ->
                []
        end.

cluster_capabilities(Version) ->
    [{n1ql, n1ql_cluster_capabilities(Version)}].

get_cluster_capabilities() ->
    cluster_capabilities(get_compat_version()).

get_ns_config_compat_version() ->
    get_ns_config_compat_version(ns_config:latest()).

get_ns_config_compat_version(Config) ->
    ns_config:search(Config, cluster_compat_version, undefined).

get_compat_version() ->
    chronicle_compat:get(cluster_compat_version,
                         #{default => min_supported_compat_version()}).

supported_compat_version() ->
    case get_pretend_version() of
        undefined ->
            ?LATEST_VERSION_NUM;
        Version ->
            Version
    end.

%% This prevents a node running LATEST_VERSION_NUM from joining (or being added
%% to) a cluster running with a compat version < min_supported_compat_version().
%% It also prevents an old (i.e. supports < min_supported_compat_version()) node
%% from joining a cluster with LATEST_VERSION_NUM compat version.
%% It has no effect whatsoever on the offline upgrade path.
min_supported_compat_version() ->
    ?MIN_SUPPORTED_VERSION.

%% NOTE: this is rpc:call-ed by mb_master
%%
%% I.e. we want later version to be able to take over mastership even
%% without requiring compat mode upgrade
mb_master_advertised_version() ->
    case get_mb_master_pretend_version() of
        undefined ->
            case get_pretend_version() of
                undefined ->
                    ?MASTER_ADVERTISED_VERSION;
                Version ->
                    Version ++ [0]
            end;
        Version ->
            Version ++ [0]
    end.

is_enabled_at(undefined = _ClusterVersion, _FeatureVersion) ->
    false;
is_enabled_at(ClusterVersion, FeatureVersion) ->
    ClusterVersion >= FeatureVersion.

is_enabled(FeatureVersion) ->
    is_enabled_at(get_compat_version(), FeatureVersion).

is_version_71(ClusterVersion) ->
    is_enabled_at(ClusterVersion, ?VERSION_71).

is_cluster_71() ->
    is_enabled(?VERSION_71).

is_version_72(ClusterVersion) ->
    is_enabled_at(ClusterVersion, ?VERSION_72).

is_cluster_72() ->
    is_enabled(?VERSION_72).

is_version_trinity(ClusterVersion) ->
    is_enabled_at(ClusterVersion, ?VERSION_TRINITY).

is_cluster_trinity() ->
    is_enabled(?VERSION_TRINITY).

is_index_aware_rebalance_on() ->
    not ns_config:read_key_fast(index_aware_rebalance_disabled, false).

is_index_pausing_on() ->
    is_index_aware_rebalance_on() andalso
        (not ns_config:read_key_fast(index_pausing_disabled, false)).

is_enterprise(Config) ->
    ns_config:search(Config, {node, node(), is_enterprise}, false).

is_enterprise() ->
    ns_config:read_key_fast({node, node(), is_enterprise}, false).

is_saslauthd_enabled() ->
    is_enterprise() andalso
        ns_config:search(ns_config:latest(),
                         {node, node(), saslauthd_enabled}, false).

is_cbas_enabled() ->
    is_enterprise().

rebalance_ignore_view_compactions() ->
    ns_config:read_key_fast(rebalance_ignore_view_compactions, false).

%% This function is used to determine if developer preview is enabled by
%% default. This is normally enabled (made true) during development of the
%% release and then disabled (made false) near release time.
is_developer_preview_enabled_by_default() ->
    false.

consider_switching_compat_mode() ->
    Config = ns_config:get(),
    CompatVersion = get_compat_version(),
    NsConfigVersion = get_ns_config_compat_version(Config),
    case CompatVersion =:= NsConfigVersion
        andalso CompatVersion =:= supported_compat_version() of
        true ->
            case is_developer_preview() of
                false ->
                    %% Specifying the environment variable takes precedence.
                    Default = misc:get_env_default(
                                developer_preview_enabled_default,
                                is_developer_preview_enabled_by_default()),
                    case Default of
                        true ->
                            ns_config:set(developer_preview_enabled, Default);
                        _ ->
                            ok
                    end;
                true ->
                    ok
            end,
            ok;
        false ->
            do_consider_switching_compat_mode(
              Config, CompatVersion, NsConfigVersion)
    end.

upgrades() ->
    [{?VERSION_TRINITY, rbac, menelaus_users, upgrade}].

do_upgrades(undefined, _, _, _) ->
    %% this happens during the cluster initialization. no upgrade needed
    ok;
do_upgrades(CurrentVersion, NewVersion, Config, NodesWanted) ->
    do_upgrades(upgrades(), CurrentVersion, NewVersion, Config, NodesWanted).

do_upgrades([], _, _, _, _) ->
    ok;
do_upgrades([{Version, Name, Module, Fun} | Rest],
            CurrentVersion, NewVersion, Config, NodesWanted)
  when CurrentVersion < Version andalso NewVersion >= Version ->
    ?log_info("Initiating ~p upgrade due to version change from ~p to ~p "
              "(target version: ~p)",
              [Name, CurrentVersion, Version, NewVersion]),
    case Module:Fun(Version, Config, NodesWanted) of
        ok ->
            do_upgrades(Rest, CurrentVersion, NewVersion, Config, NodesWanted);
        _ ->
            Name
    end;
do_upgrades([_ | Rest], CurrentVersion, NewVersion, Config, NodesWanted) ->
    do_upgrades(Rest, CurrentVersion, NewVersion, Config, NodesWanted).

do_consider_switching_compat_mode(Config, CompatVersion, NsConfigVersion) ->
    NodesWanted = ns_node_disco:nodes_wanted(),
    NodesUp = lists:sort([node() | nodes()]),
    case ordsets:is_subset(NodesWanted, NodesUp) of
        true ->
            NodeInfos = ns_doctor:get_nodes(),
            case consider_switching_compat_mode_loop(
                   NodeInfos, NodesWanted, supported_compat_version()) of
                CompatVersion when CompatVersion =:= NsConfigVersion ->
                    ok;
                AnotherVersion ->
                    case is_enabled_at(AnotherVersion, CompatVersion) of
                        true ->
                            case do_upgrades(CompatVersion, AnotherVersion,
                                             Config, NodesWanted) of
                                ok ->
                                    do_switch_compat_mode(AnotherVersion,
                                                          NodesWanted),
                                    changed;
                                Name ->
                                    ?log_error(
                                       "Refusing to upgrade the compat "
                                       "version from ~p to ~p due to failure "
                                       "of ~p upgrade"
                                       "~nNodesWanted: ~p~nNodeInfos: ~p",
                                       [CompatVersion, AnotherVersion, Name,
                                        NodesWanted, NodeInfos])
                            end;
                        false ->
                            ?log_error("Refusing to downgrade the compat "
                                       "version from ~p to ~p."
                                       "~nNodesWanted: ~p~nNodeInfos: ~p",
                                       [CompatVersion, AnotherVersion,
                                        NodesWanted, NodeInfos]),
                            ok
                    end
            end;
        false ->
            ok
    end.

%% This upgrades ns_config and chronicle to the new compat_version (NewVersion)
do_switch_compat_mode(NewVersion, NodesWanted) ->
    functools:sequence_(
      [?cut(chronicle_upgrade:upgrade(NewVersion, NodesWanted)),
       ?cut(upgrade_ns_config(NewVersion, NodesWanted))]).

upgrade_ns_config(NewVersion, NodesWanted) ->
    case ns_online_config_upgrader:upgrade_config(NewVersion) of
        ok ->
            complete_ns_config_upgrade(NodesWanted);
        already_upgraded ->
            ok
    end.

complete_ns_config_upgrade(NodesWanted) ->
    try
        case ns_config_rep:ensure_config_seen_by_nodes(NodesWanted) of
            ok -> ok;
            {error, BadNodes} ->
                ale:error(?USER_LOGGER,
                          "Was unable to sync cluster_compat_version update "
                          "to some nodes: ~p", [BadNodes]),
                error
        end
    catch T:E:S ->
            ale:error(?USER_LOGGER,
                      "Got problems trying to replicate cluster_compat_version "
                      "update~n~p", [{T, E, S}]),
            error
    end.

consider_switching_compat_mode_loop(_NodeInfos, _NodesWanted,
                                    _Version = undefined) ->
    undefined;
consider_switching_compat_mode_loop(_NodeInfos, [], Version) ->
    Version;
consider_switching_compat_mode_loop(NodeInfos, [Node | RestNodesWanted],
                                    Version) ->
    case dict:find(Node, NodeInfos) of
        {ok, Info} ->
            NodeVersion = proplists:get_value(supported_compat_version, Info,
                                              undefined),
            AgreedVersion = case is_enabled_at(NodeVersion, Version) of
                                true ->
                                    Version;
                                false ->
                                    NodeVersion
                            end,
            consider_switching_compat_mode_loop(NodeInfos, RestNodesWanted,
                                                AgreedVersion);
        _ ->
            undefined
    end.

%% undefined is "used" shortly after node is initialized and when
%% there's no compat mode yet
effective_cluster_compat_version_for(undefined) ->
    1;
effective_cluster_compat_version_for([VersionMaj, VersionMin] =
                                         _CompatVersion) ->
    VersionMaj * 16#10000 + VersionMin.

effective_cluster_compat_version() ->
    effective_cluster_compat_version_for(get_compat_version()).

get_pretend_version(Key) ->
    case application:get_env(ns_server, Key) of
        undefined ->
            undefined;
        {ok, VersionString} ->
            {[A, B | _], _, _} = misc:parse_version(VersionString),
            [A, B]
    end.

get_pretend_version() ->
    get_pretend_version(pretend_version).

get_mb_master_pretend_version() ->
    get_pretend_version(mb_master_pretend_version).

is_developer_preview() -> is_developer_preview(ns_config:latest()).
is_developer_preview(Config) ->
    ns_config:search(Config, developer_preview_enabled, false).

tls_supported(Config) ->
    is_enterprise(Config).

tls_supported() ->
    is_enterprise().

-ifdef(TEST).
mb_master_advertised_version_test() ->
    true = mb_master_advertised_version() >= ?LATEST_VERSION_NUM ++ [0].
-endif.

preserve_durable_mutations() ->
    ns_config:read_key_fast({failover, preserve_durable_mutations}, true).
