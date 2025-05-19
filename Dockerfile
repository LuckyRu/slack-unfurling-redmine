# Use an official Ruby slim image as a parent image
FROM ruby:3.4.2-slim-bullseye

# Set a consistent working directory
WORKDIR /usr/src/app

# Install essential packages (build-essential for gem native extensions, git for some gems)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

# Copy your slack-unfurling-redmine application code into the container
COPY ./slack-unfurling-redmine ./slack-unfurling-redmine

# Create a Gemfile for the main server components
# and install them locally into /usr/src/app/vendor/bundle
RUN echo "INFO: Creating Gemfile and installing server gems locally into /usr/src/app/vendor/bundle" && \
    echo 'source "https://rubygems.org"' > Gemfile && \
    echo 'gem "puma", "~> 6.0"' >> Gemfile && \
    echo 'gem "rack", "~> 3.0"' >> Gemfile && \
    echo 'gem "rackup", "~> 2.1"' >> Gemfile && \
    echo 'gem "rack-protection", "~> 3.0"' >> Gemfile && \
    echo 'gem "faraday", "~> 1.0"' >> Gemfile && \
    echo 'gem "base64", "~> 0.2.0" # Required by rack-protection in Ruby 3.4+' >> Gemfile && \
    echo 'gem "logger", "~> 1.6" # Proactively add logger' >> Gemfile && \
    # Updated version constraint for reverse_markdown
    echo 'gem "reverse_markdown", "~> 2.1" # Added ReverseMarkdown to the main server bundle' >> Gemfile && \
    rm -f Gemfile.lock && \
    bundle config set --local path 'vendor/bundle' && \
    bundle install && \
    (bundle exec which rackup && echo "INFO: rackup found via bundle exec for server gems" || (echo "ERROR: rackup not found via bundle exec for server gems" && exit 1))

# Copy the config.ru file
# This config.ru MUST handle Bundler.setup for the sub-app
COPY ./config.ru ./config.ru

# Expose the port the app runs on
ENV PORT 3000
EXPOSE 3000

# Set BUNDLE_GEMFILE for the CMD context to ensure it uses /usr/src/app/Gemfile
ENV BUNDLE_GEMFILE /usr/src/app/Gemfile
# Set RACK_ENV to production to avoid Rack::Lint and other development middleware
ENV RACK_ENV production

# Command to run the application using bundle exec rackup.
# This will use rackup from /usr/src/app/vendor/bundle.
# The config.ru is responsible for setting up the Bundler context for slack-unfurling-redmine.
CMD ["bundle", "exec", "rackup", "--host", "0.0.0.0", "-p", "3000", "/usr/src/app/config.ru"]