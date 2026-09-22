# Start only the local RSI HTTP front (port 18803) for this harness.
#
# The in-UI "Memory & learning" panel is a client plugin: it POSTs to the harness
# route `/local-rsi-api`, and the `@local/rsi-ui` host half proxies that to
# `http://127.0.0.1:18803/rsi/ui`. `service.py` is the server that answers it.
#
# `service.py` on its own also calls wake_model() (CUDA llama-server) and starts
# a second DeepSeek web UI on 18801. Neither is needed to read or manage memory:
# every operation local_ui.dispatch implements reads records, SQLite and the
# filesystem. Running `--front-only` therefore gives the panel its data without
# touching the GPU, which matters on a machine where another install already owns
# the CUDA model.
#
# Stop it with `rsi\stop.ps1` (creates the STOP marker the service polls) or by
# stopping the process listening on 18803.
. "$PSScriptRoot/env.ps1"
Set-Location $PSScriptRoot
& $RsiPython -B -u "$PSScriptRoot/service.py" --front-only
exit $LASTEXITCODE
