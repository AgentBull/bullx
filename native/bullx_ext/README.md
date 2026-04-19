# NIF for BullX

This directory contains a Rust NIF (Native Implemented Function) module for the BullX project. NIFs allow you to write performance-critical code in Rust and call it from Elixir.

## To build the NIF module:

- Your NIF will now build along with your project.

## To load the NIF:

```elixir
defmodule BullX.Ext do
  use Rustler, otp_app: :bullx, crate: "bullx_ext"

  # When your NIF is loaded, it will override this function.
  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
end
```

## Examples

[This](https://github.com/rusterlium/NifIo) is a complete example of a NIF written in Rust.
