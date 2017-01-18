############################################################
#### IMPORT FACEBOOK GROUP INTO DISCOURSE
####
#### created by Sander Datema (info@sanderdatema.nl)
####   changed by Vannilla Sky (vannillasky@tlen.pl
####
#### version 1.7 (06/02/2015)
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
#### Changelog
############################################################
#
# v. 1.7 (fork from author)
# New:
# - importing only post and messages not imported previously
# Fixed:
# - FB usernames with national chars import
# - short post/comments import
# - FB users/posts/comments fetching
#
############################################################
#### The Rake Task
############################################################

require 'koala'
require 'stringex'
require "unicode_utils/upcase"
require 'json'

desc "Import posts and comments from a Facebook group"
task "import:facebook_group" => :environment do
  TIME_AT_START = Time.now

  # Import configuration file
  @config = YAML.load_file('config/import_facebook.yml')
  TEST_MODE = @config['test_mode']
  FB_TOKEN = @config['facebook_token']
  FB_GROUP_NAME = @config['facebook_group_name']
  DC_CATEGORY_NAME = @config['discourse_category_name']
  DC_ADMIN = @config['discourse_admin']
  REAL_EMAIL = @config['real_email_addresses']
  GROUP_ID = @config['facebook_group_id'] 
  IMPORT_OLDEST_FIRST = @config['import_oldest_first']
  API_CALL_DELAY = @config['api_call_delay']
  RESTART_FROM_TOPIC_NUMBER = @config['restart_from_topic_number'] || 0
  STORE_DATA_TO_FILES = @config['store_data_to_files']

  puts "*** Running in TEST mode. No changes to Discourse database are made".yellow if TEST_MODE
  puts "*** Using fake email addresses".yellow unless REAL_EMAIL
  puts "*** Storing fetched data to disk, loading from disk when possible".yellow if STORE_DATA_TO_FILES
  puts "*** Importing in reverse order (oldest posts first)".yellow if IMPORT_OLDEST_FIRST
  puts "*** Delaying each API call #{API_CALL_DELAY} seconds to avoid rate limiting".yellow if API_CALL_DELAY > 0

  RateLimiter.disable

  # Some checks
  # Exit rake task if admin user doesn't exist
  unless dc_user_exists(DC_ADMIN) then
    puts "\nERROR: The admin user #{DC_ADMIN} does not exist".red
    exit_script
  end

  create_directories_for_imported_data if STORE_DATA_TO_FILES

  # Setup Facebook connection
  fb_initialize_connection(FB_TOKEN)

  # Collect IDs
  # group_id = fb_get_group_id(FB_GROUP_NAME)

  @fb_posts ||= [] # Initialize if needed
  @post_count, @comment_count, @like_count, @image_count = 0, 0, 0, 0

  # Fetch all facebook posts
  fetch_posts_or_load_from_disk

  if TEST_MODE then
    exit_script # We're done
  else
    # Backup Site Settings
    dc_backup_site_settings

    # Then set the temporary Site Settings we need
    dc_set_temporary_site_settings

    # Create and/or set Discourse category
    dc_category = dc_get_or_create_category(DC_CATEGORY_NAME, DC_ADMIN)

    # Import Facebooks posts into Discourse
    fb_import_posts_into_dc

    # Restore Site Settings
    dc_restore_site_settings
  end

  puts "\nDONE! Imported #{@post_count} posts, #{@comment_count} comments, #{@like_count} likes and #{@image_count} images in #{total_run_time}\n".green
end


############################################################
#### Methods
############################################################

# Connect to the Facebook Graph API
def fb_initialize_connection(token)
  begin
    @graph = Koala::Facebook::API.new(token)
    test = @graph.get_object('me')
  rescue Koala::Facebook::APIError => e
    puts "\nERROR: Connection with Facebook failed\n#{e.message}".red
    exit_script
  end

  puts "Facebook token accepted".green
end

def graph
  sleep API_CALL_DELAY
  @graph
end

