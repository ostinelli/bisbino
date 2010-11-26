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
-module(bisbino_fcgi_connection).
-vsn("0.1-dev").

% API
-export([start_link/5, get_response/5, shutdown/1, connect/2, connect_loop/2]).

% internal
-export([init/5]).

% records
-record(state, {
	host,
	port,
	sock = false,
	fconfig,
	assoc_table,
	manager_pid,
	fcgi_mpxs_conns,
	fcgi_max_reqs,
	num_current_requests = 0,
	req_queue = []
}).

% includes
-include("../include/misultin.hrl").
-include("../include/bisbino.hrl").

% ============================ \/ API ======================================================================

% Function: Pid | {error, Error}
% Description: Starts the fastcgi manager process.
start_link({FHost, FPort}, FConfig, ManagerPid, FcgiMpxsConns, FcgiMaxReqs) ->
	?LOG_DEBUG("starting fastcgi connection processof manager ~p: ~p ~p ~p ~p", [ManagerPid, {FHost, FPort}, FConfig, FcgiMpxsConns, FcgiMaxReqs]),
	proc_lib:spawn_link(?MODULE, init, [{FHost, FPort}, FConfig, ManagerPid, FcgiMpxsConns, FcgiMaxReqs]).

% Function: void()
% Description: Remove request pid number from ETS reference table.
remove_reqid(CPid, ReqId) ->
	% send
	CPid ! {remove_reqid, ReqId}.

% Function: {ok, {ReqId, Response}} | {error, Reason}
% Description: Get the response to a request, runs in the HTTP request handler process.
get_response(FPid, CPid, ReqId, FPacket, Timeout) ->
	?LOG_DEBUG("sending to fastcgi connection with pid: ~p", [CPid]),
	% send
	CPid ! {request, ReqId, self(), FPacket},
	?LOG_DEBUG("waiting for response",[]),
	case i_get_response(Timeout, <<>>, ok) of
		{ok, {ReqId, Response}} ->
			% delete ReqId reference from ETS table
			remove_reqid(CPid, ReqId),
			% release next requests
			bisbino_fcgi_manager:active_request_finished(FPid),
			% return
			{ok, {ReqId, Response}};
		{error, Reason} ->
			% delete ReqId reference from ETS table
			remove_reqid(CPid, ReqId),
			% release next requests
			bisbino_fcgi_manager:active_request_finished(FPid),
			% return
			{error, Reason}
	end.

% Description: Shutdown connection processes
shutdown(CPid) ->
	CPid ! shutdown.

% Function: {ok, FSock} | {error, Reason}
% Description: Try to connect to the fastcgi backend
connect({FHost, FPort}, FConfig) ->
	i_connect({FHost, FPort}, FConfig).

% Function: {ok, Sock} | shutdown
% Description: Repeatedly try to connect to the fastcgi backend
connect_loop({FHost, FPort}, FConfig) ->
	i_connect_loop({FHost, FPort}, FConfig).

% ============================ /\ API ======================================================================

	
% ============================ \/ INTERNAL FUNCTIONS =======================================================

