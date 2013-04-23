############################################################
#### IMPORT FACEBOOK GROUP INTO DISCOURSE
####
#### created by Sander Datema (info@sanderdatema.nl)
####
#### version 1.1 (23/04/2013)
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
#   using username@domain.ext as email address and the full
#   name of each user converted to lower case, no spaces as
#   username
# - It will use the first 50 characters of the post as title
#   for the topic
# - Will only import the first 25 comments for a topic

############################################################
#### Prerequisits
############################################################
#
# - A Facebook Graph API token. get it here:
#   https://developers.facebook.com/tools/explorer
#   Select user_groups and read_stream as permission
# - Add the gem 'koala' to your Gemfile
# - Edit the Configuration file config/import_facebook.yml

############################################################
#### The Rake Task
############################################################

desc "Import posts and comments from a Facebook group"
task "import:facebook_group" => :environment do
  # Import configuration file
  @configuration = YAML.load_file('config/import_facebook.yml')

  # Backup Site Settings
  backup_site_settings

  # Then set the temporary Site Settings we need
  set_temporary_site_settings

  # Initialize batch counter
  @first_batch = true

  # Create and/or set category
  category = get_category(@configuration['discourse_category_name'], @configuration['discourse_admin'])

  # Setup Facebook connection
  initialize_facebook_connection(@configuration['facebook_token'])

  # Collect IDs
  group_id = get_group_id(configuration['facebook_group_name'])

  # Collect all posts from Facebook group and import them into Discourse
  fetch_and_import_posts_and_comments(group_id, category)

  # Restore Site Settings
  restore_site_settings

  # DONE!
end


############################################################
#### Methods
############################################################

# Returns the Facebook Group ID of the given group name
# User must be a member of given group
def get_group_id(groupname)
  groups = @graph.get_connections("me", "groups")
  groups = groups.select {|g| g['name'] == groupname}
  groups[0]['id']
end

# Connect to the Facebook Graph API
def initialize_facebook_connection(token)
  @graph = Koala::Facebook::API.new(token)
  puts "Facebook token accepted"
end

# Returns all posts in the given Facebook group
def fetch_and_import_posts_and_comments(group_id, category)
  # Initialize post counter
  post_count = 0

  # Fetch all posts
  loop do
    batch = fetch_batch(group_id)
    batch_count = batch.count
    break if batch_count == 0
    puts "----"

    from_date_time = DateTime.parse(batch[-1]['created_time']).to_time.strftime("%d/%m/%Y %H:%M")
    til_date_time = DateTime.parse(batch[0]['created_time']).to_time.strftime("%d/%m/%Y %H:%M")

    puts batch_count.to_s + " Posts in this batch posted between " + from_date_time + " and " + til_date_time
  
    # Collect all comments per Facebook post and create new
    # topics with replies in Discourse
    batch.each do |post|
      create_topic_with_replies(post, category)
    end

    post_count += batch_count

    puts "Imported into Discourse from Facebook: " + post_count.to_s + " posts"
    puts "----"

  end

  puts "Imported into memory from Facebook " + post_count.to_s + " posts"
  puts "Finished importing Facebook posts into memory, now staring import into Discourse"
  return posts
end

def fetch_batch(group_id)
  if @first_batch then
    @batch = @graph.get_connections(group_id, 'feed')
    @first_batch = false
    batch = @batch
  else
    batch = @batch.next_page
  end
end

# Returns category for imported topics
def get_category(name, owner)
  if Category.where('name = ?', name).empty? then
    owner = User.where('username = ?', owner).first
    category = Category.create!(name: name, user_id: owner.id)
    puts "Category '" + name + "' created"
  else
    category = Category.where('name = ?', name).first
    puts "Category '" + name + "' exists"
  end

  return category
end

