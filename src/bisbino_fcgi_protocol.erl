% ==========================================================================================================
% BISBINO - FastCGI protocol
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
-module(bisbino_fcgi_protocol).
-vsn("0.1-dev").

% API
-export([generate_param_request/3, generate_management_request/1, decode_packet/1, params_unpair/1]).

% macros
-define(KEEP_FCGI_CONN_OPEN, 1).	% if 0, close the connection after the response, otherwise keep it open

% includes
-include("../include/misultin.hrl").

% ============================ \/ API ======================================================================

% generate param request
generate_param_request(ReqId, Params, Body) ->
	i_generate_param_request(ReqId, Params, Body).
	
% generate param request
generate_management_request(ReqId) ->
	i_generate_management_request(ReqId).

% Function() -> {ReqId, Type, Content} | {error, Reason}
% Description: Decodes a received FastCGI packet.
decode_packet(Bin) ->
	i_decode_packet(Bin).
	
% Function() -> [{Tag, Value},...] | {error, Reason}
% Description: Unpairs parameter values
params_unpair(Params) ->
	i_params_unpair(Params, []).
	
% ============================ /\ API ======================================================================



% ============================ \/ INTERNAL FUNCTIONS =======================================================

% generate a fastcgi packet
i_generate_param_request(ReqId, Params, Body) ->
	% FCGI_BEGIN_REQUEST
	Role = fcgi_role(fcgi_responder),
	FcgiBeginRequest = fcgi_packet(ReqId, fcgi_begin_request, <<
		Role:16/big-unsigned-integer,			% role
		?KEEP_FCGI_CONN_OPEN:8,					% if 0, close the connection after the response, otherwise keep it open
		0:40									% reserved	
	>>),
	% FCGI_PARAMS
	FcgiParams = case Params of
		[] -> fcgi_packet(ReqId, fcgi_params, <<>>);
		_ ->
			FcgiParams0 = fcgi_packet(ReqId, fcgi_params, fcgi_params_pair(Params)),
			FcgiParams1 = fcgi_packet(ReqId, fcgi_params, <<>>),
			<<
				FcgiParams0/big-binary,
				FcgiParams1/big-binary
			>>
	end,
	% FCGI_STDIN
	FcgiStdin0 = fcgi_packet(ReqId, fcgi_stdin, Body),
	FcgiStdin1 = fcgi_packet(ReqId, fcgi_stdin, <<>>),
		
	% return complete message bytes
	<<
		FcgiBeginRequest/big-binary,
		FcgiParams/big-binary,
		FcgiStdin0/big-binary,
		FcgiStdin1/big-binary
	>>.

% generate a variable request
i_generate_management_request(ReqId) ->
	% pairs
	FcgiPairs = fcgi_params_pair([
		{"FCGI_MAX_CONNS", []},
		{"FCGI_MAX_REQS", []},
		{"FCGI_MPXS_CONNS", []}	
	]),
	% return packet
	fcgi_packet(ReqId, fcgi_get_values, FcgiPairs).

% convert between type / constant value
fcgi_type(fcgi_begin_request) -> 1;
fcgi_type(fcgi_abort_request) -> 2;
fcgi_type(fcgi_end_request) -> 3;
fcgi_type(fcgi_params) -> 4;
fcgi_type(fcgi_stdin) -> 5;
fcgi_type(fcgi_stdout) -> 6;
fcgi_type(fcgi_stderr) -> 7;
fcgi_type(fcgi_data) -> 8;
fcgi_type(fcgi_get_values) -> 9;
fcgi_type(fcgi_get_values_result) -> 10;
fcgi_type(_) -> 11.
fcgi_type_rev(1) -> fcgi_begin_request;
fcgi_type_rev(2) -> fcgi_abort_request;
fcgi_type_rev(3) -> fcgi_end_request;
fcgi_type_rev(4) -> fcgi_params;
fcgi_type_rev(5) -> fcgi_stdin;
fcgi_type_rev(6) -> fcgi_stdout;
fcgi_type_rev(7) -> fcgi_stderr;
fcgi_type_rev(8) -> fcgi_data;
fcgi_type_rev(9) -> fcgi_get_values;
fcgi_type_rev(10) -> fcgi_get_values_result;
fcgi_type_rev(_) -> fcgi_unknown_type.

% convert role to constant value
fcgi_role(fcgi_responder) -> 1;
fcgi_role(fcgi_authorizer) -> 2;
fcgi_role(fcgi_filter) -> 3.

% build a fastcgi packet
fcgi_packet(ReqId, Type, Content) ->
	fcgi_packet(ReqId, Type, Content, <<>>).
