variable "url" {
  type        = string
  description = "The URL used for the database"
}

env "dev" {
  schema {
    src = "file://server/schema.sql"
  }
  url = var.url
  dev = "docker://postgres/18/dev?search_path=public"
}

env "prod" {
  schema {
    src = "file://server/schema.sql"
  }
}
