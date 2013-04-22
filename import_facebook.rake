############################################################
#### IMPORT FACEBOOK GROUP INTO DISCOURSE
####
#### created by Sander Datema (info@sanderdatema.nl)
####
#### version 1.0 (22/04/2013)
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

############################################################
#### Prerequisits
############################################################
#
# You need to set the following values in the Site Settings:
# - min_post_length = 1
# - unique_posts_mins = 0
# - rate_limit_create_topic = 0
# - rate_limit_create_post = 0
# - max_topics_per_day = 10000
# - allow_duplicate_topic_titles = true
# - title_min_entropy = 1
# - body_min_entropy = 1
# 
# 
# - A Facebook Graph API token. get it here:
#   https://developers.facebook.com/tools/explorer
#   Select user_groups and read_stream as permission
# - Add the gem 'koala' to your Gemfile
# - Edit the Configuration section (up next)

############################################################
#### Configuration
############################################################
#
# Get this token here: https://developers.facebook.com/tools/explorer
# Select user_groups and read_stream as permission
FACEBOOK_TOKEN = 'REPLACE WITH YOUR YOUR TOKEN'
# The group you want to export posts from. Need to be a member of this group.
FACEBOOK_GROUP_NAME = 'Facebook Group name here'
# The category for the topics, will be created if needed
DISCOURSE_CATEGORY_NAME = 'Name of category here'
# User with admin privileges to create users and category
DISCOURSE_ADMIN = 'Username of admin user here'

############################################################
#### The Rake Task
############################################################

desc "Import posts and comments from a Facebook group"
task "import_facebook" => :environment do

  # Initializing some things
  @first_batch = true # Counts the import batches from Facebook

  # Create and/or set category
  category = get_category(DISCOURSE_CATEGORY_NAME, DISCOURSE_ADMIN)

  # Setup Facebook connection
  initialize_facebook_connection(FACEBOOK_TOKEN)

  # Collect IDs
  group_id = get_group_id(FACEBOOK_GROUP_NAME)

  # Collect all posts from Facebook group
  posts = fetch_all_posts_and_comments(group_id)

  # Collect all comments per Facebook post and create new
  # topics with replies in Discourse
  posts_to_import_count = posts.count.to_s
  posts_done_count = 0
  posts.each do |post|
    create_topic_with_replies(post, category)
    posts_done_count += 1
    puts "Imported into Discourse " + posts_done_count.to_s + "/" + posts_to_import_count
  end

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
end

# Returns all posts in the given Facebook group
def fetch_all_posts_and_comments(group_id)
  # How many posts in the Facebook group?
  posts_count = get_posts_count(group_id)

  # Initialize empty Array
  posts = []

  # Fetch all posts
  puts "Total count of posts in Facebook group: " + posts_count.to_s
  loop do
    posts = posts.concat(fetch_batch(group_id))
    break if posts.count >= posts_count
    puts "Imported into memory from Facebook " + posts.count.to_s + "/" + posts_count.to_s
  end

  puts "Imported into memory from Facebook " + posts_count.to_s + "/" + posts_count.to_s
  return posts
end

def fetch_batch(group_id)
  if @first_batch then
    @batch = @graph.get_connections(group_id, 'feed')
    @first_batch = false
    posts = @batch
  else
    posts = @batch.next_page
  end
end

def get_posts_count(group_id)
  result = @graph.fql_query("SELECT post_id
                    FROM stream
                    WHERE source_id = " + group_id + " 
                      LIMIT 5000")
  return result.count
end

# Returns category for imported topics
def get_category(name, owner)
  if Category.where('name = ?', name).empty? then
    owner = User.where('username = ?', owner).first
    category = Category.create!(name: name, user_id: owner.id)
  else
    category = Category.where('name = ?', name).first
  end
end

def create_topic_with_replies(facebook_post, category)
  # Create Discourse user if necessary
  discourse_user = create_discourse_user_from_post_or_comment(facebook_post['from'])

  # Create a new topic
  topic = Topic.new

  # Use the converted user ID, cause Facebook ID's are in different format
  topic.user_id = discourse_user.id

  # Facebook posts don't have a title, so use first x characters of the post as title
  topic.title = facebook_post['message'][0,50]

  # Set topic category
  topic.category_id = category.id

  # Set topic create and update time
  topic.created_at = facebook_post['created_time']
  topic.updated_at = topic.created_at

  # Everything set, save the topic
  if topic.valid? then
    topic.save!

    # Create the contents of the topic, using the Facebook post
    discourse_post = Post.new

    discourse_post.user_id = topic.user_id
    discourse_post.topic_id = topic.id
    discourse_post.raw = facebook_post['message']

    discourse_post.created_at = facebook_post['created_time']
    discourse_post.updated_at = discourse_post.created_at

    if discourse_post.valid? then
      discourse_post.save!
    else # Skip if not valid for some reason
      puts "Contents of topic from Facebook post " + facebook_post['id'] + " failed to import"
      puts "Content of message:"
      puts post['message']
    end

    # Now create the replies, using the Facebook comments
    if not facebook_post['comments']['data'].empty?
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
        else # Skip if not valid for some reason
          puts "Reply in topic from Facebook post " + facebook_post['id'] + " with comment ID " + comment['id'] + " failed to import"
          puts "Content of message:"
          puts comment['message']
        end
      end
    end
  else # In case we missed a validation, don't save
    puts "Topic of Facebook post " + facebook_post['id'] + " failed to import"
    puts "Content of message:"
    puts post['message']
  end
end

def create_discourse_user_from_post_or_comment(person)
  # Create username from full name
  username = person['name'].tr('^A-Za-z0-9', '')

  # Create email address for user
  email = username.downcase + "@example.com"

  if User.where('username = ?', username).empty? then
    discourse_user = User.create!(username: username,
                                  name: person['name'],
                                  email: email,
                                  approved: true,
                                  approved_by_id: DISCOURSE_ADMIN)
  else
    discourse_user = User.where('username = ?', username).first
  end  
end
