# frozen_string_literal: true

require 'faraday'
require 'json'
require 'reverse_markdown' # For HTML to Markdown conversion

class RedmineClient
  URL_PATTERN = /\Ahttps?:\/\/.+\/issues\/\d+\z/.freeze
  COLOR = '#A00F1B' # Redmine's brand color

  # Default truncation settings, can be overridden by environment variables
  DEFAULT_MAX_PREVIEW_LINES = 7
  DEFAULT_MAX_CHARS = 400

  # Добавляем domain_from_slack как опциональный параметр, но не используем его
  def enabled?
    # Check if the Redmine API access key is configured in environment variables
    ENV['REDMINE_API_ACCESS_KEY']
  end

  def target?(url, domain_from_slack = nil)
    # Check if the given URL matches the Redmine issue URL pattern
    url =~ URL_PATTERN
  end

  def get(url)
    # Return nil if the URL doesn't match the expected pattern
    return nil unless url =~ URL_PATTERN

    # Construct the API URL for fetching the issue in JSON format
    api_url = "#{url}.json?key=#{ENV['REDMINE_API_ACCESS_KEY']}"
    
    # Make a GET request to the Redmine API
    response = Faraday.get(api_url)

    # Handle cases where the request might not be successful
    unless response.success?
      puts "[RedmineClient] ERROR: Failed to fetch issue from Redmine. URL: #{api_url}, Status: #{response.status}, Body: #{response.body[0..200]}"
      return nil
    end

    # Parse the JSON response
    begin
      issue_data = JSON.parse(response.body)
    rescue JSON::ParserError => e
      puts "[RedmineClient] ERROR: Failed to parse JSON response from Redmine. URL: #{api_url}, Error: #{e.message}, Body: #{response.body[0..200]}"
      return nil
    end
    
    issue = issue_data['issue']

    # Return nil if the issue is marked as private
    return nil if issue['is_private']

    # Construct the title for the Slack unfurl attachment
    title = "#{issue.dig('project', 'name')} | #{issue['subject']}"

    # Prepare standard fields for the attachment
    fields = ['tracker', 'status', 'priority', 'author'].map do |key|
      if issue[key] && issue[key]['name']
        {
          title: key, # Using original key name
          value: issue[key]['name'],
          short: true
        }
      else
        nil
      end
    end.compact # Use .compact to remove nil values

    # Add other top-level issue attributes as fields, excluding certain ones
    # and ensuring they are simple types (not Hashes or Arrays).
    fields += issue.keys
      .filter { |key| !%w(id project subject description created_on updated_on closed_on is_private tracker status priority author custom_fields journals attachments relations).include?(key) && ![Hash, Array].include?(issue[key].class) && !issue[key].to_s.empty? }
      .map do |key|
      {
        title: key.gsub('_', ' '), # Replace underscores with spaces for readability
        value: issue[key].to_s, # Ensure value is a string
        short: true
      }
    end

    # Add custom fields if they exist and are not ignored
    if issue['custom_fields'] && !ignore_custom_fields?
      fields += issue['custom_fields'].map do |custom_field|
        # Ensure custom field value is not empty or just whitespace
        value = custom_field['value'].is_a?(Array) ? custom_field['value'].join(', ') : custom_field['value'].to_s
        next if value.strip.empty?
        {
          title: custom_field['name'], # Custom field names are used as-is
          value: value,
          short: true
        }
      end.compact # Remove nil values from custom fields (e.g., if value was empty)
    end
    
    description_for_slack = issue['description'] # Default to original description

    if convert_html_to_markdown_enabled? && issue['description'] && !issue['description'].strip.empty?
      begin
        # Pass options directly to convert for older ReverseMarkdown versions
        # For Slack-style italics (underscores): em_delimiters: '_'
        gfm_description = ReverseMarkdown.convert(
          issue['description'],
          unknown_tags: :bypass, 
          github_flavored: true, # This enables GFM features like tables, strikethrough
          em_delimiters: '_'     # Use underscores for <em> -> _italic_
        )
        
        # Post-process GFM to Slack's specific mrkdwn
        # 1. Convert GFM bold-italic (e.g., **_text_**) to Slack bold-italic (*_text_*)
        slack_desc = gfm_description.gsub(/\*\*_((?:(?!_\*\*).)+?)_\*\*/m, '*_\1_*')
        
        # 2. Convert GFM bold (e.g., **text**) to Slack bold (*text*)
        slack_desc.gsub!(/(?<!\*)\*\*([^*]+?)\*\*(?!\*)/m, '*\1*')
        
        description_for_slack = slack_desc # Use the Slack-formatted markdown
      rescue StandardError => e
        puts "[RedmineClient] ERROR: Failed to convert HTML to Markdown for issue #{issue['id']}. Error: #{e.message}"
        # Fallback to original HTML description if conversion fails (as per user preference)
        description_for_slack = issue['description'] 
      end
    elsif issue['description'].nil? || issue['description'].strip.empty?
      description_for_slack = '' # Use empty string if description is nil or empty
    end
    # If conversion is disabled, description_for_slack remains as issue['description'] (original HTML)

    # Prepare the final hash for the Slack attachment
    {
      title: title,
      title_link: url,
      text: truncate(description_for_slack), # Truncate the description (which might be HTML or Markdown)
      color: COLOR,
      fields: skip_fields? ? [] : fields.uniq { |f| f[:title] } # Ensure unique field titles
    }
  rescue Faraday::ConnectionFailed => e
    puts "[RedmineClient] ERROR: Connection to Redmine failed. URL: #{api_url}, Error: #{e.message}"
    nil
  rescue StandardError => e
    puts "[RedmineClient] ERROR: An unexpected error occurred in RedmineClient#get. URL: #{url}, Error: #{e.class} - #{e.message}"
    puts e.backtrace.join("\n")
    nil
  end

  private

  def convert_html_to_markdown_enabled?
    # Defaults to false (disabled) if the ENV var is not set or is not a recognized 'true' value.
    env_value = ENV['CONVERT_HTML_TO_MARKDOWN']&.downcase
    %w(true t yes y 1).include?(env_value) # Only enable if explicitly set to a truthy value
  end

  def max_preview_lines
    # Read from environment variable or use default
    (ENV['MAX_PREVIEW_LINES']&.to_i || DEFAULT_MAX_PREVIEW_LINES).tap do |val|
      return DEFAULT_MAX_PREVIEW_LINES if val <= 0 # Ensure positive value
    end
  rescue StandardError # In case to_i fails on a weird string
    DEFAULT_MAX_PREVIEW_LINES
  end

  def max_chars
    # Read from environment variable or use default
    (ENV['MAX_CHARS']&.to_i || DEFAULT_MAX_CHARS).tap do |val|
      return DEFAULT_MAX_CHARS if val <= 0 # Ensure positive value
    end
  rescue StandardError # In case to_i fails on a weird string
    DEFAULT_MAX_CHARS
  end

  def truncate(text_content) # This method now might receive HTML or Markdown
    # Return an empty string if the content is nil or effectively empty
    return '' if text_content.nil? || text_content.strip.empty?
    
    # Get configured limits
    current_max_lines = max_preview_lines
    current_max_chars = max_chars

    # If it's HTML (because conversion failed or was disabled), we should be careful about truncation
    is_likely_html = text_content.include?('<') && text_content.include?('>')

    if is_likely_html
        # Basic truncation for HTML to avoid breaking it too badly.
        # Using the configured (or default) max_chars for HTML fallback.
        return text_content[0, current_max_chars] + (text_content.length > current_max_chars ? "..." : "")
    end

    # Proceed with Markdown-aware truncation if it's not likely HTML
    lines = text_content.lines
    
    # Take the initial set of lines and join them
    current_preview = lines[0, current_max_lines].map(&:chomp).join("\n").strip
    
    # Determine if truncation is needed
    original_content_exceeds_limits = text_content.length > current_max_chars || lines.size > current_max_lines

    # If the line-limited preview itself exceeds character limit, shorten it further
    if current_preview.length > current_max_chars
      safe_truncate_point = current_preview.rindex(/\s|\n/, current_max_chars)
      if safe_truncate_point
        current_preview = current_preview[0...safe_truncate_point].strip 
      else
        # No whitespace found, hard truncate the line-limited preview
        current_preview = current_preview[0...current_max_chars]
      end
    end

    # Add ellipsis if the original content was longer/had more lines than what we're showing
    if original_content_exceeds_limits && current_preview.length < text_content.length
        current_preview += "..." 
    end
    
    current_preview
  end

  def skip_fields?
    # Check environment variable to determine if fields should be skipped
    %w(true t yes y 1).include?(ENV['SKIP_FIELDS']&.downcase)
  end

  def ignore_custom_fields?
    # Check environment variable to determine if custom fields should be ignored
    %w(true t yes y 1).include?(ENV['IGNORE_CUSTOM_FIELDS']&.downcase)
  end
end
