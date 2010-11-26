% ==========================================================================================================
% BISBINO - FastCGI socket
% 
% Copyright (C) 2010, Roberto Ostinelli <roberto@ostinelli.net>.
% All rights reserved.
%
% BSD License
% 
% Redistribution and use in source and binary forms, with or without modification, are permitted provided
% that the following conditions are met:
%
%  * Redistributions of source code must retain the above copyright notice, this list of conditions and the
%	 following disclaimer.
%  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and
%	 the following disclaimer in the documentation and/or other materials provided with the distribution.
%  * Neither the name of the authors nor the names of its contributors may be used to endorse or promote
%	 products derived from this software without specific prior written permission.
%
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
% WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
% PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
% ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
% TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
% POSSIBILITY OF SUCH DAMAGE.
% ==========================================================================================================
-module(bisbino_fcgi_manager).
-vsn("0.1-dev").

% API
-export([start_link/2, shutdown/1, get_reqid_and_cpid/1, active_request_finished/1]).

% internal API
-export([init/2]).

% records
-record(state, {
	host,
	port,
	fconfig,
	reqid = 0,
	fcgi_mpxs_conns,
	fcgi_max_reqs,
	fcgi_max_conns,
	connections = [],
	active_requests_count = 0,
	request_queue
}).

% includes
-include("../include/misultin.hrl").
-include("../include/bisbino.hrl").

% ============================ \/ API ======================================================================

% Function: Pid | {error, Error}
% Description: Starts the fastcgi manager process.
start_link({FHost, FPort}, FConfig) ->
	proc_lib:spawn_link(?MODULE, init, [{FHost, FPort}, FConfig]).

% Function: {ok, ReqId, CPid} | {error, Reason}
% Description: Get an available request pid number.
get_reqid_and_cpid(FPid) ->
	% send
	FPid ! {get_reqid_and_cpid, self()},
	% wait response
	i_get_reqid_and_cpid(FPid).

% a request was finished, decrease current count
active_request_finished(FPid) ->
	FPid ! active_request_finished.

% Description: Shutdown manager and disconnect all connection processes
shutdown(FPid) ->
	FPid ! shutdown.

% ============================ /\ API ======================================================================



% ============================ \/ INTERNAL FUNCTIONS =======================================================

% init
init({FHost, FPort}, FConfig) ->
	?LOG_DEBUG("starting fastcgi manager ~p: ~p ~p", [self(), {FHost, FPort}, FConfig]),
	case bisbino_fcgi_connection:connect_loop({FHost, FPort}, FConfig) of
		{ok, FSock} ->
			% get backend variables
			?LOG_DEBUG("generating management request for backend: ~p", [{FHost, FPort}]),
			case get_management_info({FHost, FPort}, FConfig, FSock) of
				{error, _Reason} ->
					?LOG_WARNING("error getting management information response from ~p: ~p", [{FHost, FPort}, _Reason]),
					% close socket
					gen_tcp:close(FSock),
					% retry
					init({FHost, FPort}, FConfig);
				Params ->
					?LOG_DEBUG("received management parameters from fastcgi backend ~p: ~p", [{FHost, FPort}, Params]),
					% close socket
					gen_tcp:close(FSock),
					% launch fastcgi connections
					open_connections(#state{host = FHost, port = FPort, fconfig = FConfig,
						fcgi_mpxs_conns = bisbino_utility:get_key_value_default("fcgi_mpxs_conns", Params, 0),
						fcgi_max_reqs = bisbino_utility:get_key_value_default("fcgi_max_reqs", Params, 1),
						fcgi_max_conns = bisbino_utility:get_key_value_default("fcgi_max_conns", Params, 1),
						request_queue = queue:new()
					})
			end;
		shutdown ->
			?LOG_DEBUG("shutdown message received to close fastcgi manger ~p", [{FHost, FPort}]),
			shutdown
	end.

% Function: [{Tag, Val}, ...] | {error, Reason}
% Description: Get management values.
get_management_info({FHost, FPort}, FConfig, FSock) ->
	Bin = bisbino_fcgi_protocol:generate_management_request(0),
	case gen_tcp:send(FSock, Bin) of
		{error, Reason} ->
			?LOG_WARNING("error sending data: ~p", [Reason]),
			{error, Reason};
		ok ->
			% wait for response
			case get_management_info_wait({FHost, FPort}, FConfig, FSock) of
				{error, Reason} -> {error, Reason};
				Params ->
					% convert to lower string & integers
					F = fun({Tag, Val}, Acc) ->
						case catch list_to_integer(Val) of
							{'EXIT', _} -> Acc;
							IntVal -> [{string:to_lower(Tag), IntVal}|Acc]
						end
					end,
					lists:foldl(F, [], Params)
			end
	end.
