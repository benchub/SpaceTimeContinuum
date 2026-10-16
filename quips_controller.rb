module Api
  # Serves config/quips.json ("New Entropy" stretch reminders) with a strong ETag.
  # Needs a `Quips.current` (like `Units.current`, returning an object with #json and #etag)
  # and a `get "quips", to: "quips#show"` route next to the units one.
  class QuipsController < BaseController
    skip_before_action :require_protocol_headers

    def show
      quips = Quips.current
      response.headers["Cache-Control"] = "public, max-age=3600"
      response.headers["ETag"] = quips.etag
      if etag_matches?(quips.etag)
        head :not_modified
      else
        render body: quips.json, content_type: "application/json; charset=utf-8"
      end
    end

    private

    def etag_matches?(etag)
      header = request.headers["If-None-Match"].to_s
      return false if header.empty?
      header.split(",").map { |t| t.strip.delete_prefix("W/") }.any? { |t| t == etag || t == "*" }
    end
  end
end
