% ==========================================================================================================
% BISBINO - Include file
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
%    following disclaimer.
%  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and
%    the following disclaimer in the documentation and/or other materials provided with the distribution.
%  * Neither the name of the authors nor the names of its contributors may be used to endorse or promote
%    products derived from this software without specific prior written permission.
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

% bisbino configuration
-record(bisbino_config, {
	port,
	signature,
	server_software
}).

% bisbino VHOST
-record(vhost_config, {
	admin_email,						% admin email
	rewrite_rules = [],					% list of compiled rewrite rules
	directory_index,					% directory index
	serve_static_files,					% true | false
	static_files_document_root,			% if serve_static_files =:= true, files will be served from this directory
	fastcgi_managers = []				% [{Name, Port, fastcgi_server_config},...]
}).

% bisbino fastcgi_server_config
-record(fastcgi_server_config, {
	extensions,					% list of extensions supported by fastcgi
	document_root,				% document root of fastcgi
	connect_timeout,			% connection timeout to the fastcgi backend [ms]
	connect_retry_after,		% if no connection can be established, retry after specified time [ms]
	response_timeout			% response timeout from the fastcgi backend [ms]
}).