def graph_connections(id, type, options={})
  items = []

  begin
    page = graph.get_connections(id, type, options)
    begin
    items += page
    end while page = page.next_page
  rescue Koala::Facebook::AuthenticationError
    graph_authentication_error
  rescue Koala::Facebook::ClientError => error
    graph_client_error(id, error)
  rescue => error
    graph_generic_error(error, id, type)
  end

  items
end

def graph_object(id)
  begin
    @graph.get_object(id)
  rescue Koala::Facebook::AuthenticationError
    graph_authentication_error
  rescue Koala::Facebook::ClientError => error
    graph_client_error(id, error)
  rescue => error
    graph_generic_error(error, id)
  end
end

def graph_authentication_error
  puts "\nWARNING: Facebook Authentication failed!".red
  puts "\nThis is probably due to your access token having expired. Enter a new access token in config/import_facebook.yml and restart the import."
  exit_script
end

def graph_client_error(id, error)
  puts "\nWARNING: Unable to fetch object or connections for Facebook ID #{id}".red
  puts "\nA common reason for this error is that the Graph API does not return data associated with Facebook user accounts which no longer exists. Full error message:"
  puts "\n#{error.message}"
end

def graph_generic_error(error, id, type=nil)
  puts "\nWARNING: Something went wrong when fetching #{type + " for " if type}object #{id}".red
  puts "\nHere is the full error message: #{error.message}"
  exit_script
end 

def fb_fetch_posts
  puts "Fetching all Facebook posts... (this will take several minutes for large groups)"
  start_time = Time.now
  @fb_posts = graph_connections(GROUP_ID, 'feed')
  @fb_posts.reverse! if IMPORT_OLDEST_FIRST
  puts "...fetched #{@fb_posts.length} posts in #{Time.now - start_time} seconds."
end

# Import Facebook posts into Discourse
def fb_import_posts_into_dc
  if RESTART_FROM_TOPIC_NUMBER > 0
    puts "\nLast processed post was number #{RESTART_FROM_TOPIC_NUMBER} (FB: #{@fb_posts[RESTART_FROM_TOPIC_NUMBER]['id']}), continuing from there..."
  end

  @fb_posts.each_with_index do |fb_post, num_posts_processed|
    @latest_post_processed = num_posts_processed
    next if num_posts_processed < RESTART_FROM_TOPIC_NUMBER

    post = fetch_dc_post_from_facebook_id fb_post['id']

    if post
      puts progress + "Already imported post #{post.id}".yellow + post_info(post)
    else
      dc_user = get_dc_user_from_fb_object fb_post

      if fb_post['type'] == 'photo'
        fetch_image_or_load_from_disk fb_post
      end

      if fb_post['message'].nil?
        if fb_post['story']
          fb_post['message'] = fb_post['story']
        else
          fb_post['message'] = ""
        end
      end

      topic_title = generate_topic_title fb_post

      # Check if this post has an attached link
      if fb_post['link'] and fb_post['type'] != 'photo'
        fb_post['message'] += "\n\n#{fb_post['link']}"
      end

      insert_user_tags fb_post

      fb_post_time = fb_post['created_time'] || fb_post['updated_time']

      post_creator = PostCreator.new(
        dc_user,
        skip_validations: true,
        raw: fb_post['message'],
        title: topic_title,
        archetype: 'regular',
        category: DC_CATEGORY_NAME,
        created_at: Time.at(Time.parse(DateTime.iso8601(fb_post_time).to_s)))

      post = post_creator.create

      post.custom_fields['fb_id'] = fb_post['id']
      post.save(validate: false)
      post_serializer = PostSerializer.new(post, scope: true, root: false)
      post_serializer.draft_sequence = DraftSequence.current(dc_user, post.topic.draft_key)

      @post_count += 1
      puts progress + "Created topic by #{dc_user.name}: ".green + topic_title + post_info(post)
    end


    topic_id = post.topic.id

    fetch_likes_or_load_from_disk(post)
    fetch_comments_or_load_from_disk(fb_post, topic_id)
  end
end

