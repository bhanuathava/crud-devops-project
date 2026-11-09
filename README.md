# crud-devops-project – Task Manager

A Ruby on Rails rewrite of the course's Node.js CRUD application. It keeps the same REST endpoints and JSON responses, and stores tasks in MySQL. Tasks can be created, read, updated, deleted and marked as completed.

## Versions

| Component | Version |
|---|---|
| Ruby | 3.3 (see `.ruby-version`) |
| Rails | 8.1 |
| Application server | Puma (shipped with Rails) |
| Database | MySQL (via the `mysql2` gem) |

## Endpoints

| Method | Path | Body | Success | Errors |
|---|---|---|---|---|
| GET | `/` | – | Task manager web page | – |
| GET | `/up` | – | `200` when the app has booted | `500` |
| GET | `/api/tasks` | – | `200` list of tasks, ordered by id | – |
| POST | `/api/tasks` | `{"title": "..."}` | `201` created task | `400` Title is required |
| PUT | `/api/tasks/:id` | `{"title": "..."}` and/or `{"completed": true}` | `200` updated task | `400` invalid input, `404` Task not found |
| DELETE | `/api/tasks/:id` | – | `200` `{"message": "Task deleted successfully"}` | `404` Task not found |

A task looks like this:

```json
{ "id": 1, "title": "Write report", "completed": false }
```

## Project structure (application code)

```
app/controllers/api/tasks_controller.rb   # REST API for tasks
app/models/task.rb                        # Task model and validations
config/routes.rb                          # /api/tasks routes and /up health check
config/database.yml                       # MySQL connection (from environment variables)
config/puma.rb                            # Puma threads and workers
db/migrate/                               # Migration that creates the tasks table
public/index.html                         # Web page (task list, checkboxes, progress bar)
test/integration/tasks_api_test.rb        # Tests for every endpoint
```

## Configuration (environment variables)

| Variable | Default | Description |
|---|---|---|
| `RAILS_ENV` | `development` | `development`, `test` or `production` |
| `PORT` | `3000` | Port Puma listens on |
| `DB_HOST` | `127.0.0.1` | MySQL host name |
| `DB_PORT` | `3306` | MySQL port |
| `DB_USERNAME` | `root` | MySQL user |
| `DB_PASSWORD` | empty | MySQL password |
| `DB_NAME` | `crud_devops_project_<environment>` | Database name (development and production) |
| `RAILS_MAX_THREADS` | `3` | Puma threads per worker, also the database connection pool size |
| `WEB_CONCURRENCY` | `0` | Puma worker processes (`0` = single process) |
| `SECRET_KEY_BASE` or `RAILS_MASTER_KEY` | – | Required in production |
| `FORCE_SSL` | `false` | Set to `true` only when the app runs behind an HTTPS proxy |
| `RAILS_LOG_LEVEL` | `info` | Production log level |

## Run locally on macOS

1. Install Ruby 3.3 and MySQL, and start MySQL:

   ```bash
   brew install ruby@3.3 mysql
   brew services start mysql
   ```

2. Install the gems:

   ```bash
   bundle install
   ```

3. Create the database and run the migration:

   ```bash
   bin/rails db:prepare
   ```

4. Start the server:

   ```bash
   bin/rails server
   ```

5. Open http://localhost:3000

## Database migrations

The `tasks` table is created by the migration in `db/migrate/`. `bin/rails db:prepare` creates the database if it does not exist and runs any pending migrations, so it is safe to run on every start.

## Run the tests

```bash
bin/rails test
```

## Puma settings

Puma runs `WEB_CONCURRENCY` worker processes, each with `RAILS_MAX_THREADS` threads. The total number of requests handled at the same time is workers × threads (with `WEB_CONCURRENCY=0`, it is one process × threads). Each thread needs its own database connection, so the connection pool size follows `RAILS_MAX_THREADS`.
