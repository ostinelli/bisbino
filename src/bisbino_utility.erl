% ==========================================================================================================
% Bisbino - Various Utilities
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
-module(bisbino_utility).
-vsn("0.1-dev").

% API
-export([get_key_value/2, get_key_value/3, get_key_value_default/3, get_key_value_default/4, convert_ip_to_string/1, split_at_q_mark/1]).


% ============================ \/ API ======================================================================

% faster than proplists:get_value
get_key_value(Key, List) ->
	get_key_value(Key, List, 1).
get_key_value(Key, List, Pos) ->
	case lists:keyfind(Key, Pos, List) of
		false-> undefined;
		{_K, Value}-> Value
	end.
	
% get value and set default
get_key_value_default(Key, List, DefaultValue) ->
	get_key_value_default(Key, List, DefaultValue, 1).
get_key_value_default(Key, List, DefaultValue, Pos) ->
	case bisbino_utility:get_key_value(Key, List, Pos) of
		undefined -> DefaultValue;
		Value -> Value
	end.

% convert ip to string
convert_ip_to_string(Ip) when is_list(Ip) -> Ip;
convert_ip_to_string(Ip) when is_tuple(Ip) ->
	case Ip of
		{_, _, _, _} -> lists:flatten(io_lib:format("~w.~w.~w.~w", tuple_to_list(Ip)));
		{_, _, _, _, _, _} -> lists:flatten(io_lib:format("~w.~w.~w.~w.~w.~w", tuple_to_list(Ip)))
	end;
convert_ip_to_string(Ip) when is_atom(Ip) -> atom_to_list(Ip);
convert_ip_to_string(Ip)  -> lists:flatten(io_lib:format("~p", Ip)).

% split the path at the ?
split_at_q_mark(Path) ->
	split_at_q_mark(Path, []).

% ============================ /\ API ======================================================================



% ============================ \/ INTERNAL FUNCTIONS =======================================================

% split the path at the ?
split_at_q_mark([$?|T], Acc) ->
	{lists:reverse(Acc), T};
split_at_q_mark([H|T], Acc) ->
	split_at_q_mark(T, [H|Acc]);
split_at_q_mark([], Acc) ->
	{lists:reverse(Acc), []}.

% ============================ /\ INTERNAL FUNCTIONS =======================================================
