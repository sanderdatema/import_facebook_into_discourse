############################################################
#### IMPORT FACEBOOK GROUP INTO DISCOURSE
####
#### created by Sander Datema (info@sanderdatema.nl)
####
#### version 1.6 (15/05/2013)
############################################################

############################################################
#### Description
############################################################
#
# This rake task will import all posts and comments of a
# Facebook group into Discourse.
#
# - It will preserve post and comment dates
# - It will not import likes
# - It will create new user accounts for each imported user
#   using username@localhost as email address and the full
#   name of each user converted to lower case, no spaces as
#   username
# - It will use the first 50 characters of the post as title
#   for the topic

############################################################
#### Prerequisits
############################################################
#
# - A Facebook Graph API token. get it here:
#   https://developers.facebook.com/tools/explorer
#   Select user_groups and read_stream as permission
# - Add this to your Gemfile:
#   gem 'koala', require: false
# - Edit the configuration file config/import_facebook.yml

############################################################
#### The Rake Task
############################################################

require 'koala'

desc "Import posts and comments from a Facebook group"
task "import:facebook_group" => :environment do
  # Import configuration file
  @config = YAML.load_file('config/import_facebook.yml')
  TEST_MODE = @config['test_mode']
  FB_TOKEN = @config['facebook_token']
  FB_GROUP_NAME = @config['facebook_group_name']
  DC_CATEGORY_NAME = @config['discourse_category_name']
  DC_ADMIN = @config['discourse_admin']
  REAL_EMAIL = @config['real_email_addresses']

  if TEST_MODE then puts "\n*** Running in TEST mode. No changes to Discourse database are made\n".yellow end
  unless REAL_EMAIL then puts "\n*** Using fake email addresses\n".yellow end

  # Some checks
  # Exit rake task if admin user doesn't exist
  unless dc_user_exists(DC_ADMIN) then
    puts "\nERROR: The admin user #{DC_ADMIN} does not exist".red
    exit_script
  end

  # Setup Facebook connection
  fb_initialize_connection(FB_TOKEN)

  # Collect IDs
  group_id = fb_get_group_id(FB_GROUP_NAME)

  # Fetch all facebook posts
  fb_fetch_posts(group_id, current_unix_time)

  if TEST_MODE then
    exit_script # We're done
  else
    # Create users in Discourse
    dc_create_users_from_fb_writers

    # Backup Site Settings
    dc_backup_site_settings

    # Then set the temporary Site Settings we need
    dc_set_temporary_site_settings

    # Create and/or set Discourse category
    dc_category = dc_get_or_create_category(DC_CATEGORY_NAME, DC_ADMIN)

    # Import Facebooks posts into Discourse
    fb_import_posts_into_dc(dc_category)

    # Restore Site Settings
    dc_restore_site_settings
  end

  puts "\n*** DONE".green
  # DONE!
end


############################################################
#### Methods
############################################################

# Returns the Facebook Group ID of the given group name
# User must be a member of given group
def fb_get_group_id(groupname)
  groups = @graph.get_connections("me", "groups")
  groups = groups.select {|g| g['name'] == groupname}
  groups[0]['id']
end

# Connect to the Facebook Graph API
def fb_initialize_connection(token)
  begin
    @graph = Koala::Facebook::API.new(token)
    test = @graph.get_object('me')
  rescue Koala::Facebook::APIError => e
    puts "\nERROR: Connection with Facebook failed\n#{e.message}".red
    exit_script
  end

  puts "\nFacebook token accepted".green
end

def fb_fetch_posts(group_id, until_time)
  @fb_posts ||= [] # Initialize if needed

  time_of_last_imported_post = until_time

  # Fetch Facebook posts in batches and download writer/user info
  loop do
    query = "SELECT created_time,
                    updated_time,
                    post_id,
                    actor_id,
                    permalink,
                    message,
                    comments
             FROM stream
             WHERE source_id = '#{group_id}'
               AND created_time < #{time_of_last_imported_post}
             LIMIT 500"
    result = @graph.fql_query(query)

    break if result.count == 0 # No more posts to import

    # Add the results of this batch to the rest of the imported posts
    @fb_posts = @fb_posts.concat(result)

    puts "Batch: #{result.count.to_s} posts (since #{unix_to_human_time(result[-1]['created_time'])} until #{unix_to_human_time(result[0]['created_time'])})"
    time_of_last_imported_post = result[-1]['created_time']

    result.each do |post|
      fb_extract_writer(post) # Extract the writer from the post
      comments = post['comments']['comment_list']
      if comments.count > 0 then
        comments.each do |comment|
          fb_extract_writer(comment)
        end
      end
    end
  end

  puts "\nAmount of posts: #{@fb_posts.count.to_s}"
  puts "Amount of writers: #{@fb_writers.count.to_s}"
