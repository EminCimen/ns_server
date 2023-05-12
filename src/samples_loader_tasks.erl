%% @author Couchbase <info@couchbase.com>
%% @copyright 2012-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
-module(samples_loader_tasks).

-behaviour(gen_server).

-include("ns_common.hrl").
-include("cut.hrl").

%% gen_server API
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([start_loading_sample/5, get_tasks/1]).

-export([perform_loading_task/5]).

-import(menelaus_web_samples, [is_http/1]).

start_loading_sample(Sample, Bucket, Quota, CacheDir, BucketState) ->
    gen_server:call(?MODULE, {start_loading_sample, Sample, Bucket, Quota,
                              CacheDir, BucketState}, infinity).

get_tasks(Timeout) ->
    gen_server:call(?MODULE, get_tasks, Timeout).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-record(state, {
          tasks = [] :: [{string(), pid(), binary()}],
          token_pid :: undefined | pid()
         }).

init([]) ->
    erlang:process_flag(trap_exit, true),
    {ok, #state{}}.

handle_call({start_loading_sample, Sample, Bucket, Quota, CacheDir,
             BucketState}, _From,
            #state{tasks = Tasks} = State) ->
    case lists:keyfind(Bucket, 1, Tasks) of
        false ->
            Pid = start_new_loading_task(Sample, Bucket, Quota, CacheDir,
                                         BucketState),
            TaskId = misc:uuid_v4(),
            update_task_status(TaskId, queued, Bucket),
            ns_heart:force_beat(),
            NewState = State#state{tasks = Tasks ++ [{Bucket, Pid, TaskId}]},
            {reply, {newly_started, TaskId}, maybe_pass_token(NewState)};
        {_, _, TaskId} ->
            {reply, {already_started, TaskId}, State}
    end;
handle_call(get_tasks, _From, State) ->
    {reply, State#state.tasks, State}.


handle_cast(_, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason} = Msg,
            #state{tasks = Tasks, token_pid = TokenPid} = State) ->
    case lists:keyfind(Pid, 2, Tasks) of
        false ->
            ?log_error("Got exit not from child: ~p", [Msg]),
            exit(Reason);
        {Name, _, TaskId} ->
            ?log_debug("Consumed exit signal from samples loading task ~s: ~p",
                       [Name, Msg]),
            ns_heart:force_beat(),
            case Reason of
                normal ->
                    update_task_status(TaskId, completed, Name),
                    ale:info(?USER_LOGGER, "Completed loading sample bucket ~s",
                             [Name]);
                {failed_to_load_samples, Status, Output} ->
                    update_task_status(TaskId, failed, Name),
                    ale:error(?USER_LOGGER,
                              "Task ~p - loading sample bucket ~s failed. "
                              "Samples loader exited with status ~b.~n"
                              "Loader's output was:~n~n~s",
                              [TaskId, Name, Status, Output]);
                _ ->
                    update_task_status(TaskId, failed, Name),
                    ale:error(?USER_LOGGER,
                              "Task ~p - loading sample bucket ~s failed: ~p",
                              [TaskId, Name, Reason])
            end,
            NewTokenPid = case Pid =:= TokenPid of
                              true ->
                                  ?log_debug("Token holder died"),
                                  undefined;
                              _ ->
                                  TokenPid
                          end,
            NewState = State#state{tasks = lists:keydelete(Pid, 2, Tasks),
                                   token_pid = NewTokenPid},
            {noreply, maybe_pass_token(NewState)}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{tasks = Tasks}) ->
    lists:foreach(
      fun ({Name, _Pid, TaskId}) ->
              update_task_status(TaskId, failed, Name)
      end, Tasks).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

maybe_pass_token(#state{token_pid = undefined,
                        tasks = [{Name, FirstPid, TaskId}|_]} = State) ->
    FirstPid ! allowed_to_go,
    update_task_status(TaskId, running, Name),
    ?log_info("Passed samples loading token to task: ~s (~p)", [Name, TaskId]),
    State#state{token_pid = FirstPid};
maybe_pass_token(State) ->
    State.

-spec update_task_status(binary(), global_tasks:status(), string()) -> ok.
update_task_status(TaskId, Status, BucketName) ->
    global_tasks:update_task(TaskId, loadingSampleBucket, Status,
                             BucketName, []).

start_new_loading_task(Sample, Bucket, Quota, CacheDir, BucketState) ->
    proc_lib:spawn_link(?MODULE, perform_loading_task,
                        [Sample, Bucket, Quota, CacheDir, BucketState]).

perform_loading_task(Sample, Bucket, Quota, CacheDir, BucketState) ->
    receive
        allowed_to_go -> ok
    end,

    Host = misc:extract_node_address(node()),
    ClusterOpts = case misc:disable_non_ssl_ports() of
                      true ->
                          SslPort = service_ports:get_port(ssl_rest_port),
                          Cluster = "https://" ++ misc:join_host_port(
                                                    Host, SslPort),
                          ["--cluster", Cluster,
                           "--cacert", ns_ssl_services_setup:ca_file_path()];
                      false ->
                          Port = service_ports:get_port(rest_port),
                          ["--cluster", misc:join_host_port(Host, Port)]
                  end,
    BinDir = path_config:component_path(bin),
    NumReplicas = case length(ns_cluster_membership:nodes_wanted()) of
                      1 -> 0;
                      _ -> 1
                  end,

    Cmd = BinDir ++ "/cbimport",
    {DataSet, AdditionalArgs} =
        case is_http(Sample) of
            true ->
                {Sample,
                 ["--http-cache-directory", CacheDir]};
            false ->
                {"file://" ++
                     filename:join([BinDir, "..", "samples",
                                    Sample ++ ".zip"]),
                 []}
        end,
    Args = ["json",
            "--bucket", Bucket,
            "--format", "sample",
            "--threads", "2",
            "--verbose",
            "--dataset", DataSet] ++
            AdditionalArgs ++
            ClusterOpts ++
            case BucketState of
                bucket_must_exist ->
                    ["--disable-bucket-config"];
                bucket_must_not_exist ->
                    ["--bucket-quota", integer_to_list(Quota),
                     "--bucket-replicas", integer_to_list(NumReplicas)]
            end,

    Env = [{"CB_USERNAME", "@ns_server"},
           {"CB_PASSWORD", ns_config_auth:get_password(special)} |
           ns_ports_setup:build_cbauth_env_vars(ns_config:latest(), cbimport)],

    {Status, Output} = misc:run_external_tool(Cmd, Args, Env),
    case Status of
        0 ->
            ok;
        _ ->
            exit({failed_to_load_samples, Status, Output})
    end.
