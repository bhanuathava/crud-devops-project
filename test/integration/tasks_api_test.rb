require "test_helper"

class TasksApiTest < ActionDispatch::IntegrationTest
  def json
    JSON.parse(response.body)
  end

  test "health endpoint returns 200" do
    get "/up"
    assert_response :success
  end

  test "lists tasks ordered by id" do
    first = Task.create!(title: "First")
    second = Task.create!(title: "Second", completed: true)

    get "/api/tasks"

    assert_response :success
    assert_equal [
      { "id" => first.id, "title" => "First", "completed" => false },
      { "id" => second.id, "title" => "Second", "completed" => true }
    ], json
  end

  test "creates a task" do
    post "/api/tasks", params: { title: "  Write report  " }, as: :json

    assert_response :created
    assert_equal "Write report", json["title"]
    assert_equal false, json["completed"]
    assert_equal 1, Task.count
  end

  test "rejects a task without a title" do
    post "/api/tasks", params: { title: "   " }, as: :json

    assert_response :bad_request
    assert_equal({ "error" => "Title is required" }, json)
  end

  test "updates the title and keeps completed" do
    task = Task.create!(title: "Old", completed: true)

    put "/api/tasks/#{task.id}", params: { title: "New" }, as: :json

    assert_response :success
    assert_equal({ "id" => task.id, "title" => "New", "completed" => true }, json)
  end

  test "marks a task completed and not completed" do
    task = Task.create!(title: "Tick me")

    put "/api/tasks/#{task.id}", params: { completed: true }, as: :json
    assert_response :success
    assert_equal true, json["completed"]

    put "/api/tasks/#{task.id}", params: { completed: false }, as: :json
    assert_equal false, json["completed"]
  end

  test "rejects invalid updates" do
    task = Task.create!(title: "Task")

    put "/api/tasks/#{task.id}", params: { completed: "yes" }, as: :json
    assert_response :bad_request
    assert_equal "Completed must be true or false", json["error"]

    put "/api/tasks/#{task.id}", params: { title: "" }, as: :json
    assert_response :bad_request
    assert_equal "Title is required", json["error"]

    put "/api/tasks/#{task.id}", params: {}, as: :json
    assert_response :bad_request
    assert_equal "Nothing to update", json["error"]
  end

  test "returns 404 for unknown tasks" do
    put "/api/tasks/999999", params: { title: "x" }, as: :json
    assert_response :not_found
    assert_equal "Task not found", json["error"]

    delete "/api/tasks/999999"
    assert_response :not_found
  end

  test "deletes a task" do
    task = Task.create!(title: "Bye")

    delete "/api/tasks/#{task.id}"

    assert_response :success
    assert_equal({ "message" => "Task deleted successfully" }, json)
    assert_equal 0, Task.count
  end
end
