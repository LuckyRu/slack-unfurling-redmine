# frozen_string_literal: true

require_relative 'lib/slack_unfurling'
require_relative 'lib/redmine_client'
require_relative 'lib/outline_client' # <--- Добавляем нового клиента

def lambda_handler(event:, context:)
  # Создаем экземпляры всех наших клиентов
  redmine_client = RedmineClient.new
  outline_client = OutlineClient.new # <--- Создаем экземпляр

  # Передаем массив клиентов в SlackUnfurling
  # Порядок может иметь значение, если паттерны URL могут пересекаться
  # (маловероятно для разных доменов).
  service = SlackUnfurling.new([redmine_client, outline_client])

  service.call(event)
end