get_management_info_wait({FHost, FPort}, FConfig, FSock) ->
	inet:setopts(FSock, [{active, once}]),
	receive
		{tcp, FSock, Bin} ->
			% response received by fastcgi server
			?LOG_DEBUG("received response by host ~p", [{FHost, FPort}]),
			% get pid
			case bisbino_fcgi_protocol:decode_packet(Bin) of
				{_ReqId, fcgi_get_values_result, Content} ->
					?LOG_DEBUG("packet decoded by host ~p: ~p", [{FHost, FPort}, {_ReqId, fcgi_get_values_result, Content}]),
					bisbino_fcgi_protocol:params_unpair(Content);
				{error, Reason} ->
					?LOG_WARNING("host ~p received a wrong packet with error: ~p", [{FHost, FPort}, Reason]),
					{error, Reason}
			end;
		{tcp_closed, FSock} ->
			?LOG_WARNING("socket got closed by host ~p", [{FHost, FPort}]),
			{error, {socket_closed_by_fastcgi_host, {FHost, FPort}}};
		{tcp_error, FSock, Reason} ->
			?LOG_ERROR("socket error on host ~p: ~p", [{FHost, FPort}, Reason]),
			{error, Reason};
		shutdown ->
			?LOG_DEBUG("shutdown received by fastcgi manager ~p", [{FHost, FPort}]),
			{error, fastcgi_manager_shutdown_requested}
	after FConfig#fastcgi_server_config.response_timeout ->
		?LOG_WARNING("timeout waiting response from fastcgi backend ~p", [{FHost, FPort}]),
		{error, {timeout_waiting_fastcgi_response, {FHost, FPort}}}
	end.

