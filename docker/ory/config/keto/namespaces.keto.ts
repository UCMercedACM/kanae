import { Namespace, Context, SubjectSet } from "@ory/permission-namespace-types"

class User implements Namespace {}

class Role implements Namespace {
  related: {
    member: User[]
  }
}

class Project implements Namespace {
  related: {
    viewers: (User | SubjectSet<Project, "editors">)[]
    editors: (User | SubjectSet<Project, "owners">)[]
    owners: (User | SubjectSet<Role, "member">)[]
  }

  permits = {
    view: (ctx: Context): boolean =>
      this.related.viewers.includes(ctx.subject) ||
      this.related.editors.includes(ctx.subject) ||
      this.related.owners.includes(ctx.subject),

    edit: (ctx: Context): boolean =>
      this.related.editors.includes(ctx.subject) ||
      this.related.owners.includes(ctx.subject),

    own: (ctx: Context): boolean =>
      this.related.owners.includes(ctx.subject),
  }
}

class Event implements Namespace {
  related: {
    viewers: (User | SubjectSet<Event, "editors">)[]
    editors: (User | SubjectSet<Event, "owners">)[]
    owners: (User | SubjectSet<Role, "member">)[]
  }

  permits = {
    view: (ctx: Context): boolean =>
      this.related.viewers.includes(ctx.subject) ||
      this.related.editors.includes(ctx.subject) ||
      this.related.owners.includes(ctx.subject),

    edit: (ctx: Context): boolean =>
      this.related.editors.includes(ctx.subject) ||
      this.related.owners.includes(ctx.subject),

    own: (ctx: Context): boolean =>
      this.related.owners.includes(ctx.subject),
  }
}
