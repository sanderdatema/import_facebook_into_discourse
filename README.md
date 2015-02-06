# What is it?

This rake task will import all posts and comments of a Facebook group into Discourse.

* It will preserve post and comment dates
* It will not import likes
* It will create new user accounts for each imported user using username@localhost as email address and the full name of each user converted to lower case, no spaces as username
* It will use the first 50 characters of the post as title for the topic
* It has a test mode. When enables no changes to the Discourse database will be made

Use at your own risk! Please test on a dummy Discourse install first.

# Instructions

* Add `gem 'koala'` to your `Gemfile` and run `bundle install`
* Get a [Facebook Graph API token](https://developers.facebook.com/tools/explorer) (select `user_groups` and `read_stream` as permission)
* Edit `config/import_facebook.yml`
* Place `config/import_facebook.yml` in your `config` folder
* Place `lib/tasks/import_facebook.rake` in your `lib/tasks` folder
* In case of multisite prepend next command with: `export RAILS_DB=<your database>`
* Run `rake import:facebook_group`

# Todo

* Import likes
* Don't send notification mails
* FB <-> Discourse synchronisation (post written on FB appears on Discourse and vice versa)
* FB notifications after posting on Discourse

# Changelog
v. 1.7 (fork from author)

New:
 - import only posts and messages not imported previously

Fixed:
 - FB usernames with national chars import
 - short post/comments import
 - FB users/posts/comments fetching

