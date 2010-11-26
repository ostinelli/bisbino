==========================================================================================================
BISBINO - An Erlang HTTP server with FastCGI as backend.
<http://github.com/ostinelli/bisbino/>


FOREWORD
==========================================================================================================
This is a first development release of a HTTP server serving pages with a FastCGI backend. Early stage,
documentation will soon follow.

Just to get you started:

1. Install a FastCGI backend, such as php-fpm <http://php-fpm.org/>. On a UBUNTU 10.04 LTS box, the only
   thing you'll need to do is to issue the commands:

   . add repository
   sudo add-apt-repository ppa:brianmercer/php

   . install php and dependencies
   sudo apt-get install php5-cli php5-common php5-suhosin python-software-properties php5-fpm php5-cgi

   . start php5-fpm
   sudo service php5-fpm start

2. Configure your host: open the sites/default.vhost file and set the appropriate absolute path to your
   files in the parameters:

   {static_files_document_root, "** YOUR HTDOCS DIRECTORY HERE **"}.

   {fastcgi_servers, [
      {"localhost", [
         *SNIP*   
         {document_root, "** YOUR HTDOCS DIRECTORY HERE **"},
         *SNIP*
      ]}
   ]}.

3. Start bisbino. In an Erlang shell, type

   1> application:start(bisbino).

4. Point your browser to: http://localhost:8080. You should see a phpinfo() page printed out.


CHANGELOG
==========================================================================================================

0.1-dev: - initial release.
