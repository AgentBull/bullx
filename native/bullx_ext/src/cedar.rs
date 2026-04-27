use std::str::FromStr;

use cedar_policy::{
  Authorizer, Context, Decision, Effect, Entities, EntityId, EntityTypeName, EntityUid, PolicySet,
  Request,
};
use rustler::types::map::MapIterator;
use rustler::{Encoder, Env, NifResult, Term, TermType};
use serde_json::{Map as JsonMap, Number as JsonNumber, Value as JsonValue};

use crate::encoding::error;

#[rustler::nif(schedule = "DirtyCpu")]
pub fn cedar_condition_validate(condition: Term<'_>) -> NifResult<bool> {
  let condition: String = condition
    .decode()
    .map_err(|_| error("condition must be a string"))?;

  parse_synthetic_policy_set(&condition)?;
  Ok(true)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn cedar_condition_eval<'a>(
  env: Env<'a>,
  condition: Term<'a>,
  request: Term<'a>,
) -> NifResult<Term<'a>> {
  let condition: String = condition
    .decode()
    .map_err(|_| error("condition must be a string"))?;

  let policy_set = parse_synthetic_policy_set(&condition)?;
  let data = decode_request(request)?;

  let entities = build_entities(&data)?;
  let cedar_request = build_request(&data)?;

  let authorizer = Authorizer::new();
  let response = authorizer.is_authorized(&cedar_request, &policy_set, &entities);

  Ok((response.decision() == Decision::Allow).encode(env))
}

struct RequestData {
  principal_type: String,
  principal_id: String,
  action_type: String,
  action_id: String,
  resource_type: String,
  resource_id: String,
  principal_attrs: JsonValue,
  context: JsonValue,
}

fn parse_synthetic_policy_set(condition: &str) -> NifResult<PolicySet> {
  let policy_text = format!(
    "permit(principal, action, resource) when {{\n{}\n}};",
    condition
  );

  let policy_set = PolicySet::from_str(&policy_text)
    .map_err(|e| error(format!("invalid cedar condition: {e}")))?;

  if policy_set.templates().count() > 0 {
    return Err(error("cedar templates are not allowed"));
  }

  let policies: Vec<_> = policy_set.policies().collect();
  if policies.len() != 1 {
    return Err(error(format!(
      "expected exactly one cedar policy, got {}",
      policies.len()
    )));
  }

  let policy = policies[0];

  if policy.effect() != Effect::Permit {
    return Err(error("only the permit effect is allowed"));
  }

  let policy_json = policy
    .to_json()
    .map_err(|e| error(format!("policy to json failed: {e}")))?;

  let conditions = policy_json
    .get("conditions")
    .and_then(|c| c.as_array())
    .ok_or_else(|| error("policy missing conditions array"))?;

  if conditions.len() != 1 {
    return Err(error(format!(
      "expected exactly one when clause, got {}",
      conditions.len()
    )));
  }

  let kind = conditions[0]
    .get("kind")
    .and_then(|k| k.as_str())
    .ok_or_else(|| error("condition missing kind"))?;

  if kind != "when" {
    return Err(error(format!(
      "only 'when' clauses are allowed, got '{kind}'"
    )));
  }

  Ok(policy_set)
}

fn decode_request(request: Term<'_>) -> NifResult<RequestData> {
  let map = require_map(request, "request")?;

  let principal_term = require_field(&map, "principal")?;
  let principal = require_map(principal_term, "principal")?;
  let principal_type = require_string_field(&principal, "type")?;
  let principal_id = require_string_field(&principal, "id")?;
  let principal_attrs_term = require_field(&principal, "attrs")?;
  let principal_attrs = term_to_json(principal_attrs_term)?;

  if !principal_attrs.is_object() {
    return Err(error("principal.attrs must be a map"));
  }

  let action_term = require_field(&map, "action")?;
  let action = require_map(action_term, "action")?;
  let action_type = require_string_field(&action, "type")?;
  let action_id = require_string_field(&action, "id")?;

  let resource_term = require_field(&map, "resource")?;
  let resource = require_map(resource_term, "resource")?;
  let resource_type = require_string_field(&resource, "type")?;
  let resource_id = require_string_field(&resource, "id")?;

  let context_term = require_field(&map, "context")?;
  let context = term_to_json(context_term)?;

  if !context.is_object() {
    return Err(error("context must be a map"));
  }

  Ok(RequestData {
    principal_type,
    principal_id,
    action_type,
    action_id,
    resource_type,
    resource_id,
    principal_attrs,
    context,
  })
}