def generate_topic_title(fb_post)
  return topic_title_placeholder if fb_post['message'].strip.empty?

  # Keep title length within this interval
  lower_limit, upper_limit = 30, 200

  # Begin by looking at the first paragraph
  message_first_paragraph = fb_post['message'].split("\n\n").first

  # Look at second paragraph if first is too short
  if message_first_paragraph.length < lower_limit
    second_paragraph = fb_post['message'].split("\n\n")[1]
    if second_paragraph
      message_first_paragraph += " "
      message_first_paragraph += second_paragraph
    end
  end

  # Use first paragraph if within limit, otherwise truncate
  if message_first_paragraph.length < upper_limit
    topic_title = message_first_paragraph
  else
    topic_title = message_first_paragraph[0,upper_limit]
    if topic_title.include? ". "
      topic_title = topic_title.split(". ")[0..-2].join(". ")
      topic_title += "."
    else
      topic_title += " [...]"
    end
  end

  # Remove trailing period if it is the only period
  if topic_title.count('.') == 1 and topic_title[-1] == '.'
    topic_title.chop!
  end

  # Remove new lines and replace with a space
  topic_title = topic_title.gsub( /\n/m, " " )

  # Fix all-caps titles
  if topic_title == topic_title.upcase
    topic_title = UnicodeUtils.downcase(topic_title).capitalize
  end

  # Don't set internal image tag as title
  if topic_title[0..3] == "<img"
    topic_title = topic_title_placeholder
  end

  topic_title
end

def topic_title_placeholder
  "[no title]"
end

def progress
  num_posts_to_process = @fb_posts.length - RESTART_FROM_TOPIC_NUMBER
  percentage = (@post_count.to_f / num_posts_to_process * 100).round(1)
  "\n[#{percentage}%] [#{@latest_post_processed} of #{@fb_posts.length}] ".blue
end

def post_info(post)
  timestamp = post.created_at.to_s[0..18]
  id, fb_id = post.id, post.custom_fields['fb_id']
  ids = "Post ID #{id} and Facebook ID #{fb_id}"
  " (Posted by #{post.user.name} at #{timestamp} with #{ids})".blue
end 

def fetch_comments(fb_item, topic_id, post_number=nil)
  if fb_item['comments'] || (fb_item['comment_count'] && fb_item['comment_count'] > 0)
    comment_count = fb_item['comments'].length rescue fb_item['comment_count']
    puts "Fetching #{comment_count} comments for #{fb_item['id']}..."
  else
    #puts "No comments found for #{fb_item['id']}, skipping..."
    return nil
  end

  options = {"fields" => "id,from,message,created_time,comment_count,like_count,message_tags,attachment"}
  comments = graph_connections(fb_item["id"], "comments", options)

  comments.each do |comment|
    dc_create_comment(comment.dup, topic_id, post_number)
  end

  comments
end

def dc_create_comment(comment, topic_id, post_number=nil)

  post = fetch_dc_post_from_facebook_id comment['id']

  unless post
    dc_user = get_dc_user_from_fb_object comment

    fetch_attachment(comment) if comment['attachment']

    comment_time = comment['created_time'] || comment['updated_time']

    insert_user_tags comment

    # Differentiate between comments and subcomments
    if post_number
      post_creator = PostCreator.new(
        dc_user,
        skip_validations: true,
        raw: comment['message'],
        topic_id: topic_id,
        reply_to_post_number: post_number,
        created_at: Time.at(Time.parse(DateTime.iso8601(comment_time).to_s)))
    else
      post_creator = PostCreator.new(
        dc_user,
        skip_validations: true,
        raw: comment['message'],
        topic_id: topic_id,
        created_at: Time.at(Time.parse(DateTime.iso8601(comment_time).to_s)))
    end

    post = post_creator.create

      post.custom_fields['fb_id'] = comment['id']
      post.save(validate: false)
      post_serializer = PostSerializer.new(post, scope: true, root: false)
      post_serializer.draft_sequence = DraftSequence.current(dc_user, post.topic.draft_key)
      puts "Created comment by #{dc_user.name}: ".green + post.raw
      @comment_count += 1
  else
    puts "Already imported comment #{post.id} with Facebook ID #{post.custom_fields['fb_id']}, skipping...".yellow
  end

  if comment['like_count'] && comment['like_count'] > 0
    fetch_likes_or_load_from_disk(post)
  end

  fetch_comments_or_load_from_disk(comment, topic_id, post.post_number)
