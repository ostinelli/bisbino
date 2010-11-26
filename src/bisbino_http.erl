% ==========================================================================================================
% BISBINO - http handle
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
-module(bisbino_http).
-vsn("0.1-dev").

% gen_server callbacks
-export([handle_http/3]).

% includes
-include_lib("kernel/include/file.hrl").
-include("../include/misultin.hrl").
-include("../include/bisbino.hrl").

% ============================ \/ BISBINO CALLBACK =========================================================
% callback from misultin
handle_http(Req, VHosts, Config) ->
	% get raw request
	R = Req:raw(),
	% which host is this for
	?LOG_DEBUG("getting request's host", []),
	case bisbino_utility:get_key_value('Host', R#req.headers) of
		undefined ->
			% no host specified, as per http specs return 400 (Bad Request)
			?LOG_DEBUG("no host specified, return http 400 error", []),
			Req:respond(400, error_template(400, Config#bisbino_config.signature));
		HostStr ->
			?LOG_DEBUG("request specifies string host: ~p", [HostStr]),
			% get host part, according to http specs this might have port also
			[Host0|_] = string:tokens(HostStr, ":"),
			Host = string:to_lower(Host0),
			% seek host in VHosts
			case bisbino_utility:get_key_value(Host, VHosts) of
				undefined ->
					?LOG_DEBUG("requested host is not configured, send 501", []),
					Req:respond(501, error_template(501, Config#bisbino_config.signature));
				VHostConfig ->
					% found vhost
					?LOG_DEBUG("request is for host: ~p", [{Host, VHostConfig}]),
					handle_http(uri, Req, Config, {Host, VHostConfig}, {HostStr, R})
			end
	end.

% get uri
handle_http(uri, Req, Config, {VHost, VHostConfig}, {HostStr, R}) ->
	% get Uri
	RawUri = case R#req.uri of
		{abs_path, Uri} ->
			% keep as is
			Uri;
		{absoluteURI, Uri} ->
			% convert to abs_path
			string:sub_string(Uri, string:str(Uri, HostStr) + length(HostStr))
	end,
	handle_http(rewrite, Req, Config, {VHost, VHostConfig}, {R, RawUri});
	
% rewrite
handle_http(rewrite, Req, Config, {VHost, #vhost_config{rewrite_rules = RewriteRules, directory_index = DirectoryIndex} = VHostConfig}, {R, RawUri}) ->
	?LOG_DEBUG("request uri is: ~p", [RawUri]),
	% rewrite rules
	Uri0 = rewrite_build(RawUri, RewriteRules),
	?LOG_DEBUG("first rewritten uri is: ~p", [Uri0]),
	% get new uri, and set new args
	{Uri1, Args} = bisbino_utility:split_at_q_mark(Uri0),
	NewArgs = string:join([R#req.args, Args], "&"),
	?LOG_DEBUG("new requests args are: ~p", [NewArgs]),
	% missing directory index?
	Uri = case lists:last(Uri1) of
		47 -> lists:concat([Uri1, DirectoryIndex]); % uri end in /, we need to append directory index
		_ -> Uri1
	end,
	?LOG_DEBUG("final rewritten uri is: ~p", [Uri]),
	% end of building final uri
	handle_http(static, Req, Config, {VHost, VHostConfig}, {R#req{args = NewArgs}, Uri});

% serve static files if any
handle_http(static, Req, Config, {VHost, #vhost_config{serve_static_files = ServeStaticFiles, static_files_document_root = StaticFilesDocumentRoot, fastcgi_managers = FastcgiManagers} = VHostConfig}, {R, Uri}) ->
	% build file path
	FilePath = lists:concat([StaticFilesDocumentRoot, Uri]),
	% should we serve this file directly?
	ServeFile = case ServeStaticFiles of
		true when R#req.method =:= 'GET' -> filelib:is_regular(FilePath);	% serve local static files if these exist, on a GET request
		_ -> false
	end,
	% check if file's extension is supported by fastcgi backends of this host
	case get_backend_server_list(FilePath, FastcgiManagers) of
		[] ->
			% no fastcgi backend server supports this extension
			?LOG_DEBUG("no fastcgi backend server support file's extension: ~p", [FilePath]),
			case ServeFile of
				true ->
					% send file directly
					?LOG_DEBUG("send file to browser",[]),
					Req:file(FilePath);
				false ->
					% we shouldn't serve this file
					?LOG_DEBUG("file does not exist or shouldn't be served, return a 404",[]),
					Req:respond(404, error_template(404, Config#bisbino_config.signature))
			end;
		Backends ->
			% one or more fastcgi backend servers support this extension -> send to fastcgi
			?LOG_DEBUG("file can be served by the following fastcgi backends: ~p",[Backends]),
			handle_http(fastcgi_get_manager, Req, Config, {VHost, VHostConfig}, {R, Uri, Backends})
	end;

% get the backend that will answer 
handle_http(fastcgi_get_manager, Req, Config, {VHost, VHostConfig}, {R, Uri, Backends}) ->
	% get active backends from gen_server
	FastcgiManagersActive = bisbino:get_fastcgi_managers_active(),
	?LOG_DEBUG("active fastcgi backends: ~p", [FastcgiManagersActive]),
	% get list of Backends which are in FastcgiManagersActive
	F = fun({_, NamePort, _}) ->
		lists:member(NamePort, Backends)
	end,	
	AvailableBackends = lists:filter(F, FastcgiManagersActive),
	?LOG_DEBUG("available fastcgi backends: ~p", [AvailableBackends]),
	% randomly select one of the active server, if more than one [vary basic balancer here, can easily be improved]
	% {Pid, {Name, Port}, #fastcgi_server_config}}
	Backend = case AvailableBackends of
		[] ->
			% no servers
			false;
		[AvailableBackend] ->
			% one server
			AvailableBackend;
		_ ->
			% many servers
			lists:nth(random:uniform(length(AvailableBackends)), AvailableBackends)
	end,
	% available found?
	?LOG_DEBUG("selected fastcgi backend: ~p", [Backend]),
	case Backend of
		false ->
			% no active servers
			?LOG_ERROR("there are no active fastcgi server to respond the request: ~p", [Req]),
			Req:respond(503, error_template(503, Config#bisbino_config.signature));
		_ ->
			% build the request
			handle_http(fastcgi_build, Req, Config, {VHost, VHostConfig}, {R, Uri, Backend})
	end;

% build variables to pass to fastcgi
handle_http(fastcgi_build, Req, Config, {VHost, VHostConfig}, {R, Uri, {_FPid, {_FHost, _FPort}, FConfig} = Backend}) ->
	?LOG_DEBUG("building the fastcgi request parameters",[]),
	
	% TODO: missing PATH_INFO, PATH_TRANSLATED, AUTH_TYPE, REMOTE_USER
	
	% init
	FcgiParams0 = [
		{"GATEWAY_INTERFACE", "FastCGI/1.0"},
		{"SERVER_SIGNATURE", Config#bisbino_config.signature},
		{"SERVER_SOFTWARE", Config#bisbino_config.server_software},
		{"SERVER_ADMIN", VHostConfig#vhost_config.admin_email},
		{"SERVER_NAME", VHost},
		{"SERVER_PORT", Config#bisbino_config.port},
		{"DOCUMENT_ROOT", FConfig#fastcgi_server_config.document_root},
		{"SCRIPT_NAME", Uri},
		{"SCRIPT_FILENAME", lists:concat([FConfig#fastcgi_server_config.document_root, Uri])},
		{"REQUEST_METHOD", atom_to_list(R#req.method)},
		{"REQUEST_URI", lists:concat([Uri, "?", R#req.args])},
		{"QUERY_STRING", R#req.args},
		{"CONTENT_LENGTH", integer_to_list(size(R#req.body))}
	],
	% remote_addr & remote_port
	FcgiParams1 = case R#req.peer_addr of
		undefined -> FcgiParams0;
		Val0 -> [{"REMOTE_ADDR", bisbino_utility:convert_ip_to_string(Val0)}|FcgiParams0]
	end,
	FcgiParams2 = case R#req.peer_port of
		undefined -> FcgiParams1;
		Val1 -> [{"REMOTE_PORT", integer_to_list(Val1)}|FcgiParams1]
	end,
	% server_protocol
	FcgiParams = case R#req.vsn of
		{Maj, Min} -> [{"SERVER_PROTOCOL", lists:concat(["HTTP/", Maj, ".", Min])}|FcgiParams2];
		_ -> FcgiParams2
	end,
	% params from http headers
	HttpParams0 = get_and_convert_to_fcgi_params([
		{"HTTP_ACCEPT", 'Accept'},
		{"HTTP_ACCEPT_ENCODING", 'Accept-Encoding'},
		{"HTTP_ACCEPT_LANGUAGE", 'Accept-Language'},
		{"HTTP_COOKIE", 'Cookie'},
		{"HTTP_FORWARDED", "X-Forwarded-For"},
		{"HTTP_PRAGMA", 'Pragma'},
		{"HTTP_REFERER", 'Referer'},
		{"HTTP_USER_AGENT", 'Referer'},
		{"CONTENT_TYPE", 'Content-Type'}
	], R#req.headers),
	% http_host
	HttpParams = case bisbino_utility:get_key_value('Host', R#req.headers) of
		undefined -> HttpParams0;
		IpAddr -> [{"HTTP_HOST", bisbino_utility:convert_ip_to_string(IpAddr)}|HttpParams0]
	end,
	% put all together
	Params = lists:concat([FcgiParams, HttpParams]),
	?LOG_DEBUG("built params: ~pm body size: ~p", [Params, size(R#req.body)]),
	% send to fastcgi
	handle_http(fastcgi_send, Req, Config, {VHost, VHostConfig}, {R, Backend, Params});
	
% send to fastcgi
handle_http(fastcgi_send, Req, Config, {VHost, VHostConfig}, {R, {FPid, {_FHost, _FPort}, FConfig} = Backend, Params}) ->
	% get request id
	case bisbino_fcgi_manager:get_reqid_and_cpid(FPid) of
		{ok, ReqId, CPid} ->
			?LOG_DEBUG("got reqid ~p from fastcgi manager for ~p, generate fastcgi packet", [ReqId, {_FHost, _FPort}]),
			% build content
			FPacket = bisbino_fcgi_protocol:generate_param_request(ReqId, Params, R#req.body),
			% send it to fastcgi
			?LOG_DEBUG("sending packet of size ~p to fastcgi connection process", [size(FPacket)]),
			case bisbino_fcgi_connection:get_response(FPid, CPid, ReqId, FPacket, FConfig#fastcgi_server_config.response_timeout) of
				{error, _Reason} ->
					?LOG_ERROR("fastcgi bad gateway error: ~p, responding to request: ~p, on backend ~p", [_Reason, Req, {_FHost, _FPort}]),
					Req:respond(502, error_template(502, Config#bisbino_config.signature));
				{ok, {_ReqId, FcgiResponse}} ->
					?LOG_DEBUG("got fastcgi response: ~p", [FcgiResponse]),
					% send response
					handle_http(respond, Req, Config, {VHost, VHostConfig}, {R, Backend, FcgiResponse})
			end;
		{error, _Reason} ->
			?LOG_ERROR("fastcgi internal error: ~p, responding to request: ~p, on backend ~p", [_Reason, Req, {_FHost, _FPort}]),
			Req:respond(500, error_template(500, Config#bisbino_config.signature))
	end;
	
% handle fastcgi response
handle_http(respond, Req, Config, {_VHost, _VHostConfig}, {_R, _Backend, FcgiResponse}) ->
	?LOG_DEBUG("splitting fastcgi response: ~p", [FcgiResponse]),
	{HeadersStr, Body} = split_fcgi_response(FcgiResponse),
	?LOG_DEBUG("response splitted in header: ~p, and body: ~p, sending reponse to browser", [HeadersStr, Body]),
	case get_fcgi_status(HeadersStr) of
		404 ->
			Req:raw_headers_respond(get_fcgi_status(HeadersStr), HeadersStr, error_template(404, Config#bisbino_config.signature));
		HttpCode ->
			Req:raw_headers_respond(HttpCode, HeadersStr, Body)
	end.

% ============================ /\ BISBINO CALLBACK =========================================================



% ============================ \/ INTERNAL FUNCTIONS =======================================================

% Function: [{FName, FPort},...]
% Description: Get which vhost's interpreters can respond to this file extension.
get_backend_server_list(FilePath, FastcgiManagers) ->
	% get file extension
	Ext = string:to_lower(filename:extension(FilePath)),
	% check if this file has an extension supported by one of the backend fastcgi servers
	F = fun({{FName, FPort}, FConfig}, Acc) ->
		case lists:member(Ext, FConfig#fastcgi_server_config.extensions) of
			true -> [{FName, FPort}|Acc];	% fastcgi backend of this host supports this extension
			_ -> Acc
		end
	end,
	lists:foldl(F, [], FastcgiManagers).

% Function: [{FcgiTag, Val},...]
% Description: Helper function to convert http headers & values to fastcgi params.
get_and_convert_to_fcgi_params(Params, HttpHeaders) ->
	F = fun({FcgiTag, HttpTag}, Acc) ->
		case bisbino_utility:get_key_value(HttpTag, HttpHeaders) of
			undefined -> Acc;
			Val -> [{FcgiTag, Val}|Acc]
		end
	end,
	lists:foldl(F, [], Params).

% Function: {HeadersStr, Body}
% Description: splits the fastcgi response into headers & body.
split_fcgi_response(Content) ->
	ContentStr = binary_to_list(Content),
	case string:str(ContentStr, "\r\n\r\n") of
		0 ->
			{ContentStr, ""};
		Sep ->
			{lists:flatten([string:left(ContentStr, Sep - 1)|"\r\n"]), string:sub_string(ContentStr, Sep + 4)}
	end.

% Function: integer()
% Description: Get status specified in fastcgi response
get_fcgi_status(HeadersStr) ->
	% get beginning of header
	case string:str(HeadersStr, "Status:") of
		0 ->
			200;
		SPos ->
			% get end of header
			Str0 = string:strip(string:sub_string(HeadersStr, SPos + 7)),
			Str1 = case string:str(Str0, "\r\n") of
				0 -> Str0;
				EPos -> string:strip(string:sub_string(Str0, 1, EPos - 1))
			end,
			% get numerical part
			Str2 = case string:str(Str1, " ") of
				0 -> Str1;
				EPos1 -> string:sub_string(Str1, 1, EPos1 - 1)
			end,
			% convert to number
			case catch(list_to_integer(Str2)) of
				{'EXIT', _} -> 200;
				Status -> Status
			end
	end.

% build common error template
error_template(HttpCode, Signature) ->
	["<html><head></head><body><h1>", misultin_utility:get_http_status_code(HttpCode), "</h1>", Signature, "</body></html>"].

% apply rewrite rules
rewrite_build(Uri, []) -> Uri;	
rewrite_build(Uri, [{RE, Replace, {Stop}}|RewriteRules]) ->
	Uri1 = re:replace(Uri, RE, Replace, [{return, list}]),
	case Stop of
		true ->
			case Uri1 =/= Uri of
				true -> Uri1;
				false -> rewrite_build(Uri1, RewriteRules)
			end;
		false -> rewrite_build(Uri1, RewriteRules)
	end.

% ============================ /\ INTERNAL FUNCTIONS =======================================================
