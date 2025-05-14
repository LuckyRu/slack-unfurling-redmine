# config.ru

# Standard library dependencies
require 'json'

# Rack and Rack::Protection will be loaded from the main app's bundle
# (defined in /usr/src/app/Gemfile and installed into /usr/src/app/vendor/bundle)
require 'rack'
require 'rack/protection' # Ensure this is required if you use it below
require 'rack/common_logger' # Explicitly require CommonLogger

puts "[CONFIG.RU] INFO: Starting up. Rack and Rack::Protection loaded from main bundle."

# --- Setup Bundler for the slack-unfurling-redmine application ---
# This is crucial so that when app.rb is required, it can find its
# own bundled gems (e.g., faraday) which were installed into its
# 'vendor/bundle' directory.
begin
  puts "[CONFIG.RU] INFO: Attempting to set up Bundler for slack-unfurling-redmine..."
  original_dir = Dir.pwd
  # The app code is copied into /usr/src/app/slack-unfurling-redmine in the Docker image
  app_dir = File.expand_path('slack-unfurling-redmine', '/usr/src/app')
  app_gemfile = File.join(app_dir, 'Gemfile') # Path to the sub-app's Gemfile

  unless File.directory?(app_dir)
    raise "Application directory not found: #{app_dir}"
  end
  # The suer/slack-unfurling-redmine project has a Gemfile
  unless File.exist?(app_gemfile)
    raise "Application Gemfile not found: #{app_gemfile}. This is needed for Bundler.setup."
  end

  # Store the original BUNDLE_GEMFILE (which points to the main app's Gemfile)
  original_bundle_gemfile_env = ENV['BUNDLE_GEMFILE']
  # Temporarily set BUNDLE_GEMFILE to the sub-app's Gemfile path
  ENV['BUNDLE_GEMFILE'] = app_gemfile

  puts "[CONFIG.RU] INFO: Temporarily set ENV['BUNDLE_GEMFILE'] to: #{ENV['BUNDLE_GEMFILE']}"
  puts "[CONFIG.RU] INFO: Current directory before chdir: #{Dir.pwd}"

  Dir.chdir(app_dir) do
    puts "[CONFIG.RU] INFO: Changed directory to #{Dir.pwd} (for slack-unfurling-redmine)"
    puts "[CONFIG.RU] INFO: About to call 'require \"bundler/setup\"' for sub-app."
    # With BUNDLE_GEMFILE now pointing to the sub-app's Gemfile,
    # Bundler.setup should correctly initialize its environment.
    require 'bundler/setup'
    puts "[CONFIG.RU] INFO: Bundler.setup completed successfully for slack-unfurling-redmine."
  end

  puts "[CONFIG.RU] INFO: Current directory after chdir block: #{Dir.pwd}" # Should be /usr/src/app

  # Restore the original BUNDLE_GEMFILE environment variable
  ENV['BUNDLE_GEMFILE'] = original_bundle_gemfile_env
  puts "[CONFIG.RU] INFO: Restored ENV['BUNDLE_GEMFILE'] to: #{ENV['BUNDLE_GEMFILE'] || 'nil (was not originally set)'}"

  # The working directory for the main Rack app is /usr/src/app.
  # We need to load the sub-app's entry point using its full path.
  require File.join(app_dir, 'app.rb')
  puts "[CONFIG.RU] INFO: Successfully loaded /usr/src/app/slack-unfurling-redmine/app.rb"

rescue LoadError => e
  puts "[CONFIG.RU] ERROR: Failed to load Bundler or app dependencies for slack-unfurling-redmine: #{e.class} - #{e.message}"
  puts "[CONFIG.RU] ERROR: Backtrace: #{e.backtrace.join("\n")}"
  raise "Critical dependency loading error for sub-app: #{e.message}"
rescue RuntimeError => e
  puts "[CONFIG.RU] ERROR: Runtime error during Bundler setup for slack-unfurling-redmine: #{e.class} - #{e.message}"
  puts "[CONFIG.RU] ERROR: Backtrace: #{e.backtrace.join("\n")}"
  raise "Critical runtime error during sub-app setup: #{e.message}"
end

# --- Rack::CommonLogger Middleware ---
# Explicitly add Rack::CommonLogger to see request logs even in production.
# $stdout is typically where Docker container logs go.
use Rack::CommonLogger, $stdout
puts "[CONFIG.RU] INFO: Rack::CommonLogger middleware configured to log to $stdout."

# --- Rack::Protection Middleware ---
# Explicitly disable protections that require session setup or might cause issues with Rack::Lint.
use Rack::Protection, except: [
  :session_hijacking,
  :remote_token,
  :csrf, # Common alias for authenticity_token
  :authenticity_token,
  :http_origin,
  :host_authorization,
  :content_type_sniffing, # Disable X-Content-Type-Options header
  # Consider also disabling others if issues persist, e.g.:
  # :frame_options,
  # :json_csrf,
  # :xss_header # (Rack::Protection::XSSHeader)
]
puts "[CONFIG.RU] INFO: Rack::Protection middleware configured with specific exceptions."


# --- Main Application Logic (Rack App) ---
app = Proc.new do |env|
  request = Rack::Request.new(env)
  response_body_json_str = ''
  status_code = 500 # Default to server error
  # Corrected header name to lowercase 'content-type'
  response_headers = {'content-type' => 'application/json'}

  # Updated to handle POST requests to / OR /call
  if request.post? && (request.path == '/' || request.path == '' || request.path == '/call')
    puts "[APP] INFO: Received POST request to #{request.path}"
    begin
      request_body_string = request.body.read
      request.body.rewind

      simulated_event = {
        "body" => request_body_string,
        "requestContext" => {
          "http" => {
            "method" => request.request_method,
            "path" => request.path_info # Path within this app, e.g., "/" or "/call"
          }
        },
        "headers" => env.select { |k, _v| k.start_with?('HTTP_') || %w[CONTENT_TYPE CONTENT_LENGTH].include?(k) }
                      .transform_keys { |k| k.sub(/^HTTP_/, '').downcase.gsub('_', '-') }
      }

      result = lambda_handler(event: simulated_event, context: "")

      status_code = result[:statusCode]
      response_body_json_str = result[:body]
      # Merge headers from lambda_handler if any, ensuring they are also lowercase
      if result[:headers]
        result[:headers].each do |key, value|
          response_headers[key.downcase] = value
        end
      end

    rescue JSON::ParserError => e
      puts "[APP] ERROR: Failed to parse request body JSON: #{e.message}"
      status_code = 400
      response_body_json_str = JSON.generate({error: "Invalid JSON in request body", details: e.message})
    rescue StandardError => e
      puts "[APP] ERROR: Unhandled exception in lambda_handler or POST processing: #{e.class} - #{e.message}"
      puts "[APP] ERROR: Backtrace: #{e.backtrace.join("\n")}"
      status_code = 500
      response_body_json_str = JSON.generate({error: "Internal server error", details: e.message})
    end
  elsif request.get? && request.path == "/health"
    puts "[APP] INFO: Received GET request to /health"
    status_code = 200
    response_body_json_str = JSON.generate({status: "healthy", timestamp: Time.now.iso8601})
  else
    puts "[APP] WARN: Received #{request.request_method} request to #{request.path} - returning 404"
    status_code = 404 # Not Found for other paths/methods
    response_body_json_str = JSON.generate({error: "Endpoint not found. POST to / or /call, or GET /health."})
  end

  [status_code, response_headers, [response_body_json_str]]
end

# Run the Rack application
run app
puts "[CONFIG.RU] INFO: Application configured and ready to run."