end

def fetch_dc_post_from_facebook_id(fb_id)
  facebook_field = PostCustomField.where(name: 'fb_id', value: fb_id).first
  post = Post.where(id: facebook_field.post_id).first rescue nil
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

def get_dc_user_from_fb_object(fb_object)
  fb_from = fb_object['from']
  unless fb_from
    puts "\nWARNING: No from field found, using UnknownUser instead...".red
    puts "The reason for missing from fields is often that a user account no longer exists or is unaccessible for some other reason. Here is the Facebook object in question:"
    puts fb_object.inspect
    return get_dc_user_for_unknown_poster
  end

  existing_user = FacebookUserInfo.where(facebook_user_id: fb_from['id']).first

  if existing_user
    dc_user = User.where(id: existing_user.user_id).first
  else
    fb_user_object = graph_object(fb_from['id'])
    if fb_user_object
      dc_user = dc_create_user_from_fb_object fb_user_object
    else
      dc_user = dc_create_user_from_fb_object({ "name" => fb_from['name'],
                                                "first_name" => fb_from['name'].split(" ")[0..-2].join(" "),
                                                "last_name" => fb_from['name'].split(" ")[-1],
                                                "id" => fb_from['id'],
                                                "link" => "https://facebook.com/#{fb_from['id']}"})
    end
  end

  if dc_user
    return dc_user
  else
    puts "Failed to lookup or create user from this Facebook data:".red
    puts fb_from.inspect
    exit_script
  end
end

def get_dc_user_for_unknown_poster
  if dc_user_exists "UnknownUser"
    return dc_get_user "UnknownUser"
  else
    return dc_create_user_from_fb_object({ "name" => "UnknownUser",
                                              "first_name" => "Unknown",
                                              "last_name" => "User",
                                              "id" => "0",
                                              "link" => "https://facebook.com/#"})
  end
end

def dc_create_user_from_fb_object(fb_writer)
  # Setup Discourse username
  dc_username = fb_username_to_dc(fb_writer['name'])

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

    dc_user = User.create!(username: dc_username,
                           name: fb_writer['name'],
                           email: dc_email,
                           approved: true,
                           approved_by_id: dc_get_user(DC_ADMIN).id)
    dc_user.activate;

  unless dc_user
    puts "Failed to create Discourse user for this Facebook object:".red
    puts fb_writer.inspect
    exit_script
  end

    # Create Facebook credentials so the user could login later and claim his account
    FacebookUserInfo.create!(user_id: dc_user.id,
                            facebook_user_id: fb_writer['id'].to_i,
                            username: fb_writer['name'],
                            first_name: fb_writer['first_name'],
                            last_name: fb_writer['last_name'],
                            name: fb_writer['name'].tr(' ', '_'),
                            link: fb_writer['link'])

    puts "User #{fb_writer['name']} (#{dc_username} / #{dc_email}) created".green
    return dc_user
end

def fetch_likes(item)
  fb_id = item.custom_fields['fb_id']

  likes = graph_connections(fb_id, 'likes')
  return nil if likes.blank?

  if likes.length > 0
    likes.each do |like|
      create_like(like, item)
    end
  end 

  likes
end

def create_like(like, item)
  fb_id = item.custom_fields['fb_id']
  liker = get_dc_user_from_fb_object({ "from" => like })

  if liker
    begin
      like_action = PostAction.act(liker, item, PostActionType.types[:like])
    rescue PostAction::AlreadyActed
      puts "  - #{liker.name} already liked #{item.id} (#{fb_id})".yellow
    else
      puts "  - #{liker.name} liked post #{item.id} (#{fb_id})".green
      @like_count += 1
    end
  end
end

def insert_user_tags(fb_item)
  return nil unless fb_item['message_tags']

  fb_item['message_tags'].each_with_index do |tag, index|
    tag = tag[1].first if tag.class == Array
    next unless tag['type'] == 'user'

    user = get_dc_user_from_fb_object({ 'from' => tag })
    dc_tag = "@#{user.username}"

    length_diff = dc_tag.length - tag['length']
    fb_item['message_tags'].each_with_index do |t, i|
      next unless i > index
      t = t[1].first if t.class == Array
      t['offset'] += length_diff
    end

    fb_item['message'][tag['offset'], tag['length']] = dc_tag
  end
