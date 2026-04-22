# Archdo configuration — generated for Phoenix project
[
  # Layer definitions
  layers: [
    interface: ~r/^BullxWeb\./,
    domain: ~r/^Bullx\.(?!Repo|Mailer)/,
    infrastructure: ~r/^Bullx\.(Repo|Mailer)/
  ],

  # Allowed dependency direction (interface → domain → infrastructure)
  allowed_deps: %{
    interface: [:domain, :infrastructure],
    domain: [:infrastructure],
    infrastructure: []
  }

  # Severity overrides (uncomment to customize)
  # overrides: [
  #   {:"5.6", :ignore},           # Accept default supervisor restarts
  #   {:"6.4", severity: :info},    # Downgrade long files to info
  # ]
]
