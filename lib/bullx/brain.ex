defmodule BullX.Brain do
  @moduledoc """
  Persistent memory and knowledge graph. A typed ontology of objects, links, and
  properties forms the skeleton; `(observer, observed)`-keyed cortexes hold
  engrams (LLM-extracted reasoning traces at distinct inference levels). A
  background Dreamer process consolidates engrams, detects contradictions, and
  promotes abstraction level.

  RFC-000 establishes the namespace and an empty top-level supervisor; memory
  and knowledge services are added by later RFCs.
  """
end
