module Api
  class NamesController < BaseController
    before_action :authenticate_device!, only: :create

    # GET /check/:guid/:name
    def show
      name = leaderboard_name
      device = Device.find_by(guid: guid)
      available, reason = Device.name_availability(name, device: device)
      body = { name: name, available: available }
      body[:reason] = reason if reason
      render json: body
    end

    # POST /name/:guid/:name
    def create
      name = leaderboard_name
      fail!(:bad_request, "invalid name: 3-24 letters, digits, spaces, _ - . starting and ending with a letter or digit") unless Device.valid_name?(name)

      available, _reason = Device.name_availability(name, device: @device)
      return render_unavailable(name) unless available

      begin
        @device.update!(name: name)
      rescue ActiveRecord::RecordNotUnique
        # Someone else claimed the same (case-insensitive) name between the check and the save.
        return render_unavailable(name)
      end
      record_visit
      render json: { status: "success", name: @device.name }
    end

    private

    def render_unavailable(name)
      render json: { status: "unavailable", name: name }, status: :conflict
    end
  end
end
