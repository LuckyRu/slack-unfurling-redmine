# frozen_string_literal: true

require 'json'
require_relative './slack_api_client'

class SlackUnfurling
  def initialize(clients_array)
    @clients = clients_array.select(&:enabled?)
    if @clients.empty?
      puts "[SlackUnfurling] WARNING: No clients are enabled or provided."
    end
  end

  def call(event)
    params = JSON.parse(event["body"])

    case params['type']
    when 'url_verification'
      challenge = params['challenge']
      if !@clients.empty?
        { statusCode: 200, body: JSON.generate(challenge: challenge) }
      else
        puts "[SlackUnfurling] INFO: url_verification received, but no clients enabled."
        # Slack обычно ожидает 200 OK на challenge, даже если сервис не полностью готов.
        # Можно просто вернуть challenge, или ошибку, если это предпочтительнее.
        { statusCode: 200, body: JSON.generate(challenge: challenge) } # или 404
      end
    when 'event_callback'
      slack_event = params.dig('event')
      # Убедимся, что это событие link_shared и есть event
      unless slack_event && slack_event['type'] == 'link_shared'
        puts "[SlackUnfurling] INFO: Received event_callback, but not a link_shared event or event data missing. Type: #{slack_event ? slack_event['type'] : 'N/A'}"
        return { statusCode: 200, body: JSON.generate(ok: true) } # Отвечаем Slack, что все ок
      end

      channel = slack_event['channel']
      ts = slack_event['message_ts']
      links = slack_event['links']

      return { statusCode: 200, body: JSON.generate(ok: true) } if links.nil? || links.empty?

      unfurls = {}
      links.each do |link_info|
        url = link_info['url']
        domain_from_slack = link_info['domain'] # <--- Получаем домен из данных Slack

        # Передаем url и domain_from_slack в target?
        found_client = @clients.find do |c|
          # Проверяем, принимает ли метод target? два аргумента
          if c.method(:target?).arity == 2
            c.target?(url, domain_from_slack)
          else
            c.target?(url) # Для старых клиентов, как RedmineClient, если не обновлен
          end
        end

        if found_client
          puts "[SlackUnfurling] INFO: Found client for URL #{url}: #{found_client.class.name}"
          unfurl_data = found_client.get(url) # get принимает только url
          unfurls[url] = unfurl_data if unfurl_data
        else
          # Закомментируйте или используйте DEBUG_MODE, если это слишком шумно
          # puts "[SlackUnfurling] INFO: No client found for URL #{url} with domain #{domain_from_slack}"
        end
      end

      if unfurls.any?
        payload = JSON.generate(
          channel: channel,
          ts: ts,
          unfurls: unfurls
        )
        slack_api_client = SlackApiClient.new
        slack_api_client.request(payload)
        puts "[SlackUnfurling] INFO: Sent unfurl data to Slack for #{unfurls.keys.count} link(s)."
      else
        puts "[SlackUnfurling] INFO: No unfurl data generated for any links."
      end
      { statusCode: 200, body: JSON.generate(ok: true) }
    else
      puts "[SlackUnfurling] WARN: Unhandled event type: #{params['type']}"
      { statusCode: 400, body: JSON.generate(error: "Unhandled event type") }
    end
  rescue JSON::ParserError => e
    puts "[SlackUnfurling] ERROR: Failed to parse event body JSON: #{e.message}"
    { statusCode: 400, body: JSON.generate(error: "Invalid JSON in request body", details: e.message) }
  rescue StandardError => e
    puts "[SlackUnfurling] ERROR: Unhandled exception in 'call': #{e.class} - #{e.message}"
    puts "[SlackUnfurling] ERROR: Backtrace: #{e.backtrace.join("\n")}"
    { statusCode: 500, body: JSON.generate(error: "Internal server error", details: e.message) }
  end
end