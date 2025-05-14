# Slack Redmine Link Unfurler Service

This service listens for Slack events when links from your Redmine instance are shared. It then fetches details about the Redmine issue and posts a rich unfurled message back to Slack, providing a preview of the issue.

This setup guide assumes you are using the repository at [https://github.com/LuckyRu/slack-unfurling-redmine](https://github.com/LuckyRu/slack-unfurling-redmine), which includes the application code and the necessary Docker configuration files.

## Prerequisites

* **Docker and Docker Compose**: Ensure Docker and Docker Compose are installed on your server.
* **Git**: To clone the repository.
* **Redmine Instance**: A running Redmine instance that is accessible from the server where this service will be deployed. You'll need an API access key from Redmine.
* **Slack Workspace**: A Slack workspace where you want to unfurl Redmine links. You'll need to create or configure a Slack App.
* **Publicly Accessible Server with a Domain Name**: Slack requires event subscription URLs to be HTTPS. This setup uses `https-portal` to automate SSL certificate acquisition (e.g., via Let's Encrypt) and act as a reverse proxy. Your server must be reachable via a domain name (e.g., `your-unfurler-domain.com`).

## Setup Instructions

### 1. Clone the Repository

Clone the repository to your server:

```bash
git clone https://github.com/LuckyRu/slack-unfurling-redmine.git
cd slack-unfurling-redmine
```

This repository contains:

* The `slack-unfurling-redmine` application code (based on `suer/slack-unfurling-redmine`).
* `Dockerfile`: Defines how to build the application's Docker image.
* `config.ru`: Rack configuration file for the Ruby application.
* `docker-compose.yml`: Manages your services (the application and an HTTPS portal).

### 2. Configure Environment Variables

The primary configuration you need to do is within the `docker-compose.yml` file located at the root of the cloned repository. Open it and modify the `environment` section for the `slack-unfurling-redmine` service and the `https-portal` service.

**Key variables to set in `docker-compose.yml`:**

For the `slack-unfurling-redmine` service:

* `REDMINE_API_ACCESS_KEY`: **Required**. Replace `your-redmine-api-key` with your actual Redmine API access key.
* `SLACK_OAUTH_ACCESS_TOKEN`: **Required**. Replace `your-slack-oauth-key` with your Slack App's Bot User OAuth Token (starts with `xoxb-`).
* `SKIP_FIELDS`: Set to `true` if you want to hide fields like tracker, status, priority. Default in your example is true.
* `IGNORE_CUSTOM_FIELDS`: Set to `true` if you want to hide custom fields. Default in your example is true.
* `CONVERT_HTML_TO_MARKDOWN`: Uncomment and set to `true` to enable HTML to Markdown conversion for descriptions. It's disabled (commented out) by default in your example.
* `MAX_PREVIEW_LINES`: Controls description truncation. Default in your example is `7`.
* `MAX_CHARS`: Controls description truncation. Default in your example is `400`.

**For the `https-portal` service:**

* `DOMAINS`: Change `'your.domain.com -> http://slack-unfurling-redmine:3000'` to use your actual public domain name. This configuration forwards requests from your domain to the root of the `slack-unfurling-redmine` service. The `config.ru` provided handles requests at both / and /call.
* `STAGE`: Set to `'production'` for live use, or `'staging'` for testing to avoid Let's Encrypt rate limits.
* (Optional) `LETSENCRYPT_EMAIL`: Your email for Let's Encrypt notifications.

### 3. Build and Run the Service

Once you have configured your `docker-compose.yml`:

1. Build the Docker image:
   ```
   docker compose build
   ```

2. Start the services:
   ```
   docker compose up -d
   ```
   The `-d` flag runs the containers in detached mode (in the background).


## HTTPS Setup

The `https-portal` service in the `docker-compose.yml` file automatically handles:

* Obtaining SSL certificates from Let's Encrypt for the domain specified in the `DOMAINS` environment variable.
* Renewing these certificates.
* Terminating HTTPS (SSL) connections.
* Acting as a reverse proxy, forwarding decrypted HTTP traffic to your `slack-unfurling-redmine` application container.

Ensure your domain's DNS A record points to your server's public IP address. Ports 80 and 443 must be open on your server's firewall and not used by other services.


## Slack App Configuration

1. **Go to Slack API**: Navigate to api.slack.com/apps and select your app (or create a new one).
2. **Event Subscriptions**:
    * Go to "Event Subscriptions" in the sidebar.
    * **Enable Events**: Toggle to "On".
    * **Request URL**: Enter your public HTTPS URL. If your `DOMAINS` in `docker-compose.yml` is set to `your.domain.com -> http://slack-unfurling-redmine:3000`, you could use `https://your.domain.com/call`.
        * Slack will attempt to verify this URL. The application is designed to respond to this `url_verification` event.
    * **Subscribe to bot events**: Add the link_shared event.
    * Save changes.
3. App Unfurl Domains:
    * Go to "App Unfurl Domains".
    * Add the domain(s) of your Redmine instance (e.g., `redmine.example.com`).
4. OAuth & Permissions:
    * Go to "OAuth & Permissions".
    * **Bot Token Scopes**: Ensure `links:read` and `links:write`.
    * Note your Bot User OAuth Token (for `SLACK_OAUTH_ACCESS_TOKEN`).
5. Install/Reinstall App:
    * (Re)install the app to your workspace.
    * Invite your bot user to relevant channels.


## Troubleshooting and Logs

* Check Docker Compose logs:
    ```bash
    docker compose logs -f slack-unfurling-redmine
    docker compose logs -f https-portal
    ```
* **Slack App Event Delivery**: Check your Slack app settings under "Event Subscriptions" for delivery errors.
* **HTTPS Portal**: Ensure https-portal starts correctly and can obtain SSL certificates.















# slack-unfurling-redmine

A Slack unfruling Lambda function for Redmine.
It based on AWS SAM(Serverless application mode).

Inspired by and based on [slack-unfurling-esa](https://github.com/mallowlabs/slack-unfurling-esa).

## Requirements

* AWS CLI
* SAM CLI

## Deploy

### Slack side

#### 1. Create Slack App

https://api.slack.com/apps

#### 2. `Event Subscriptions` setting

`Enable Events` Set to On

`App Unfurl Domains` Add your redmine url.

Click `Save Changes`.

#### 3. `OAuth & Permissions` setting

Added `links:write` to `Scopes`.

Click `Install App to Workspace`.

Remember your `OAuth Access Token`.

### Lambda side

```bash
$ aws s3 mb s3://your-sandbox --region ap-northeast-1
```

```bash
$ cd slack-unfurling-redmine
$ bundle install --path vendor/bundle --without test
```

```bash
$ sam package \
    --template-file template.yaml \
    --output-template-file serverless-output.yaml \
    --s3-bucket your-sandbox
```

```bash
$ sam deploy \
    --template-file serverless-output.yaml \
    --stack-name your-slack-unfurling-redmine \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
      RedmineAPIAccessKey=your-api-access-key \
      SlackOauthAccessToken=your-slack-oauth-token
```

Confirm your endpoint url.

(To ignore custom fields, add IgnoreCustomFields=true for parameter-overrides.)

(To skip all fields, add SkipFields=true for parameter-overrides.)

```bash
$ aws cloudformation describe-stacks --stack-name your-slack-unfurling-redmine --region ap-northeast-1
```

### Slack side
Input your endpoint url to `Request URL` in `Event Subscriptions`.

Click `Save Changes`.

### delete

```bash
$ sam delete
```