end

def fetch_attachment(fb_item)
  case fb_item['attachment']['type']
  when "photo"
    fetch_image_or_load_from_disk fb_item
  end
end

def fetch_image(fb_item)
  if fb_item['attachment']
    url = fb_item['attachment']['media']['image']['src']
  elsif fb_item['type'] == 'photo'
    photo_object = graph_object fb_item['object_id']
    url = photo_object['images'].first['source']
  end
  file = FileHelper.download(url, 10**7, "facebook-imported-image", true)
  create_image fb_item, file
  file
end

def create_image(fb_item, file)
  user = get_dc_user_from_fb_object fb_item
  filename = "#{fb_item['id']}.jpg"

  upload = nil
  silence_stream(STDERR) do
    upload = Upload.create_for(user.id, file, filename, file.size)
  end

  tag = "<img src='#{upload.url}' width='#{upload.width}' height='#{upload.height}'>"
  fb_item['message'] = "" unless fb_item['message']
  fb_item['message'] << "\n\n" unless fb_item['message'].strip.empty?
  fb_item['message'] << tag
  @image_count += 1
  puts "Uploaded image for post with Facebook ID #{fb_item['id']}".green
end

def create_directories_for_imported_data
  base_directory    = "#{Rails.root}/imported-data"
  @import_directory = "#{base_directory}/#{GROUP_ID}"
  directories = []
  directories << base_directory
  directories << @import_directory
  directories << "#{@import_directory}/comments"
  directories << "#{@import_directory}/likes"
  directories << "#{@import_directory}/images"
  directories.each { |d| Dir.mkdir(d) unless Dir.exist?(d) }
end

def fetch_posts_or_load_from_disk
  fb_fetch_posts unless STORE_DATA_TO_FILES

  filename  = "#{@import_directory}/#{GROUP_ID}.json"

  if File.exist?(filename)
    @fb_posts = JSON.parse File.read(filename)
    puts "Loaded #{@fb_posts.length} fetched Facebook posts from disk"
  else
    fb_fetch_posts
    File.write filename, @fb_posts.to_json
    puts "Saved #{@fb_posts.length} fetched Facebook posts to disk"
  end
end

def fetch_comments_or_load_from_disk(fb_item, topic_id, post_number=nil)
  fetch_comments(fb_item, topic_id, post_number) unless STORE_DATA_TO_FILES

  filename = "#{@import_directory}/comments/#{fb_item['id']}.json"

  if File.exist?(filename)
    comments = JSON.parse File.read(filename)
    puts "Loaded #{comments.length} comments for #{fb_item['id']} from disk"
    comments.each do |comment|
      dc_create_comment(comment, topic_id, post_number)
    end
  else
    comments = fetch_comments(fb_item, topic_id, post_number)
    return unless comments
    File.write filename, comments.to_json
    puts "Saved #{comments.length} fetched comments for #{fb_item['id']} to disk"
  end
end

def fetch_likes_or_load_from_disk(item)
  fetch_likes(item) unless STORE_DATA_TO_FILES

  fb_id = item.custom_fields['fb_id']
  filename  = "#{@import_directory}/likes/#{fb_id}.json"

  if File.exist?(filename)
    likes = JSON.parse File.read(filename)
    puts "Loaded #{likes.length} likes for #{fb_id} from disk"
    likes.each do |like|
      create_like(like, item)
    end
  else
    likes = fetch_likes(item)
    return unless likes
    File.write filename, likes.to_json
    puts "Saved #{likes.length} fetched likes for #{fb_id} to disk"
  end
end

