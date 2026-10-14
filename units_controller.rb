module Api
  # Serves config/units.json ("New Entropy" silly units) with a strong ETag.
  class UnitsController < BaseController
    skip_before_action :require_protocol_headers

    def show
      units = Units.current
      response.headers["Cache-Control"] = "public, max-age=3600"
      response.headers["ETag"] = units.etag
      if etag_matches?(units.etag)
        head :not_modified
      else
        render body: units.json, content_type: "application/json; charset=utf-8"
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