fcgi_packet(ReqId, Type, <<Content0:65535/big-binary, ContentRem/big-binary>>, Acc) ->
	P = fcgi_packet_build(ReqId, Type, Content0),
	fcgi_packet(ReqId, Type, ContentRem, <<Acc/binary, P/binary>>);
fcgi_packet(ReqId, Type, Content, Acc) ->
	P = fcgi_packet_build(ReqId, Type, Content),
	<<Acc/binary, P/binary>>.
fcgi_packet_build(ReqId, Type, Content) ->
	TypeVal = fcgi_type(Type),
	ContentLength = size(Content),	
	{PaddingLength, Padding} = case size(Content) rem 8 of
		0 -> {0, <<>>};
		PL -> {8 - PL, list_to_binary(lists:duplicate(8 - PL, 0))}
	end,
	<<
		1:8/big-unsigned-integer,				% version
		TypeVal:8/big-unsigned-integer,			% type of message
		ReqId:16/big-unsigned-integer,			% request identifier
		ContentLength:16/big-unsigned-integer,	% content length
		PaddingLength:8/big-unsigned-integer,	% padding length
		0:8/big-unsigned-integer,				% reserved
		Content:ContentLength/big-binary,		% content
		Padding:PaddingLength/big-binary		% padding
	>>.	

% build param pairs
fcgi_params_pair(Params) ->
	F = fun({Tag, Value}, Acc) ->
		TagLengthBin = fcgi_params_pair_taglen(Tag),
		ValueLengthBin = fcgi_params_pair_taglen(Value),
		TagBin = list_to_binary(Tag),
		ValueBin = list_to_binary(Value),
		<<
			TagLengthBin/big-binary,
			ValueLengthBin/big-binary,
			TagBin/big-binary,
			ValueBin/big-binary,
			Acc/big-binary
		>>
	end,
	lists:foldl(F, <<>>, Params).
fcgi_params_pair_taglen(El) ->
	case length(El) of
		ELength when ELength < 128 -> <<ELength:8/big-unsigned-integer>>;
		ELength0 -> 
			ELength = 2147483648 + ELength0,
			<<ELength:32/big-unsigned-integer>>
	end.

% decode a packet
i_decode_packet(Bin) when size(Bin) >= 8 ->
	<<
		_Version:8/big-unsigned-integer,		% version
		TypeVal:8/big-unsigned-integer,			% type of message
		ReqId:16/big-unsigned-integer,			% request identifier
		ContentLength:16/big-unsigned-integer,	% content length
		_PaddingLength:8/big-unsigned-integer,	% padding length
		0:8/big-unsigned-integer,				% reserved
		Content:ContentLength/big-binary,		% content
		_Padding/big-binary						% padding
	>> = Bin,
	{ReqId, fcgi_type_rev(TypeVal), Content};
i_decode_packet(_Bin) -> {error, fcgi_packet_too_small}.

% unpair parameters
i_params_unpair(<<>>, Params) ->
	Params;
i_params_unpair(ParamsBin, Params) ->
	case i_params_unpair_len(ParamsBin) of
		{TagLength, ValueLength, T0} ->
			case size(T0) >= TagLength + ValueLength of
				true ->
					<<Tag:TagLength/big-binary, Value:ValueLength/big-binary, T/big-binary>> = T0,
					i_params_unpair(T, [{binary_to_list(Tag), binary_to_list(Value)}|Params]);
				false ->
					{error, invalid_fcgi_packet}
			end;
		{error, Reason} -> {error, Reason}
	end.
i_params_unpair_len(ParamsBin) ->
	case i_params_unpair_getlen(ParamsBin) of
		{error, Reason} -> {error, Reason};
		{TagLength, T0}  ->
			case i_params_unpair_getlen(T0) of
				{error, Reason} -> {error, Reason};
				{ValueLength, T} ->	{TagLength, ValueLength, T}
			end
	end.		
i_params_unpair_getlen(<<Len:8/big-unsigned-integer, T/big-binary>>) when Len < 128 -> {Len, T};
i_params_unpair_getlen(<<L0:8/big-unsigned-integer, L1:8/big-unsigned-integer, L2:8/big-unsigned-integer, L3:8/big-unsigned-integer, T/big-binary>>) ->
	L4 = L0 - 128,
	<<Len:32/big-unsigned-integer>> = <<L4:8/big-unsigned-integer, L1:8/big-unsigned-integer, L2:8/big-unsigned-integer, L3:8/big-unsigned-integer>>,
	{Len, T};
i_params_unpair_getlen(_) -> {error, invalid_fcgi_packet_len}.

% ============================ /\ INTERNAL FUNCTIONS =======================================================
