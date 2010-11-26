% ==========================================================================================================
% BISBINO
%
% Copyright (C) 2010, Roberto Ostinelli <roberto@ostinelli.net>
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
-module(bisbino).
-behaviour(gen_server).
-vsn("0.1-dev").

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% API
-export([start_link/0, stop/0, add_active_fcgi_manager/3, remove_active_fcgi_server/1, get_fastcgi_managers_active/0]).

% records
-record(state, {
	port,
	fastcgi_managers = [],			% list of available servers: [{Pid, {Name, Port}, #fastcgi_server_config},...]
	fastcgi_managers_active = []		% list of active servers: [{Pid, {Name, Port}},...]
}).

% macros
-define(SERVER, ?MODULE).
-define(BISBINO_CONFIG_FILE, "bisbino.conf").
-define(VHOST_DIR, "sites").

% includes
-include("../include/misultin.hrl").
-include("../include/bisbino.hrl").

% ============================ \/ API ======================================================================

% Function: {ok,Pid} | ignore | {error, Error}
% Description: Starts the server.
start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

% Function: -> ok
% Description: Manually stops the server.
stop() ->
	gen_server:cast(?SERVER, stop).
	
% add fastcgi available server
add_active_fcgi_manager(FPid, {FHost, FPort}, Config) ->
	gen_server:cast(?SERVER, {add_active_fcgi_manager, {FPid, {FHost, FPort}, Config}}).

% remove fastcgi available server
remove_active_fcgi_server(FPid) ->
	gen_server:cast(?SERVER, {remove_active_fcgi_server, FPid}).

% Function: [{Pid, {Name, Port}, #fastcgi_server_config}},...]
% Description: Get active fastcgi servers
get_fastcgi_managers_active() ->
	gen_server:call(?SERVER, get_fastcgi_managers_active).

% ============================ /\ API ======================================================================


% ============================ \/ GEN_SERVER CALLBACKS =====================================================

% ----------------------------------------------------------------------------------------------------------
% Function: -> {ok, State} | {ok, State, Timeout} | ignore | {stop, Reason}
% Description: Initiates the server.
% ----------------------------------------------------------------------------------------------------------
init([]) ->
	% trap_exit -> this gen_server needs to be supervised
	process_flag(trap_exit, true),
	% get options
	?LOG_DEBUG("reading configuration file",[]),
	% read config
	case file:consult(filename:join([filename:dirname(code:which(?MODULE)), "..", ?BISBINO_CONFIG_FILE])) of
		{ok, Terms} ->
			% get server configuration - TODO: provide input checks
			Port = bisbino_utility:get_key_value(server_port, Terms),
			% create config record to be passed to http Req handler
			{ok, Hostname} = inet:gethostname(),
			Config = #bisbino_config{
				port = integer_to_list(Port),
				signature = lists:concat(["Bisbino/0.1 (Erlang) Server at ", Hostname, " Port ", integer_to_list(Port)]),
				server_software = lists:concat(["Bisbino/0.1 (Erlang ", erlang:system_info(otp_release), ", Kernel Poll ", atom_to_list(erlang:system_info(kernel_poll)), ")"])
			},
			% build vhost list
			?LOG_DEBUG("build vhost list",[]),
			FReadVhost = fun(FilePath, Acc) ->
				?LOG_DEBUG("reading vhost file: ~p", [FilePath]),
				case file:consult(FilePath) of
					{ok, VTerms} ->
						?LOG_DEBUG("read terms: ~p", [VTerms]),
						% get Fcgi servers
						FGetFcgi = fun({FcgiName, FcgiOptions}, FcgiAcc) ->
							[{{FcgiName, bisbino_utility:get_key_value(port, FcgiOptions)}, #fastcgi_server_config{
								extensions = bisbino_utility:get_key_value(extensions, FcgiOptions),
								document_root = bisbino_utility:get_key_value(document_root, FcgiOptions),
								connect_timeout = bisbino_utility:get_key_value(connect_timeout, FcgiOptions),
								connect_retry_after = bisbino_utility:get_key_value(connect_retry_after, FcgiOptions),
								response_timeout = bisbino_utility:get_key_value(response_timeout, FcgiOptions)							
							}}|FcgiAcc]
						end,
						FcgiServers0 = lists:foldl(FGetFcgi, [], bisbino_utility:get_key_value(fastcgi_servers, VTerms)),
						% compile rewrite rules
						RewriteRules = compile_rewrites(bisbino_utility:get_key_value(rewrite_rules, VTerms)),
						case lists:keyfind(error, 1, RewriteRules) of
							{error, Reason} ->
								[{error, FilePath, {invalid_vhost_rewrite_rules, Reason}}|Acc];
							false ->
								% build and append vhost
								[{string:to_lower(bisbino_utility:get_key_value(name, VTerms)), #vhost_config{
									admin_email = bisbino_utility:get_key_value(admin_email, VTerms),
									rewrite_rules = RewriteRules,
									directory_index = bisbino_utility:get_key_value(directory_index, VTerms),
									serve_static_files = bisbino_utility:get_key_value(serve_static_files, VTerms),
									static_files_document_root = bisbino_utility:get_key_value(static_files_document_root, VTerms),
									fastcgi_managers = FcgiServers0						
								}}|Acc]
						end;
					{error, Reason} ->
						?LOG_DEBUG("error reading terms: ~p", [Reason]),
						% error reading file
						[{error, FilePath, {invalid_vhost_config_file, Reason}}|Acc]
				end
			end,
			% build list of VHOSTS records
			?LOG_DEBUG("build list of vhosts records",[]),
			VHosts = lists:foldl(FReadVhost, [], filelib:wildcard(filename:join([filename:dirname(code:which(?MODULE)), "..", ?VHOST_DIR, "*.vhost"]))),
			% check if everything ok
			case lists:keyfind(error, 1, VHosts) of
				{error, FilePath, Reason} ->
					% error reading vhost file
					?LOG_ERROR("error reading vhost file ~p: ~p", [FilePath, Reason]),
					{stop, {invalid_vhost_config_file, {FilePath, Reason}}};
				false ->
					% vhosts config files are ok, build rewrite rules, build unique list of fcgi servers
					?LOG_DEBUG("build unique list of fcgi servers",[]),
					F1 = fun({_Vh, VhC}, F1Acc) ->
						F2 = fun({{UName, UPort}, _} = UServer, F2Acc) ->
							case bisbino_utility:get_key_value({UName, UPort}, F1Acc) of
								undefined -> [UServer|F2Acc]; % new server, add
								_ -> F2Acc
							end
						end,
						lists:concat([lists:foldl(F2, [], VhC#vhost_config.fastcgi_managers), F1Acc])
					end,
					% build list of unique fastcgi servers
					FastCgiManagers0 = lists:foldl(F1, [], VHosts),
					% create fastcgi servers processes
					?LOG_DEBUG("create fastcgi managers for backends: ~p", [FastCgiManagers0]),
					FSpawn = fun({{FHost, FPort}, FConfig}, SpawnAcc) ->
						FPid = bisbino_fcgi_manager:start_link({FHost, FPort}, FConfig),
						[{FPid, {FHost, FPort}, FConfig}|SpawnAcc]
					end,
					FastCgiManagers = lists:foldl(FSpawn, [], FastCgiManagers0),
					% start misultin & set monitor
					?LOG_DEBUG("starting misultin",[]),
					misultin:start_link([{port, Port}, {loop, fun(Req) -> bisbino_http:handle_http(Req, VHosts, Config) end}]),
					erlang:monitor(process, misultin),
					?LOG_INFO("bisbino server started on port ~p", [Port]),
					{ok, #state{port = Port, fastcgi_managers = FastCgiManagers}}
			end;
		{error, Reason} ->
			% error reading bisbino
			{stop, {invalid_bisbino_config_file, Reason}}
	end.

% ----------------------------------------------------------------------------------------------------------
% Function: handle_call(Request, From, State) -> {reply, Reply, State} | {reply, Reply, State, Timeout} |
%									   {noreply, State} | {noreply, State, Timeout} |
%									   {stop, Reason, Reply, State} | {stop, Reason, State}
% Description: Handling call messages.
% ----------------------------------------------------------------------------------------------------------

% get active fastcgi servers
handle_call(get_fastcgi_managers_active, _From, #state{fastcgi_managers_active = FastCgiManagersActive} = State) ->
	{reply, FastCgiManagersActive, State};

% handle_call generic fallback
handle_call(_Request, _From, State) ->
	{reply, undefined, State}.

% ----------------------------------------------------------------------------------------------------------
% Function: handle_cast(Msg, State) -> {noreply, State} | {noreply, State, Timeout} | {stop, Reason, State}
% Description: Handling cast messages.
% ----------------------------------------------------------------------------------------------------------

% add fastcgi server to the active ones
handle_cast({add_active_fcgi_manager, {FPid, {FHost, FPort}, Config}}, #state{fastcgi_managers_active = FastCgiManagersActive} = State) ->
	?LOG_DEBUG("adding fastcgi active server ~p", [{FPid, {FHost, FPort}}]),
	NewFastCgiManagersActive = [{FPid, {FHost, FPort}, Config}|FastCgiManagersActive],
	?LOG_DEBUG("fastcgi active server list: ~p", [NewFastCgiManagersActive]),
	{noreply, State#state{fastcgi_managers_active = NewFastCgiManagersActive}};

% remove fastcgi server from the active ones
handle_cast({remove_active_fcgi_server, FPid}, #state{fastcgi_managers_active = FastCgiManagersActive} = State) ->
	?LOG_DEBUG("removing fastcgi active server ~p", [FPid]),
	NewFastCgiManagersActive = lists:keydelete(FPid, 1, FastCgiManagersActive),
	?LOG_DEBUG("fastcgi active server list: ~p", [NewFastCgiManagersActive]),
	{noreply, State#state{fastcgi_managers_active = NewFastCgiManagersActive}};

% manual shutdown
handle_cast(stop, State) ->
	?LOG_INFO("manual shutdown..", []),
	{stop, normal, State};

% handle_cast generic fallback (ignore)
handle_cast(_Msg, State) ->
	?LOG_WARNING("received unknown cast message: ~p", [_Msg]),
	{noreply, State}.

% ----------------------------------------------------------------------------------------------------------
% Function: handle_info(Info, State) -> {noreply, State} | {noreply, State, Timeout} | {stop, Reason, State}
% Description: Handling all non call/cast messages.
% ----------------------------------------------------------------------------------------------------------

% handle info when misultin server goes down -> take down misultin_gen_server too [the supervisor will take everything up again]
handle_info({'DOWN', _, _, {misultin, _}, _Info}, State) ->
	?LOG_ERROR("misultin crashed: ~p, stopping bisbino", [_Info]),
	{stop, normal, State};

% a process crashed, maybe a fastcgi connection closed
handle_info({'EXIT', FPid, {error, _Reason}}, #state{fastcgi_managers = FastCgiManagers, fastcgi_managers_active = FastCgiManagersActive} = State) ->
	% get server info
	case lists:keyfind(FPid, 1, FastCgiManagersActive) of
		false ->
			% not found in list, ignore
			{noreply, State};
		{FPid, {FHost, FPort}, FConfig} ->
			?LOG_WARNING("fastcgi server process manager for ~p exited with error: ~p, respawning", [{FHost, FPort}, _Reason]),
			% try reconnect {Host, Port}, Configs
			NewFPid = bisbino_fcgi_manager:start_link({FHost, FPort}, FConfig),
			% replace pid info on server list, and remove from active list
			{noreply, State#state{fastcgi_managers = lists:keyreplace(FPid, 1, FastCgiManagers, {NewFPid, FHost, FPort}), fastcgi_managers_active = lists:keydelete(FPid, 1, FastCgiManagersActive)}}
	end;

% handle_info generic fallback (ignore)
handle_info(_Info, State) ->
	?LOG_WARNING("received unknown info message: ~p", [_Info]),
	{noreply, State}.

% ----------------------------------------------------------------------------------------------------------
% Function: terminate(Reason, State) -> void()
% Description: This function is called by a gen_server when it is about to terminate. When it returns,
% the gen_server terminates with Reason. The return value is ignored.
% ----------------------------------------------------------------------------------------------------------
terminate(_Reason, #state{fastcgi_managers = FastCgiManagers} = _State) ->
	?LOG_INFO("shutting down bisbino server with Pid ~p", [self()]),
	% stop misultin
	misultin:stop(),
	% disconnect from fastcgi servers
	?LOG_DEBUG("closing down all fastcgi connections", []),
	lists:foreach(fun({FPid, _FHost, _FPort}) -> bisbino_fcgi_manager:shutdown(FPid) end, FastCgiManagers),
	terminated.

% ----------------------------------------------------------------------------------------------------------
% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
% Description: Convert process state when code is changed.
% ----------------------------------------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% ============================ /\ GEN_SERVER CALLBACKS =====================================================


% ============================ \/ INTERNAL FUNCTIONS =======================================================

% Function: [{RE, Replace, {stop()}}, ...]
% Description: Compiles and build rewrite rules.
compile_rewrites(RWRules) ->
	FCompile = fun({RWFind, RWReplace, RWOptions}, RWAcc) ->
		case re:compile(RWFind) of
			{error, ErrSpec} ->
				[{error, {invalid_rewrite, ErrSpec, {RWFind, RWReplace, RWOptions}}}|RWAcc];
			{ok, RE} ->
				[{RE, RWReplace, {lists:member(stop, RWOptions)}}|RWAcc]
		end
	end,
	lists:reverse(lists:foldl(FCompile, [], RWRules)).

% ============================ /\ INTERNAL FUNCTIONS =======================================================

