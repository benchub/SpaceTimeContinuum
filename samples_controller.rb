module Api
  class SamplesController < BaseController
    MAX_SAMPLES = 1440
    MAX_BODY_BYTES = 2.megabytes

    before_action :authenticate_device!

    # POST /sample/:guid
    def create
      body = parse_body
      samples = body["samples"]
      fail!(:bad_request, "samples must be an array") unless samples.is_a?(Array)
      fail!(:content_too_large, "too many samples (max #{MAX_SAMPLES})") if samples.size > MAX_SAMPLES
      unless samples.all? { |s| s.is_a?(Hash) && s["minute_start"].is_a?(Integer) }
        fail!(:bad_request, "every sample must be an object with an integer minute_start")
      end

      now = Time.current.to_i
      accepted = []
      rejected = []
      valid = []
      seen = Set.new
      samples.each do |s|
        minute = s["minute_start"]
        next unless seen.add?(minute)
        if (reason = Sample.rejection_reason(s, now: now))
          rejected << { minute_start: minute, reason: reason }
        else
          accepted << minute
          valid << s
        end
      end

      Sample.ingest(@device, valid)
      record_visit(utc_offset_s: body["utc_offset_s"])

      render json: { status: "ok", accepted: accepted, rejected: rejected }
    end

    private

    def parse_body
      raw = request.raw_post.to_s
      fail!(:content_too_large, "request body too large") if raw.bytesize > MAX_BODY_BYTES
      body = JSON.parse(raw)
      fail!(:bad_request, "body must be a JSON object") unless body.is_a?(Hash)
      body
    rescue JSON::ParserError
      fail!(:bad_request, "malformed JSON")
    end
  end
end
