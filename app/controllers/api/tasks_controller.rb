module Api
  # JSON API for tasks. Responses and error messages match the original Node.js app.
  class TasksController < ActionController::API
    rescue_from ActiveRecord::ActiveRecordError do |error|
      Rails.logger.error(error.full_message)
      render json: { error: "Database error" }, status: :internal_server_error
    end

    rescue_from ActionDispatch::Http::Parameters::ParseError do
      render json: { error: "Invalid JSON" }, status: :bad_request
    end

    # GET /api/tasks
    def index
      render json: Task.order(:id)
    end

    # POST /api/tasks
    def create
      title = params[:title].to_s.strip
      return render_error("Title is required", :bad_request) if title.empty?

      render json: Task.create!(title: title), status: :created
    end

    # PUT /api/tasks/:id (title, completed, or both)
    def update
      title = params.key?(:title) ? params[:title].to_s.strip : nil
      completed = params[:completed]

      return render_error("Title is required", :bad_request) if title == ""

      if params.key?(:completed) && ![ true, false ].include?(completed)
        return render_error("Completed must be true or false", :bad_request)
      end

      if title.nil? && !params.key?(:completed)
        return render_error("Nothing to update", :bad_request)
      end

      task = Task.find_by(id: params[:id])
      return render_error("Task not found", :not_found) unless task

      changes = {}
      changes[:title] = title unless title.nil?
      changes[:completed] = completed if params.key?(:completed)
      task.update!(changes)

      render json: task
    end

    # DELETE /api/tasks/:id
    def destroy
      task = Task.find_by(id: params[:id])
      return render_error("Task not found", :not_found) unless task

      task.destroy!
      render json: { message: "Task deleted successfully" }
    end

    private

    def render_error(message, status)
      render json: { error: message }, status: status
    end
  end
end