def fetch_image_or_load_from_disk(fb_item)
  fetch_image(fb_item) unless STORE_DATA_TO_FILES

  filename = "#{@import_directory}/images/#{fb_item['id']}.jpg"

  if File.exist?(filename)
    file = File.open(filename, 'r')
    puts "Loaded image for #{fb_item['id']} from disk"
    create_image(fb_item, file)
  else
    file = fetch_image fb_item
    return unless file
    File.write filename, file.read
    puts "Saved fetched image for #{fb_item['id']} to disk"
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
  @site_settings['min_post_length'] = SiteSetting.min_post_length
  @site_settings['min_topic_title_length'] = SiteSetting.min_topic_title_length
  @site_settings['title_prettify'] = SiteSetting.title_prettify
  @site_settings['allow_duplicate_topic_titles'] = SiteSetting.allow_duplicate_topic_titles
  @site_settings['min_title_similar_length'] = SiteSetting.min_title_similar_length
  @site_settings['min_body_similar_length'] = SiteSetting.min_body_similar_length
  @site_settings['max_reply_history'] = SiteSetting.max_reply_history
  @site_settings['newuser_max_replies_per_topic'] = SiteSetting.newuser_max_replies_per_topic
  @site_settings['title_max_word_length'] = SiteSetting.title_max_word_length
  @site_settings['newuser_max_links'] = SiteSetting.newuser_max_links
  @site_settings['flag_sockpuppets'] = SiteSetting.flag_sockpuppets
  @site_settings['newuser_spam_host_threshold'] = SiteSetting.newuser_spam_host_threshold
  @site_settings['max_new_accounts_per_registration_ip'] = SiteSetting.max_new_accounts_per_registration_ip
  @site_settings['max_age_unmatched_ips'] = SiteSetting.max_age_unmatched_ips
  @site_settings['rate_limit_new_user_create_topic'] = SiteSetting.rate_limit_new_user_create_topic
  @site_settings['rate_limit_new_user_create_post'] = SiteSetting.rate_limit_new_user_create_post
  @site_settings['max_topics_in_first_day'] = SiteSetting.max_topics_in_first_day
  @site_settings['max_replies_in_first_day'] = SiteSetting.max_replies_in_first_day
  @site_settings['sequential_replies_threshold'] = SiteSetting.sequential_replies_threshold
  @site_settings['dominating_topic_minimum_percent'] = SiteSetting.dominating_topic_minimum_percent
  @site_settings['disable_emails'] = SiteSetting.disable_emails
end

# Restore site settings
def dc_restore_site_settings
  SiteSetting.send("unique_posts_mins=", @site_settings['unique_posts_mins'])
  SiteSetting.send("rate_limit_create_topic=", @site_settings['rate_limit_create_topic'])
  SiteSetting.send("rate_limit_create_post=", @site_settings['rate_limit_create_post'])
  SiteSetting.send("max_topics_per_day=", @site_settings['max_topics_per_day'])
  SiteSetting.send("title_min_entropy=", @site_settings['title_min_entropy'])
  SiteSetting.send("body_min_entropy=", @site_settings['body_min_entropy'])
  SiteSetting.send("min_post_length=", @site_settings['min_post_length'])
  SiteSetting.send("min_topic_title_length=", @site_settings['min_topic_title_length'])
  SiteSetting.send("title_prettify=", @site_settings['title_prettify'])
  SiteSetting.send("allow_duplicate_topic_titles=", @site_settings['allow_duplicate_topic_titles'])
  SiteSetting.send("min_title_similar_length=", @site_settings['min_title_similar_length'])
  SiteSetting.send("min_body_similar_length=", @site_settings['min_body_similar_length'])
  SiteSetting.send("max_reply_history=", @site_settings['max_reply_history'])
  SiteSetting.send("newuser_max_replies_per_topic=", @site_settings['newuser_max_replies_per_topic'])
  SiteSetting.send("title_max_word_length=", @site_settings['title_max_word_length'])
  SiteSetting.send("newuser_max_links=", @site_settings['newuser_max_links'])
  SiteSetting.send("flag_sockpuppets=", @site_settings['flag_sockpuppets'])
  SiteSetting.send("newuser_spam_host_threshold=", @site_settings['newuser_spam_host_threshold'])
  SiteSetting.send("max_new_accounts_per_registration_ip=", @site_settings['max_new_accounts_per_registration_ip'])
  SiteSetting.send("max_age_unmatched_ips=", @site_settings['max_age_unmatched_ips'])
  SiteSetting.send("rate_limit_new_user_create_topic=", @site_settings['rate_limit_new_user_create_topic'])
  SiteSetting.send("rate_limit_new_user_create_post=", @site_settings['rate_limit_new_user_create_post'])
  SiteSetting.send("max_topics_in_first_day=", @site_settings['max_topics_in_first_day'])
  SiteSetting.send("max_replies_in_first_day=", @site_settings['max_replies_in_first_day'])
  SiteSetting.send("sequential_replies_threshold=", @site_settings['sequential_replies_threshold'])
  SiteSetting.send("dominating_topic_minimum_percent=", @site_settings['dominating_topic_minimum_percent'])
  SiteSetting.send("disable_emails=", @site_settings['disable_emails'])
