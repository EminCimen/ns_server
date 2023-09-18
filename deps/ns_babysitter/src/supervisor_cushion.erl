%% @author Couchbase <info@couchbase.com>
%% @copyright 2010-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
%% This module exists to slow down supervisors to prevent fast spins
%% on crashes.
%%
-module(supervisor_cushion).

-behaviour(gen_server).

-include("ns_common.hrl").

%% API
-export([start_link/6, start_link/7, child_pid/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DEFAULT_OPTIONS, #{always_delay => false}).

-record(state, {name, delay, started, child_pid, shutdown_timeout,
                options :: #{always_delay := boolean()}}).

start_link(Name, Delay, ShutdownTimeout, M, F, A) ->
    start_link(Name, Delay, ShutdownTimeout, M, F, A, #{}).
start_link(Name, Delay, ShutdownTimeout, M, F, A, Options) ->
    gen_server:start_link(?MODULE, [Name, Delay, ShutdownTimeout, M, F, A,
                                    Options], []).

init([Name, Delay, ShutdownTimeout, M, F, A, Options]) ->
    process_flag(trap_exit, true),
    ?log_debug("Starting supervisor cushion for ~p with delay of ~p",
               [Name, Delay]),

    Started = erlang:monotonic_time(),

    OptionsWithDefaults = maps:merge(?DEFAULT_OPTIONS, Options),
    BaseState = #state{name = Name, delay = Delay, started = Started,
                       options = OptionsWithDefaults},

    case apply(M, F, A) of
        {ok, Pid} ->
            {ok, BaseState#state{child_pid=Pid,
                                 shutdown_timeout=ShutdownTimeout}};
        X ->
            {ok, die_slowly(X, BaseState)}
    end.

handle_call(child_pid, _From, State) ->
    {reply, State#state.child_pid, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', _Pid, Reason}, State) ->
    ?log_info("Cushion managed supervisor for ~p failed:  ~p",
              [State#state.name, Reason]),
    State1 = die_slowly(Reason, State),
    {noreply, State1};
handle_info({die, Reason}, State) ->
    {stop, Reason, State};
handle_info({send_to_port, _}= Msg, State) ->
    State#state.child_pid ! Msg,
    {noreply, State};
handle_info(Info, State) ->
    ?log_warning("Cushion got unexpected info supervising ~p: ~p",
                 [State#state.name, Info]),
    {noreply, State}.

die_slowly(Reason, #state{options = Options} = State) ->
    #{always_delay := AlwaysDelay} = Options,

    %% How long (in microseconds) has this service been running?
    Lifetime0 = erlang:monotonic_time() - State#state.started,
    Lifetime  = misc:convert_time_unit(Lifetime0, millisecond),

    %% If the restart was too soon, slow down a bit.
    case AlwaysDelay =:= true orelse Lifetime < State#state.delay of
        true ->
            ?log_info("Cushion managed supervisor for ~p exited on node ~p in "
                      "~.2fs~n",
                      [State#state.name, node(), Lifetime / 1000]),
            timer:send_after(State#state.delay, {die, Reason});
        _ -> self() ! {die, Reason}
    end,
    State#state{child_pid=undefined}.

terminate(_Reason, #state{child_pid = undefined}) ->
    ok;
terminate(Reason, #state{name = Name, child_pid=Pid,
                         shutdown_timeout=Timeout}) ->
    erlang:exit(Pid, Reason),
    case misc:wait_for_process(Pid, Timeout) of
        ok ->
            ok;
        {error, timeout} ->
            ?log_warning("Cushioned process ~p with pid ~p failed to terminate "
                         "within ~pms. Killing it brutally.",
                         [Name, Pid, Timeout]),
            erlang:exit(Pid, kill),
            ok = misc:wait_for_process(Pid, infinity)
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% API
child_pid(Pid) ->
    gen_server:call(Pid, child_pid).
