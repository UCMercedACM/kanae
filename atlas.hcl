variable "url" {
  type        = string
  description = "The URL used for the database"
}

env "dev" {
  schema {
    src = "file://server/schema.sql"
    repo {
      name = "kanae"
    }
  }
  url = var.url
  dev = "docker://postgres/17/dev?search_path=public"
}

env "prod" {
  schema {
    src = "file://server/schema.sql"
    repo {
      name = "kanae"
    }
  }
}