% launch connections
open_connections(#state{host = FHost, port = FPort, fconfig = FConfig, fcgi_mpxs_conns = FcgiMpxsConns, fcgi_max_reqs = FcgiMaxReqs, fcgi_max_conns = FcgiMaxConns} = State) ->
	% create fastcgi connection processes
	?LOG_DEBUG("create fastcgi connection processes for backend: ~p", [{FHost, FPort}]),
	Self = self(),
	FSpawn = fun(_, SpawnAcc) ->
		[bisbino_fcgi_connection:start_link({FHost, FPort}, FConfig, Self, FcgiMpxsConns, FcgiMaxReqs)|SpawnAcc]
	end,
	Connections = lists:foldl(FSpawn, [], lists:seq(1, FcgiMaxConns)),
	% now fastcgi manager is active
	?LOG_DEBUG("adding active fastcgi manager to bisbino for host: ~p", [{FHost, FPort}]),
	bisbino:add_active_fcgi_manager(self(), {FHost, FPort}, FConfig),
	% enter management loop
	loop(State#state{connections = Connections}).

% main manager loop
loop(State) ->
	receive
		{get_reqid_and_cpid, RequestorPid} ->
			?LOG_DEBUG("request for reqid and cpid received by ~p for backend: ~p", [RequestorPid, {State#state.host, State#state.port}]),
			ActiveRequestCount = State#state.active_requests_count,
			case ActiveRequestCount < State#state.fcgi_max_reqs of
				true ->
					?LOG_DEBUG("request limit has not been reached, respond immediately",[]),
					% send info
					case generate_and_send_reqid_and_cpid(RequestorPid, State#state.reqid, State#state.connections) of
						{error, _Reason} ->
							?LOG_ERROR("error while sending reqid and cpid: ~p", [_Reason]),
							loop(State);
						ReqId ->
							loop(State#state{reqid = ReqId, active_requests_count = ActiveRequestCount + 1})
					end;
				_ ->
					?LOG_DEBUG("request limit has been reached for requestor ~p, add to queue of current length ~p", [RequestorPid, length(RQueue)]),
					% add to queue
					loop(State#state{request_queue = queue:in(RequestorPid, State#state.request_queue)})
			end;
		active_request_finished ->
			ActiveRequestCount = State#state.active_requests_count - 1,
			?LOG_DEBUG("an active request was finished, current active count: ~p", [ActiveRequestCount]),
			case ActiveRequestCount < State#state.fcgi_max_reqs of
				true ->
					case queue:out(State#state.request_queue) of
						{empty, _} ->
							% nothing in queue
							loop(State#state{active_requests_count = ActiveRequestCount});
						{{value, RequestorPid}, TRQueue} ->
							% send info
							case generate_and_send_reqid_and_cpid(RequestorPid, State#state.reqid, State#state.connections) of
								{error, _Reason} ->
									?LOG_ERROR("error while sending reqid and cpid: ~p", [_Reason]),
									loop(State#state{active_requests_count = ActiveRequestCount, request_queue = TRQueue});
								ReqId ->
									loop(State#state{reqid = ReqId, active_requests_count = ActiveRequestCount + 1, request_queue = TRQueue})
							end
					end;
				_ ->
					?LOG_DEBUG("current active request limit is still reached, do nothing",[]),
					loop(State#state{active_requests_count = ActiveRequestCount})
			end;
		shutdown ->
			?LOG_DEBUG("shutdown request received by fastcgi manager for ~p, sending shutdown to fastcgi connection processes", [{State#state.host, State#state.port}]),
			i_shutdown_connections(State#state.connections);
		{'EXIT', _Pid, _Reason} ->
			?LOG_ERROR("fastcgi connection process ~p crashed with reason: ~p, resetting fcgi manager", [_Pid, _Reason]),
			% we don't know how many requests the connection process was handling, so to avoid locking on max number of requests we restart all
			i_reset(State);
		_Unknown ->
			?LOG_WARNING("received unknown message by fastcgi manager for ~p, ignoring", [{State#state.host, State#state.port}, _Unknown]),
			loop(State)
	end.

% reset
i_reset(State) ->
	i_shutdown_connections(State#state.connections),
	init({State#state.host, State#state.port}, State#state.fconfig).

% shutdown all processes
i_shutdown_connections(Connections) ->
	?LOG_DEBUG("shutting down all connection processes",[]),
	bisbino:remove_active_fcgi_server(self()),
	lists:foreach(fun(CPid) -> bisbino_fcgi_connection:shutdown(CPid) end, Connections).

% Function:  ReqId | {error, Reason}
% generate reqid and cpid info, runs in the manager loop
generate_and_send_reqid_and_cpid(RequestorPid, PrevReqId, Connections) ->
	% generate available req id
	ReqId = case PrevReqId of
		2147483647 -> 1;	% reset counter
		_ -> PrevReqId + 1	% add 1
	end,
	% very basic load balancer between connections
	case Connections of
		[] ->
			% no connections, should never happen
			i_reqid_and_cpid_error(RequestorPid, no_fastcgi_connections),
			{error, no_fastcgi_connections};
		[CPid] ->
			% one connection
			generate_and_send_reqid_and_cpid_send_ok(RequestorPid, ReqId, CPid);
		_ ->
			% many connections
			CPid = lists:nth(random:uniform(length(Connections)), Connections),
			generate_and_send_reqid_and_cpid_send_ok(RequestorPid, ReqId, CPid)
	end.
generate_and_send_reqid_and_cpid_send_ok(RequestorPid, ReqId, CPid) ->
	?LOG_DEBUG("sending response, ReqId: ~p, CPid: ~p", [ReqId, CPid]),
	i_reqid_and_cpid_ok(RequestorPid, ReqId, CPid),
	ReqId.

% send ok
i_reqid_and_cpid_ok(RequestorPid, ReqId, CPid) ->
	RequestorPid ! {self(), reqid_and_cpid, ReqId, CPid}.
% send error
i_reqid_and_cpid_error(RequestorPid, Reason) ->
	RequestorPid ! {self(), error, Reason}.
	
% Function: {ok, ReqId, CPid} | {error, Reason}
% Description: Internal wait: get an available request pid number and a connection pid, runs in the http handler loop
i_get_reqid_and_cpid(FPid) ->
	receive
		{FPid, reqid_and_cpid, ReqId, CPid} ->
			% ok, return
			{ok, ReqId, CPid};
		{FPid, error, Reason} ->
			% return error
			{error, Reason};
		_ ->
			% unknown message, ignore
			i_get_reqid_and_cpid(FPid)
	after 10000 ->
		{error, timeout_waiting_for_reqid_from_fastcgi_manager}
	end.

% ============================ /\ INTERNAL FUNCTIONS =======================================================