end

# Import Facebook posts into Discourse
def fb_import_posts_into_dc(dc_category)
  post_count = 0
  @fb_posts.each do |fb_post|
    post_count += 1

    # Get details of the writer of this post
    fb_post_user = @fb_writers.find {|k| k['id'] == fb_post['actor_id'].to_s}

    # Get the Discourse user of this writer
    dc_user = dc_get_user(fb_username_to_dc(fb_post_user['username']))

    # Facebook posts don't have a title, so use first 50 characters of the post as title
    topic_title = fb_post['message'][0,50]
    # Remove new lines and replace with a space
    topic_title = topic_title.gsub( /\n/m, " " )

    # Set topic create and update time
    #dc_topic.created_at = Time.at(fb_post['created_time'])
    #dc_topic.updated_at = dc_topic.created_at

    progress = post_count.percent_of(@fb_posts.count).round.to_s
    puts "[#{progress}%]".blue + " Creating topic '" + topic_title.blue #+ "' (#{topic_created_at})"

    post_creator = PostCreator.new(dc_user,
                                   raw: fb_post['message'],
                                   title: topic_title,
                                   archetype: 'regular',
                                   category: DC_CATEGORY_NAME,
                                   created_at: Time.at(fb_post['created_time']),
                                   updated_at: Time.at(fb_post['created_time']))
    post = post_creator.create

    topic_id = post.topic.id

    # Everything set, save the topic
    unless post_creator.errors.present? then
      post_serializer = PostSerializer.new(post, scope: true, root: false)
      post_serializer.topic_slug = post.topic.slug if post.topic.present?
      post_serializer.draft_sequence = DraftSequence.current(dc_user, post.topic.draft_key)

      puts " - First post of topic created".green

      # Now create the replies, using the Facebook comments
      unless fb_post['comments']['count'] == 0 then
        fb_post['comments']['comment_list'].each do |comment|
          # Get details of the writer of this comment
          comment_user = @fb_writers.find {|k| k['id'] == comment['fromid'].to_s}

          # Get the Discourse user of this writer
          dc_user = dc_get_user(fb_username_to_dc(comment_user['username']))

          post_creator = PostCreator.new(dc_user,
                                         raw: comment['text'],
                                         topic_id: topic_id,
                                         created_at: Time.at(comment['time']),
                                         updated_at: Time.at(comment['time']))

          post = post_creator.create

          # dc_post.created_at = Time.at(comment['time'])
          # dc_post.updated_at = dc_post.created_at

          unless post_creator.errors.present? then
            post_serializer = PostSerializer.new(post, scope: true, root: false)
            post_serializer.topic_slug = post.topic.slug if post.topic.present?
            post_serializer.draft_sequence = DraftSequence.current(dc_user, post.topic.draft_key)
          else # Skip if not valid for some reason
            puts " - Comment (#{comment['id']}) failed to import, #{post_creator.errors.messages[:raw][0]}".red
          end
        end
          puts " - #{fb_post['comments']['count'].to_s} Comments imported".green
        end
    else # Skip if not valid for some reason
      puts "Contents of topic from Facebook post #{fb_post['post_id']} failed to import, #{post_creator.errors.messages[:base]}".red
    end
  end
end

# Returns the Discourse category where imported Facebook posts will go
def dc_get_or_create_category(name, owner)
  if Category.where('name = ?', name).empty? then
    puts "Creating category '#{name}'"
    owner = User.where('username = ?', owner).first
    category = Category.create!(name: name, user_id: owner.id)
  else
    puts "Category '#{name}' exists"
    category = Category.where('name = ?', name).first
  end
end