fn build_entities(data: &RequestData) -> NifResult<Entities> {
  let entities_json = JsonValue::Array(vec![JsonValue::Object({
    let mut map = JsonMap::new();
    map.insert(
      "uid".into(),
      JsonValue::Object({
        let mut uid = JsonMap::new();
        uid.insert(
          "type".into(),
          JsonValue::String(data.principal_type.clone()),
        );
        uid.insert("id".into(), JsonValue::String(data.principal_id.clone()));
        uid
      }),
    );
    map.insert("attrs".into(), data.principal_attrs.clone());
    map.insert("parents".into(), JsonValue::Array(vec![]));
    map
  })]);

  Entities::from_json_value(entities_json, None)
    .map_err(|e| error(format!("failed to build entities: {e}")))
}

fn build_request(data: &RequestData) -> NifResult<Request> {
  let principal_uid = build_uid(&data.principal_type, &data.principal_id)?;
  let action_uid = build_uid(&data.action_type, &data.action_id)?;
  let resource_uid = build_uid(&data.resource_type, &data.resource_id)?;

  let context = Context::from_json_value(data.context.clone(), None)
    .map_err(|e| error(format!("invalid cedar context: {e}")))?;

  Request::new(principal_uid, action_uid, resource_uid, context, None)
    .map_err(|e| error(format!("invalid cedar request: {e}")))
}

fn build_uid(type_name: &str, id: &str) -> NifResult<EntityUid> {
  let type_name = EntityTypeName::from_str(type_name)
    .map_err(|e| error(format!("invalid entity type {type_name:?}: {e}")))?;

  let id = EntityId::from_str(id).map_err(|e| error(format!("invalid entity id {id:?}: {e}")))?;

  Ok(EntityUid::from_type_name_and_id(type_name, id))
}

fn require_map<'a>(
  term: Term<'a>,
  field: &str,
) -> NifResult<std::collections::HashMap<String, Term<'a>>> {
  if term.get_type() != TermType::Map {
    return Err(error(format!("{field} must be a map")));
  }

  let mut out = std::collections::HashMap::new();

  for (k, v) in MapIterator::new(term).ok_or_else(|| error(format!("{field} must be a map")))? {
    let key: String = k
      .decode()
      .map_err(|_| error(format!("{field} keys must be strings")))?;
    out.insert(key, v);
  }

  Ok(out)
}

fn require_field<'a>(
  map: &std::collections::HashMap<String, Term<'a>>,
  key: &str,
) -> NifResult<Term<'a>> {
  map
    .get(key)
    .copied()
    .ok_or_else(|| error(format!("missing required field {key:?}")))
}

fn require_string_field(
  map: &std::collections::HashMap<String, Term<'_>>,
  key: &str,
) -> NifResult<String> {
  let term = require_field(map, key)?;
  term
    .decode()
    .map_err(|_| error(format!("field {key:?} must be a string")))
}

fn term_to_json(term: Term<'_>) -> NifResult<JsonValue> {
  match term.get_type() {
    TermType::Atom => atom_to_json(term),
    TermType::Binary => term
      .decode::<String>()
      .map(JsonValue::String)
      .map_err(|_| error("binary value must be valid utf-8")),
    TermType::Integer => term
      .decode::<i64>()
      .map(|n| JsonValue::Number(JsonNumber::from(n)))
      .map_err(|_| error("integer out of range")),
    TermType::List => list_to_json(term),
    TermType::Map => map_to_json(term),
    other => Err(error(format!("unsupported term type: {other:?}"))),
  }
}

fn atom_to_json(term: Term<'_>) -> NifResult<JsonValue> {
  let atom_name: String = term
    .atom_to_string()
    .map_err(|_| error("atom decode failed"))?;

  match atom_name.as_str() {
    "true" => Ok(JsonValue::Bool(true)),
    "false" => Ok(JsonValue::Bool(false)),
    "nil" => Err(error("nil values are not allowed")),
    other => Ok(JsonValue::String(other.to_string())),
  }
}

fn list_to_json(term: Term<'_>) -> NifResult<JsonValue> {
  let iter: rustler::types::list::ListIterator =
    term.decode().map_err(|_| error("invalid list value"))?;

  let mut values = Vec::new();
  for element in iter {
    values.push(term_to_json(element)?);
  }

  Ok(JsonValue::Array(values))
}

fn map_to_json(term: Term<'_>) -> NifResult<JsonValue> {
  let mut object = JsonMap::new();

  for (k, v) in MapIterator::new(term).ok_or_else(|| error("invalid map value"))? {
    let key: String = k.decode().map_err(|_| error("map keys must be strings"))?;

    object.insert(key, term_to_json(v)?);
  }

  Ok(JsonValue::Object(object))
}
