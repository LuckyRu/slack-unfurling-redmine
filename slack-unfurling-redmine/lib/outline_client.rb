# frozen_string_literal: true

require 'faraday'
require 'json'
require 'uri' # Для URI.parse и Regexp.escape

class OutlineClient
  # Этот паттерн описывает часть пути URL после базового домена.
  DEFAULT_OUTLINE_PATH_PATTERN = %r{/(?:doc(?:ument)?/|s/)[a-zA-Z0-9\-]+(?:-[a-zA-Z0-9]{10,12})?\z}.freeze
  COLOR = '#3478F6'

  DEFAULT_MAX_PREVIEW_LINES = 7
  DEFAULT_MAX_CHARS = 400

  attr_reader :expected_domain

  def initialize
    # Читаем ожидаемый домен, приводим к нижнему регистру и убираем пробелы
    @expected_domain = ENV['OUTLINE_EXPECTED_DOMAIN']&.downcase&.strip
    if @expected_domain.nil? || @expected_domain.empty?
      puts "[OutlineClient] WARN: OUTLINE_EXPECTED_DOMAIN is not configured. Client will be disabled."
      @expected_domain = nil # Убедимся, что nil, если пустой
    else
      puts "[OutlineClient] Initialized. Expected domain: '#{@expected_domain}'"
    end
  end

  def enabled?
    !ENV['OUTLINE_API_TOKEN'].nil? && !ENV['OUTLINE_API_TOKEN'].empty? &&
    !@expected_domain.nil?
  end

  # target? теперь принимает url_string и domain_from_slack
  def target?(url_string, domain_from_slack)
    return false unless enabled?

    # 1. Проверяем, совпадает ли домен из Slack с нашим ожидаемым доменом
    unless domain_from_slack&.downcase == @expected_domain
      # Закомментируйте или используйте DEBUG_MODE, если это слишком шумно
      # puts "[OutlineClient] Domain mismatch: Slack sent '#{domain_from_slack&.downcase}', expected '#{@expected_domain}' for URL #{url_string}" if ENV['DEBUG_MODE'] == 'true'
      return false
    end

    # 2. Проверяем, соответствует ли путь URL структуре Outline
    begin
      uri = URI.parse(url_string)
      path_to_check = uri.path
      # Паттерн обычно не должен включать query параметры, но если нужно, можно добавить:
      # path_to_check += "?#{uri.query}" if uri.query
      
      match = path_to_check =~ DEFAULT_OUTLINE_PATH_PATTERN
      is_match = !match.nil?
      
      puts "[OutlineClient] Target check for URL: #{url_string}, Domain: #{domain_from_slack}. Expected domain match: true. Path: #{path_to_check}. Path pattern match: #{is_match}" if ENV['DEBUG_MODE'] == 'true'
      return is_match
    rescue URI::InvalidURIError
      puts "[OutlineClient] WARN: Invalid URI encountered in target? for URL: #{url_string}"
      return false
    end
  end

  def get(url_string) # url_string - это полный URL, который прошел проверку в target?
    return nil unless enabled? # На всякий случай

    begin
      uri = URI.parse(url_string)
    rescue URI::InvalidURIError
      puts "[OutlineClient] ERROR: Invalid URI passed to get method: #{url_string}"
      return nil
    end

    # Формируем базовый URL для API из схемы и хоста пришедшего URL
    # Это безопасно, так как target? уже проверил, что uri.host (через domain_from_slack)
    # совпадает с @expected_domain.
    current_api_base = "#{uri.scheme}://#{uri.host}/api"

    # Снова получаем совпадение пути для извлечения идентификатора
    path_match = uri.path.match(DEFAULT_OUTLINE_PATH_PATTERN)
    unless path_match
      # Эта ситуация не должна возникнуть, если target? отработал корректно
      puts "[OutlineClient] ERROR: Path pattern did not match in get() after matching in target? for URL: #{url_string}"
      return nil
    end

    doc_identifier = path_match[0].gsub(%r{^/(?:doc(?:ument)?/|s/)}, '')
    if doc_identifier.empty?
        puts "[OutlineClient] ERROR: Could not extract document identifier from path: #{path_match[0]} for URL #{url_string}"
        return nil
    end

    api_action_path = if path_match[0].start_with?("/s/")
                        "/shares.get"
                      elsif path_match[0].start_with?("/doc/") || path_match[0].start_with?("/document/")
                        "/documents.info"
                      else
                        puts "[OutlineClient] ERROR: Unknown path structure for API call based on path: #{path_match[0]} for URL #{url_string}"
                        return nil
                      end

    full_api_endpoint = "#{current_api_base}#{api_action_path}"
    # Outline API ожидает 'id' для этих эндпоинтов, содержащий либо UUID документа, либо Share ID
    payload = { id: doc_identifier }

    puts "[OutlineClient] Attempting to fetch: #{full_api_endpoint} with payload: #{payload.to_json}" if ENV['DEBUG_MODE'] == 'true'

    begin
      response = Faraday.post(full_api_endpoint) do |req|
        req.headers['Authorization'] = "Bearer #{ENV['OUTLINE_API_TOKEN']}"
        req.headers['Content-Type'] = 'application/json'
        req.body = payload.to_json
      end

      unless response.success?
        puts "[OutlineClient] ERROR: Failed to fetch document. URL: #{url_string}, API: #{full_api_endpoint}, Status: #{response.status}, Body: #{response.body.slice(0, 500)}"
        return nil
      end

      response_data = JSON.parse(response.body)
      # Структура ответа может немного отличаться (например, shares.get оборачивает документ в data.document)
      document_node = response_data.dig('data', 'document') || response_data.dig('data')
      
      unless document_node
        puts "[OutlineClient] ERROR: 'document' or 'data' node not found in API response for URL: #{url_string} (API: #{full_api_endpoint}). Response: #{response.body.slice(0,500)}"
        return nil
      end

      title = document_node['title']
      content_markdown = document_node['text']

      if title.nil? || content_markdown.nil?
        puts "[OutlineClient] ERROR: Title or text is missing for URL: #{url_string} (API: #{full_api_endpoint}). Document node keys: #{document_node.keys.join(', ').slice(0,500)}"
        return nil
      end

      return {
        title: title,
        title_link: url_string, # Оригинальный URL
        text: truncate(content_markdown),
        color: COLOR,
      }
    rescue Faraday::ConnectionFailed => e
      puts "[OutlineClient] ERROR: Connection to Outline failed. API: #{full_api_endpoint}, Original URL: #{url_string}, Error: #{e.message}"
      nil
    rescue JSON::ParserError => e
      puts "[OutlineClient] ERROR: Failed to parse JSON from Outline. API: #{full_api_endpoint}, Original URL: #{url_string}, Error: #{e.message}, Body: #{response&.body&.slice(0,500)}"
      nil
    rescue StandardError => e
      puts "[OutlineClient] ERROR: Unexpected error in OutlineClient#get. API: #{full_api_endpoint}, Original URL: #{url_string}, Error: #{e.class} - #{e.message}"
      puts e.backtrace.join("\n") # Логируем полный backtrace для неожиданных ошибок
      nil
    end
  end

  private

  # Методы max_preview_lines, max_chars, truncate остаются без изменений
  def max_preview_lines
    (ENV['OUTLINE_MAX_PREVIEW_LINES']&.to_i || ENV['MAX_PREVIEW_LINES']&.to_i || DEFAULT_MAX_PREVIEW_LINES).tap do |val|
      return DEFAULT_MAX_PREVIEW_LINES if val <= 0
    end
  rescue StandardError
    DEFAULT_MAX_PREVIEW_LINES
  end

  def max_chars
    (ENV['OUTLINE_MAX_CHARS']&.to_i || ENV['MAX_CHARS']&.to_i || DEFAULT_MAX_CHARS).tap do |val|
      return DEFAULT_MAX_CHARS if val <= 0
    end
  rescue StandardError
    DEFAULT_MAX_CHARS
  end

  def truncate(text_content)
    return '' if text_content.nil? || text_content.strip.empty?

    current_max_lines = max_preview_lines
    current_max_chars = max_chars

    lines = text_content.lines
    current_preview = lines[0, current_max_lines].map(&:chomp).join("\n").strip

    original_content_exceeds_limits = text_content.length > current_max_chars || lines.size > current_max_lines

    if current_preview.length > current_max_chars
      safe_truncate_point = current_preview.rindex(/\s|\n/, current_max_chars)
      current_preview = if safe_truncate_point && safe_truncate_point > (current_max_chars - 30)
                          current_preview[0...safe_truncate_point].strip
                        else
                          current_preview[0...current_max_chars]
                        end
    end

    if original_content_exceeds_limits && current_preview.length < text_content.strip.length
      current_preview += "..." unless current_preview.end_with?("...")
    end
    current_preview
  end
end