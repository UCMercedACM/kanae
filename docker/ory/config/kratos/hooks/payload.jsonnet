function(ctx) {
  flow_id: ctx.flow.id,
  identity: {
    id: ctx.identity.id,
    schema_id: ctx.identity.schema_id,
    traits: ctx.identity.traits,
  },
}