end

# Set temporary site settings needed for this rake task
def dc_set_temporary_site_settings
  SiteSetting.send("unique_posts_mins=", 0)
  SiteSetting.send("rate_limit_create_topic=", 0)
  SiteSetting.send("rate_limit_create_post=", 0)
  SiteSetting.send("max_topics_per_day=", 10000)
  SiteSetting.send("title_min_entropy=", 1)
  SiteSetting.send("body_min_entropy=", 1)
  SiteSetting.send("min_post_length=", 2)
  SiteSetting.send("min_topic_title_length=", 3)
  SiteSetting.send("title_prettify=", false)
  SiteSetting.send("allow_duplicate_topic_titles=", true)
  SiteSetting.send("min_title_similar_length=", 50)
  SiteSetting.send("min_body_similar_length=", 90)
  SiteSetting.send("max_reply_history=", 999)
  SiteSetting.send("newuser_max_replies_per_topic=", 999)
  SiteSetting.send("title_max_word_length=", 300)
  SiteSetting.send("newuser_max_links=", 200)
  SiteSetting.send("flag_sockpuppets=", false)
  SiteSetting.send("newuser_spam_host_threshold=", 999)
  SiteSetting.send("max_new_accounts_per_registration_ip=", 999)
  SiteSetting.send("max_age_unmatched_ips=", 1)
  SiteSetting.send("rate_limit_new_user_create_topic=", 0)
  SiteSetting.send("rate_limit_new_user_create_post=", 0)
  SiteSetting.send("max_topics_in_first_day=", 999)
  SiteSetting.send("max_replies_in_first_day=", 999)
  SiteSetting.send("sequential_replies_threshold=", 999)
  SiteSetting.send("dominating_topic_minimum_percent=", 99)
  SiteSetting.send("disable_emails=", true)
end

# Check if user exists
# For some really weird reason this method returns the opposite value
# So if it did find the user, the result is false
def dc_user_exists(name)
  User.where('username = ?', name).exists?
end

def dc_get_user(name)
  User.where('username = ?', name).first
end

def total_run_time
  total_seconds = Time.now - TIME_AT_START
  seconds = total_seconds % 60
  minutes = (total_seconds / 60) % 60
  hours = total_seconds / (60 * 60)
  format("%02d hours %02d minutes %02d seconds", hours, minutes, seconds)
end

# Exit the script
def exit_script
  dc_restore_site_settings
  puts "\nScript will now exit\n".yellow
  puts "Total run time: #{total_run_time}"
  puts "Imported #{@post_count} posts, #{@comment_count} comments, #{@like_count} likes and #{@image_count} images"
  puts "Index of last topic processed: #{@latest_post_processed} (put this in config file to restart from where you were)\n\n"
  exit
end

def fb_username_to_dc(name)
  # Create username from full name, only letters and numbers
  username = name.to_ascii.tr('^A-Za-z0-9', '')

  # Maximum length of a Discourse username is 15 characters
  username = username[0,19]

  while User.where('username = ?', username).exists?
    if username[-1] =~ /[[:digit:]]/
      digits = ""
      while username[-1] =~ /[[:digit:]]/
        digits = "#{username[-1]}#{digits}"
        username.chop!
      end
      digits = (digits.to_i + 1).to_s
      username = "#{username[0..19-digits.length]}#{digits}"
    else
      username = "#{username[0..18]}2"
    end
  end

  return username
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
