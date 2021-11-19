%% @author Couchbase <info@couchbase.com>
%% @copyright 2017-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included
%% in the file licenses/BSL-Couchbase.txt.  As of the Change Date specified
%% in that file, in accordance with the Business Source License, use of this
%% software will be governed by the Apache License, Version 2.0, included in
%% the file licenses/APL2.txt.

%% This module provides a wrapper around global and
%% leader_registry_server. Normally, leader_registry_server is called. But if
%% the end user chooses to disable new orchestration, the module will revert
%% to using global.
-module(leader_registry).

-include("ns_common.hrl").

%% name service API
-export([register_name/2, unregister_name/1, whereis_name/1, send/2]).

register_name(Name, Pid) ->
    leader_registry_server:register_name(Name, Pid).

unregister_name(Name) ->
    leader_registry_server:unregister_name(Name).

whereis_name(Name) ->
    leader_registry_server:whereis_name(Name).

send(Name, Msg) ->
    leader_registry_server:send(Name, Msg).
