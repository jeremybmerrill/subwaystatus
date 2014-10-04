subway status
=============

get an email each morning if one of your subway lines is down (NYC only)

installation
------------

copy config-example.yml to config.yml
customize config.yml
add `30 8 * * 1,2,3,4,5 /bin/bash -lc 'cd /home/username/subwaystatus && /home/username/.rbenv/versions/2.1.0/bin/ruby /home/username/subwaystatus/subwaystatus.rb 2>&1' ` to your crontab
hope it works