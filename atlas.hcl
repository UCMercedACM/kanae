variable "host" {
  type        = string
  description = "The database host. The kanae-migrate Job passes serviceNames.database through --var"
  default     = "database"
}

variable "url" {
  type        = string
  description = "The URL used for the database"
  default     = ""
}

variable "dev_url" {
  type        = string
  description = "The database to point to that MUST have pg_trgm installed to make Atlas not complain that gin operators don't exist"
  default     = ""
}

env "dev" {
  schema {
    src = "file://src/schema.sql"
  }
  url = var.url
  dev = var.dev_url
}


env "prod" {
  schema {
    src = "file:///etc/atlas/schema.sql"
  }
  url = "postgres://kanae_migrate:${urlescape(file("/run/secrets/KANAE_MIGRATE_PASSWORD"))}@${var.host}:5432/kanae?search_path=public&sslmode=disable"
  dev = "postgres://kanae_migrate:${urlescape(file("/run/secrets/KANAE_MIGRATE_PASSWORD"))}@${var.host}:5432/postgres?search_path=public&sslmode=disable"
}
