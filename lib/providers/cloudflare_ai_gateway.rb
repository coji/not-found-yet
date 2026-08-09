# frozen_string_literal: true

require "faraday"
require "json"

module Providers
  # AI Gateway との通信だけを担当する交換可能な adapter。
  # Agent や Mutator はこの中身を知らない。外向き通信はここだけ。
  class CloudflareAIGateway
    class Error < StandardError; end
    class Unavailable < Error; end
    class Throttled < Error; end
    class Timeout < Error; end

    Result = Struct.new(:text, :usage, :status, :model, keyword_init: true)

    def initialize(model: Config.llm_model)
      @model = model
    end

    def available? = Config.provider_configured?

    # purpose: "gaze" | "dream"
    def respond(system:, user:, purpose:, max_output_tokens:, timeout_ms:, schema: nil, schema_name: nil)
      raise Unavailable, "provider not configured" unless available?

      body = {
        "model" => @model,
        "reasoning" => { "effort" => Config.reasoning_effort },
        "max_output_tokens" => max_output_tokens,
        "store" => false,
        "input" => [
          { "role" => "system", "content" => system },
          { "role" => "user", "content" => user }
        ]
      }
      if schema
        body["text"] = {
          "format" => {
            "type" => "json_schema",
            "name" => schema_name || "decision",
            "strict" => true,
            "schema" => schema
          }
        }
      end

      response = connection(timeout_ms).post(endpoint) do |req|
        # /accounts/{id}/ai/* は Account > Workers AI > Read 権限の token を要求する。
        # AI Gateway 権限だけの token は 401 (code 10000) を返す。
        req.headers["Authorization"] = "Bearer #{Config.cf_api_token}"
        req.headers["Content-Type"] = "application/json"
        req.headers["cf-aig-gateway-id"] = Config.cf_gateway_id
        # gateway 側にも締切を渡す。こちらが諦めた後に provider が走り続けない。
        req.headers["cf-aig-request-timeout"] = timeout_ms.to_s
        # 自動再試行はしない。同じ思考を二度買わない。
        req.headers["cf-aig-max-attempts"] = "1"
        # prompt / response 本文は保存しない。token・cost 等の metadata だけ残す。
        req.headers["cf-aig-collect-log-payload"] = "false"
        req.headers["cf-aig-metadata"] = JSON.generate(
          "app" => "creature", "purpose" => purpose, "generation" => Body.generation.to_s
        )
        req.body = JSON.generate(body)
      end

      raise Throttled, "gateway spend limit or rate limit" if response.status == 429
      raise Error, "gateway status #{response.status}" unless response.status.between?(200, 299)

      parsed = JSON.parse(response.body.to_s)
      Result.new(text: extract_text(parsed), usage: parsed["usage"], status: response.status, model: @model)
    rescue Faraday::TimeoutError, Net::ReadTimeout => e
      raise Timeout, e.class.name
    rescue JSON::ParserError
      raise Error, "unparsable gateway response"
    end

    def endpoint
      "#{Config.cf_base_url}/accounts/#{Config.cf_account_id}/ai/v1/responses"
    end

    def connection(timeout_ms)
      Faraday.new do |f|
        f.options.timeout = timeout_ms / 1000.0
        f.options.open_timeout = [timeout_ms / 2000.0, 5.0].min
        f.adapter Faraday.default_adapter
      end
    end

    # Responses API は output[] の中に message / reasoning が混ざる。
    # output_text だけを拾う。
    def extract_text(parsed)
      return parsed["output_text"] if parsed["output_text"].is_a?(String)

      Array(parsed["output"]).flat_map do |item|
        next [] unless item.is_a?(Hash)

        Array(item["content"]).filter_map do |c|
          c["text"] if c.is_a?(Hash) && %w[output_text text].include?(c["type"])
        end
      end.join.strip
    end
  end
end
