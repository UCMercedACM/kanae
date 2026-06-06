variable "url" {
  type        = string
  description = "The URL used for the database"
}

variable "dev_url" {
  type        = string
  description = "The database to point to that MUST have pg_trgm installed to make Atlas not complain that gin operators don't exist"
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
    src = "file://src/schema.sql"
  }
}
