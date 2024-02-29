%% @author Couchbase <info@couchbase.com>
%% @copyright 2013-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
%% @doc This service watches changes of terse bucket info and uploads
%% it to ep-engine
-module(terse_bucket_info_uploader).

-behaviour(gen_server).

-include("ns_common.hrl").

-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         refresh/1, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(SET_CLUSTER_CONFIG_RETRY_TIME, 1000).

-record(state, {
          port_pid :: pid()
         }).

%%%===================================================================
%%% API
%%%===================================================================
start_link(BucketName) ->
    ns_bucket_sup:ignore_if_not_couchbase_bucket(
      BucketName,
      fun (_) ->
              proc_lib:start_link(?MODULE, init, [[BucketName]])
      end).

server_name(BucketName) ->
    list_to_atom("terse_bucket_info_uploader-" ++ BucketName).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([BucketName]) ->
    Self = self(),
    Name = server_name(BucketName),
    register(Name, Self),

    ns_pubsub:subscribe_link(bucket_info_cache_invalidations, fun invalidation_loop/2, {BucketName, Self}),
    %% Free up our parent to continue on. This is needed as the rest of
    %% this function might take some time to complete.
    proc_lib:init_ack({ok, Self}),

    Pid = memcached_config_mgr:memcached_port_pid(),
    remote_monitors:monitor(Pid),

    submit_refresh(BucketName, Self),
    gen_server:enter_loop(?MODULE, [], #state{port_pid = Pid}).

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({refresh, BucketName}, State) ->
    flush_refresh_msgs(BucketName),
    refresh_cluster_config(BucketName),
    {noreply, State};
handle_info({remote_monitor_down, Pid, Reason},
            #state{port_pid = Pid} = State) ->
    ?log_debug("Got DOWN with reason: ~p from memcached port server: ~p. "
               "Shutting down", [Reason, Pid]),
    {stop, {shutdown, {memcached_port_server_down, Pid, Reason}}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
flush_refresh_msgs(BucketName) ->
    case misc:flush({refresh, BucketName}) of
        N when N > 0 ->
            ?log_debug("Flushed ~p refresh messages", [N]);
        _ ->
            ok
    end.

refresh(BucketName) ->
    ns_bucket_sup:ignore_if_not_couchbase_bucket(
      BucketName,
      fun (_) ->
              server_name(BucketName) ! {refresh, BucketName}
      end).

refresh_cluster_config(BucketName) ->
    case bucket_info_cache:terse_bucket_info(BucketName) of
        {ok, Rev, RevEpoch, Blob} ->
            case ns_memcached_sockets_pool:executing_on_socket(
                   fun (Sock) ->
                           mc_client_binary:set_cluster_config(Sock,
                                                               BucketName,
                                                               Rev,
                                                               RevEpoch,
                                                               Blob)
                   end) of
                ok ->
                    ok;
                {memcached_error, etmpfail, undefined} ->
                    %% Bucket isn't in a state where the cluster config can
                    %% be set...try again in a bit
                    ?log_debug("Bucket ~s is not ready for setting cluster "
                               "config", [BucketName]),
                    erlang:send_after(?SET_CLUSTER_CONFIG_RETRY_TIME,
                                      self(), {refresh, BucketName}),
                    ok
            end;
        not_present ->
            ?log_debug("Bucket ~s is dead", [BucketName]),
            ok;
        {T, E, Stack} = Exception ->
            ?log_error("Got exception trying to get terse bucket info: ~p",
                       [Exception]),
            timer:sleep(10000),
            erlang:raise(T, E, Stack)
    end.

submit_refresh(BucketName, Process) ->
    Process ! {refresh, BucketName}.

invalidation_loop(BucketName, {BucketName, Parent}) ->
    submit_refresh(BucketName, Parent),
    {BucketName, Parent};
invalidation_loop('*', {BucketName, Parent}) ->
    submit_refresh(BucketName, Parent),
    {BucketName, Parent};
invalidation_loop(_, State) ->
    State.