% Function: {ok, CSock} | {error, Reason}
% Description: loop to try connecting to fastcgi backend
i_connect({FHost, FPort}, #fastcgi_server_config{connect_timeout = ConnectTimeout}) ->
	?LOG_DEBUG("trying to connect to fastcgi server ~p", [{FHost, FPort}]),
	case gen_tcp:connect(FHost, FPort, [binary, {active, once}, {packet, fcgi}], ConnectTimeout) of
		{ok, Sock} ->
			% created
			?LOG_DEBUG("connected to fastcgi server ~p", [{FHost, FPort}]),
			{ok, Sock};
		{error, Reason} ->
			?LOG_ERROR("could not connect to fastcgi server ~p: ~p", [{FHost, FPort}, Reason]),
			{error, Reason}
	end.

% Function: {ok, CSock} | shutdown
% Description: loop to try connecting to fastcgi backend
i_connect_loop({FHost, FPort}, #fastcgi_server_config{connect_retry_after = ConnectRetryAfter, connect_timeout = ConnectTimeout} = FConfig) ->
	?LOG_DEBUG("trying to loop connect to fastcgi server ~p", [{FHost, FPort}]),
	T0 = erlang:now(),
	case gen_tcp:connect(FHost, FPort, [binary, {active, once}, {packet, fcgi}], ConnectTimeout) of
		{ok, Sock} ->
			% created
			?LOG_DEBUG("connected to fastcgi server ~p", [{FHost, FPort}]),
			{ok, Sock};
		{error, _Reason} ->
			?LOG_ERROR("could not connect to fastcgi server ~p: ~p, waiting to retry", [{FHost, FPort}, _Reason]),
			% ensure that timeout period has passed [if host is unreacheable, connect will skip the timeout]
			TimeDiff = case ConnectRetryAfter - timer:now_diff(erlang:now(), T0) of
				TimeDiff0 when TimeDiff0 > 0 -> TimeDiff0;
				_ -> ConnectRetryAfter
			end,
			?LOG_DEBUG("timediff: ~p", [TimeDiff]),
			receive
				shutdown ->
					?LOG_DEBUG("shutdown request received by fastcgi connection process ~p while trying to connect", [{FHost, FPort}]),
					shutdown
			after TimeDiff ->
				% error connecting, retry
				i_connect_loop({FHost, FPort}, FConfig)
			end
	end.

% init
init({FHost, FPort}, FConfig, ManagerPid, FcgiMpxsConns, FcgiMaxReqs) ->	
	% create table
	AssocTable = ets:new(reqpid, [set, private]),
	% enter loop
	loop(#state{host = FHost, port = FPort, fconfig = FConfig, assoc_table = AssocTable, manager_pid = ManagerPid, fcgi_mpxs_conns = FcgiMpxsConns, fcgi_max_reqs = FcgiMaxReqs}).

% main connection loop
loop(#state{sock = CSock} = State) ->
	receive
		{request, ReqId, RequestorPid, FPacket} ->
			% request received
			?LOG_DEBUG("request relay received for host ~p by http process ~p", [{State#state.host, State#state.port}, RequestorPid]),
			% save in ETS
			ets:insert(State#state.assoc_table, {ReqId, RequestorPid}),
			% send request to fastcgi
			case CSock of
				false ->
					% no connection to fastcgi, create one
					case i_connect({State#state.host, State#state.port}, State#state.fconfig) of
						{ok, NewSock} -> 
							% send
							?LOG_DEBUG("sending to fastcgi socket: ~p", [NewSock]),
							case gen_tcp:send(NewSock, FPacket) of
								ok ->
									loop(State#state{sock = NewSock});
								{error, Reason} ->
									i_send_error(RequestorPid, ReqId, {fastcgi_connection_error, Reason}),
									gen_tcp:close(NewSock),
									loop(State#state{sock = false})
							end;
						{error, Reason} ->
							% send error
							?LOG_ERROR("sending error to requestor pid: ~p", [RequestorPid]),
							i_send_error(RequestorPid, ReqId, {fastcgi_connection_error, Reason}),
							loop(State#state{sock = false})
					end;
				_ ->
					% send
					?LOG_DEBUG("sending to fastcgi socket: ~p", [CSock]),
					case gen_tcp:send(CSock, FPacket) of
						ok ->
							loop(State);
						{error, Reason} ->
							i_send_error(RequestorPid, ReqId, {fastcgi_connection_error, Reason}),
							gen_tcp:close(CSock),
							loop(State#state{sock = false})
					end
			end;
		{tcp, CSock, Bin} ->
			% response received by fastcgi server
			?LOG_DEBUG("received response by fastcgi host ~p", [{State#state.host, State#state.port}]),
			% get RequestorPid
			case bisbino_fcgi_protocol:decode_packet(Bin) of
				{ReqId, Type, Content} ->
					?LOG_DEBUG("packet decoded by host ~p: ~p", [{State#state.host, State#state.port}, {ReqId, Type, Content}]),
					% lookup Pid
					case ets:lookup(State#state.assoc_table, ReqId) of
						[{ReqId, RequestorPid}] ->
							% this is  a packet response to an http request, respond
							i_send_response(RequestorPid, ReqId, Type, Content);
						_ ->
							% TODO: interpret response
							?LOG_DEBUG("ignoring packet: ~p", [{ReqId, Type, Content}]),
							ok
					end;
				{error, _Reason} ->
					?LOG_WARNING("connection process received a wrong packet by host ~p with error: ~p", [{State#state.host, State#state.port}, _Reason]),
					ok
			end,
			% set options
			inet:setopts(CSock, [{active, once}]),
			% loop
			loop(State);		
		{remove_reqid, ReqId} ->
			?LOG_DEBUG("removing request id ~p reference on connection for host ~p", [ReqId, {State#state.host, State#state.port}]),
			% remove reference to req id
			ets:delete(State#state.assoc_table, ReqId),
			% loop
			loop(State);
		{tcp_closed, CSock} ->
			?LOG_DEBUG("fastcgi connection process socket got closed by host ~p", [{State#state.host, State#state.port}]),
			% reset
			loop(State#state{sock = false});
		{tcp_error, CSock, _Reason} ->
			?LOG_ERROR("socket error on host ~p: ~p, resetting connection", [{State#state.host, State#state.port}, _Reason]),
			% close socket
			gen_tcp:close(CSock),
			% reset
			init({State#state.host, State#state.port}, State#state.fconfig, State#state.manager_pid,  State#state.fcgi_mpxs_conns,  State#state.fcgi_max_reqs);
		shutdown ->
			?LOG_DEBUG("shutdown request received by fastcgi connection process ~p", [{State#state.host, State#state.port}]),
			% delete ets table
			ets:delete(State#state.assoc_table),
			gen_tcp:close(State#state.sock);
		_Unknown ->
			?LOG_DEBUG("received unknown message by fastcgi connection process ~p, ignoring", [{State#state.host, State#state.port}, _Unknown]),
			loop(State)
	end.

% internal send response: runs in the connection process
i_send_response(RequestorPid, ReqId, Type, Content) ->
	RequestorPid ! {response, {ReqId, Type, Content}}.

% internal send error: runs in the connection process
i_send_error(RequestorPid, ReqId, Reason) ->
	RequestorPid ! {error, {ReqId, Reason}}.

% Function: {ok, CPid, {ReqId, Acc}} | {error, CPid, Reason}
% internal get response
i_get_response(Timeout, Acc, Result) ->
	receive
		{response, {_ReqId, fcgi_stderr, Content}} ->
			?LOG_DEBUG("received a fastcgi error response: ~p", [Content]),
			% received an error, fill in response and set flag to ignore rest
			i_get_response(Timeout, <<Acc/big-binary, Content/big-binary>>, error);
		{response, {_ReqId, fcgi_stdout, Content}} when Result =:= ok ->
			% received content, add to Acc
			i_get_response(Timeout, <<Acc/big-binary, Content/big-binary>>, Result);
		{response, {_ReqId, fcgi_stdout, Content}} ->
			% we have a fcgi_stderr, add before
			i_get_response(Timeout, <<Content/big-binary, Acc/big-binary>>, Result);
		{response, {ReqId, fcgi_end_request, _Content}} ->
			% received end of stdout, return response
			{ok, {ReqId, Acc}};		
		{response, _Response} ->
			% ignore
			?LOG_WARNING("received unknown response: ~p, ignoring", [_Response]),
			i_get_response(Timeout, Acc, Result);
		{error, {ReqId, Reason}} ->
			?LOG_ERROR("received error in response from connection process: ~p", [Reason]),
			{error, {ReqId, Reason}};
		_Unknown ->
			% ignore
			?LOG_WARNING("received unknown message: ~p, ignoring", [_Unknown]),
			i_get_response(Timeout, Acc, Result)
	after Timeout ->
		% timeout, this means process is overwhelmed or crashed
		{error, timeout_waiting_fastcgi_response}
	end.

% ============================ /\ INTERNAL FUNCTIONS =======================================================