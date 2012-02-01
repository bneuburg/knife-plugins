Put those plugins to ~/.chef/plugins/knife/

Gem requirements:

- grit
- chef
- openssl

cookbook status
===============

To compare the server version of a cookbook with one in the cookbook path 
on your workstation, simply run
   `knife cookbook status COOKBOOKNAME`
This will compare the latest version of COOKBOOKNAME on the server with one
in the local cookbook path.
If there are mismatches and you want to know which files are affected, run
   `knife cookbook status COOKBOOKNAME --md5sums`
To check if a certain version of the cookbook on the server matches your local
cookbook, run
   `knife cookbook status COOKBOOKNAME VERSION`

To compare a server cookbook with a remote git repository, you either need to
set `git_url` in your `knife.rb` to e.g. "https://github.com/cookbooks" or pass the
url with the `--git-url` option, and need to pass the `-g` option additionally.
NOTE: It is important that each cookbook at the remote url is kept as a separate git
repository, e.g. when you run 
   `knife cookbook status apache2 -g --git-url "git://myrepo/stuff"`
you need to make sure that there is a git repo "git://myrepo/stuff/apache2.git".

To search for a commit in your git repo that matches the server version the closest,
use the `-r` option.

For a threeway comparision, i.e. comparing the chef server version with the local 
one and the one in your git remote source, use the `-t` option.

node secret add
===============

Why was this plugin created?

Chef offers encrypted data bags to store secrets in a way so that only certain nodes
can decrypt them. This is useful in e.g. a case where one of your nodes gets hacked
and the attacker could read e.g. the root password attribute for a mysql server
running on another node of your Chef infrastructure. 
The attacker could just use the hacked node's private Chef key to query that attribute.

However encrypted data bags require 'out-of-band' administration, i.e. you need to copy
the cryptographic key to the nodes that need to decrypt the encrypted data bag via ssh.
Moreover you need to manage all the keys for each encrypted data bag.

In my opinion this overhead is not necessary since Chef already provides a public
key infrastructure, which can be used without much hassle.

How does it work?

This plugin uses the public key of the node you want to generate the secret for
to encrypt a plaintext you pass and set the encrypted string to an attribute you pass.
   `knife node secret add my.no.de mypassword mysql.rootpw`
would set the nodes attribute [:mysql][:rootpw] to the encrypted version of "mypassword".
To use another public key instead of the one of client[my.no.de], use the `-x` option.
To just check what would be done, use `-d` or `--dry-run`.
To set a certain kind of attribute (i.e. default, normal, override) use the `-t` option:
   `knife node secret add my.no.de foo mysql.rootpw -t override`

To decrypt the encrypted string, your cookbook needs to support it and you need a
patched version of the openssl cookbook. For an example and the patched openssl 
cookbook check https://github.com/oscarschneider/openssldemo.

role secret add
===============

This plugin basically works the same way as node secret add, however you don't pass
a node name as parameter but a role name.

It will then query the Chef server for all nodes of role X and basically runs a 
`knife node secret add NODE secret attribute` on those. This is useful if you e.g.
have a set of servers that all need to have the same password for a certain service.
   `knife role secret add mysql_servers foo mysql.rootpw`
This plugin offers the same options as node secret add except for the `-x` option.