def create_topic_with_replies(facebook_post, category)
  # Create Discourse user if necessary
  discourse_user = create_discourse_user_from_post_or_comment(facebook_post['from'])

  # Create a new topic
  topic = Topic.new

  # Facebook posts don't have a title, so use first 50 characters of the post as title
  topic.title = facebook_post['message'][0,50]

  puts " - Creating topic '" + topic.title + "' through user " + discourse_user.name

  # Set ID of user who created the topic
  topic.user_id = discourse_user.id

  # Set topic category
  topic.category_id = category.id

  # Set topic create and update time
  topic.created_at = facebook_post['created_time']
  topic.updated_at = topic.created_at

  # Everything set, save the topic
  if topic.valid? then
    topic.save!
    puts " - Topic created"

    # Create the contents of the topic, using the Facebook post
    discourse_post = Post.new

    discourse_post.user_id = topic.user_id
    discourse_post.topic_id = topic.id
    discourse_post.raw = facebook_post['message']

    discourse_post.created_at = facebook_post['created_time']
    discourse_post.updated_at = discourse_post.created_at

    if discourse_post.valid? then
      discourse_post.save!
      puts " - First post of topic created"
    else # Skip if not valid for some reason
      puts "Contents of topic from Facebook post " + facebook_post['id'] + " failed to import"
      puts "Error: " + p(topic.errors)
      puts "Content of message:"
      puts post['message']
    end

    # Now create the replies, using the Facebook comments
    if not facebook_post['comments']['data'].empty?
      comment_count = 1
      comment_total = facebook_post['comments']['data'].count
      facebook_post['comments']['data'].each do |comment|
        # Create Discourse user if necessary
        discourse_user = create_discourse_user_from_post_or_comment(comment['from'])

        discourse_post = Post.new

        discourse_post.user_id = discourse_user.id
        discourse_post.topic_id = topic.id
        discourse_post.raw = comment['message']

        discourse_post.created_at = comment['created_time']
        discourse_post.updated_at = discourse_post.created_at

        if discourse_post.valid? then
          discourse_post.save!
          puts " - Comment " + comment_count.to_s + "/" + comment_total.to_s + " imported"
        else # Skip if not valid for some reason
          puts "Reply in topic from Facebook post " + facebook_post['id'] + " with comment ID " + comment['id'] + " failed to import"
          puts "Error: " + p(discourse_post.errors)
          puts "Content of message:"
          puts comment['message']
        end
        comment_count += 1
      end
    end
  else # In case we missed a validation, don't save
    puts "Topic of Facebook post " + facebook_post['id'] + " failed to import"
    puts "Error: " + p(discourse_post.errors)
    puts "Content of message:"
    puts post['message']
  end
end

def create_discourse_user_from_post_or_comment(person)
  # Fetch person info from Facebook
  facebook_info = @graph.get_object(person['id'].to_i)

  # Create username from full name
  username = facebook_info['username'].tr('^A-Za-z0-9', '').downcase

  # Maximum length of a Discourse username is 15 characters
  username = username[0,15]

  # Create email address for user
  if facebook_info['email'].nil? then
    email = username + "@localhost"
  else
    email = facebook_info['email']
  end

  # Create user if it doesn't exist
  if User.where('username = ?', username).empty? then
    discourse_user = User.create!(username: username,
                                  name: facebook_info['name'],
                                  email: email,
                                  approved: true,
                                  approved_by_id: @configuration['discourse_admin'])

    # Create Facebook credentials so the user could login later and claim his account
    FacebookUserInfo.create!(user_id: discourse_user.id,
                             facebook_user_id: facebook_info['id'].to_i,
                             username: facebook_info['username'],
                             first_name: facebook_info['first_name'],
                             last_name: facebook_info['last_name'],
                             name: facebook_info['name'].tr(' ', '_'),
                             link: facebook_info['link'])
    puts " - User " + facebook_info['name'] + " (" + username + " / " + email + ") created"

  else
    discourse_user = User.where('username = ?', username).first
  end

  return discourse_user
end

def backup_site_settings
  @site_settings = {}
  @site_settings['min_post_length'] = SiteSetting.min_post_length
  @site_settings['unique_posts_mins'] = SiteSetting.unique_posts_mins
  @site_settings['rate_limit_create_topic'] = SiteSetting.rate_limit_create_topic
  @site_settings['rate_limit_create_post'] = SiteSetting.rate_limit_create_post
  @site_settings['max_topics_per_day'] = SiteSetting.max_topics_per_day
  @site_settings['mallow_duplicate_topic_titles'] = SiteSetting.allow_duplicate_topic_titles
  @site_settings['title_min_entropy'] = SiteSetting.title_min_entropy
  @site_settings['body_min_entropy'] = SiteSetting.body_min_entropy
end

def restore_site_settings
  SiteSetting.min_post_length = @site_settings['min_post_length']
  SiteSetting.unique_posts_mins = @site_settings['unique_posts_mins']
  SiteSetting.rate_limit_create_topic = @site_settings['rate_limit_create_topic']
  SiteSetting.rate_limit_create_post = @site_settings['rate_limit_create_post']
  SiteSetting.max_topics_per_day = @site_settings['max_topics_per_day']
  SiteSetting.allow_duplicate_topic_titles = @site_settings['mallow_duplicate_topic_titles']
  SiteSetting.title_min_entropy = @site_settings['title_min_entropy']
  SiteSetting.body_min_entropy = @site_settings['body_min_entropy']
end

def set_temporary_site_settings
  SiteSetting.min_post_length = 1
  SiteSetting.unique_posts_mins = 0
  SiteSetting.rate_limit_create_topic = 0
  SiteSetting.rate_limit_create_post = 0
  SiteSetting.max_topics_per_day = 10000
  SiteSetting.allow_duplicate_topic_titles = true
  SiteSetting.title_min_entropy = 1
  SiteSetting.body_min_entropy = 1
end