# Create a Discourse user with Facebook info unless it already exists
def dc_create_users_from_fb_writers
  @fb_writers.each do |fb_writer|
    # Setup Discourse username
    dc_username = fb_username_to_dc(fb_writer['username'])

    # Create email address for user
    if fb_writer['email'].nil? then
      dc_email = dc_username + "@localhost.fake"
    else
      if REAL_EMAIL then
        dc_email = fb_writer['email']
      else
        dc_email = fb_writer['email'] + '.fake'
      end
    end

    # Create user if it doesn't exist
    if User.where('username = ?', dc_username).empty? then
      dc_user = User.create!(username: dc_username,
                             name: fb_writer['name'],
                             email: dc_email,
                             approved: true,
                             approved_by_id: dc_get_user_id(DC_ADMIN))

      # Create Facebook credentials so the user could login later and claim his account
      FacebookUserInfo.create!(user_id: dc_user.id,
                               facebook_user_id: fb_writer['id'].to_i,
                               username: fb_writer['username'],
                               first_name: fb_writer['first_name'],
                               last_name: fb_writer['last_name'],
                               name: fb_writer['name'].tr(' ', '_'),
                               link: fb_writer['link'])
      puts "User #{fb_writer['name']} (#{dc_username} / #{dc_email}) created".green
    end
  end
end

# Backup site settings
def dc_backup_site_settings
  @site_settings = {}
  @site_settings['unique_posts_mins'] = SiteSetting.unique_posts_mins
  @site_settings['rate_limit_create_topic'] = SiteSetting.rate_limit_create_topic
  @site_settings['rate_limit_create_post'] = SiteSetting.rate_limit_create_post
  @site_settings['max_topics_per_day'] = SiteSetting.max_topics_per_day
  @site_settings['title_min_entropy'] = SiteSetting.title_min_entropy
  @site_settings['body_min_entropy'] = SiteSetting.body_min_entropy
end

# Restore site settings
def dc_restore_site_settings
  SiteSetting.send("unique_posts_mins=", @site_settings['unique_posts_mins'])
  SiteSetting.send("rate_limit_create_topic=", @site_settings['rate_limit_create_topic'])
  SiteSetting.send("rate_limit_create_post=", @site_settings['rate_limit_create_post'])
  SiteSetting.send("max_topics_per_day=", @site_settings['max_topics_per_day'])
  SiteSetting.send("title_min_entropy=", @site_settings['title_min_entropy'])
  SiteSetting.send("body_min_entropy=", @site_settings['body_min_entropy'])
end

# Set temporary site settings needed for this rake task
def dc_set_temporary_site_settings
  SiteSetting.send("unique_posts_mins=", 0)
  SiteSetting.send("rate_limit_create_topic=", 0)
  SiteSetting.send("rate_limit_create_post=", 0)
  SiteSetting.send("max_topics_per_day=", 10000)
  SiteSetting.send("title_min_entropy=", 1)
  SiteSetting.send("body_min_entropy=", 1)
end

# Check if user exists
# For some really weird reason this method returns the opposite value
# So if it did find the user, the result is false
def dc_user_exists(name)
  User.where('username = ?', name).exists?
end

def dc_get_user_id(name)
  User.where('username = ?', name).first.id
end

def dc_get_user(name)
  User.where('username = ?', name).first
end

# Returns current unix time
def current_unix_time
  Time.now.to_i
end

def unix_to_human_time(unix_time)
  Time.at(unix_time).strftime("%d/%m/%Y %H:%M")
end

# Exit the script
def exit_script
  puts "\nScript will now exit\n".yellow
  exit
end

def fb_extract_writer(post)
  @fb_writers ||= [] # Initialize if needed

  if post.has_key? 'actor_id' # Facebook post
    writer = post['actor_id']
  else # Facebook comment
    writer = post['fromid']
  end

  # Fetch user info from Facebook and add to writers array
  unless @fb_writers.any? {|w| w['id'] == writer.to_s}
    @fb_writers << @graph.get_object(writer)
  end
end

def fb_username_to_dc(name)
  # Create username from full name, only letters and numbers
  username = name.tr('^A-Za-z0-9', '').downcase

  # Maximum length of a Discourse username is 15 characters
  username = username[0,15]
end

# Add colors to class String
class String
  def red
    colorize(self, 31);
  end

  def green
    colorize(self, 32);
  end

  def yellow
    colorize(self, 33);
  end

  def blue
    colorize(self, 34);
  end

  def colorize(text, color_code)
    "\033[#{color_code}m#{text}\033[0m"
  end
end

# Calculate percentage
class Numeric
  def percent_of(n)
    self.to_f / n.to_f * 100.0
  end
end
